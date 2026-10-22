-- Turning an OpenAPI / Swagger description into `.http` blocks.
--
-- The thing worth guarding here is that a generated block is a *real* request:
-- every one of these round-trips back through curlite's own parser, so the
-- import can never produce something the plugin cannot read.

local config = require("curlite.config")
local env = require("curlite.env")
local openapi = require("curlite.openapi")
local parser = require("curlite.parser")
local util = require("curlite.util")

local M = {}

local SPEC = {
  openapi = "3.0.3",
  info = { title = "Petstore", version = "1.0.0" },
  servers = { { url = "https://api.example.com/v2" } },
  paths = {
    ["/pets"] = {
      get = {
        operationId = "listPets",
        summary = "List pets",
        tags = { "pets" },
        parameters = {
          { name = "limit", ["in"] = "query", schema = { type = "integer", default = 20 } },
          {
            name = "status",
            ["in"] = "query",
            required = true,
            schema = { type = "string", enum = { "available", "sold" } },
          },
          { name = "q", ["in"] = "query", required = true, schema = { type = "string" } },
        },
        responses = {
          ["200"] = { description = "ok", content = { ["application/json"] = {} } },
        },
      },
      post = {
        operationId = "createPet",
        summary = "Add a pet",
        requestBody = {
          required = true,
          content = {
            ["application/json"] = { schema = { ["$ref"] = "#/components/schemas/Pet" } },
          },
        },
        responses = { ["201"] = { description = "created" } },
      },
    },
    ["/pets/{petId}"] = {
      parameters = {
        { name = "petId", ["in"] = "path", required = true, schema = { type = "integer" } },
      },
      get = {
        operationId = "getPet",
        responses = {
          ["200"] = { description = "ok", content = { ["application/json"] = {} } },
        },
      },
      delete = {
        operationId = "deletePet",
        summary = "Remove a pet",
        description = "Deletes it for good",
        deprecated = true,
        parameters = {
          {
            name = "X-Request-Id",
            ["in"] = "header",
            required = true,
            schema = { type = "string", example = "abc-123" },
          },
          { name = "Accept-Language", ["in"] = "header", schema = { type = "string" } },
        },
        responses = { ["204"] = { description = "gone" } },
      },
    },
  },
  components = {
    schemas = {
      Pet = {
        type = "object",
        required = { "name", "photoUrl" },
        properties = {
          name = { type = "string", example = "Rex" },
          photoUrl = { type = "string", format = "uri" },
          age = { type = "integer", default = 1 },
          tags = { type = "array", items = { type = "string" } },
          vet = { ["$ref"] = "#/components/schemas/Vet" },
          born = { type = "string", format = "date" },
        },
      },
      Vet = {
        type = "object",
        properties = { id = { type = "integer" }, name = { type = "string" } },
      },
    },
  },
}

---@return table
local function spec()
  return vim.deepcopy(SPEC)
end

local function reset()
  config.setup({})
  env.reset()
  openapi.reset()
end

---@param ops table[]
---@param label string
---@return table
local function find(ops, label)
  for _, op in ipairs(ops) do
    if op.label == label then
      return op
    end
  end
  error("no operation " .. label, 2)
end

--- Parse a generated block the way curlite reads the file it lands in.
---@param op table
---@param opts table|nil
---@return curlite.Request
local function roundtrip(op, opts)
  local lines = openapi.block(op, opts)
  local doc = parser.parse(lines, "/tmp/import.http")
  if #doc.requests ~= 1 then
    error(("a block must be exactly one request, got %d:\n%s"):format(
      #doc.requests,
      table.concat(lines, "\n")
    ), 2)
  end
  return doc.requests[1]
end

---@param files table<string, string>
---@return string dir
local function project(files)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  reset()
  return dir
end

function M.every_operation_is_listed_in_a_readable_order(t)
  reset()
  local ops = openapi.operations(spec(), {})
  local labels = {}
  for _, op in ipairs(ops) do
    table.insert(labels, op.label)
  end
  -- Paths alphabetically, and within a path the way you think about a
  -- resource rather than alphabetically.
  t.eq(labels, { "GET /pets", "POST /pets", "GET /pets/{petId}", "DELETE /pets/{petId}" })
end

