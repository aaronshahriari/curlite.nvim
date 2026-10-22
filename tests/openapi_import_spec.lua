-- The import itself: the picker narrows the spec, `<CR>` writes the block into
-- the buffer you were editing, and the cursor lands on the request so it can
-- be sent straight away.

local config = require("curlite.config")
local curlite = require("curlite")
local env = require("curlite.env")
local openapi = require("curlite.openapi")
local picker = require("curlite.openapi_picker")
local util = require("curlite.util")

local M = {}

local SPEC = [[{
  "openapi": "3.0.3",
  "info": { "title": "Petstore", "version": "1.0.0" },
  "servers": [{ "url": "https://api.example.com/v2" }],
  "paths": {
    "/pets": {
      "get": {
        "operationId": "listPets",
        "summary": "List pets",
        "responses": { "200": { "description": "ok",
          "content": { "application/json": {} } } }
      },
      "post": {
        "operationId": "createPet",
        "summary": "Add a pet",
        "requestBody": { "content": { "application/json": { "schema": {
          "type": "object",
          "required": ["name"],
          "properties": { "name": { "type": "string", "example": "Rex" } }
        } } } },
        "responses": { "201": { "description": "created" } }
      }
    },
    "/pets/{petId}": {
      "delete": {
        "operationId": "deletePet",
        "summary": "Remove a pet",
        "parameters": [
          { "name": "petId", "in": "path", "required": true,
            "schema": { "type": "string" } }
        ],
        "responses": { "204": { "description": "gone" } }
      }
    }
  }
}]]

---@param files table<string, string>
---@return string dir
local function project(files)
  local dir = vim.fn.tempname()
  files["openapi.json"] = files["openapi.json"] or SPEC
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  env.reset()
  openapi.reset()
  config.setup({})
  curlite.setup({})
  return dir
end

---@param path string
local function open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Run `fn` with the built-in picker's handle, whatever the configured front
--- end would have been, and without needing telescope on the runtimepath.
---@param fn fun(handle: table)
local function with_picker(fn)
  local real = picker.open
  local handle = nil
  picker.open = function(opts)
    handle = picker.open_builtin(opts)
    return handle
  end
  local ok, err = pcall(function()
    curlite.openapi()
    -- The spec is read from disk, so the picker is open by the time `openapi`
    -- returns; a URL would be a callback away.
    if not handle then
      error("the picker did not open", 0)
    end
    fn(handle)
  end)
  picker.open = real
  if handle and handle.close then
    handle.close()
  end
  if not ok then
    error(err, 0)
  end
end

--- `emit` schedules, so the loop has to turn before the message is there.
---@param t table
---@param fn fun()
---@return table[]
local function shown(t, fn)
  t.drain()
  fn()
  vim.wait(50, function()
    return false
  end)
  return t.drain()
end

---@return string
local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

function M.enter_drops_the_request_in_at_the_cursor(t)
  local dir = project({ ["api.http"] = "### existing\nGET https://x.test/ping\n" })
  open(dir .. "/api.http")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  with_picker(function(handle)
    handle.set_query("add a pet")
    t.eq(handle.shown()[1].label, "POST /pets", "the fuzzy query found it")
    handle.choose()
  end)

  t.eq(
    buffer_text(),
    table.concat({
      "### existing",
      "GET https://x.test/ping",
      "",
      "### Add a pet",
      "# @name createPet",
      "POST https://api.example.com/v2/pets",
      "Content-Type: application/json",
      "",
      "{",
      '  "name": "Rex"',
      "}",
      "",
    }, "\n")
  )
  -- The cursor lands on the request, so `<CR>` sends what was just inserted.
  t.eq(vim.api.nvim_win_get_cursor(0)[1], 6)
  t.eq(vim.api.nvim_get_current_line(), "POST https://api.example.com/v2/pets")
  vim.cmd("bwipeout!")
end

function M.the_block_follows_the_selected_environment(t)
  local dir = project({
    ["api.http"] = "",
    ["http-client.env.json"] = [[{ "dev": { "host": "http://localhost:3000" } }]],
  })
  open(dir .. "/api.http")
  env.select("dev", dir .. "/api.http")

  with_picker(function(handle)
    handle.set_query("list pets")
    handle.choose()
  end)

  t.match(buffer_text(), "GET {{host}}/v2/pets")
  vim.cmd("bwipeout!")
end

function M.the_picker_does_not_unset_the_environment(t)
  -- The preview is an http buffer, which is how the confirm dialog once lost
  -- the environment for the next request. A float is not a file.
  local dir = project({
    ["api.http"] = "",
    ["http-client.env.json"] = [[{ "dev": {}, "prod": {} }]],
  })
  open(dir .. "/api.http")
  env.select("prod", dir .. "/api.http")

  with_picker(function(handle)
    handle.set_query("list")
    handle.choose()
  end)

  t.eq(env.current(dir .. "/api.http"), "prod")
  t.truthy(env.chosen(dir .. "/api.http"))
  vim.cmd("bwipeout!")
end

function M.an_empty_buffer_is_filled_rather_than_pushed_down(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  with_picker(function(handle)
    handle.set_query("list")
    handle.choose()
  end)

  t.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "### List pets")
  vim.cmd("bwipeout!")
end

