local complete = require("curlite.complete")
local env = require("curlite.env")
local util = require("curlite.util")

local M = {}

--- A project on disk with an http buffer loaded and named inside it.
---@param files table<string, string>
---@param buffer_name string
---@return integer bufnr, string dir
local function project(files, buffer_name)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  env.reset()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. buffer_name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(files[buffer_name] or "", "\n"))
  vim.bo[buf].filetype = "http"
  return buf, dir
end

--- Labels of the items offered, for easy assertions.
---@param items table[]
---@return string[]
local function labels(items)
  return vim.tbl_map(function(entry)
    return entry.label
  end, items)
end

---@param items table[]
---@param label string
---@return table|nil
local function find(items, label)
  for _, entry in ipairs(items) do
    if entry.label == label then
      return entry
    end
  end
end

--- ---------------------------------------------------------------- context

function M.a_double_brace_starts_a_variable(t)
  t.eq(
    complete.context("GET {{", 6),
    { kind = "variable", prefix = "", start = 6, replace_start = 4, replace_end = 6 }
  )
  t.eq(
    complete.context("GET {{ho", 8),
    { kind = "variable", prefix = "ho", start = 6, replace_start = 4, replace_end = 8 }
  )
  -- Names may hold dots and dollars.
  t.eq(complete.context("GET {{auth.cli", 14).prefix, "auth.cli")
  t.eq(complete.context("GET {{$uui", 10).prefix, "$uui")
end

function M.the_replaced_range_covers_the_braces(t)
  -- The range starts at the `{{`, not at the name: an engine that guesses it
  -- from its own keyword pattern stops at `$` and `.`.
  local ctx = complete.context("GET {{auth.cli", 14)
  t.eq(ctx.replace_start, 4)
  t.eq(ctx.replace_end, 14)

  -- A closing pair after the cursor is absorbed rather than left behind.
  local paired = complete.context("GET {{}}", 6)
  t.eq(paired.replace_start, 4)
  t.eq(paired.replace_end, 8, "the `}}` is part of what gets replaced")

  local reopened = complete.context("GET {{host}}", 10)
  t.eq(reopened.replace_start, 4)
  t.eq(reopened.replace_end, 12, "re-completing a finished variable replaces all of it")

  -- A lone brace still counts, for a half-written pair.
  t.eq(complete.context("GET {{}", 6).replace_end, 7)
end

function M.variables_complete_with_their_braces(t)
  local buf = project({
    ["http-client.env.json"] = [[{ "$curliteshared": { "host": "https://x.dev" } }]],
    ["api.http"] = "GET {{ho\n",
  }, "api.http")
  vim.api.nvim_win_set_buf(0, buf)

  local ctx = complete.context("GET {{ho", 8)
  local items = complete.items(ctx, buf)
  local host = find(items, "host")
  t.truthy(host, "host is offered")
  t.eq(host.label, "host", "the menu still reads as a plain name")
  t.eq(host.insertText, "{{host}}", "but it inserts the whole thing")
  t.eq(host.filterText, "host")
  t.eq(host.curlite.start, 4)
  t.eq(host.curlite.stop, 8)
  t.eq(host.curlite.back, 0, "the cursor lands after the braces")
end

function M.an_unfinished_path_keeps_the_cursor_inside(t)
  local buf = project({
    ["api.http"] = "### LOGIN\nPOST https://x.dev/login\n\nGET {{LOG\n",
  }, "api.http")
  vim.api.nvim_win_set_buf(0, buf)

  local items = complete.items(complete.context("GET {{LOG", 9), buf)
  local chain = find(items, "LOGIN.response.body.$.")
  t.truthy(chain, "the chain reference is offered")
  t.eq(chain.insertText, "{{LOGIN.response.body.$.}}")
  t.eq(chain.curlite.back, 2, "a path still being written stays inside the braces")

  local status = find(items, "LOGIN.response.status")
  t.eq(status.curlite.back, 0, "a finished one does not")
end

