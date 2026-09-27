--- Confirmation modal for requests explicitly marked as guarded.

local preview = require("curlite.preview")

local M = {}

---@param cmd curlite.Command
---@param callback fun(approved: boolean)
function M.ask(cmd, callback)
  -- Headless runs must fail closed rather than wait forever for input.
  if #vim.api.nvim_list_uis() == 0 then
    callback(false)
    return
  end

  local lines = preview.lines(cmd)
  table.insert(lines, "")
  table.insert(lines, "Run this request? [y/N]")
  table.insert(lines, "Choose y or n, then press Enter")

  local choice = false
  local buf, win = preview.open(lines, { title = " confirm request ", focus = true, min_width = 42 })
  vim.wo[win].cursorline = true
  pcall(vim.api.nvim_win_set_cursor, win, { #lines - 1, 0 })

  local finished = false
  local function finish(approved)
    if finished then
      return
    end
    finished = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    callback(approved)
  end

  local function select(approved)
    choice = approved
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, #lines - 2, #lines - 1, false, {
      approved and "Run this request? [Y/n]" or "Run this request? [y/N]",
    })
    vim.bo[buf].modifiable = false
  end

  vim.keymap.set("n", "y", function()
    select(true)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "n", function()
    select(false)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", function()
    finish(choice)
  end, { buffer = buf, nowait = true, silent = true })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      finish(false)
    end, { buffer = buf, nowait = true, silent = true })
  end
end

return M
