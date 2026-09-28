-- Sending is gated on having chosen an environment. This is the safety
-- property the whole selection design exists for: a request must never go out
-- against an environment you did not pick for this file.

local curlite = require("curlite")
local env = require("curlite.env")
local exec = require("curlite.exec")
local util = require("curlite.util")

local M = {}

---@param files table<string, string>
---@return string dir
local function project(files)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  env.reset()
  require("curlite.config").setup({})
  return dir
end

--- Open `path` in the current window and put the cursor on its request.
---@param path string
local function open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Run `fn` with `exec.send` recorded rather than performed.
---@param fn fun()
---@return table[] sent
local function capture(fn)
  local sent = {}
  local real = exec.send
  exec.send = function(req)
    table.insert(sent, req)
  end
  local ok, err = pcall(fn)
  exec.send = real
  if not ok then
    error(err, 0)
  end
  return sent
end

--- The open environment picker, if there is one.
---@return integer|nil win
local function picker_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative ~= "" and type(cfg.title) == "table" then
      for _, chunk in ipairs(cfg.title) do
        if type(chunk[1]) == "string" and chunk[1]:find("Environment") then
          return win
        end
      end
    end
  end
end

local function close_picker()
  local win = picker_win()
  if win then
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_feedkeys(vim.keycode("q"), "x", false)
    end)
  end
end

local HTTP = "GET http://127.0.0.1:1/never\n"
local ENV_FILE = [[{ "$curliteshared": { "a": "1" }, "dev": {}, "prod": {} }]]

function M.a_send_with_no_environment_opens_the_picker_instead(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  open(dir .. "/api.http")

  local sent = capture(function()
    curlite.run_at_cursor()
  end)

  t.eq(#sent, 0, "nothing may go out before an environment is chosen")
  t.truthy(picker_win(), "the picker opens so the choice can be made")
  close_picker()
end

function M.choosing_in_the_picker_sends_the_request(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  open(dir .. "/api.http")

  local sent = capture(function()
    curlite.run_at_cursor()
    local win = picker_win()
    t.truthy(win, "the picker opened")
    -- Land on "dev" and take it.
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    end)
  end)

  t.eq(#sent, 1, "the request you asked for goes out once the choice is made")
  t.eq(env.current(dir .. "/api.http"), "dev")
end

function M.a_second_send_does_not_ask_again(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  open(dir .. "/api.http")
  env.select("prod", dir .. "/api.http")

  local sent = capture(function()
    curlite.run_at_cursor()
  end)
  t.eq(#sent, 1)
  t.falsy(picker_win(), "the environment is chosen once per file, not once per request")
end

function M.a_project_with_no_environments_is_not_gated(t)
  local dir = project({ ["api.http"] = HTTP })
  open(dir .. "/api.http")

  local sent = capture(function()
    curlite.run_at_cursor()
  end)
  t.eq(#sent, 1, "nothing to choose between means nothing to ask about")
  t.falsy(picker_win())
end

function M.require_selection_can_be_turned_off(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  require("curlite.config").setup({ env = { require_selection = false } })
  open(dir .. "/api.http")

  local sent = capture(function()
    curlite.run_at_cursor()
  end)
  t.eq(#sent, 1)
  t.falsy(picker_win())
  require("curlite.config").setup({})
end

function M.opening_the_file_again_asks_again(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  curlite.setup({})
  open(dir .. "/api.http")
  env.select("prod", dir .. "/api.http")
  t.eq(env.current(dir .. "/api.http"), "prod")

  -- Close and re-open the file, the way you would across a day's work.
  vim.cmd("bwipeout!")
  open(dir .. "/api.http")

  t.falsy(env.chosen(dir .. "/api.http"), "re-entering a file starts with no environment")
  local sent = capture(function()
    curlite.run_at_cursor()
  end)
  t.eq(#sent, 0)
  t.truthy(picker_win())
  close_picker()
end

return M
