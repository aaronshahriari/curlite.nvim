--- The response window.
---
--- One reusable scratch buffer per pane, shown in one window. The body pane is
--- kept *pure* -- nothing but the response body -- so treesitter highlights it
--- properly and a `jq` filter can run over it. Status, timing and the pane
--- list all live in the winbar instead of being written into the buffer.

local config = require("curlite.config")
local format = require("curlite.format")
local response = require("curlite.response")
local scripts = require("curlite.scripts")
local size = require("curlite.size")
local util = require("curlite.util")

local M = {}

local NS = vim.api.nvim_create_namespace("curlite")
local INLINE_NS = vim.api.nvim_create_namespace("curlite_inline")
local FLASH_NS = vim.api.nvim_create_namespace("curlite_flash")

-- Above `curlite.highlight`'s marks (200), so the flash is visible over the
-- method and URL colouring rather than hidden behind it.
local PRIORITY_FLASH = 300

-- One scratch buffer per pane, created lazily and reused.
---@type table<string, integer>
local buffers = {}

M.winid = nil ---@type integer|nil
M.pane = nil ---@type string|nil

-- Ring of past results, newest last.
---@type curlite.Result[]
M.history = {}
M.history_index = 0 ---@type integer  1-based; 0 means "nothing yet"

-- A live jq filter applied to the body pane, per history entry.
local filter_expr = nil

-- Formatting a body costs real time on a large response, and `render_body`
-- runs on every pane switch, every history step and every redraw of the `all`
-- pane. Memoise it per result.
--
-- Bounded, and deliberately small. Weak keys alone are not a bound: a result
-- stays alive as long as it is in the history ring, so caching every one meant
-- holding the split lines of fifty responses -- which cost more than the
-- bodies themselves. You look at one or two responses at a time; caching more
-- buys nothing.
local BODY_CACHE_MAX = 4

---@type table<table, { key: string, lines: string[], ft: string|nil, seq: integer }>
local body_cache = setmetatable({}, { __mode = "k" })
local body_cache_seq = 0

---@param result table
---@param entry { key: string, lines: string[], ft: string|nil }
local function body_cache_put(result, entry)
  body_cache_seq = body_cache_seq + 1
  entry.seq = body_cache_seq
  body_cache[result] = entry

  local count, oldest, oldest_seq = 0, nil, math.huge
  for key, value in pairs(body_cache) do
    count = count + 1
    if value.seq < oldest_seq then
      oldest, oldest_seq = key, value.seq
    end
  end
  if count > BODY_CACHE_MAX and oldest then
    body_cache[oldest] = nil
  end
end

-- What each pane's buffer currently holds. Cycling back to a pane you have
-- already seen should cost nothing: the buffer still has the right text, and
-- rewriting thirty thousand lines to produce the same result is pure waste.
-- Values are weak, so a result dropped from the history ring is not pinned
-- here -- and when it goes, the entry reads as nil and the pane redraws.
---@type table<string, table>
local drawn_result = setmetatable({}, { __mode = "v" })
---@type table<string, string>
local drawn_key = {}

--- A cheap discriminator for "is this the same thing I last drew?".
---
--- Identity alone would be wrong: `show()` is public, and a caller that mutates
--- a result and shows it again deserves to see the change. These fields cover
--- every part of a result that can sensibly differ, and none of them costs more
--- than reading a number.
---@param result curlite.Result
---@return string
local function signature(result)
  local resp = result.response
  return table.concat({
    filter_expr or "",
    resp and resp.status or -1,
    resp and #resp.body or -1,
    resp and resp.duration_ms or -1,
    resp and #resp.hops or -1,
    result.error or "",
    result.skipped and 1 or 0,
    #((result.script or {}).tests or {}),
    #((result.script or {}).logs or {}),
  }, "\1")
end

-- Where a split response window was immediately before it was hidden. Floats
-- and tabs keep their configured behaviour; ordinary splits are restored next
-- to the same window, at the same edge and size.
---@type { tab: integer, axis: "row"|"col", after: boolean, anchor: integer, root_edge: boolean, width: number, height: number }|nil
local saved_split = nil

local PANE_LABELS = {
  body = "Body",
  headers = "Headers",
  all = "All",
  stats = "Stats",
  verbose = "Verbose",
  script = "Script",
}

