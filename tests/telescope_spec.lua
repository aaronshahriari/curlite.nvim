-- The telescope front end.
--
-- Telescope is not on the runtimepath here -- pulling it in would change
-- which picker the rest of the suite gets -- so these cover the parts that
-- stand on their own: the entry list, and the backend choice. The preview
-- itself is `picker.preview_lines`, covered in picker_spec.

local config = require("curlite.config")
local env = require("curlite.env")
local picker = require("curlite.picker")
local telescope = require("curlite.telescope")
local util = require("curlite.util")

local function project(files)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  env.reset()
  return dir
end

local ENV_FILE = [[{
  "$curliteshared": {
    "apiVersion": "v1",
    "$default_headers": { "Accept": "application/json" }
  },
  "dev":  { "host": "http://localhost:3000", "auth": { "id": "abc" } },
  "prod": {
    "host": "https://api.example.com",
    "$default_headers": { "Authorization": "Bearer {{tok}}" }
  }
}]]

--- The floating window the built-in picker opens, if it is up.
local function builtin_win()
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

local function close_builtin()
  local win = builtin_win()
  if win then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local M = {}

function M.the_entry_list_leads_with_a_deliberate_none(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local list = telescope.entries(dir .. "/api.http")

  t.eq(#list, 3)
  t.eq(list[1].name, nil, "`(no environment)` comes first")
  t.eq(list[1].label, "(no environment)")
  t.eq(list[2].name, "dev")
  t.eq(list[3].name, "prod")
end

function M.each_entry_counts_its_variables_and_headers(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local list = telescope.entries(dir .. "/api.http")

  -- The shared block alone: apiVersion, and the header it sends.
  t.eq(list[1].count, 1)
  t.eq(list[1].headers, 1)
  -- dev adds host and auth on top of the shared apiVersion.
  t.eq(list[2].count, 3)
  t.eq(list[2].headers, 1, "dev inherits the shared header and adds none")
  -- prod adds host, and a header of its own.
  t.eq(list[3].count, 2)
  t.eq(list[3].headers, 2)
end

function M.the_selected_environment_is_marked(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local source = dir .. "/api.http"

  local none = telescope.entries(source)
  for _, entry in ipairs(none) do
    t.falsy(entry.active, "nothing is active before a choice is made")
  end

  env.select("prod", source)
  local list = telescope.entries(source)
  t.falsy(list[1].active)
  t.falsy(list[2].active)
  t.truthy(list[3].active, "prod is the one marked")

  -- Choosing "no environment" is a choice, and is marked as one.
  env.select(nil, source)
  t.truthy(telescope.entries(source)[1].active)
end

function M.the_header_key_is_not_counted_as_a_variable(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local list = telescope.entries(dir .. "/api.http")
  -- prod holds `host` and `$default_headers`; only one of them is a variable.
  t.eq(list[3].count, 2, "apiVersion + host, and not the directive")
end

function M.telescope_is_not_loadable_here(t)
  t.falsy(telescope.available(), "the suite runs without telescope, by design")
end

function M.auto_falls_back_to_the_builtin_picker(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  config.setup({})
  t.eq(config.get().ui.picker.backend, "auto", "which is the default")

  picker.open({ source = dir .. "/api.http" })
  t.truthy(builtin_win(), "with no telescope, the built-in window opens")
  close_builtin()
end

function M.builtin_is_honoured_even_with_telescope_around(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  config.setup({ ui = { picker = { backend = "builtin" } } })

  local opened = false
  local real = telescope.available
  telescope.available = function()
    return true
  end
  local real_open = telescope.open
  telescope.open = function()
    opened = true
  end

  picker.open({ source = dir .. "/api.http" })
  telescope.available, telescope.open = real, real_open

  t.falsy(opened, "`builtin` must not reach for telescope")
  t.truthy(builtin_win())
  close_builtin()
  config.setup({})
end

function M.asking_for_telescope_without_it_says_so(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  config.setup({ ui = { picker = { backend = "telescope" } } })

  t.drain()
  picker.open({ source = dir .. "/api.http" })
  vim.wait(50, function()
    return false
  end)
  local msgs = t.drain()

  t.truthy(builtin_win(), "the picker still opens rather than doing nothing")
  local warned = false
  for _, m in ipairs(msgs) do
    if m.msg:find("telescope", 1, true) then
      warned = true
    end
  end
  t.truthy(warned, "and says why it is not the one you asked for")

  close_builtin()
  config.setup({})
end

function M.the_telescope_front_end_is_used_when_available(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  config.setup({})

  local got
  local real, real_open = telescope.available, telescope.open
  telescope.available = function()
    return true
  end
  telescope.open = function(o)
    got = o
  end

  picker.open({ source = dir .. "/api.http", telescope = { theme = "dropdown" } })
  telescope.available, telescope.open = real, real_open

  t.truthy(got, "`auto` prefers telescope")
  t.eq(got.source, dir .. "/api.http")
  t.eq(got.telescope, { theme = "dropdown" }, "caller options are passed through")
  t.falsy(builtin_win(), "and the built-in window stays shut")
end

return M
