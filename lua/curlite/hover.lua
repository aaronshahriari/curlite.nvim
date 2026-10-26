--- The hover card: the resolved request under the cursor, laid out to be read.
---
--- `inspect` is the dump you go and look at; hover is the glance you take
--- mid-edit, so it is built for scanning rather than for completeness:
---
---   ╭ CREATE_THING · dev ─────────────────────────────╮
---   │                                                 │
---   │  POST https://api.example.com/v1/things         │
---   │       ?expand = owner                           │
---   │       &fields = id,name                         │
---   │                                                 │
---   │  headers ──────────────────────────────────  3  │
---   │  Content-Type:   application/json               │
---   │  Authorization:  Bearer eyJhbGciOiJIUzI1…       │
---   │                                                 │
---   │  body ─────────────────────────── json · 94 B   │
---   │  {                                              │
---   │    "name": "widget"                             │
---   │  }                                              │
---   │                                                 │
---   ╰ K focus · q close ──────────────────────────────╯
---
--- Three things make it readable where a raw request dump is not: the query
--- string is broken onto one line per parameter (a resolved URL is the single
--- longest thing in a request, and the part you actually want to check is the
--- parameters), header values are aligned into a column and wrapped with a
--- hanging indent instead of running off the edge, and the sections are
--- labelled so the eye can jump straight to the body.
---
--- Everything is laid out as `{ text, marks }` rows by `M.rows`, which is a
--- pure function of the request and the available width -- the window is just
--- what those rows are poured into, and the layout is testable without one.

local config = require("curlite.config")
local preview = require("curlite.preview")
local util = require("curlite.util")

local M = {}

local NS = vim.api.nvim_create_namespace("curlite_hover")
local AUGROUP = "curlite_hover"

--- The card currently on screen, if any.
---@type { win: integer, buf: integer, src_win: integer, src_buf: integer }|nil
local open_card = nil

--- ------------------------------------------------------------------ config

---@return table
local function opts()
  local cfg = config.get()
  local hover = (cfg.ui or {}).hover or {}
  return {
    style = hover.style or "card",
    border = hover.border or ((cfg.ui or {}).float or {}).border or "rounded",
    min_width = hover.min_width or 46,
    max_width = hover.max_width or 88,
    max_height = hover.max_height or 0.5,
    padding = hover.padding == nil and 2 or hover.padding,
    split_query = hover.split_query ~= false,
    body_lines = hover.body_lines or 40,
    rules = hover.rules ~= false,
    hints = hover.hints ~= false,
  }
end

--- ------------------------------------------------------------------- rows

---@class curlite.hover.Mark
---@field group string
---@field from integer   -- byte column, 0-indexed
---@field to integer     -- byte column, exclusive

---@class curlite.hover.Row
---@field text string
---@field marks curlite.hover.Mark[]
---@field elastic boolean|nil  -- stretches to the card's width; not measured