--- Define the plugin's highlight groups as links, so a colorscheme change is
--- picked up without curlite doing anything.
function M.setup_highlights()
  local hl = config.get().ui.highlights
  local links = {
    CurliteSuccess = hl.success,
    CurliteRedirect = hl.redirect,
    CurliteClientError = hl.client_error,
    CurliteServerError = hl.server_error,
    CurliteRunning = hl.running,
    CurliteInline = hl.inline,
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  -- The rest are fixed links rather than config, because they describe
  -- curlite's own layout rather than a response's meaning. Override any of
  -- them with `:highlight` -- `default = true` means yours wins.
  local fixed = {
    -- the brief highlight over a request as it is sent
    CurliteFlash = "Visual",
    -- winbar
    CurlitePaneActive = "TabLineSel",
    CurlitePaneInactive = "TabLine",
    -- headers / request panes
    CurliteHeaderName = "Identifier",
    CurliteHeaderValue = "String",
    CurliteMethod = "Keyword",
    CurliteUrl = "Underlined",
    CurliteStatusLine = "Title",
    CurliteRule = "WinSeparator",
    -- stats pane
    CurliteSection = "Title",
    CurliteLabel = "Comment",
    CurliteValue = "Normal",
    CurliteTotal = "Special",
    -- script pane
    CurliteTestPass = "DiagnosticOk",
    CurliteTestFail = "DiagnosticError",
    CurliteTestName = "Normal",
    CurliteTestDetail = "Comment",
    CurliteLogLine = "Normal",
    -- environment picker
    CurliteEnvActive = "DiagnosticOk",
    CurliteEnvName = "Normal",
    CurliteEnvCount = "Comment",
    CurliteEnvOrigin = "Comment",
  }
  for name, target in pairs(fixed) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

---@param status integer
---@return string  highlight group
local function status_hl(status)
  return ({
    success = "CurliteSuccess",
    redirect = "CurliteRedirect",
    client_error = "CurliteClientError",
    server_error = "CurliteServerError",
  })[response.grade(status)]
end

---@param status integer
---@return string
local function status_icon(status)
  local icons = config.get().ui.icons
  local grade = response.grade(status)
  if grade == "success" then
    return icons.success
  elseif grade == "redirect" then
    return icons.redirect
  end
  return icons.error
end

--- Get (creating if needed) the scratch buffer for a pane.
---@param pane string
---@return integer
local function pane_buffer(pane)
  local buf = buffers[pane]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, ("curlite://%s"):format(pane))
  buffers[pane] = buf
  M.apply_result_keymaps(buf)
  return buf
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

--- ------------------------------------------------------------------ panes