function M.the_fuzzy_text_covers_what_you_would_type(t)
  reset()
  local op = find(openapi.operations(spec(), {}), "GET /pets")
  t.match(op.ordinal, "GET")
  t.match(op.ordinal, "/pets")
  t.match(op.ordinal, "List pets")
  t.match(op.ordinal, "listPets")
  t.match(op.ordinal, "pets")
end

function M.a_block_is_a_request_curlite_can_read(t)
  reset()
  for _, op in ipairs(openapi.operations(spec(), {})) do
    local req = roundtrip(op)
    t.eq(req.method, op.method)
    t.truthy(req.url ~= "" and req.url ~= nil, "every block has a URL")
  end
end

function M.required_query_parameters_land_on_the_url(t)
  reset()
  local req = roundtrip(find(openapi.operations(spec(), {}), "GET /pets"))
  -- `status` has an enum, so the first member is the value; `q` has nothing,
  -- so it is left as a variable; `limit` is optional and left off.
  t.eq(req.url, "https://api.example.com/v2/pets?q={{q}}&status=available")
  t.falsy(req.url:find("limit", 1, true), "an optional parameter is not assumed")
end

function M.query_all_includes_the_optional_ones(t)
  reset()
  config.setup({ openapi = { query = "all" } })
  local req = roundtrip(find(openapi.operations(spec(), {}), "GET /pets"))
  t.eq(req.url, "https://api.example.com/v2/pets?limit=20&q={{q}}&status=available")
  reset()
end

function M.query_none_leaves_the_url_alone(t)
  reset()
  config.setup({ openapi = { query = "none" } })
  local req = roundtrip(find(openapi.operations(spec(), {}), "GET /pets"))
  t.eq(req.url, "https://api.example.com/v2/pets")
  reset()
end

function M.a_path_parameter_with_nothing_to_go_on_becomes_a_variable(t)
  reset()
  -- `/pets/0` would look like a real pet. A variable says what is missing,
  -- and completion offers it.
  local req = roundtrip(find(openapi.operations(spec(), {}), "GET /pets/{petId}"))
  t.eq(req.url, "https://api.example.com/v2/pets/{{petId}}")
end

function M.a_path_parameter_uses_the_specs_value_when_there_is_one(t)
  reset()
  local s = spec()
  s.paths["/pets/{petId}"].parameters[1].example = 42
  local req = roundtrip(find(openapi.operations(s, {}), "GET /pets/{petId}"))
  t.eq(req.url, "https://api.example.com/v2/pets/42")
end

function M.required_headers_are_written_and_optional_ones_are_not(t)
  reset()
  local req = roundtrip(find(openapi.operations(spec(), {}), "DELETE /pets/{petId}"))
  t.eq(req.headers["X-Request-Id"], "abc-123")
  t.eq(req.headers["Accept-Language"], nil, "an optional header is not assumed")
end

function M.a_header_the_environment_sends_is_left_out(t)
  reset()
  local op = find(openapi.operations(spec(), {}), "DELETE /pets/{petId}")
  local req = roundtrip(op, { env_headers = { ["x-request-id"] = "{{trace}}" } })
  t.eq(
    req.headers["X-Request-Id"],
    nil,
    "repeating it here would override the environment with the spec's placeholder"
  )
end

function M.accept_comes_from_the_response_content_type(t)
  reset()
  local req = roundtrip(find(openapi.operations(spec(), {}), "GET /pets"))
  t.eq(req.headers["Accept"], "application/json")

  local quiet = roundtrip(find(openapi.operations(spec(), {}), "DELETE /pets/{petId}"))
  t.eq(quiet.headers["Accept"], nil, "a 204 advertises no body to accept")
end

function M.a_body_is_built_from_the_schema_required_fields_first(t)
  reset()
  local req = roundtrip(find(openapi.operations(spec(), {}), "POST /pets"))
  t.eq(req.headers["Content-Type"], "application/json")
  t.eq(req.body, [[{
  "name": "Rex",
  "photoUrl": "https://example.com",
  "age": 1,
  "born": "1970-01-01",
  "tags": [
    ""
  ],
  "vet": {
    "id": 0,
    "name": ""
  }
}]])
  t.truthy(util.json_decode(req.body), "and it is valid JSON")
end