-- blink.cmp's auto-brackets appends `()` to every item whose kind is
-- `Function` or `Method`, because those mean "callable". Nothing curlite
-- offers is callable: `GET` tagged as `Method` is what produced `GET ()`.
function M.nothing_is_offered_as_a_callable(t)
  local buf = project({
    ["http-client.env.json"] = [[{ "$curliteshared": { "host": "https://x.dev" } }]],
    ["api.http"] = "### LOGIN\nPOST https://x.dev\n\nGET {{\n",
  }, "api.http")
  vim.api.nvim_win_set_buf(0, buf)

  local CALLABLE = { [2] = "Method", [3] = "Function" }
  local sites = {
    { "", 0 },              -- methods and header names
    { "GET {{", 6 },        -- variables and the `$` helpers
    { "# @", 3 },           -- metadata
    { "Accept: ", 8 },      -- header values
  }
  for _, site in ipairs(sites) do
    for _, entry in ipairs(complete.items(complete.context(site[1], site[2]), buf)) do
      t.falsy(
        CALLABLE[entry.kind],
        ("%q offers %q as %s, which blink would append `()` to")
          :format(site[1], entry.label, CALLABLE[entry.kind] or "?")
      )
    end
  end

  -- And the two that used to be.
  local methods = complete.items(complete.context("", 0), buf)
  t.eq(find(methods, "GET").kind, complete.KIND.Keyword, "a method is a keyword")
  local vars = complete.items(complete.context("GET {{", 6), buf)
  t.eq(find(vars, "$uuid").kind, complete.KIND.Value, "a dynamic helper yields a value")
end

function M.only_variables_are_wrapped(t)
  -- A header or a method is not a `{{...}}`, and must not grow braces.
  local items = complete.items(complete.context("", 0), 0)
  local get = find(items, "GET")
  t.eq(get.insertText, "GET ")
  t.falsy(get.curlite)

  local meta = complete.items(complete.context("# @na", 5), 0)
  t.truthy(find(meta, "name"))
  t.falsy(find(meta, "name").curlite)
end

function M.a_closed_brace_is_not_a_variable(t)
  local ctx = complete.context("GET {{host}}/users", 18)
  t.truthy(ctx == nil or ctx.kind ~= "variable")
end

function M.the_last_open_brace_wins(t)
  local ctx = complete.context("GET {{host}}/{{pa", 17)
  t.eq(ctx.kind, "variable")
  t.eq(ctx.prefix, "pa")
end

function M.metadata_headers_and_line_starts_are_recognised(t)
  t.eq(complete.context("# @ti", 5), { kind = "metadata", prefix = "ti", start = 3 })
  local header = complete.context("Content-Type: app", 17)
  t.eq(header.kind, "header_value")
  t.eq(header.header, "Content-Type")
  t.eq(complete.context("GE", 2), { kind = "line_start", prefix = "GE", start = 0 })
end

function M.items_match_the_context(t)
  local buf = project({ ["api.http"] = "GET https://example.com\n" }, "api.http")
  t.truthy(vim.tbl_contains(labels(complete.items(complete.context("# @", 3), buf)), "timeout"))
  t.truthy(
    vim.tbl_contains(labels(complete.items(complete.context("POS", 3), buf)), "POST")
  )
  t.truthy(
    vim.tbl_contains(
      labels(complete.items(complete.context("Accept: ", 8), buf)),
      "application/json"
    )
  )
end

--- -------------------------------------------------------------- variables

function M.shared_variables_complete_with_no_environment_selected(t)
  local buf = project({
    ["http-client.env.json"] = [[{
      "$curliteshared": { "apiVersion": "v1" },
      "dev": { "host": "http://localhost:3000" },
      "prod": { "host": "https://api.example.com" }
    }]],
    ["api.http"] = "GET {{host}}\n",
  }, "api.http")

  local items = complete.variable_items(buf)
  local shared = find(items, "apiVersion")
  t.truthy(shared, "the shared block always completes")
  t.truthy(shared.detail:find("$curliteshared", 1, true), "it says where it comes from")
  t.falsy(find(items, "host"), "an unselected environment's variables do not resolve, so they are not offered")
end

