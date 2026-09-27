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
local util = require("curlite.util")

local M = {}

local NS = vim.api.nvim_create_namespace("curlite")
local INLINE_NS = vim.api.nvim_create_namespace("curlite_inline")

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

  local ctype = resp.headers["Content-Type"] or resp.headers["content-type"] or ""

  if resp.body == "" then
    return { ("(empty body — %d %s)"):format(resp.status, resp.status_text) }, nil
  end

  if format.is_binary(resp.body, ctype) then
    return {
      ("(binary response — %s, %s)"):format(ctype ~= "" and ctype or "unknown type", util.human_size(#resp.body)),
      "",
      "Press `gs` to save it to a file.",
    }, nil
  end

  local body = resp.body
  if filter_expr and filter_expr ~= "" then
    local filtered, err = format.jq(body, filter_expr)
    if filtered then
      return vim.split(filtered, "\n", { plain = true }), "json"
    end
    return { ("jq: %s"):format(err), "", "Press `/` to change the filter, `<Esc>` to clear it." }, nil
  end

  local formatted, ft = format.body(body, ctype)
  return vim.split(formatted, "\n", { plain = true }), ft
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
      if cfg.width > 0 then
        vim.api.nvim_win_set_width(M.winid, cfg.width)
      end
    elseif cfg.height > 0 then
      vim.api.nvim_win_set_height(M.winid, cfg.height)
    end
  end

  local wo = vim.wo[M.winid]
  wo.wrap = cfg.wrap
  wo.number = cfg.number
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldenable = false
  wo.cursorline = true
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

  return buf
end

--- Show a result, opening or reusing the response window.
---@param result curlite.Result
---@param opts { pane: string|nil, push: boolean|nil }|nil
function M.show(result, opts)
  opts = opts or {}
  local cfg = config.get().ui

  if opts.push ~= false then
    table.insert(M.history, result)
    local limit = config.get().history.size
    while limit > 0 and #M.history > limit do
      table.remove(M.history, 1)
    end
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
  local buf = pane_buffer(M.pane or cfg.default_pane)
  set_lines(buf, { ("%s %s"):format(req.method, req.url), "", "sending..." })
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.bo[buf].filetype = ""

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
    util.notify("curlite: no response yet", vim.log.levels.INFO)
  end
end

function M.focus()
  if win_valid() then
    vim.api.nvim_set_current_win(M.winid)
  end
end

--- ------------------------------------------------------------- inline status

--- Virtual text on the request line: ` 200 OK · 143ms`.
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

  local text, hl
  if result.response and result.response.status > 0 then
    local resp = result.response
    local icon = status_icon(resp.status)
    text = ("%s%d %s · %s"):format(
      icon ~= "" and (icon .. " ") or "",
      resp.status,
      resp.status_text,
      util.human_time(resp.duration_ms)
    )
    hl = status_hl(resp.status)
    local passed, failed = scripts.tally(result.script)
    if passed + failed > 0 then
      text = text .. (" · %d/%d"):format(passed, passed + failed)
      if failed > 0 then
        hl = "CurliteTestFail"
      end
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
  util.alert(("curlite: yanked %s"):format(util.human_size(#result.response.body)), vim.log.levels.INFO)
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
      util.alert(("curlite: wrote %s"):format(path), vim.log.levels.INFO)
    else
      util.err(("curlite: %s"):format(err))
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
  map(maps.next_history, function()
    M.cycle_history(1)
  end, "newer response")
  map(maps.prev_history, function()
    M.cycle_history(-1)
  end, "older response")
  map(maps.jump_to_request, M.jump_to_request, "jump to request")
  map(maps.yank_body, M.yank_body, "yank body")
  map(maps.save_body, M.save_body, "save body")
  map(maps.filter, M.prompt_filter, "jq filter")
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
  for _, buf in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  buffers = {}
  M.history = {}
  M.history_index = 0
  filter_expr = nil
end

return M