function M.a_media_types_own_example_wins_over_the_schema(t)
  reset()
  local s = spec()
  s.paths["/pets"].post.requestBody.content["application/json"].example =
    { name = "Fido", age = 7 }
  local req = roundtrip(find(openapi.operations(s, {}), "POST /pets"))
  t.eq(util.json_decode(req.body), { name = "Fido", age = 7 })
end

function M.a_form_body_is_written_the_way_curlite_reads_one(t)
  reset()
  local s = spec()
  s.paths["/pets"].post.requestBody.content = {
    ["application/x-www-form-urlencoded"] = {
      schema = {
        type = "object",
        required = { "name" },
        properties = { name = { type = "string", example = "Rex" }, age = { type = "integer" } },
      },
    },
  }
  local req = roundtrip(find(openapi.operations(s, {}), "POST /pets"))
  t.eq(req.headers["Content-Type"], "application/x-www-form-urlencoded")
  t.eq(req.body, "name=Rex\n&age=0")
end

function M.a_multipart_body_carries_its_boundary_in_the_header(t)
  reset()
  local s = spec()
  s.paths["/pets"].post.requestBody.content = {
    ["multipart/form-data"] = {
      schema = {
        type = "object",
        required = { "name" },
        properties = {
          name = { type = "string", example = "Rex" },
          photo = { type = "string", format = "binary" },
        },
      },
    },
  }
  local req = roundtrip(find(openapi.operations(s, {}), "POST /pets"))
  -- Without the boundary in the header the body is unsendable, and curlite's
  -- own parser is what reads it back out.
  t.eq(req.headers["Content-Type"], "multipart/form-data; boundary=CurliteBoundary")
  t.match(req.body, "--CurliteBoundary")
  t.match(req.body, 'name="name"')
  t.match(req.body, "--CurliteBoundary--")
end

function M.a_recursive_schema_terminates(t)
  reset()
  local s = spec()
  s.components.schemas.Node = {
    type = "object",
    properties = {
      value = { type = "string" },
      child = { ["$ref"] = "#/components/schemas/Node" },
    },
  }
  s.paths["/pets"].post.requestBody.content["application/json"].schema =
    { ["$ref"] = "#/components/schemas/Node" }
  local req = roundtrip(find(openapi.operations(s, {}), "POST /pets"))
  t.truthy(util.json_decode(req.body), "a schema that contains itself still produces JSON")
  t.truthy(#req.body < 2000, "and the depth limit keeps it small")
end

function M.the_title_is_the_summary_and_the_name_is_the_operation_id(t)
  reset()
  local lines = openapi.block(find(openapi.operations(spec(), {}), "DELETE /pets/{petId}"))
  t.eq(lines[1], "### Remove a pet")
  t.eq(lines[2], "# @name deletePet")
  t.eq(lines[3], "# deprecated")
  t.eq(lines[4], "# Deletes it for good")
  -- `# @name` is what `# @run` and `{{deletePet.response...}}` reach for.
  local req = parser.parse(lines, "/tmp/i.http").requests[1]
  t.eq(req.name, "deletePet")
end

function M.an_operation_with_no_summary_falls_back_to_its_id(t)
  reset()
  local lines = openapi.block(find(openapi.operations(spec(), {}), "GET /pets/{petId}"))
  t.eq(lines[1], "### getPet")
  t.falsy(lines[2]:find("@name", 1, true), "naming it twice would say nothing extra")
end

function M.the_title_source_is_configurable(t)
  reset()
  config.setup({ openapi = { name = "operationId" } })
  local ops = openapi.operations(spec(), {})
  t.eq(openapi.block(find(ops, "DELETE /pets/{petId}"))[1], "### deletePet")
  config.setup({ openapi = { name = "path" } })
  t.eq(openapi.block(find(ops, "DELETE /pets/{petId}"))[1], "### DELETE /pets/{petId}")
  reset()
end

function M.comments_can_be_turned_off(t)
  reset()
  config.setup({ openapi = { comments = false, name_meta = false } })
  local lines = openapi.block(find(openapi.operations(spec(), {}), "DELETE /pets/{petId}"))
  t.eq(lines[1], "### Remove a pet")
  t.eq(lines[2], "DELETE https://api.example.com/v2/pets/{{petId}}")
  reset()
end

function M.a_block_ends_with_a_blank_line(t)
  reset()
  local lines = openapi.block(find(openapi.operations(spec(), {}), "GET /pets"))
  t.eq(lines[#lines], "", "so the next block does not start on its heels")
end

--- ------------------------------------------------------------------- base

function M.the_base_follows_the_environment_when_it_defines_a_host(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": { "host": "http://localhost:3000" } }]],
    ["api.http"] = "GET x\n",
  })
  local source = dir .. "/api.http"
  env.select("dev", source)

  local ops = openapi.operations(spec(), { source = source })
  -- The environment owns the host; the spec's server owns the path under it.
  t.eq(find(ops, "GET /pets").url, "{{host}}/v2/pets")
  reset()
end

function M.the_base_follows_the_environment_before_one_is_even_picked(t)
  -- Importing before choosing an environment is the normal way round: `host`
  -- lives in `dev` and `prod`, not in the shared block, and the block has to
  -- come out the same either way.
  local dir = project({
    ["http-client.env.json"] = [[{
      "dev": { "host": "http://localhost:3000" },
      "prod": { "host": "https://api.example.com" }
    }]],
    ["api.http"] = "GET x\n",
  })
  local source = dir .. "/api.http"
  t.falsy(env.chosen(source), "nothing selected yet")
  t.eq(find(openapi.operations(spec(), { source = source }), "GET /pets").url, "{{host}}/v2/pets")
  reset()
end

function M.the_base_is_the_specs_server_when_the_environment_has_none(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": { "token": "x" } }]],
    ["api.http"] = "GET x\n",
  })
  local source = dir .. "/api.http"
  env.select("dev", source)
  t.eq(find(openapi.operations(spec(), { source = source }), "GET /pets").url,
    "https://api.example.com/v2/pets")
  reset()
end

function M.base_spec_ignores_the_environment(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": { "host": "http://localhost:3000" } }]],
    ["api.http"] = "GET x\n",
  })
  local source = dir .. "/api.http"
  env.select("dev", source)
  config.setup({ openapi = { base = "spec" } })
  t.eq(find(openapi.operations(spec(), { source = source }), "GET /pets").url,
    "https://api.example.com/v2/pets")
  reset()