function M.what_is_inserted_parses_as_a_request_you_can_send(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  with_picker(function(handle)
    handle.set_query("remove")
    handle.choose()
  end)

  local doc = require("curlite.parser").parse_buffer(0)
  t.eq(#doc.requests, 1)
  t.eq(doc.requests[1].method, "DELETE")
  t.eq(doc.requests[1].url, "https://api.example.com/v2/pets/{{petId}}")
  t.eq(doc.requests[1].name, "deletePet")
  vim.cmd("bwipeout!")
end

function M.the_preview_is_the_block_that_will_be_inserted(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  with_picker(function(handle)
    handle.set_query("list pets")
    local shown = handle.shown()
    local preview = vim.api.nvim_buf_get_lines(
      vim.api.nvim_win_get_buf(handle.preview_win),
      0,
      -1,
      false
    )
    t.eq(preview, openapi.block(shown[1]), "what you read is what you get")
    t.eq(vim.bo[vim.api.nvim_win_get_buf(handle.preview_win)].filetype, "http")
  end)
  vim.cmd("bwipeout!")
end

function M.the_list_narrows_as_you_type(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  with_picker(function(handle)
    t.eq(#handle.shown(), 3, "everything, to begin with")
    handle.set_query("pets")
    t.eq(#handle.shown(), 3)
    handle.set_query("post")
    t.eq(handle.shown()[1].label, "POST /pets")
    handle.set_query("petid")
    t.eq(handle.shown()[1].label, "DELETE /pets/{petId}")
    handle.set_query("nothing here")
    t.eq(#handle.shown(), 0, "and says so rather than pretending")
  end)
  vim.cmd("bwipeout!")
end

function M.moving_past_the_ends_wraps(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  with_picker(function(handle)
    t.eq(handle.selected(), 1)
    handle.move(-1)
    t.eq(handle.selected(), #handle.shown(), "up from the top goes to the bottom")
    handle.move(1)
    t.eq(handle.selected(), 1)
  end)
  vim.cmd("bwipeout!")
end

function M.cancelling_inserts_nothing(t)
  local dir = project({ ["api.http"] = "### existing\nGET https://x.test/ping\n" })
  open(dir .. "/api.http")
  local before = buffer_text()

  with_picker(function(handle)
    handle.close()
  end)

  t.eq(buffer_text(), before)
  vim.cmd("bwipeout!")
end

function M.a_project_with_no_spec_says_so(t)
  local dir = vim.fn.tempname()
  util.write_file(dir .. "/api.http", "")
  vim.fn.mkdir(dir .. "/.git", "p")
  env.reset()
  openapi.reset()
  config.setup({})
  curlite.setup({})
  open(dir .. "/api.http")

  local said = shown(t, function()
    curlite.openapi()
  end)
  t.eq(#said, 1)
  t.match(said[1].msg, "no OpenAPI spec found")
  vim.cmd("bwipeout!")
end

function M.a_named_spec_that_is_not_there_says_so(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  local said = shown(t, function()
    curlite.openapi("./nope.yaml")
  end)
  t.eq(#said, 1)
  t.match(said[1].msg, "does not exist")
  vim.cmd("bwipeout!")
end

function M.a_spec_can_be_named_outright(t)
  local dir = project({ ["api.http"] = "", ["elsewhere/other.json"] = SPEC })
  open(dir .. "/api.http")

  local real = picker.open
  local titles = nil
  picker.open = function(opts)
    titles = opts.spec.__source
  end
  curlite.openapi("./elsewhere/other.json")
  picker.open = real

  t.eq(titles, dir .. "/elsewhere/other.json", "a relative path is relative to the .http file")
  vim.cmd("bwipeout!")
end

function M.a_buffer_that_cannot_be_written_to_is_refused(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")
  -- The response window, a help page, anything `nomodifiable`: there is
  -- nowhere to put the request, and saying so beats a stray error.
  vim.cmd("enew")
  vim.bo.modifiable = false

  local said = shown(t, function()
    curlite.openapi()
  end)
  t.eq(#said, 1)
  t.match(said[1].msg, "cannot be written to")

  vim.bo.modifiable = true
  vim.cmd("bwipeout!")
  vim.cmd("bwipeout!")
end

function M.marking_several_inserts_them_all_in_order(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  -- What telescope's `<Tab>` hands back: more than one operation at once.
  local ops = openapi.operations(openapi.load_file(dir .. "/openapi.json"), {})
  local real = picker.open
  picker.open = function(opts)
    opts.on_choice({ ops[1], ops[2] })
  end
  curlite.openapi()
  picker.open = real

  local doc = require("curlite.parser").parse_buffer(0)
  t.eq(#doc.requests, 2)
  t.eq(doc.requests[1].method, "GET")
  t.eq(doc.requests[2].method, "POST")
  vim.cmd("bwipeout!")
end

function M.the_subcommand_and_the_command_both_reach_it(t)
  local dir = project({ ["api.http"] = "" })
  open(dir .. "/api.http")

  local real = picker.open
  local opened = 0
  picker.open = function()
    opened = opened + 1
  end
  vim.cmd("Curlite openapi")
  vim.cmd("CurliteOpenapi")
  vim.cmd(("CurliteOpenapi %s"):format(vim.fn.fnameescape(dir .. "/openapi.json")))
  picker.open = real

  t.eq(opened, 3)
  vim.cmd("bwipeout!")
end

return M
