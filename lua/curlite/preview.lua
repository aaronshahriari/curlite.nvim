--- Shared rendering for resolved-request previews and confirmations.

local config = require("curlite.config")
local format = require("curlite.format")
local util = require("curlite.util")

local M = {}

--- A resolved body as display lines. JSON is re-indented so a preview of a
--- minified payload is readable, the same way `:Curlite format` treats the
--- body you typed; everything else is shown byte-for-byte.
---
--- The body here is already resolved, so there are no `{{template}}` tokens to
--- mask -- unlike `curlite.request_format`, which formats the source you keep.
---@param body string
---@return string[]
local function body_lines(body)
  local cfg = config.get()
  local first = vim.trim(body):sub(1, 1)

  -- The pure-Lua formatter is linear but not free, and `response.max_format_size` is
  -- the existing ceiling for "don't re-indent something enormous".
  local limit = cfg.response.max_format_size
  if
    (cfg.format or {}).bodies ~= false
    and (first == "{" or first == "[")
    and (limit <= 0 or #body <= limit)
    and util.json_decode(body)
  then
    body = format.json(body, (cfg.format or {}).indent or 2)
  end

  return vim.split(body, "\n", { plain = true })
end

---@param cmd curlite.Command
---@param include_curl boolean|nil
---@return string[]
function M.lines(cmd, include_curl)
  local lines = { ("%s %s"):format(cmd.request.method, cmd.request.url) }
  for _, name in ipairs(cmd.request.header_order or {}) do
    if cmd.request.headers[name] then
      table.insert(lines, ("%s: %s"):format(name, cmd.request.headers[name]))
    end
  end
  if cmd.sent_body and cmd.sent_body ~= "" then
    table.insert(lines, "")
    vim.list_extend(lines, body_lines(cmd.sent_body))
  end
  if include_curl then
    table.insert(lines, "")
    table.insert(lines, "# curl equivalent")
    vim.list_extend(
      lines,
      vim.split(require("curlite.curl").to_shell(cmd, true), "\n", { plain = true })
    )
  end
  return lines
end

---@class curlite.PreviewGeometry
---@field width integer
---@field height integer
---@field row integer
---@field col integer

---@param lines string[]
---@param opts { min_width: integer|nil, max_width: integer|nil, wrap: boolean|nil }|nil
---@return curlite.PreviewGeometry
function M.geometry(lines, opts)
  opts = opts or {}
  local editor_max = math.max(20, vim.o.columns - 8)
  local max_width = math.min(opts.max_width or 72, editor_max)
  local min_width = math.min(opts.min_width or 20, max_width)

  local content = 0
  for _, line in ipairs(lines) do
    content = math.max(content, vim.fn.strdisplaywidth(line))
  end
  local width = math.max(min_width, math.min(content + 2, max_width))

  local height
  if opts.wrap then
    height = 0
    for _, line in ipairs(lines) do
      height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end
  else
    height = math.max(1, #lines)
  end
  height = math.max(1, math.min(height, math.max(1, vim.o.lines - 8)))

  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  }
end

---@param lines string[]
---@param opts { title: string|nil, focus: boolean|nil, min_width: integer|nil, max_width: integer|nil, wrap: boolean|nil, footer: string|nil }|nil
---@return integer buf, integer win
function M.open(lines, opts)
  opts = opts or {}
  local geo = M.geometry(lines, opts)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "http"
  vim.bo[buf].modifiable = false

  local win_opts = {
    relative = "editor",
    width = geo.width,
    height = geo.height,
    row = geo.row,
    col = geo.col,
    style = "minimal",
    border = config.get().ui.float.border,
    title = opts.title or " request ",
    title_pos = "center",
  }
  if opts.footer then
    win_opts.footer = opts.footer
    win_opts.footer_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, opts.focus == true, win_opts)
  vim.wo[win].wrap = opts.wrap == true
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 0
  if opts.wrap then
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
  end
  return buf, win
end

return M