end

function M.base_can_be_a_literal(t)
  reset()
  config.setup({ openapi = { base = "{{baseUrl}}" } })
  t.eq(find(openapi.operations(spec(), {}), "GET /pets").url, "{{baseUrl}}/pets")
  reset()
end

function M.server_variables_are_filled_in_from_their_defaults(t)
  reset()
  local s = spec()
  s.servers = {
    {
      url = "https://{region}.example.com/{version}",
      variables = { region = { default = "eu" }, version = { enum = { "v3" } } },
    },
  }
  t.eq(openapi.server(s), "https://eu.example.com/v3")
end

function M.with_no_server_at_all_the_base_is_a_variable(t)
  reset()
  local s = spec()
  s.servers = nil
  t.eq(find(openapi.operations(s, {}), "GET /pets").url, "{{host}}/pets")
end

--- -------------------------------------------------------------- swagger 2

function M.swagger_two_is_read_too(t)
  reset()
  local s = {
    swagger = "2.0",
    host = "api.example.com",
    basePath = "/v1",
    schemes = { "https" },
    consumes = { "application/json" },
    produces = { "application/json" },
    definitions = {
      Pet = {
        type = "object",
        required = { "name" },
        properties = { name = { type = "string", example = "Rex" } },
      },
    },
    paths = {
      ["/pets"] = {
        post = {
          operationId = "addPet",
          summary = "Add a pet",
          parameters = {
            { name = "body", ["in"] = "body", schema = { ["$ref"] = "#/definitions/Pet" } },
          },
          responses = { ["200"] = { description = "ok" } },
        },
      },
      ["/upload"] = {
        post = {
          operationId = "upload",
          consumes = { "application/x-www-form-urlencoded" },
          parameters = {
            { name = "note", ["in"] = "formData", type = "string", default = "hi" },
          },
          responses = { ["200"] = { description = "ok" } },
        },
      },
    },
  }

  local ops = openapi.operations(s, {})
  local req = roundtrip(find(ops, "POST /pets"))
  t.eq(req.url, "https://api.example.com/v1/pets")
  t.eq(req.headers["Content-Type"], "application/json")
  t.eq(req.headers["Accept"], "application/json", "`produces` is the 2.0 spelling")
  t.eq(util.json_decode(req.body), { name = "Rex" })

  local form = roundtrip(find(ops, "POST /upload"))
  t.eq(form.headers["Content-Type"], "application/x-www-form-urlencoded")
  t.eq(form.body, "note=hi")
