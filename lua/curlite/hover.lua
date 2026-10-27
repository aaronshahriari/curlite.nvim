--- Hover: the resolved request under the cursor, beside the cursor.
---
---   ╭────────────────────────────────────────────────────────────╮
---   │ POST https://api.example.com/v1/things?expand=owner        │
---   │ Content-Type: application/json                             │
---   │ Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 │
---   │ Accept: application/json                                   │
---   │                                                            │
---   │ {                                                          │
---   │   "name": "widget",                                        │
---   │   "active": false                                          │
---   │ }                                                          │
---   ╰────────────────────────────────────────────────────────────╯
---
--- The request, as it will actually be sent, and nothing else: no labels, no
--- dividers, no counts, no footer. It is the same text you would see in the
--- buffer, which is the point -- there is nothing to read past to find the
--- line you came for.
---
--- What it does spend room on is showing all of it. The window is as wide as
--- its longest line and as tall as it has lines, up to `max_width` and
--- `max_height`, so a body is not folded away behind a "+12 lines" note. A
--- line too long even for that wraps rather than running off the edge.
---
--- `inspect` is the other half of the pair: the same request plus its curl
--- line, in a window you go and read.

local config = require("curlite.config")
local preview = require("curlite.preview")

local M = {}

local NS = vim.api.nvim_create_namespace("curlite_hover")
local AUGROUP = "curlite_hover"

--- The hover currently on screen, if any.
---@type { win: integer, buf: integer, src_win: integer, src_buf: integer }|nil
local open_hover = nil

---@return { border: string|string[], max_width: number, max_height: number, padding: integer }
local function opts()
  local cfg = config.get()
  local hover = (cfg.ui or {}).hover or {}
  return {
    border = hover.border or ((cfg.ui or {}).float or {}).border or "rounded",
    max_width = hover.max_width or 0.9,
    max_height = hover.max_height or 0.8,
    padding = hover.padding == nil and 1 or math.max(0, hover.padding),
  }
end

---@param s string
---@return integer
local function w(s)
  return vim.fn.strdisplaywidth(s)
end