function M.the_selected_environment_completes_alongside_shared(t)
  local buf, dir = project({
    ["http-client.env.json"] = [[{
      "$curliteshared": { "apiVersion": "v1" },
      "dev": { "host": "http://localhost:3000" },
      "prod": { "host": "https://api.example.com" }
    }]],
    ["api.http"] = "GET {{host}}\n",
  }, "api.http")
  env.select("dev", dir .. "/api.http")

  local items = complete.variable_items(buf)
  t.truthy(find(items, "apiVersion"), "shared still completes inside an environment")
  local host = find(items, "host")
  t.truthy(host, "the selected environment's variables complete")
  t.truthy(host.detail:find("dev", 1, true), "labelled with the environment it came from")
  t.truthy(host.detail:find("localhost", 1, true), "and with the value it holds")
end

function M.an_environment_value_shadows_the_shared_one(t)
  local buf, dir = project({
    ["http-client.env.json"] = [[{
      "$curliteshared": { "host": "shared-host" },
      "dev": { "host": "dev-host" }
    }]],
    ["api.http"] = "GET {{host}}\n",
  }, "api.http")
  env.select("dev", dir .. "/api.http")

  local items = complete.variable_items(buf)
  local host = find(items, "host")
  t.eq(#vim.tbl_filter(function(e)
    return e.label == "host"
  end, items), 1, "one entry per name")
  t.truthy(host.detail:find("dev%-host"), "described by the value that would actually be sent")
end

function M.nested_values_complete_by_path(t)
  local buf, dir = project({
    ["http-client.env.json"] = [[{ "dev": { "auth": { "client_id": "abc" } } }]],
    ["api.http"] = "GET x\n",
  }, "api.http")
  env.select("dev", dir .. "/api.http")

  local items = complete.variable_items(buf)
  t.truthy(find(items, "auth"))
  t.truthy(find(items, "auth.client_id"), "{{auth.client_id}} resolves, so it completes")
end

function M.document_variables_requests_and_functions_complete(t)
  local buf = project({
    ["api.http"] = table.concat({
      "@token = abc123",
      "",
      "### LOGIN",
      "POST https://example.com/login",
      "",
      "### ME",
      "GET https://example.com/me",
      "",
    }, "\n"),
  }, "api.http")

  local items = complete.variable_items(buf)
  local token = find(items, "token")
  t.truthy(token)
  t.truthy(token.detail:find("abc123", 1, true))
  t.truthy(find(items, "LOGIN.response.body.$."), "a named request is offered as a chain reference")
  t.truthy(find(items, "LOGIN.response.status"))
  t.truthy(find(items, "$uuid"), "the dynamic functions are always there")
end

function M.script_globals_complete(t)
  local buf = project({ ["api.http"] = "GET x\n" }, "api.http")
  env.globals.session = "s-1"
  local items = complete.variable_items(buf)
  local entry = find(items, "session")
  t.truthy(entry)
  t.truthy(entry.detail:find("script global", 1, true))
  env.globals = {}
end

--- --------------------------------------------------------------- omnifunc

function M.omnifunc_finds_the_start_and_filters(t)
  local buf = project({
    ["http-client.env.json"] = [[{ "$curliteshared": { "apiVersion": "v1", "apiKey": "k" } }]],
    ["api.http"] = "GET {{api\n",
  }, "api.http")

  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 9 })

  t.eq(complete.omnifunc(1, ""), 4, "completion replaces from the braces, which it rewrites")
  -- Vim hands back everything from `findstart` on, braces included.
  local words = vim.tbl_map(function(entry)
    return entry.word
  end, complete.omnifunc(0, "{{api"))
  table.sort(words)
  t.eq(words, { "{{apiKey}}", "{{apiVersion}}" })

  -- A caller that strips the braces itself is matched just the same.
  local bare = vim.tbl_map(function(entry)
    return entry.word
  end, complete.omnifunc(0, "api"))
  table.sort(bare)
  t.eq(bare, { "{{apiKey}}", "{{apiVersion}}" })

  -- Nothing to complete mid-URL: the menu must not open at all.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET https://example.com/a" })
  vim.api.nvim_win_set_cursor(0, { 1, 25 })
  t.eq(complete.omnifunc(1, ""), -3)
end

return M