end

--- ------------------------------------------------------------- the source

function M.a_spec_is_found_by_walking_up_from_the_file(t)
  local dir = project({
    ["openapi.json"] = [[{ "openapi": "3.0.0", "paths": {} }]],
    ["requests/api.http"] = "GET x\n",
  })
  local found = openapi.discover(dir .. "/requests/api.http")
  t.eq(found, { dir .. "/openapi.json" })
  reset()
end

function M.a_spec_beside_the_file_wins_over_one_further_up(t)
  local dir = project({
    ["openapi.json"] = [[{ "openapi": "3.0.0", "paths": {} }]],
    ["requests/openapi.json"] = [[{ "openapi": "3.0.0", "paths": {} }]],
    ["requests/api.http"] = "GET x\n",
  })
  local found = openapi.discover(dir .. "/requests/api.http")
  t.eq(found[1], dir .. "/requests/openapi.json")
  reset()
end

function M.loading_a_file_reads_json_and_yaml(t)
  local dir = project({
    ["openapi.json"] = [[{ "openapi": "3.0.0", "info": { "title": "J" }, "paths": {} }]],
    ["openapi.yaml"] = "openapi: 3.0.0\ninfo:\n  title: Y\npaths: {}\n",
  })
  t.eq(openapi.load_file(dir .. "/openapi.json").info.title, "J")
  t.eq(openapi.load_file(dir .. "/openapi.yaml").info.title, "Y")

  local missing, err = openapi.load_file(dir .. "/nope.json")
  t.eq(missing, nil)
  t.match(err, "does not exist")
  reset()
end

function M.an_edited_spec_is_picked_up(t)
  local dir = project({ ["openapi.yaml"] = "openapi: 3.0.0\ninfo:\n  title: One\npaths: {}\n" })
  t.eq(openapi.load_file(dir .. "/openapi.yaml").info.title, "One")
  -- The cache is keyed on size and mtime, so a rewrite is seen at once.
  vim.wait(10)
  util.write_file(dir .. "/openapi.yaml", "openapi: 3.0.0\ninfo:\n  title: Two\npaths: {}\n")
  t.eq(openapi.load_file(dir .. "/openapi.yaml").info.title, "Two")
  reset()
end

function M.html_and_nonsense_are_refused_with_a_reason(t)
  reset()
  local value, err = openapi.parse("<!DOCTYPE html><html></html>", "the page")
  t.eq(value, nil)
  t.match(err, "HTML")

  value, err = openapi.parse("{ this is not json", "spec.json")
  t.eq(value, nil)
  t.truthy(err)
end

function M.a_swagger_ui_page_names_its_spec(t)
  reset()
  local html = [[
    <html><script>
      window.ui = SwaggerUIBundle({ url: "/v3/api-docs", dom_id: '#swagger-ui' });
    </script></html>
  ]]
  t.eq(
    openapi.spec_url_in(html, "https://example.com/swagger/index.html"),
    "https://example.com/v3/api-docs"
  )
end

function M.a_page_that_names_nothing_falls_back_to_the_usual_paths(t)
  reset()
  local found = openapi.spec_url_in("<html><body>nothing here</body></html>", "https://example.com/docs")
  t.eq(found, "https://example.com/openapi.json")
end

function M.relative_urls_resolve_against_the_page(t)
  reset()
  t.eq(openapi.resolve_url("/a/b.json", "https://x.test/docs/ui.html"), "https://x.test/a/b.json")
  t.eq(openapi.resolve_url("b.json", "https://x.test/docs/ui.html"), "https://x.test/docs/b.json")
  t.eq(openapi.resolve_url("https://y.test/c.json", "https://x.test/"), "https://y.test/c.json")
end

