--- Shared rendering for resolved-request previews and confirmations.

local config = require("curlite.config")

local M = {}

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
  if cmd.sent_body then
    table.insert(lines, "")
    vim.list_extend(lines, vim.split(cmd.sent_body, "\n", { plain = true }))
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

---@param lines string[]
---@param opts { title: string|nil, focus: boolean|nil, min_width: integer|nil }|nil
---@return integer buf, integer win
function M.open(lines, opts)
  opts = opts or {}
  local width = opts.min_width or 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(20, math.min(width + 4, math.max(20, vim.o.columns - 8)))
  local height = math.max(1, math.min(#lines, math.max(1, vim.o.lines - 8)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "http"
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, opts.focus == true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = config.get().ui.float.border,
    title = opts.title or " request ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  return buf, win
end

return M