--- One row from `{ text, highlight-group }` chunks. Byte columns are taken as
--- the text is assembled, so a multibyte value cannot push a mark off its
--- chunk the way a character count would.
---@param chunks table[]
---@return curlite.hover.Row
local function row(chunks)
  local text, marks = "", {}
  for _, chunk in ipairs(chunks) do
    local part = chunk[1] or ""
    if chunk[2] and part ~= "" then
      table.insert(marks, { group = chunk[2], from = #text, to = #text + #part })
    end
    text = text .. part
  end
  return { text = text, marks = marks }
end

local function blank()
  return { text = "", marks = {} }
end

---@param s string
---@return integer
local function w(s)
  return vim.fn.strdisplaywidth(s)
end

--- `label ───────────────── meta`, filled to exactly `width`. The rule is what
--- keeps the sections apart without spending a blank line on each one.
---
--- Rules are *elastic*: they are the one row that stretches to whatever width
--- the card ends up being, so `M.open` leaves them out when it measures how
--- wide the content wants to be. Without that every card would come up at the
--- maximum width, which is the whole complaint about hovering being a wall.
---@param label string
---@param meta string|nil
---@param width integer
---@return curlite.hover.Row
local function rule(label, meta, width)
  meta = meta or ""
  local fill = width - w(label) - 1 - (meta ~= "" and w(meta) + 1 or 0)
  local chunks = {
    { label, "CurliteHoverLabel" },
    { " ", nil },
    { ("─"):rep(math.max(1, fill)), "CurliteHoverRule" },
  }
  if meta ~= "" then
    table.insert(chunks, { " ", nil })
    table.insert(chunks, { meta, "CurliteHoverMeta" })
  end
  local out = row(chunks)
  out.elastic = true
  return out
end

--- Is this byte the middle of a UTF-8 character rather than the start of one?
---@param byte integer|nil
---@return boolean
local function continuation_byte(byte)
  return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

--- Break `value` into pieces that fit `width`, preferring a space and falling
--- back to a hard cut, so one enormous token (a JWT, a signed URL) still wraps
--- instead of being truncated away.
---@param value string
---@param width integer
---@return string[]
local function wrap(value, width)
  width = math.max(8, width)
  local out = {}
  while w(value) > width do
    local cut = nil
    for i = width + 1, 2, -1 do
      if value:sub(i, i) == " " then
        cut = i
        break
      end
    end
    if cut then
      table.insert(out, value:sub(1, cut - 1))
      value = value:sub(cut + 1)
    else
      -- Walk back to a character boundary: `sub` counts bytes, and cutting a
      -- multibyte character in half would render as a replacement glyph.
      local bytes = width
      while bytes > 1 and continuation_byte(value:byte(bytes + 1)) do
        bytes = bytes - 1
      end
      table.insert(out, value:sub(1, bytes))
      value = value:sub(bytes + 1)
    end
  end
  table.insert(out, value)
  return out
end

--- `?expand=owner&fields=id,name` as `{ key, value }` pairs. A parameter with
--- no `=` keeps its whole text as the key, because `?debug` is a flag and
--- showing it as `debug = ` would be a lie.
---@param query string
---@return { key: string, value: string|nil }[]
local function params(query)
  local out = {}
  for _, part in ipairs(vim.split(query, "&", { plain = true })) do
    if part ~= "" then
      local key, value = part:match("^([^=]*)=(.*)$")
      table.insert(out, { key = key or part, value = value })
    end
  end
  return out
end

--- What the body is, for the `body ───` rule's right-hand side. The header
--- wins over a sniff: a JSON body sent as `text/plain` is being sent as text
--- deliberately, and the card should say so.
---@param headers table<string,string>
---@param body string
---@return string
local function body_kind(headers, body)
  local ct
  for name, value in pairs(headers or {}) do
    if name:lower() == "content-type" then
      ct = value:lower():gsub(";.*", ""):gsub("%s", "")
      break
    end
  end
  if ct and ct ~= "" then
    if ct:find("json", 1, true) then
      return "json"
    elseif ct:find("xml", 1, true) then
      return "xml"
    elseif ct:find("x-www-form-urlencoded", 1, true) then
      return "form"
    elseif ct:find("multipart", 1, true) then
      return "multipart"
    end
    return (ct:gsub("^text/", ""))
  end

  local first = vim.trim(body):sub(1, 1)
  if first == "{" or first == "[" then
    return "json"
  elseif first == "<" then
    return "xml"
  end
  return "text"
end

---@class curlite.hover.Context
---@field method string|nil
---@field url string|nil
---@field http_version string|nil
---@field headers table<string,string>|nil
---@field header_order string[]|nil
---@field body string|nil
---@field name string|nil
---@field env string|nil
---@field error string|nil

--- The card's lines, as a pure function of the request and the width it has
--- to live in. `width` is the *inner* width -- padding is added by `M.open`.
---@param ctx curlite.hover.Context
---@param width integer
---@return curlite.hover.Row[]
function M.rows(ctx, width)
  local cfg = opts()
  local rows = {}

  if ctx.error then
    rows[#rows + 1] = row({ { "⚠ ", "CurliteHoverError" }, { ctx.error, "CurliteHoverError" } })
    if ctx.method or ctx.url then
      rows[#rows + 1] = blank()
    end
  end

  -- The request line. The method keeps its buffer colour, the URL loses its
  -- query string to the rows underneath.
  if ctx.method or ctx.url then
    local method = (ctx.method or "GET"):upper()
    local url = ctx.url or ""
    local base, query = url, ""
    if cfg.split_query then
      local head, tail = url:match("^([^?]*)%?(.*)$")
      if head and tail and tail ~= "" then
        base, query = head, tail
      end
    end

    local lead = method .. " "
    local method_group = require("curlite.highlight").method_group(method)
    local chunks = {
      { lead, method_group },
      { base, "CurliteHttpUrl" },
    }
    if ctx.http_version and ctx.http_version ~= "" then
      table.insert(chunks, { " " .. ctx.http_version, "CurliteHoverMeta" })
    end
    local line = row(chunks)
    if w(line.text) <= width then
      rows[#rows + 1] = line
    else
      -- A URL too long for the card wraps under the method, so the host stays
      -- on the first line where it is worth reading.
      for i, piece in ipairs(wrap(base, width - w(lead))) do
        rows[#rows + 1] = row({
          { i == 1 and lead or (" "):rep(w(lead)), i == 1 and method_group or nil },
          { piece, "CurliteHttpUrl" },
        })
      end
    end

    if query ~= "" then
      local parsed = params(query)
      local key_width = 0
      for _, p in ipairs(parsed) do
        key_width = math.max(key_width, w(p.key))
      end
      local indent = (" "):rep(w(lead))
      for i, p in ipairs(parsed) do
        local sigil = i == 1 and "?" or "&"
        if p.value then
          local gap = (" "):rep(key_width - w(p.key)) .. " = "
          local head = {
            { indent, nil },
            { sigil, "CurliteHoverPunct" },
            { p.key, "CurliteHoverQueryKey" },
            { gap, "CurliteHoverPunct" },
          }
          local column = w(indent) + w(sigil) + key_width + w(" = ")
          for j, piece in ipairs(wrap(p.value, width - column)) do
            if j == 1 then
              local chunks2 = vim.deepcopy(head)
              table.insert(chunks2, { piece, "CurliteHoverQueryValue" })
              rows[#rows + 1] = row(chunks2)
            else
              rows[#rows + 1] = row({
                { (" "):rep(column), nil },
                { piece, "CurliteHoverQueryValue" },
              })
            end
          end
        else
          rows[#rows + 1] = row({
            { indent, nil },
            { sigil, "CurliteHoverPunct" },
            { p.key, "CurliteHoverQueryKey" },
          })
        end
      end
    end
  end

  -- Headers, as a two-column table. The names are padded to a common width so
  -- the values form a column you can read straight down.
  local order = ctx.header_order or {}
  local headers = ctx.headers or {}
  local shown = {}
  for _, name in ipairs(order) do
    if headers[name] then
      table.insert(shown, name)
    end
  end
  if #shown > 0 then
    local name_width = 0
    for _, name in ipairs(shown) do
      name_width = math.max(name_width, w(name) + 1)
    end
    if #rows > 0 then
      rows[#rows + 1] = blank()
    end
    if cfg.rules then
      rows[#rows + 1] = rule("headers", tostring(#shown), width)
    end
    for _, name in ipairs(shown) do
      local gap = (" "):rep(name_width - w(name) + 1)
      local column = w(name) + 1 + w(gap)
      for i, piece in ipairs(wrap(headers[name], width - column)) do
        if i == 1 then
          rows[#rows + 1] = row({
            { name, "CurliteHttpHeaderName" },
            { ":", "CurliteHttpHeaderSep" },
            -- The padding between is left uncoloured, so a themed background
            -- on either group does not bleed across the gap.
            { gap, nil },
            { piece, "CurliteHttpHeaderValue" },
          })
        else
          rows[#rows + 1] = row({
            { (" "):rep(column), nil },
            { piece, "CurliteHttpHeaderValue" },
          })
        end
      end
    end
  end

  -- The body, re-indented if it is JSON, capped so a 2000-line payload cannot
  -- turn the glance into a scroll.
  if ctx.body and ctx.body ~= "" then
    local lines = preview.body(ctx.body)
    local limit = cfg.body_lines
    local dropped = 0
    if limit and limit > 0 and #lines > limit then
      dropped = #lines - limit
      lines = vim.list_slice(lines, 1, limit)
    end

    if #rows > 0 then
      rows[#rows + 1] = blank()
    end
    if cfg.rules then
      local meta = ("%s · %s"):format(body_kind(headers, ctx.body), util.human_size(#ctx.body))
      rows[#rows + 1] = rule("body", meta, width)
    end
    for _, line in ipairs(lines) do
      rows[#rows + 1] = { text = line, marks = {} }
    end
    if dropped > 0 then
      rows[#rows + 1] = row({
        { ("… %d more line%s"):format(dropped, dropped == 1 and "" or "s"), "CurliteHoverMeta" },
      })
    end
  end

  if #rows == 0 then
    rows[#rows + 1] = row({ { "nothing to show", "CurliteHoverMeta" } })
  end
  return rows
end

--- ----------------------------------------------------------------- window

--- Where the card goes, relative to the cursor. Below it when there is room,
--- above it when there is not -- the same flip `vim.lsp.buf.hover()` does, so
--- hovering the last request in a file does not push the card off screen.
---@param height integer
---@param width integer
---@return string anchor, integer row, integer col
local function placement(height, width)
  local above = vim.fn.winline() - 1
  local below = vim.api.nvim_win_get_height(0) - vim.fn.winline()
  local anchor, line = "NW", 1
  if below < height + 2 and above > below then
    anchor, line = "SW", 0
  end

  -- `relative = "cursor"` is not clamped horizontally, so a request line with
  -- the cursor near the right edge would hang the card off the screen.
  local col = 0
  local screen = vim.fn.screencol()
  local overflow = (screen + width + 2) - vim.o.columns
  if overflow > 0 then
    col = -math.min(overflow, math.max(0, screen - 1))
  end
  return anchor, line, col
end

--- Is the card still standing?
---@return integer|nil win, integer|nil buf
function M.current()
  if open_card and vim.api.nvim_win_is_valid(open_card.win) then
    return open_card.win, open_card.buf
  end
  return nil
end

--- Take the card down.
function M.close()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  if open_card then
    local card = open_card
    open_card = nil
    pcall(vim.api.nvim_win_close, card.win, true)
    if vim.api.nvim_buf_is_valid(card.buf) then
      pcall(vim.api.nvim_buf_delete, card.buf, { force = true })
    end
  end
end

--- Close on anything that means "you have moved on", but never on the step
--- into the card itself. The check is deferred a tick because `BufLeave` fires
--- *before* the window switch lands: asking which window is current from
--- inside the event would still answer "the request buffer" and shut the card
--- the moment you focused it.
---@param src_buf integer
---@param src_win integer
local function watch(src_buf, src_win)
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  local function bail()
    vim.schedule(function()
      local win = M.current()
      if win and vim.api.nvim_get_current_win() ~= win then
        M.close()
      end
    end)
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" }, {
    group = group,
    buffer = src_buf,
    callback = bail,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized", "TabLeave" }, {
    group = group,
    callback = bail,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(src_win),
    callback = function()
      M.close()
    end,
  })
  -- Leaving the card once you are in it closes it, so it cannot be left
  -- hanging over a buffer you have walked away from.
  if open_card then
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      buffer = open_card.buf,
      callback = function()
        vim.schedule(M.close)
      end,
    })
  end
end

--- The old hover: `vim.lsp.util.open_floating_preview` over the raw request.
--- Kept for `ui.hover.style = "plain"`.
---@param lines string[]
---@return integer|nil buf, integer|nil win
local function plain(lines)
  local contents, syntax = lines, "http"
  local ok, added = pcall(vim.treesitter.language.add, "http")
  if ok and added then
    contents = { "```http" }
    vim.list_extend(contents, lines)
    table.insert(contents, "```")
    syntax = "markdown"
  end

  local float_buf, float_win = vim.lsp.util.open_floating_preview(contents, syntax, {
    border = opts().border,
    focus_id = "curlite_hover",
    wrap = true,
    max_width = math.max(40, math.min(100, vim.o.columns - 10)),
    max_height = math.max(5, math.floor(vim.o.lines * 0.5)),
    close_events = { "CursorMoved", "CursorMovedI", "InsertCharPre", "WinScrolled" },
  })

  if
    float_win
    and vim.api.nvim_win_is_valid(float_win)
    and vim.api.nvim_win_get_buf(float_win) == float_buf
  then
    vim.keymap.set("n", "<Esc>", function()
      pcall(vim.api.nvim_win_close, float_win, true)
    end, { buffer = float_buf, nowait = true, silent = true })
  end
  return float_buf, float_win
end

--- Show the card for one resolved request.
---
--- Called a second time while a card is up it focuses that card instead of
--- drawing another, which is what makes `K K` step into it the way an LSP
--- hover does.
---@param ctx curlite.hover.Context
---@return integer|nil buf, integer|nil win
function M.open(ctx)
  local cfg = opts()

  local focus_win = M.current()
  if focus_win then
    vim.api.nvim_set_current_win(focus_win)
    return vim.api.nvim_win_get_buf(focus_win), focus_win
  end

  if cfg.style == "plain" then
    local lines = {}
    if ctx.error then
      table.insert(lines, "# " .. ctx.error)
    end
    if ctx.method or ctx.url then
      table.insert(lines, ("%s %s"):format((ctx.method or "GET"):upper(), ctx.url or ""))
    end
    for _, name in ipairs(ctx.header_order or {}) do
      if (ctx.headers or {})[name] then
        table.insert(lines, ("%s: %s"):format(name, ctx.headers[name]))
      end
    end
    if ctx.body and ctx.body ~= "" then
      table.insert(lines, "")
      vim.list_extend(lines, preview.body(ctx.body))
    end
    return plain(lines)
  end

  local pad = math.max(0, cfg.padding)
  local max_width = math.max(20, math.min(cfg.max_width, vim.o.columns - 6))
  local inner_max = max_width - pad * 2

  -- Two passes: lay the rows out at the widest the card may be to find how
  -- much room the content really wants, then lay them out again at that width
  -- so the rules and the wrapping fit the card that gets drawn.
  local measured = 0
  for _, r in ipairs(M.rows(ctx, inner_max)) do
    if not r.elastic then
      measured = math.max(measured, w(r.text))
    end
  end
  -- `min_width`/`max_width` are the card's width, border and padding included,
  -- because that is the number you can see; `inner` is what the rows get.
  local floor = math.min(math.max(0, cfg.min_width - pad * 2), inner_max)
  local inner = math.max(floor, math.min(measured, inner_max))
  local rows = M.rows(ctx, inner)

  local prefix = (" "):rep(pad)
  local lines, marks = {}, {}
  local function emit(r)
    table.insert(lines, prefix .. r.text)
    local shifted = {}
    for _, mark in ipairs(r.marks) do
      table.insert(shifted, { group = mark.group, from = mark.from + pad, to = mark.to + pad })
    end
    table.insert(marks, shifted)
  end
  if pad > 0 then
    emit(blank())
  end
  for _, r in ipairs(rows) do
    emit(r)
  end
  if pad > 0 then
    emit(blank())
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- `syntax`, deliberately not `filetype`: `syntax/http.vim` is what colours
  -- a JSON body (it picks the body region up through its leading padding),
  -- but a `FileType http` on the card would hand it the whole http apparatus
  -- -- curlite's buffer highlighter re-reading the card as a document, and
  -- the request keymaps, `<CR>` included, on a buffer that only holds a
  -- picture of a request. Everything the card adds is extmarked instead, and
  -- extmarks sit above syntax.
  vim.bo[buf].syntax = "http"
  vim.bo[buf].modifiable = false
  for i, line_marks in ipairs(marks) do
    for _, mark in ipairs(line_marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, mark.from, {
        end_col = mark.to,
        hl_group = mark.group,
        priority = 200,
      })
    end
  end

  local width = inner + pad * 2
  local max_height = cfg.max_height
  if max_height <= 1 then
    max_height = math.floor(vim.o.lines * max_height)
  end
  max_height = math.max(3, math.min(max_height, vim.o.lines - 6))
  local height = math.max(1, math.min(#lines, max_height))
  local hidden = #lines - height

  local anchor, line, col = placement(height, width)
  local win_opts = {
    relative = "cursor",
    anchor = anchor,
    row = line,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = cfg.border,
    zindex = 45,
  }

  -- A border is what a title hangs off; with `border = "none"` Neovim refuses
  -- both, so the card goes up bare instead of erroring.
  if cfg.border and cfg.border ~= "none" then
    local name = ctx.name and ctx.name ~= "" and ctx.name or "request"
    local title = { { " ", "CurliteHoverTitle" }, { name, "CurliteHoverTitle" } }
    if ctx.env and ctx.env ~= "" then
      table.insert(title, { " · ", "CurliteHoverRule" })
      table.insert(title, { ctx.env, "CurliteHoverEnv" })
    end
    table.insert(title, { " ", "CurliteHoverTitle" })
    win_opts.title = title
    win_opts.title_pos = "left"

    if cfg.hints then
      local hint = " K focus · q close"
      if hidden > 0 then
        hint = hint .. (" · +%d line%s"):format(hidden, hidden == 1 and "" or "s")
      end
      win_opts.footer = { { hint .. " ", "CurliteHoverHint" } }
      win_opts.footer_pos = "left"
    end
  end

  local win = vim.api.nvim_open_win(buf, false, win_opts)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].winhighlight = "NormalFloat:CurliteHoverNormal,FloatBorder:CurliteHoverBorder"

  open_card = {
    win = win,
    buf = buf,
    src_win = vim.api.nvim_get_current_win(),
    src_buf = vim.api.nvim_get_current_buf(),
  }

  -- Inside the card: `q` and `<Esc>` close it, and `K` stays quiet rather than
  -- hunting for a request in a buffer that holds a rendering of one.
  for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, function()
      M.close()
    end, { buffer = buf, nowait = true, silent = true, desc = "curlite: close hover" })
  end
  local hover_key = (config.get().keymaps or {}).hover
  if type(hover_key) == "string" and hover_key ~= "" then
    vim.keymap.set("n", hover_key, "<Nop>", { buffer = buf, nowait = true, silent = true })
  end

  watch(open_card.src_buf, open_card.src_win)
  return buf, win
end

return M