--- Run `fn` with curl stubbed out: `urls` maps a URL to what it serves, and
--- anything else 404s the way `--fail` reports it.
---@param urls table<string, string>
---@param fn fun()
---@return string[] requested
local function with_server(urls, fn)
  local real = vim.system
  local requested = {}
  vim.system = function(args, _, cb)
    local url = args[#args]
    table.insert(requested, url)
    local body = urls[url]
    cb({
      code = body and 0 or 22,
      stdout = body or "",
      stderr = body and "" or "The requested URL returned error: 404",
    })
    return { wait = function() end, kill = function() end }
  end
  local ok, err = pcall(fn)
  vim.system = real
  if not ok then
    error(err, 0)
  end
  return requested
end

function M.a_spec_is_fetched_from_a_url(t)
  reset()
  local body = [[{ "openapi": "3.0.0", "info": { "title": "Remote" },
    "paths": { "/ping": { "get": { "responses": {} } } } }]]
  local got, err
  with_server({ ["https://api.test/openapi.json"] = body }, function()
    openapi.load("https://api.test/openapi.json", nil, function(spec, e)
      got, err = spec, e
    end)
    vim.wait(200, function()
      return got ~= nil or err ~= nil
    end)
  end)
  t.eq(err, nil)
  t.eq(got.info.title, "Remote")
  t.eq(got.__source, "https://api.test/openapi.json")
  -- The URL it came from is the base when the spec names no server.
  t.eq(openapi.server(got), "https://api.test")
end

function M.a_url_is_only_fetched_once_a_session(t)
  reset()
  local body = [[{ "openapi": "3.0.0", "paths": {} }]]
  local requested = with_server({ ["https://api.test/s.json"] = body }, function()
    for _ = 1, 2 do
      local done = false
      openapi.load_url("https://api.test/s.json", function()
        done = true
      end)
      vim.wait(200, function()
        return done
      end)
    end
  end)
  t.eq(#requested, 1, "the second read comes from the session cache")
  openapi.reset()
end

function M.a_swagger_ui_page_is_followed_to_its_spec(t)
  reset()
  local page = [[<html><script>SwaggerUIBundle({ url: "/v3/api-docs" })</script></html>]]
  local body = [[{ "openapi": "3.0.0", "info": { "title": "Behind the page" },
    "paths": {} }]]
  local got, err
  local requested = with_server({
    ["https://api.test/swagger/index.html"] = page,
    ["https://api.test/v3/api-docs"] = body,
  }, function()
    openapi.load("https://api.test/swagger/index.html", nil, function(spec, e)
      got, err = spec, e
    end)
    vim.wait(400, function()
      return got ~= nil or err ~= nil
    end)
  end)
  t.eq(err, nil)
  t.eq(got.info.title, "Behind the page")
  t.eq(requested, { "https://api.test/swagger/index.html", "https://api.test/v3/api-docs" })
end

function M.a_page_that_leads_nowhere_says_so(t)
  reset()
  local got, err
  with_server({ ["https://api.test/docs"] = "<html>nothing</html>" }, function()
    openapi.load("https://api.test/docs", nil, function(spec, e)
      got, err = spec, e
    end)
    vim.wait(400, function()
      return got ~= nil or err ~= nil
    end)
  end)
  t.eq(got, nil)
  -- It tried the conventional path and got a 404 from it.
  t.match(err, "could not fetch")
end

function M.a_url_that_fails_reports_what_curl_said(t)
  reset()
  local got, err
  with_server({}, function()
    openapi.load("https://api.test/nope.json", nil, function(spec, e)
      got, err = spec, e
    end)
    vim.wait(200, function()
      return got ~= nil or err ~= nil
    end)
  end)
  t.eq(got, nil)
  t.match(err, "404")
end

function M.a_spec_with_no_operations_is_empty_not_an_error(t)
  reset()
  t.eq(openapi.operations({ openapi = "3.0.0", paths = {} }, {}), {})
  t.eq(openapi.operations({}, {}), {})
  t.eq(openapi.operations(nil, {}), {})
end

function M.the_request_line_is_found_for_the_cursor(t)
  reset()
  local lines = openapi.block(find(openapi.operations(spec(), {}), "POST /pets"))
  t.eq(lines[openapi.request_line(lines)], "POST https://api.example.com/v2/pets")
end

return M