---@param result curlite.Result
---@return string[] lines, string|nil filetype
local function render_body(result)
  local resp = result.response
  if not resp then
    return { result.error or "no response" }, nil
  end

  local key = signature(result)
  local cached = body_cache[result]
  if cached and cached.key == key then
    return cached.lines, cached.ft
  end

  -- `headers` is case-insensitive, so one spelling is enough.
  local ctype = resp.headers["Content-Type"] or ""

  local function remember(lines, ft)
    body_cache_put(result, { key = key, lines = lines, ft = ft })
    return lines, ft
  end

  if resp.body == "" then
    return remember({ ("(empty body — %d %s)"):format(resp.status, resp.status_text) }, nil)
  end

  if format.is_binary(resp.body, ctype) then
    return remember({
      ("(binary response — %s, %s)"):format(
        ctype ~= "" and ctype or "unknown type",
        util.human_size(#resp.body)
      ),
      "",
      "Press `gs` to save it to a file.",
    }, nil)
  end

  if filter_expr and filter_expr ~= "" then
    local filtered, err = format.jq(resp.body, filter_expr)
    if filtered then
      return remember(vim.split(filtered, "\n", { plain = true }), "json")
    end
    return remember(
      { ("jq: %s"):format(err), "", "Press `/` to change the filter, `<Esc>` to clear it." },
      nil
    )
  end

  local formatted, ft = format.body(resp.body, ctype)
  return remember(vim.split(formatted, "\n", { plain = true }), ft)
end

---@param result curlite.Result
---@return string[] lines, table[] marks
local function render_headers(result)
  local resp = result.response
  local lines, marks = {}, {}
  if not resp then
    return { result.error or "no response" }, marks
  end

  for hop_idx, hop in ipairs(resp.hops) do
    if hop_idx > 1 then
      table.insert(lines, "")
    end
    local status_line = ("%s %d %s"):format(hop.http_version, hop.status, hop.status_text)
    table.insert(lines, status_line)
    table.insert(marks, {
      line = #lines - 1,
      col = 0,
      end_col = #hop.http_version,
      hl = "CurliteStatusLine",
    })
    table.insert(marks, {
      line = #lines - 1,
      col = #hop.http_version + 1,
      end_col = -1,
      hl = status_hl(hop.status),
    })

    local names = vim.deepcopy(hop.header_order)
    table.sort(names, function(a, b)
      return a:lower() < b:lower()
    end)
    for _, name in ipairs(names) do
      local text = ("%s: %s"):format(name, hop.headers[name])
      table.insert(lines, text)
      table.insert(marks, { line = #lines - 1, col = 0, end_col = #name + 1, hl = "CurliteHeaderName" })
      table.insert(marks, { line = #lines - 1, col = #name + 2, end_col = #text, hl = "CurliteHeaderValue" })
    end
  end

  return lines, marks
end

---@param result curlite.Result
---@return string[] lines, table[] marks
local function render_all(result)
  local cfg = config.get()
  local lines, marks = {}, {}
  local req = result.request

  if cfg.response.show_request and req then
    local reqline = ("%s %s"):format(req.method, req.url)
    table.insert(lines, reqline)
    table.insert(marks, { line = 0, col = 0, end_col = #req.method, hl = "CurliteMethod" })
    table.insert(marks, { line = 0, col = #req.method + 1, end_col = -1, hl = "CurliteUrl" })

    local names = vim.deepcopy(req.header_order or {})
    table.sort(names, function(a, b)
      return a:lower() < b:lower()
    end)
    for _, name in ipairs(names) do
      if req.headers[name] then
        local text = ("%s: %s"):format(name, req.headers[name])
        table.insert(lines, text)
        table.insert(marks, { line = #lines - 1, col = 0, end_col = #name + 1, hl = "CurliteHeaderName" })
        table.insert(marks, { line = #lines - 1, col = #name + 2, end_col = -1, hl = "CurliteHeaderValue" })
      end
    end

    if result.command and result.command.sent_body then
      table.insert(lines, "")
      vim.list_extend(lines, vim.split(result.command.sent_body, "\n", { plain = true }))
    end
    table.insert(lines, "")
    table.insert(lines, ("─"):rep(40))
    table.insert(marks, { line = #lines - 1, col = 0, end_col = -1, hl = "CurliteRule" })
    table.insert(lines, "")
  end

  local hdr_lines, hdr_marks = render_headers(result)
  local offset = #lines
  vim.list_extend(lines, hdr_lines)
  for _, mark in ipairs(hdr_marks) do
    mark.line = mark.line + offset
    table.insert(marks, mark)
  end

  table.insert(lines, "")
  vim.list_extend(lines, (render_body(result)))

  return lines, marks
end

---@param result curlite.Result
---@return string[] lines, table[] marks
local function render_stats(result)
  local resp = result.response
  local lines, marks = {}, {}
  if not resp then
    return { result.error or "no response" }, marks
  end
  local s = resp.stats or {}

  -- Labels are padded into a fixed column so the values line up; the mark
  -- offsets below depend on that width.
  local LABEL_WIDTH = 22
  local VALUE_COL = 2 + LABEL_WIDTH + 1

  ---@param label string
  ---@param value string
  ---@param hl string|nil  overrides CurliteValue for this row
  local function row(label, value, hl)
    table.insert(lines, ("  %-" .. LABEL_WIDTH .. "s %s"):format(label, value))
    local line = #lines - 1
    table.insert(marks, { line = line, col = 2, end_col = 2 + #label, hl = "CurliteLabel" })
    table.insert(marks, { line = line, col = VALUE_COL, end_col = -1, hl = hl or "CurliteValue" })
    return line
  end

  local function section(title)
    if #lines > 0 then
      table.insert(lines, "")
    end
    table.insert(lines, title)
    table.insert(marks, { line = #lines - 1, col = 0, end_col = #title, hl = "CurliteSection" })
  end

  local function ms(v)
    return v and util.human_time(v * 1000) or "—"
  end

  section("Response")
  row("Status", ("%d %s"):format(resp.status, resp.status_text), status_hl(resp.status))
  row("HTTP version", resp.http_version ~= "" and resp.http_version or (s.http_version or "—"))
  row("Method", result.request and result.request.method or s.method or "—")
  row("Content type", resp.headers["Content-Type"] or s.content_type or "—")
  row("URL", s.url_effective or result.request.url, "CurliteUrl")
  if (s.num_redirects or 0) > 0 then
    row("Redirects", tostring(s.num_redirects))
  end

  section("Timing")
  row("DNS lookup", ms(s.time_namelookup))
  row("TCP connect", ms(s.time_connect and s.time_connect - (s.time_namelookup or 0)))
  if (s.time_appconnect or 0) > 0 then
    row("TLS handshake", ms(s.time_appconnect - (s.time_connect or 0)))
  end
  row("Request sent", ms(s.time_pretransfer and s.time_pretransfer - (s.time_appconnect or s.time_connect or 0)))
  row("Waiting (TTFB)", ms(s.time_starttransfer and s.time_starttransfer - (s.time_pretransfer or 0)))
  row("Download", ms(s.time_total and s.time_total - (s.time_starttransfer or 0)))
  row("Total", util.human_time(resp.duration_ms), "CurliteTotal")

  section("Size")
  row("Response body", util.human_size(math.floor(s.size_download or #resp.body)))
  row("Response headers", util.human_size(math.floor(s.size_header or #resp.raw_headers)))
  row("Request sent", util.human_size(math.floor(s.size_request or 0)))
  if (s.size_upload or 0) > 0 then
    row("Request body", util.human_size(math.floor(s.size_upload)))
  end
  if (s.speed_download or 0) > 0 then
    row("Download speed", util.human_size(math.floor(s.speed_download)) .. "/s")
  end

  section("Connection")
  row("Remote", ("%s:%s"):format(s.remote_ip or "—", s.remote_port or "—"))
  row("Local port", tostring(s.local_port or "—"))
  row("Connections", tostring(s.num_connects or 0))
  if s.ssl_verify_result ~= nil then
    row(
      "TLS verify",
      s.ssl_verify_result == 0 and "ok" or ("failed (%s)"):format(s.ssl_verify_result),
      s.ssl_verify_result == 0 and "CurliteSuccess" or "CurliteServerError"
    )
  end

  if next(resp.cookies or {}) then
    section("Cookies set")
    local names = vim.tbl_keys(resp.cookies)
    table.sort(names)
    for _, name in ipairs(names) do
      row(name, resp.cookies[name])
    end
  end

  return lines, marks
end

---@param result curlite.Result
---@return string[] lines
local function render_verbose(result)
  local resp = result.response
  if not resp or resp.verbose == "" then
    return { "(no verbose output)" }
  end
  return vim.split((resp.verbose:gsub("\r", "")), "\n", { plain = true })
end

---@param result curlite.Result
---@return string[] lines, table[] marks
local function render_script(result)
  local lines, marks = {}, {}
  local sr = result.script

  if not sr or (#sr.logs == 0 and #sr.tests == 0 and not sr.error) then
    return { "(no script output)" }, marks
  end

  local function section(title, hl)
    if #lines > 0 then
      table.insert(lines, "")
    end
    table.insert(lines, title)
    table.insert(marks, { line = #lines - 1, col = 0, end_col = -1, hl = hl or "CurliteSection" })
  end

  if sr.error then
    section("Error", "CurliteTestFail")
    for _, l in ipairs(vim.split(sr.error, "\n", { plain = true })) do
      table.insert(lines, "  " .. l)
      table.insert(marks, { line = #lines - 1, col = 0, end_col = -1, hl = "CurliteTestFail" })
    end
  end

  if #sr.logs > 0 then
    section("Log")
    for _, log in ipairs(sr.logs) do
      for _, l in ipairs(vim.split(log, "\n", { plain = true })) do
        table.insert(lines, "  " .. l)
        table.insert(marks, { line = #lines - 1, col = 2, end_col = -1, hl = "CurliteLogLine" })
      end
    end
  end

  if #sr.tests > 0 then
    local passed, failed = scripts.tally(sr)
    local tally = ("%d passed, %d failed"):format(passed, failed)
    if #lines > 0 then
      table.insert(lines, "")
    end
    table.insert(lines, ("Tests  %s"):format(tally))
    table.insert(marks, { line = #lines - 1, col = 0, end_col = 5, hl = "CurliteSection" })
    table.insert(marks, {
      line = #lines - 1,
      col = 7,
      end_col = -1,
      hl = failed > 0 and "CurliteTestFail" or "CurliteTestPass",
    })

    for _, test in ipairs(sr.tests) do
      local icon = test.ok and "✓" or "✗"
      table.insert(lines, ("  %s %s"):format(icon, test.name))
      local line = #lines - 1
      table.insert(marks, {
        line = line,
        col = 2,
        end_col = 2 + #icon,
        hl = test.ok and "CurliteTestPass" or "CurliteTestFail",
      })
      table.insert(marks, {
        line = line,
        col = 3 + #icon,
        end_col = -1,
        hl = test.ok and "CurliteTestName" or "CurliteTestFail",
      })
      if test.message then
        for _, l in ipairs(vim.split(test.message, "\n", { plain = true })) do
          table.insert(lines, ("      %s"):format(l))
          table.insert(marks, { line = #lines - 1, col = 0, end_col = -1, hl = "CurliteTestDetail" })
        end
      end
    end
  end

  return lines, marks
end

--- ---------------------------------------------------------------- window

---@return boolean
local function win_valid()
  return M.winid ~= nil and vim.api.nvim_win_is_valid(M.winid)
end

--- Swap the buffer shown in the response window.
---
--- The window sets `winfixbuf` so a stray `:bnext` or a plugin can't replace
--- the response with something else -- which also blocks *us* from switching
--- panes, so it comes off for the duration of the swap.
---@param win integer
---@param buf integer
local function set_win_buf(win, buf)
  local fixed = vim.wo[win].winfixbuf
  if fixed then
    vim.wo[win].winfixbuf = false
  end
  vim.api.nvim_win_set_buf(win, buf)
  if fixed then
    vim.wo[win].winfixbuf = true
  end
end

---@param node table
---@param last boolean
---@return integer|nil
local function edge_leaf(node, last)
  if node[1] == "leaf" then
    return node[2]
  end
  local children = node[2]
  local child = children[last and #children or 1]
  return child and edge_leaf(child, last) or nil
end

---@param node table
---@param target integer
---@param root boolean
---@return table|nil
local function split_parent(node, target, root)
  if node[1] == "leaf" then
    return nil
  end
  local children = node[2]
  for index, child in ipairs(children) do
    if child[1] == "leaf" and child[2] == target then
      local after = index > 1
      local sibling = after and children[index - 1] or children[index + 1]
      if not sibling then
        return nil
      end
      return {
        axis = node[1],
        after = after,
        anchor = edge_leaf(sibling, after),
        root_edge = root,
      }
    end
    local found = split_parent(child, target, false)
    if found then
      return found
    end
  end
  return nil
end

---@return table|nil
local function capture_split()
  if not win_valid() then
    return nil
  end
  local win = M.winid
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return nil
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  if tab ~= vim.api.nvim_get_current_tabpage() then
    return nil
  end
  local placement = split_parent(vim.fn.winlayout(), win, true)
  if not placement or not placement.anchor then
    return nil
  end
  placement.tab = tab
  placement.width = size.as_fraction("width", vim.api.nvim_win_get_width(win))
  placement.height = size.as_fraction("height", vim.api.nvim_win_get_height(win))
  return placement
end

---@param buf integer
---@return boolean
local function restore_split(buf)
  local placement = saved_split
  if not placement or placement.tab ~= vim.api.nvim_get_current_tabpage() then
    return false
  end

  local vertical = placement.axis == "row"
  local command
  if placement.root_edge then
    command = placement.after and "botright " or "topleft "
  else
    if not vim.api.nvim_win_is_valid(placement.anchor)
      or vim.api.nvim_win_get_tabpage(placement.anchor) ~= placement.tab
    then
      saved_split = nil
      return false
    end
    vim.api.nvim_set_current_win(placement.anchor)
    command = placement.after and "rightbelow " or "leftabove "
  end
  command = command .. (vertical and "vsplit" or "split")

  local ok = pcall(vim.cmd, command)
  if not ok then
    saved_split = nil
    return false
  end
  M.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.winid, buf)
  if vertical then
    pcall(vim.api.nvim_win_set_width, M.winid, size.resolve("width", placement.width))
  else
    pcall(vim.api.nvim_win_set_height, M.winid, size.resolve("height", placement.height))
  end
  return true
end

---@param buf integer
local function open_window(buf)
  local cfg = config.get().ui
  local prev = vim.api.nvim_get_current_win()

  if cfg.display == "float" then
    local width = math.floor(vim.o.columns * cfg.float.width)
    local height = math.floor(vim.o.lines * cfg.float.height)
    M.winid = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = cfg.float.border,
    })
  elseif cfg.display == "tab" then
    vim.cmd("tabnew")
    M.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.winid, buf)
  else
    if not restore_split(buf) then
      local cmd = ({
        right = "botright vsplit",
        left = "topleft vsplit",
        below = "botright split",
        above = "topleft split",
      })[cfg.display] or "botright vsplit"
      vim.cmd(cmd)
      M.winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.winid, buf)
      if cfg.display == "right" or cfg.display == "left" then
        local width = size.resolve("width", cfg.width)
        if width then
          vim.api.nvim_win_set_width(M.winid, width)
        end
      else
        local height = size.resolve("height", cfg.height)
        if height then
          vim.api.nvim_win_set_height(M.winid, height)
        end
      end
    end
  end

  local wo = vim.wo[M.winid]
  wo.wrap = cfg.wrap
  wo.number = cfg.number
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldenable = false
  wo.cursorline = cfg.cursorline == true
  wo.winfixbuf = true

  if vim.api.nvim_win_is_valid(prev) and not cfg.focus then
    vim.api.nvim_set_current_win(prev)
  end
end

--- The winbar: status on the left, pane tabs on the right.
---@param result curlite.Result
---@return string
local function winbar(result)
  local cfg = config.get().ui
  local parts = {}

  local resp = result.response
  if resp and resp.status > 0 then
    local icon = status_icon(resp.status)
    table.insert(
      parts,
      ("%%#%s#%s %d %s%%*"):format(
        status_hl(resp.status),
        icon ~= "" and (" " .. icon) or "",
        resp.status,
        resp.status_text
      )
    )
    table.insert(parts, ("%%#Comment# %s  %s%%*"):format(
      util.human_time(resp.duration_ms),
      util.human_size(#resp.body)
    ))
    local passed, failed = scripts.tally(result.script)
    if passed + failed > 0 then
      table.insert(
        parts,
        ("%%#%s# %d/%d%%*"):format(
          failed > 0 and "CurliteTestFail" or "CurliteTestPass",
          passed,
          passed + failed
        )
      )
    end
  elseif result.error then
    table.insert(parts, ("%%#CurliteServerError# %s %s%%*"):format(cfg.icons.error, result.error))
  end

  if filter_expr and filter_expr ~= "" then
    table.insert(parts, ("%%#Special# /%s%%*"):format(filter_expr))
  end

  if #M.history > 1 then
    table.insert(parts, ("%%#Comment# [%d/%d]%%*"):format(M.history_index, #M.history))
  end

  local left = table.concat(parts, " ")

  local tabs = {}
  for _, pane in ipairs(cfg.panes) do
    local label = PANE_LABELS[pane] or pane
    local group = pane == M.pane and "CurlitePaneActive" or "CurlitePaneInactive"
    -- `%N@fn@` makes the tab clickable.
    table.insert(tabs, ("%%@v:lua.require'curlite.ui'.click_pane_%s@%%#%s# %s %%*%%X"):format(pane, group, label))
  end

  return left .. "%=" .. table.concat(tabs, "")
end

-- Clickable winbar handlers, one per pane (winbar click handlers take no args).
for _, pane in ipairs({ "body", "headers", "all", "stats", "verbose", "script" }) do
  M["click_pane_" .. pane] = function()
    M.set_pane(pane)
  end
end

--- ---------------------------------------------------------------- display

---@param result curlite.Result
---@param pane string
local function draw(result, pane)
  local buf = pane_buffer(pane)

  local key = signature(result)
  if drawn_result[pane] == result and drawn_key[pane] == key then
    return buf
  end

  local lines, marks, ft

  if pane == "body" then
    lines, ft = render_body(result)
  elseif pane == "headers" then
    lines, marks = render_headers(result)
    ft = nil
  elseif pane == "all" then
    lines, marks = render_all(result)
    ft = nil
  elseif pane == "stats" then
    lines, marks = render_stats(result)
  elseif pane == "verbose" then
    lines = render_verbose(result)
  elseif pane == "script" then
    lines, marks = render_script(result)
  else
    lines = { ("unknown pane: %s"):format(pane) }
  end

  set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  -- `end_col = -1` in a renderer means "to the end of the line". Resolve it
  -- against the actual text rather than spilling onto the next row: an extmark
  -- whose end runs past the last line is rejected, and when that rejection was
  -- swallowed every such mark disappeared silently.
  for _, mark in ipairs(marks or {}) do
    local text = lines[mark.line + 1]
    if text then
      local end_col = mark.end_col
      if end_col == nil or end_col < 0 or end_col > #text then
        end_col = #text
      end
      local col = math.min(mark.col, #text)
      if end_col > col then
        vim.api.nvim_buf_set_extmark(buf, NS, mark.line, col, {
          end_col = end_col,
          hl_group = mark.hl,
        })
      end
    end
  end

  -- Only the body pane gets a real filetype; the others are curlite's own
  -- layout and a language parser would only mis-highlight them.
  local want_ft = ft or ({
    verbose = "curlite_verbose",
    headers = "curlite_headers",
    all = "curlite_headers",
    stats = "",
    script = "",
  })[pane] or ""
  if vim.bo[buf].filetype ~= want_ft then
    vim.bo[buf].filetype = want_ft
  end

  drawn_result[pane] = result
  drawn_key[pane] = key

  return buf
end

--- Roughly what a history entry costs to keep: the strings that scale with
--- the response. Everything else is a handful of numbers.
---@param result curlite.Result
---@return integer
local function entry_bytes(result)
  local resp = result.response
  if not resp then
    return 0
  end
  return #(resp.body or "") + #(resp.verbose or "") + #(resp.raw_headers or "")
end

--- Trim the history ring to both its limits: a count and a byte budget.
---
--- `response.json` is dropped from every entry but the newest. It is derived
--- data -- `request_variable` and the panes both fall back to decoding the
--- body -- and on a large JSON response the decoded table costs several times
--- what the text does, so keeping fifty of them dwarfs everything else here.
local function trim_history()
  local cfg = config.get().history

  local limit = cfg.size or 0
  while limit > 0 and #M.history > limit do
    table.remove(M.history, 1)
  end

  for i = 1, #M.history - 1 do
    local resp = M.history[i].response
    if resp then
      resp.json = nil
    end
  end

  local budget = cfg.max_bytes or 0
  if budget > 0 then
    local total = 0
    for _, entry in ipairs(M.history) do
      total = total + entry_bytes(entry)
    end
    -- Always keep the newest, however large: dropping what the user just
    -- asked for would be absurd.
    while #M.history > 1 and total > budget do
      total = total - entry_bytes(M.history[1])
      table.remove(M.history, 1)
    end
  end
end

--- Show a result, opening or reusing the response window.
---@param result curlite.Result
---@param opts { pane: string|nil, push: boolean|nil }|nil
function M.show(result, opts)
  opts = opts or {}
  local cfg = config.get().ui

  if opts.push ~= false then
    table.insert(M.history, result)
    trim_history()
    M.history_index = #M.history
    filter_expr = nil
  end

  M.pane = opts.pane or M.pane or cfg.default_pane

  -- A pane the user removed from `ui.panes` shouldn't be reachable.
  if not vim.tbl_contains(cfg.panes, M.pane) then
    M.pane = cfg.panes[1] or "body"
  end

  local buf = draw(result, M.pane)

  if not win_valid() then
    open_window(buf)
  elseif vim.api.nvim_win_get_buf(M.winid) ~= buf then
    set_win_buf(M.winid, buf)
  end

  if win_valid() then
    vim.wo[M.winid].winbar = cfg.winbar and winbar(result) or ""
    -- Put the cursor back at the top for a fresh result.
    if opts.push ~= false then
      pcall(vim.api.nvim_win_set_cursor, M.winid, { 1, 0 })
    end
  end
end

--- Re-render whatever is on screen (after a pane or filter change).
---@param pane string|nil
function M.refresh(pane)
  local result = M.history[M.history_index]
  if not result then
    return
  end
  M.show(result, { pane = pane, push = false })
end

---@param pane string
function M.set_pane(pane)
  M.refresh(pane)
end

---@param delta integer
function M.cycle_pane(delta)
  local panes = config.get().ui.panes
  local idx = 1
  for i, p in ipairs(panes) do
    if p == M.pane then
      idx = i
      break
    end
  end
  idx = ((idx - 1 + delta) % #panes) + 1
  M.set_pane(panes[idx])
end

---@param delta integer
function M.cycle_history(delta)
  if #M.history == 0 then
    return
  end
  local idx = math.min(math.max(M.history_index + delta, 1), #M.history)
  if idx == M.history_index then
    return
  end
  M.history_index = idx
  filter_expr = nil
  M.show(M.history[idx], { push = false })
end

--- Show a "sending..." placeholder so a slow request gives feedback.
---@param req curlite.Request
function M.show_pending(req)
  local cfg = config.get().ui
  local pane = M.pane or cfg.default_pane
  local buf = pane_buffer(pane)
  set_lines(buf, { ("%s %s"):format(req.method, req.url), "", "sending..." })
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.bo[buf].filetype = ""
  -- This pane no longer shows what `draw` last put there.
  drawn_result[pane], drawn_key[pane] = nil, nil

  if not win_valid() then
    open_window(buf)
  elseif vim.api.nvim_win_get_buf(M.winid) ~= buf then
    set_win_buf(M.winid, buf)
  end
  if win_valid() and cfg.winbar then
    vim.wo[M.winid].winbar = ("%%#CurliteRunning# %s %s %s%%*"):format(
      cfg.icons.running,
      req.method,
      req.url
    )
  end
end

function M.close()
  if win_valid() then
    saved_split = capture_split()
    vim.api.nvim_win_close(M.winid, true)
  end
  M.winid = nil
end

function M.toggle()
  if win_valid() then
    M.close()
    return
  end
  local result = M.history[M.history_index]
  if result then
    M.show(result, { push = false })
  else
    util.emit("no_response", "curlite: no response yet")
  end
end

function M.focus()
  if win_valid() then
    vim.api.nvim_set_current_win(M.winid)
  end
end

--- ----------------------------------------------------------------- flash

-- The buffer currently carrying a flash, so it can be cleared without the
-- caller having to remember where it was drawn.
local flash_bufnr = nil
-- Bumped on every flash, so a timer that fires after a *later* flash has
-- replaced its own cannot clear the newer one.
local flash_generation = 0

--- Remove the flash highlight, wherever it is.
function M.clear_flash()
  if flash_bufnr and vim.api.nvim_buf_is_valid(flash_bufnr) then
    vim.api.nvim_buf_clear_namespace(flash_bufnr, FLASH_NS, 0, -1)
  end
  flash_bufnr = nil
end

--- Briefly highlight the request that was just sent, so a fired request is
--- visible at the cursor rather than only in the response window.
---@param req curlite.Request
---@param bufnr integer|nil
function M.flash(req, bufnr)
  local cfg = config.get().ui
  if not cfg.flash then
    return
  end
  bufnr = bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- The normal flash covers the whole section the user fired, including its
  -- `###` title and metadata. The optional line scope remains request-line only.
  local first = cfg.flash_scope == "line"
      and (req.url_line or req.start_line)
    or (req.start_line or req.url_line)
  if not first then
    return
  end
  local last = cfg.flash_scope == "line" and first or (req.end_line or first)

  local count = vim.api.nvim_buf_line_count(bufnr)
  first = math.max(1, math.min(first, count))
  last = math.max(first, math.min(last, count))

  M.clear_flash()
  flash_bufnr = bufnr
  flash_generation = flash_generation + 1
  local generation = flash_generation

  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  for index, line in ipairs(lines) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, FLASH_NS, first + index - 2, 0, {
      end_col = #line,
      hl_group = "CurliteFlash",
      -- Carry the highlight past the end of a short line, so a block of
      -- uneven lines reads as one region rather than as ragged stripes.
      hl_eol = true,
      priority = PRIORITY_FLASH,
    })
  end

  -- 0 means "hold until the response lands", which `clear_flash` does from
  -- `on_done`. Anything else is a plain timeout.
  local timeout = cfg.flash_timeout or 0
  if timeout > 0 then
    vim.defer_fn(function()
      if flash_generation == generation then
        M.clear_flash()
      end
    end, timeout)
  end
end

--- ------------------------------------------------------------- inline status

--- Virtual text on the request line: ` 200 OK`, plus whatever `ui.inline`
--- turns on.
---@param result curlite.Result
---@param bufnr integer|nil
function M.set_inline(result, bufnr)
  local cfg = config.get().ui
  if not cfg.inline_status then
    return
  end
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line = result.raw and result.raw.url_line
  if not line then
    return
  end
  if line > vim.api.nvim_buf_line_count(bufnr) then
    return
  end

  local show = cfg.inline or {}
  local text, hl
  if result.response and result.response.status > 0 then
    local resp = result.response
    -- Everything here is also in the winbar a split away, so each part is
    -- opt-in: by default the inline text is the status and nothing else.
    local parts = {}
    if show.status ~= false then
      table.insert(parts, ("%d %s"):format(resp.status, resp.status_text))
    end
    if show.time then
      table.insert(parts, util.human_time(resp.duration_ms))
    end
    if show.size then
      table.insert(parts, util.human_size(#resp.body))
    end

    hl = status_hl(resp.status)
    local passed, failed = scripts.tally(result.script)
    if show.tests and passed + failed > 0 then
      table.insert(parts, ("%d/%d"):format(passed, passed + failed))
    end
    -- A failing assertion recolours the status even when the tally itself is
    -- hidden: the point of the inline text is to be glanceable.
    if failed > 0 then
      hl = "CurliteTestFail"
    end

    if #parts == 0 then
      return
    end
    text = table.concat(parts, " · ")

    local icon = show.icon ~= false and status_icon(resp.status) or ""
    if icon ~= "" then
      text = icon .. " " .. text
    end
  elseif result.skipped then
    text, hl = "skipped", "Comment"
  elseif result.error then
    text, hl = ("%s %s"):format(cfg.icons.error, result.error), "CurliteServerError"
  else
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, INLINE_NS, line - 1, line)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, INLINE_NS, line - 1, 0, {
    virt_text = { { "  " .. text, hl } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

---@param bufnr integer|nil
function M.clear_inline(bufnr)
  bufnr = bufnr or 0
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, INLINE_NS, 0, -1)
  end
end

--- ------------------------------------------------------------------ actions

--- Prompt for a jq filter over the current body.
function M.prompt_filter()
  local result = M.history[M.history_index]
  if not result or not result.response then
    return
  end
  vim.ui.input({ prompt = "jq filter: ", default = filter_expr or "." }, function(input)
    if input == nil then
      return
    end
    filter_expr = vim.trim(input) ~= "" and input or nil
    M.refresh("body")
  end)
end

--- Whether `/` should open the jq prompt rather than Vim's normal search.
--- It is meaningful only over a JSON body (or while correcting an active jq
--- expression); every other response pane keeps native `/` behavior.
---@return boolean
function M.jq_filter_available()
  if M.pane ~= "body" or not win_valid() then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(M.winid)
  return vim.bo[buf].filetype == "json" or (filter_expr ~= nil and filter_expr ~= "")
end

function M.clear_filter()
  if filter_expr then
    filter_expr = nil
    M.refresh()
  end
end

--- Yank the current body to a register.
function M.yank_body()
  local result = M.history[M.history_index]
  if not result or not result.response then
    return
  end
  vim.fn.setreg(vim.v.register or '"', result.response.body)
  util.emit("yank", ("curlite: yanked %s"):format(util.human_size(#result.response.body)), {
    data = { bytes = #result.response.body },
  })
end

--- Save the current body to a file.
function M.save_body()
  local result = M.history[M.history_index]
  if not result or not result.response then
    return
  end
  local ctype = result.response.headers["Content-Type"] or ""
  local ext = ctype:find("json") and ".json"
    or ctype:find("xml") and ".xml"
    or ctype:find("html") and ".html"
    or ""
  vim.ui.input({
    prompt = "Save response to: ",
    default = vim.fn.getcwd() .. "/response" .. ext,
    completion = "file",
  }, function(path)
    if not path or path == "" then
      return
    end
    local ok, err = util.write_file(vim.fn.expand(path), result.response.body)
    if ok then
      util.emit("save", ("curlite: wrote %s"):format(path), { data = { path = path } })
    else
      util.emit("write_error", ("curlite: %s"):format(err), { level = vim.log.levels.ERROR })
    end
  end)
end

--- Jump back to the request that produced the shown response.
function M.jump_to_request()
  local result = M.history[M.history_index]
  if not result or not result.raw then
    return
  end
  local source = result.raw.source
  local line = result.raw.url_line or result.raw.start_line

  -- Prefer a window already showing that file.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if source and vim.api.nvim_buf_get_name(buf) == source then
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      return
    end
  end

  if source then
    vim.cmd(("edit +%d %s"):format(line, vim.fn.fnameescape(source)))
  end
end

--- Re-send the request that produced the shown response.
function M.resend()
  local result = M.history[M.history_index]
  if not result or not result.raw then
    return
  end
  require("curlite").run(result.raw)
end

--- Apply the response-window keymaps to a pane buffer.
---@param buf integer
function M.apply_result_keymaps(buf)
  local maps = config.get().result_keymaps
  if maps == false then
    return
  end

  local function map(lhs, fn, desc)
    if lhs and lhs ~= false then
      vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = "curlite: " .. desc })
    end
  end

  map(maps.close, M.close, "close response")
  map(maps.next_pane, function()
    M.cycle_pane(1)
  end, "next pane")
  map(maps.prev_pane, function()
    M.cycle_pane(-1)
  end, "previous pane")
  for pane, key in pairs({
    body = maps.show_body,
    headers = maps.show_headers,
    all = maps.show_all,
    stats = maps.show_stats,
    verbose = maps.show_verbose,
    script = maps.show_script,
  }) do
    map(key, function()
      M.set_pane(pane)
    end, "show " .. pane)
  end
  map(maps.next_history, function()
    M.cycle_history(1)
  end, "newer response")
  map(maps.prev_history, function()
    M.cycle_history(-1)
  end, "older response")
  map(maps.jump_to_request, M.jump_to_request, "jump to request")
  map(maps.yank_body, M.yank_body, "yank body")
  map(maps.save_body, M.save_body, "save body")
  if maps.filter and maps.filter ~= false then
    vim.keymap.set("n", maps.filter, function()
      if not M.jq_filter_available() then
        return maps.filter
      end
      vim.schedule(M.prompt_filter)
      return "<Ignore>"
    end, {
      buffer = buf,
      silent = true,
      nowait = true,
      expr = true,
      desc = "curlite: jq filter or search",
    })
  end
  map(maps.refresh, M.resend, "re-send request")
  map("<Esc>", M.clear_filter, "clear filter")

  -- Jump straight to a pane by number.
  for i, pane in ipairs(config.get().ui.panes) do
    map(tostring(i), function()
      M.set_pane(pane)
    end, "pane " .. pane)
  end
end

--- Drop every buffer and window. Used by `:CurliteClear`.
function M.reset()
  M.close()
  saved_split = nil
  for _, buf in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  buffers = {}
  body_cache = setmetatable({}, { __mode = "k" })
  drawn_result = setmetatable({}, { __mode = "v" })
  drawn_key = {}
  M.history = {}
  M.history_index = 0
  filter_expr = nil
end

return M
