local curlite = require("curlite")

local M = {}

local function copy(lines)
  local previous = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  curlite.copy_curl("a")
  local text = vim.fn.getreg("a")
  vim.api.nvim_set_current_buf(previous)
  vim.api.nvim_buf_delete(buf, { force = true })
  return text
end

function M.named_request_keeps_its_header_as_a_shell_comment(t)
  local text = copy({ "### SHARE USER", "GET https://example.com/users/42" })
  t.match(text, "^### SHARE USER\ncurl ")
  t.match(text, "https://example%.com/users/42")
end

function M.unnamed_request_copies_only_the_command(t)
  local text = copy({ "GET https://example.com/health" })
  t.match(text, "^curl ")
end

return M
