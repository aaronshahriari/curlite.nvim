-- `$default_headers` in the environment file: shared, per-environment, and
-- what the request itself does to them.

local env = require("curlite.env")
local util = require("curlite.util")
local parser = require("curlite.parser")
local variables = require("curlite.variables")

--- Build a throwaway project tree and return its directory.
---@param files table<string, string>
---@return string dir
local function project(files)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  return dir
end

local ENV = [[{
  "$shared": {
    "apiVersion": "v1",
    "$default_headers": {
      "Accept": "application/json",
      "X-Api-Version": "{{apiVersion}}",
      "X-Shared-Only": "yes"
    }
  },
  "dev": {
    "host": "http://localhost:3000",
    "token": "dev-token"
  },
  "prod": {
    "host": "https://api.example.com",
    "token": "prod-token",
    "$default_headers": {
      "Authorization": "Bearer {{token}}",
      "X-Shared-Only": false,
      "Accept": "application/vnd.api+json"
    }
  }
}]]

--- Resolve the first request in `text` against `envname`.
---@return curlite.Request
local function resolve(dir, text, envname)
  local path = dir .. "/api.http"
  util.write_file(path, text)
  env.reset()
  env.select(envname, path)
  local doc = parser.parse_file(path)
  local req = doc.requests[1]
  return (variables.render_request(req, variables.context(req, path)))
end

local function header(req, name)
  for key, value in pairs(req.headers) do
    if key:lower() == name:lower() then
      return value
    end
  end
  return nil
end

local M = {}

function M.shared_default_headers_are_sent(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET {{host}}/things\n", "dev")
  t.eq(header(req, "Accept"), "application/json")
  t.eq(header(req, "X-Shared-Only"), "yes")
end

function M.default_headers_are_substituted(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET {{host}}/things\n", "dev")
  t.eq(header(req, "X-Api-Version"), "v1", "a {{var}} in a default header resolves")
end

function M.the_environment_overrides_shared(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET {{host}}/things\n", "prod")
  t.eq(header(req, "Accept"), "application/vnd.api+json")
end

function M.the_environment_can_drop_a_shared_header(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET {{host}}/things\n", "prod")
  t.eq(header(req, "X-Shared-Only"), nil, "`false` drops it rather than sending it")
end

function M.environment_headers_see_environment_variables(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET {{host}}/things\n", "prod")
  t.eq(header(req, "Authorization"), "Bearer prod-token")
end

function M.the_request_wins(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET {{host}}/things\nAccept: text/csv\n", "prod")
  t.eq(header(req, "Accept"), "text/csv")
  t.eq(header(req, "Authorization"), "Bearer prod-token", "the others still apply")
end

function M.the_request_wins_whatever_the_case(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET {{host}}/things\naccept: text/csv\n", "dev")
  t.eq(header(req, "Accept"), "text/csv")
  local seen = 0
  for name in pairs(req.headers) do
    if name:lower() == "accept" then
      seen = seen + 1
    end
  end
  t.eq(seen, 1, "the default must not be added alongside it")
end

function M.no_environment_still_gets_the_shared_headers(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local req = resolve(dir, "GET https://x.dev/things\n", nil)
  t.eq(header(req, "Accept"), "application/json")
  t.eq(header(req, "Authorization"), nil, "but not prod's")
end

function M.header_keys_are_not_variables(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  env.reset()
  local vars = env.vars(dir .. "/api.http", "prod")
  t.eq(vars["$default_headers"], nil, "the directive must not leak into completion")
  t.eq(vars.token, "prod-token", "real variables are untouched")
end

function M.camel_case_spelling_is_accepted(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "dev": { "$defaultHeaders": { "X-From": "camel" } }
    }]],
  })
  local req = resolve(dir, "GET https://x.dev\n", "dev")
  t.eq(header(req, "X-From"), "camel")
end

function M.the_private_file_can_add_headers(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "dev": { "$default_headers": { "Accept": "application/json" } }
    }]],
    ["http-client.private.env.json"] = [[{
      "dev": { "$default_headers": { "Authorization": "Bearer secret" } }
    }]],
  })
  local req = resolve(dir, "GET https://x.dev\n", "dev")
  t.eq(header(req, "Accept"), "application/json", "the public file still applies")
  t.eq(header(req, "Authorization"), "Bearer secret")
end

function M.headers_reach_the_curl_line(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "dev": { "$default_headers": { "X-Trace": "on" } }
    }]],
  })
  local req = resolve(dir, "GET https://x.dev\n", "dev")
  local cmd = require("curlite.curl").build(req)
  local found = false
  for i, a in ipairs(cmd.argv) do
    if a == "--header" and cmd.argv[i + 1] == "X-Trace: on" then
      found = true
    end
  end
  t.truthy(found, "the resolved header is passed to curl")
end

function M.the_order_is_stable(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "dev": { "$default_headers": { "A": "1", "B": "2", "C": "3", "D": "4", "E": "5" } }
    }]],
  })
  local first = resolve(dir, "GET https://x.dev\n", "dev").header_order
  for _ = 1, 5 do
    t.eq(resolve(dir, "GET https://x.dev\n", "dev").header_order, first)
  end
end

function M.headers_lookup_falls_back_to_shared_alone(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  env.reset()
  local path = dir .. "/api.http"
  t.eq(env.headers(path, nil)["Accept"], "application/json")
  t.eq(env.headers(path, "prod")["Accept"], "application/vnd.api+json")
  t.eq(env.headers(path, "prod")["X-Shared-Only"], false)
end

function M.the_picker_preview_shows_them(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  env.reset()
  local path = dir .. "/api.http"
  local lines, origins = require("curlite.picker").preview_lines(path, "prod")
  local text = table.concat(lines, "\n")
  t.match(text, "sent with every request")
  t.match(text, "Authorization: Bearer {{token}}", "shown unresolved, as written")
  t.falsy(text:find("X%-Shared%-Only"), "a dropped header is not listed")
  t.falsy(text:find("%$default_headers"), "the directive is not shown as a variable")

  local marked = {}
  for line, origin in pairs(origins) do
    if lines[line]:find("Authorization") then
      marked.auth = origin
    elseif lines[line]:find("X%-Api%-Version") then
      marked.version = origin
    end
  end
  t.eq(marked.auth, "prod", "prod's own header is attributed to prod")
  t.eq(marked.version, "$curliteshared", "the inherited one to the shared key")
end

function M.the_preview_shows_headers_with_no_variables(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "dev": { "$default_headers": { "X-Only": "header" } }
    }]],
  })
  env.reset()
  local lines = require("curlite.picker").preview_lines(dir .. "/api.http", "dev")
  t.match(table.concat(lines, "\n"), "X%-Only: header")
end

function M.the_key_is_not_offered_in_completion(t)
  local dir = project({ ["http-client.env.json"] = ENV })
  local path = dir .. "/api.http"
  require("curlite.util").write_file(path, "GET {{host}}\n")
  env.reset()

  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  -- After the load: reading an http buffer deliberately forgets the
  -- environment, so selecting first would be undone here.
  env.select("prod", path)

  local items = require("curlite.complete").variable_items(bufnr)
  for _, it in ipairs(items) do
    local label = it.label or it.word
    t.falsy(
      label and label:find("default_headers", 1, true),
      "completion offered " .. tostring(label)
    )
  end
  -- The real variables are still there.
  local found = false
  for _, it in ipairs(items) do
    if (it.label or it.word) == "token" then
      found = true
    end
  end
  t.truthy(found, "token is still offered")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return M
