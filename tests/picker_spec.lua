local env = require("curlite.env")
local picker = require("curlite.picker")
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
  return dir
end

local ENV_FILE = [[{
  "$curliteshared": { "apiVersion": "v1" },
  "dev":  { "host": "http://localhost:3000", "auth": { "id": "abc" } },
  "prod": { "host": "https://api.example.com" }
}]]

function M.the_preview_is_the_environments_variables_as_json(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local lines, origins = picker.preview_lines(dir .. "/api.http", "dev")
  local text = table.concat(lines, "\n")

  local ok, decoded = pcall(vim.json.decode, text)
  t.truthy(ok, "the preview must be valid JSON: " .. text)
  t.eq(decoded.host, "http://localhost:3000")
  t.eq(decoded.apiVersion, "v1", "the shared variables are shown merged in")
  t.eq(decoded.auth.id, "abc", "nested values are shown in full")
  t.truthy(#lines > 4, "nested values are pretty-printed, not collapsed onto one line")

  -- Every top-level key says which environment it came from.
  local marked = {}
  for _, origin in pairs(origins) do
    marked[origin] = true
  end
  t.truthy(marked["dev"], "the environment's own values are marked with its name")
  t.truthy(marked["$curliteshared"], "inherited values are marked as shared")
end

function M.previewing_an_environment_does_not_select_it(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  picker.preview_lines(dir .. "/api.http", "prod")
  t.eq(env.current(dir .. "/api.http"), nil)
end

function M.the_shared_preview_stands_alone(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local lines = picker.preview_lines(dir .. "/api.http", nil)
  local decoded = vim.json.decode(table.concat(lines, "\n"))
  t.eq(decoded.apiVersion, "v1")
  t.eq(decoded.host, nil, "no environment means no environment's host")
end

function M.an_empty_environment_previews_as_empty(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": {} }]],
    ["api.http"] = "GET x\n",
  })
  local lines = picker.preview_lines(dir .. "/api.http", "dev")
  t.eq(lines[1], "{}")
end

function M.the_picker_lists_every_environment_and_a_way_out(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local chosen, called = nil, false
  local handle = picker.open({
    source = dir .. "/api.http",
    on_choice = function(name)
      called, chosen = true, name
    end,
  })

  local lines = vim.api.nvim_buf_get_lines(handle.list_buf, 0, -1, false)
  t.eq(#lines, 3, "(no environment), dev, prod")
  t.truthy(lines[1]:find("no environment", 1, true))
  t.truthy(lines[2]:find("dev", 1, true))
  t.truthy(lines[3]:find("prod", 1, true))
  t.truthy(vim.api.nvim_win_is_valid(handle.preview_win), "the preview opens beside the list")

  -- The preview follows the cursor.
  vim.api.nvim_win_set_cursor(handle.list_win, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.list_buf })
  local preview = vim.api.nvim_buf_get_lines(
    vim.api.nvim_win_get_buf(handle.preview_win),
    0,
    -1,
    false
  )
  t.truthy(
    table.concat(preview, "\n"):find("api.example.com", 1, true),
    "the highlighted environment's variables are the ones shown"
  )

  vim.api.nvim_win_call(handle.list_win, function()
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end)
  t.truthy(called, "<CR> chooses")
  t.eq(chosen, "prod")
  t.falsy(vim.api.nvim_win_is_valid(handle.list_win), "and closes the picker")
end

function M.the_picker_is_big_enough_to_read(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  local handle = picker.open({ source = dir .. "/api.http", on_choice = function() end })

  local list = vim.api.nvim_win_get_config(handle.list_win)
  local preview = vim.api.nvim_win_get_config(handle.preview_win)
  t.truthy(list.height >= 8, "a list you can see the whole project in")
  t.truthy(
    list.width + preview.width > vim.o.columns * 0.6,
    "the point of the picker is seeing the values, so it takes real room"
  )
  t.truthy(preview.width > list.width, "most of that room goes to the variables")
  handle.close()
end

function M.the_current_environment_is_marked_and_focused(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = "GET x\n" })
  env.select("prod", dir .. "/api.http")
  local handle = picker.open({ source = dir .. "/api.http", on_choice = function() end })

  local lines = vim.api.nvim_buf_get_lines(handle.list_buf, 0, -1, false)
  t.truthy(lines[3]:find("●", 1, true), "the active environment is marked")
  t.eq(vim.api.nvim_win_get_cursor(handle.list_win)[1], 3, "and is where the cursor starts")
  handle.close()
  env.reset()
end

return M
