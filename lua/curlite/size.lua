local M = {}

---@param axis "width"|"height"
---@return integer
function M.total(axis)
  if axis == "width" then
    return vim.o.columns
  end
  return math.max(1, vim.o.lines - (vim.o.cmdheight or 1) - 1)
end

---@param axis "width"|"height"
---@return integer
local function reserve(axis)
  if axis == "width" then
    return math.max(vim.o.winwidth or 20, 10)
  end
  return math.max(vim.o.winheight or 5, 3)
end

--- Resolve a fraction of the editor (0 < value < 1) or an absolute cell count.
---@param axis "width"|"height"
---@param value number|nil
---@param total integer|nil
---@return integer|nil
function M.resolve(axis, value, total)
  if type(value) ~= "number" or value ~= value or value <= 0 then
    return nil
  end
  total = total or M.total(axis)
  local cells = value < 1 and math.floor(total * value + 0.5) or math.floor(value)
  local largest = total - reserve(axis) - 1
  if largest < 1 then
    return nil
  end
  return math.max(1, math.min(cells, largest))
end

---@param axis "width"|"height"
---@param cells integer
---@return number|nil
function M.as_fraction(axis, cells)
  local total = M.total(axis)
  if type(cells) ~= "number" or cells < 1 or total < 1 then
    return nil
  end
  return math.floor((cells / total) * 1000 + 0.5) / 1000
end

return M