--- A fraction of `total`, or an absolute cell count above 1.
---@param value number
---@param total integer
---@return integer
local function extent(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

---@class curlite.hover.Context
---@field method string|nil
---@field url string|nil
---@field http_version string|nil
---@field headers table<string,string>|nil
---@field header_order string[]|nil
---@field body string|nil
---@field error string|nil

--- The request as display lines: the request line, its headers, then the body
--- after a blank line, exactly as it reads in an `.http` file.
---@param ctx curlite.hover.Context
---@return string[]
function M.lines(ctx)
  local lines = {}

  if ctx.error then
    lines[#lines + 1] = "# " .. ctx.error
  end
  if ctx.method or ctx.url then
    local line = ("%s %s"):format((ctx.method or "GET"):upper(), ctx.url or "")
    if ctx.http_version and ctx.http_version ~= "" then
      line = line .. " " .. ctx.http_version
    end
    lines[#lines + 1] = line
  end
  for _, name in ipairs(ctx.header_order or {}) do
    local value = (ctx.headers or {})[name]
    if value then
      lines[#lines + 1] = ("%s: %s"):format(name, value)
    end
  end
  if ctx.body and ctx.body ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, preview.body(ctx.body))
  end

  if #lines == 0 then
    lines[#lines + 1] = "# nothing to show"
  end
  return lines
end

--- Where it goes, relative to the cursor. Below when there is room, above
--- when there is not -- the flip `vim.lsp.buf.hover()` does, so hovering the
--- last request in a file does not push the window off screen.
---@param height integer
---@param width integer
---@return string anchor, integer row, integer col
local function placement(height, width)
  local above = vim.fn.winline() - 1
  local below = vim.api.nvim_win_get_height(0) - vim.fn.winline()
  local anchor, row = "NW", 1
  if below < height + 2 and above > below then
    anchor, row = "SW", 0
  end

  -- `relative = "cursor"` is not clamped horizontally, so hovering with the
  -- cursor near the right edge would hang the window off the screen.
  local col = 0
  local screen = vim.fn.screencol()
  local overflow = (screen + width + 2) - vim.o.columns
  if overflow > 0 then
    col = -math.min(overflow, math.max(0, screen - 1))
  end
  return anchor, row, col
end

--- Is it still up?
---@return integer|nil win, integer|nil buf
function M.current()
  if open_hover and vim.api.nvim_win_is_valid(open_hover.win) then
    return open_hover.win, open_hover.buf
  end
  return nil
end

--- Take it down.
function M.close()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  if open_hover then
    local hover = open_hover
    open_hover = nil
    pcall(vim.api.nvim_win_close, hover.win, true)
    if vim.api.nvim_buf_is_valid(hover.buf) then
      pcall(vim.api.nvim_buf_delete, hover.buf, { force = true })
    end
  end
end

--- Close on anything that means "you have moved on", but never on the step
--- into the window itself. The check is deferred a tick because `BufLeave`
--- fires *before* the window switch lands: asking which window is current
--- from inside the event would still answer "the request buffer", and would
--- shut the window the moment you focused it.
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
  if open_hover then
    -- Leaving it once you are in it closes it, so it cannot be left hanging
    -- over a buffer you have walked away from.
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      buffer = open_hover.buf,
      callback = function()
        vim.schedule(M.close)
      end,
    })
  end
end

--- Show one resolved request.
---
--- Called again while a hover is up it focuses that one instead of drawing
--- another, which is what makes `K K` step inside the way an LSP hover does.
---@param ctx curlite.hover.Context
---@return integer|nil buf, integer|nil win
function M.open(ctx)
  local cfg = opts()

  local focus = M.current()
  if focus then
    vim.api.nvim_set_current_win(focus)
    return vim.api.nvim_win_get_buf(focus), focus
  end

  local pad = (" "):rep(cfg.padding)
  local lines = {}
  local content = 0
  for _, line in ipairs(M.lines(ctx)) do
    table.insert(lines, line == "" and "" or pad .. line)
    content = math.max(content, w(line) + cfg.padding * 2)
  end

  local width =
    math.max(1, math.min(content, extent(cfg.max_width, vim.o.columns), vim.o.columns - 4))
  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(w(line) / width))
  end
  local height = math.max(1, math.min(rows, extent(cfg.max_height, vim.o.lines), vim.o.lines - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- `syntax`, deliberately not `filetype`: `syntax/http.vim` is what colours
  -- the request -- the method, the URL, a JSON body -- but a `FileType http`
  -- would hand this buffer the whole http apparatus, curlite's buffer
  -- highlighter re-reading it as a document and the request keymaps, `<CR>`
  -- included, on a buffer that only holds a picture of a request.
  vim.bo[buf].syntax = "http"
  vim.bo[buf].modifiable = false

  -- The one thing the syntax file cannot colour here is a header, because it
  -- anchors the name at column 0 and these are indented by the padding.
  for i, line in ipairs(lines) do
    local name, sep = line:match("^%s*([A-Za-z][A-Za-z0-9._-]*)(:)")
    if name and sep then
      local from = #line:match("^%s*")
      local marks = {
        { "CurliteHttpHeaderName", from, from + #name },
        { "CurliteHttpHeaderSep", from + #name, from + #name + 1 },
        { "CurliteHttpHeaderValue", from + #name + 1, #line },
      }
      for _, mark in ipairs(marks) do
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, mark[2], {
          end_col = mark[3],
          hl_group = mark[1],
          priority = 200,
        })
      end
    end
  end

  local anchor, row, col = placement(height, width)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    anchor = anchor,
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = cfg.border,
    zindex = 45,
  })
  vim.wo[win].wrap = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].winhighlight = "NormalFloat:CurliteHoverNormal,FloatBorder:CurliteHoverBorder"

  open_hover = {
    win = win,
    buf = buf,
    src_win = vim.api.nvim_get_current_win(),
    src_buf = vim.api.nvim_get_current_buf(),
  }

  -- Inside it: `q` and `<Esc>` close, and the hover key stays quiet rather
  -- than hunting for a request in a buffer that holds a rendering of one.
  for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, function()
      M.close()
    end, { buffer = buf, nowait = true, silent = true, desc = "curlite: close hover" })
  end
  local hover_key = (config.get().keymaps or {}).hover
  if type(hover_key) == "string" and hover_key ~= "" then
    vim.keymap.set("n", hover_key, "<Nop>", { buffer = buf, nowait = true, silent = true })
  end

  watch(open_hover.src_buf, open_hover.src_win)
  return buf, win
end

return M
