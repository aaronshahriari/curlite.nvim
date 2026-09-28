--- Confirmation modal for requests explicitly marked as guarded.

local preview = require("curlite.preview")

local M = {}

local NS = vim.api.nvim_create_namespace("curlite_confirm")
local BUTTONS = "[ Yes ]    [ No ]"

local function inverted(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  if not hl.fg and not hl.ctermfg then
    return { reverse = true, bold = true }
  end
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  return {
    bold = true,
    fg = hl.bg or normal.bg,
    bg = hl.fg,
    ctermfg = hl.ctermbg or "Black",
    ctermbg = hl.ctermfg,
  }
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "CurliteConfirmYes", inverted("DiagnosticOk"))
  vim.api.nvim_set_hl(0, "CurliteConfirmNo", inverted("DiagnosticWarn"))
  -- The cursor is parked on the selected button so that `hjkl` feel right, but
  -- a block cursor there paints a chunk of the button in `Cursor`'s colour --
  -- a near-white square in most themes -- over the highlight underneath.
  -- `blend = 100` makes it invisible without moving it.
  vim.api.nvim_set_hl(0, "CurliteConfirmCursor", { blend = 100, nocombine = true })
end

-- `guicursor` is global, so it is saved and restored around the dialog rather
-- than set and forgotten. nil means "not currently hidden".
local saved_guicursor = nil

local function hide_cursor()
  if saved_guicursor == nil then
    saved_guicursor = vim.o.guicursor
  end
  -- `pcall`: a `guicursor` Vim does not accept must not take the dialog with
  -- it, since the dialog is the thing guarding the request.
  pcall(function()
    vim.o.guicursor = "a:CurliteConfirmCursor/CurliteConfirmCursor"
  end)
end

local function restore_cursor()
  if saved_guicursor == nil then
    return
  end
  pcall(function()
    vim.o.guicursor = saved_guicursor
  end)
  saved_guicursor = nil
end

local function center(text, width)
  local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
  return string.rep(" ", pad) .. text
end

---@param cmd curlite.Command
---@param callback fun(approved: boolean)
function M.ask(cmd, callback)
  -- Headless runs must fail closed rather than wait forever for input.
  if #vim.api.nvim_list_uis() == 0 then
    callback(false)
    return
  end

  ensure_highlights()

  local req_lines = preview.lines(cmd)
  local geo = preview.geometry(vim.list_extend(vim.deepcopy(req_lines), {
    "",
    "Run this request?",
    "",
    BUTTONS,
  }), {
    min_width = 44,
    max_width = math.min(72, vim.o.columns - 8),
    wrap = true,
  })

  local lines = vim.deepcopy(req_lines)
  table.insert(lines, "")
  table.insert(lines, center("Run this request?", geo.width))
  table.insert(lines, "")
  table.insert(lines, center(BUTTONS, geo.width))
  local choice_row = #lines - 1

  local choice = false
  local buf, win = preview.open(lines, {
    title = " confirm request ",
    focus = true,
    min_width = geo.width,
    max_width = geo.width,
    wrap = true,
    footer = " y/n · enter · esc ",
  })

  hide_cursor()

  local function paint()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    local line = vim.api.nvim_buf_get_lines(buf, choice_row, choice_row + 1, false)[1] or ""
    local cursor_col = 0
    local function mark(label, selected, hl)
      local s, e = line:find(label, 1, true)
      if not s then
        return
      end
      vim.api.nvim_buf_set_extmark(buf, NS, choice_row, s - 1, {
        end_col = e,
        hl_group = selected and hl or "Comment",
        hl_mode = "replace",
        priority = 200,
      })
      if selected then
        cursor_col = s - 1
      end
    end
    mark("[ Yes ]", choice, "CurliteConfirmYes")
    mark("[ No ]", not choice, "CurliteConfirmNo")
    pcall(vim.api.nvim_win_set_cursor, win, { choice_row + 1, cursor_col })
  end

  paint()

  local finished = false
  local function finish(approved)
    if finished then
      return
    end
    finished = true
    restore_cursor()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    callback(approved)
  end

  local function select(approved)
    choice = approved
    paint()
  end

  local map = { buffer = buf, nowait = true, silent = true }
  local function bind(keys, fn)
    for _, key in ipairs(keys) do
      vim.keymap.set("n", key, fn, map)
    end
  end
  bind({ "y", "Y", "h", "<Left>" }, function()
    select(true)
  end)
  bind({ "n", "N", "l", "<Right>" }, function()
    select(false)
  end)
  bind({ "<Tab>", "<S-Tab>", "<Space>" }, function()
    select(not choice)
  end)
  bind({ "<CR>" }, function()
    finish(choice)
  end)
  bind({ "q", "<Esc>" }, function()
    finish(false)
  end)

  -- `guicursor` is global, so leaving it hidden would follow the user out of
  -- the dialog and into the rest of the session. `finish` covers every path
  -- the keymaps offer; this covers the ones they do not -- `:q`, a window
  -- manager closing the float, or anything else that disposes of the buffer.
  -- Failing closed here matters: this dialog exists to guard a request, so an
  -- exit that never reached `finish` is a "no".
  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      restore_cursor()
      finish(false)
    end,
  })
end

return M
