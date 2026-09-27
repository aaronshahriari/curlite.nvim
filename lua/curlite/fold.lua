--- Fold expression for `.http` buffers: one fold per request.

local M = {}

--- `foldexpr` for the current line.
---@return string
function M.expr()
  local lnum = vim.v.lnum
  local line = vim.fn.getline(lnum)
  -- A `###` separator opens a level-1 fold and closes the previous one.
  if line:match("^###") then
    return ">1"
  end
  -- A request line in a `###`-less file does the same.
  if line:match("^%u+%s+%S") and vim.fn.getline(lnum - 1):match("^%s*$") then
    local method = line:match("^(%u+)%s")
    local methods = require("curlite.parser").methods
    if methods[method] then
      return ">1"
    end
  end
  return "="
end

return M
