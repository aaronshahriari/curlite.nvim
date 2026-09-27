local env = require("curlite.env")
local util = require("curlite.util")

--- Build a throwaway project tree and return its paths.
---@param files table<string, string>
---@return string dir
local function project(files)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  -- A `.git` makes the root deterministic even without an env file.
  vim.fn.mkdir(dir .. "/.git", "p")
  return dir
end

local M = {}

function M.loads_environments(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "$shared": { "apiVersion": "v1" },
      "dev":  { "host": "http://localhost:3000" },
      "prod": { "host": "https://api.example.com" }
    }]],
    ["api.http"] = "GET {{host}}\n",
  })
  env.reset()
  t.eq(env.names(dir .. "/api.http"), { "dev", "prod" })
end

function M.shared_is_merged_under_the_selection(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "$shared": { "apiVersion": "v1", "host": "shared-host" },
      "prod": { "host": "https://api.example.com" }
    }]],
    ["api.http"] = "GET {{host}}\n",
  })
  env.reset()
  env.select("prod", dir .. "/api.http")
  local vars, name = env.active(dir .. "/api.http")
  t.eq(name, "prod")
  t.eq(vars.apiVersion, "v1")
  t.eq(vars.host, "https://api.example.com", "the environment must win over $shared")
end

function M.private_file_overrides_public(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": { "host": "http://localhost", "token": "PLACEHOLDER" } }]],
    ["http-client.private.env.json"] = [[{ "dev": { "token": "real-secret" } }]],
    ["api.http"] = "GET {{host}}\n",
  })
  env.reset()
  env.select("dev", dir .. "/api.http")
  local vars = env.active(dir .. "/api.http")
  t.eq(vars.host, "http://localhost", "public-only keys survive")
  t.eq(vars.token, "real-secret")
end

function M.nearer_file_wins(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": { "host": "outer", "only_outer": "yes" } }]],
    ["api.http"] = "GET {{host}}\n",
  })
  vim.fn.mkdir(dir .. "/nested", "p")
  util.write_file(dir .. "/nested/http-client.env.json", [[{ "dev": { "host": "inner" } }]])
  util.write_file(dir .. "/nested/api.http", "GET {{host}}\n")

  env.reset()
  env.select("dev", dir .. "/nested/api.http")
  local vars = env.active(dir .. "/nested/api.http")
  t.eq(vars.host, "inner")
  t.eq(vars.only_outer, "yes", "the outer file still contributes")
end

function M.comments_in_env_files_are_tolerated(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      // the local stack
      "dev": { "host": "http://localhost:3000" }
      /* and nothing else yet */
    }]],
    ["api.http"] = "GET {{host}}\n",
  })
  env.reset()
  t.eq(env.names(dir .. "/api.http"), { "dev" })
end

function M.urls_in_env_files_survive_comment_stripping(t)
  -- The `//` in `https://` must not be mistaken for a comment.
  local dir = project({
    ["http-client.env.json"] = [[{ "prod": { "host": "https://api.example.com/v1" } }]],
    ["api.http"] = "GET {{host}}\n",
  })
  env.reset()
  env.select("prod", dir .. "/api.http")
  t.eq(env.active(dir .. "/api.http").host, "https://api.example.com/v1")
end

function M.nested_objects_are_kept(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": { "auth": { "client_id": "abc", "scopes": ["a","b"] } } }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  env.select("dev", dir .. "/api.http")
  local vars = env.active(dir .. "/api.http")
  t.eq(vars.auth.client_id, "abc")
  t.eq(vars.auth.scopes, { "a", "b" })
end

function M.selection_is_remembered_per_project(t)
  local a = project({
    ["http-client.env.json"] = [[{ "dev": {}, "prod": {} }]],
    ["a.http"] = "GET x\n",
  })
  local b = project({
    ["http-client.env.json"] = [[{ "dev": {}, "prod": {} }]],
    ["b.http"] = "GET x\n",
  })
  env.reset()
  env.select("prod", a .. "/a.http")
  env.select("dev", b .. "/b.http")
  t.eq(env.current(a .. "/a.http"), "prod")
  t.eq(env.current(b .. "/b.http"), "dev")
end

function M.first_environment_is_the_default(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "staging": {}, "alpha": {} }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  -- names() sorts, so "alpha" is first.
  t.eq(env.current(dir .. "/api.http"), "alpha")
end

function M.dotenv_is_read(t)
  local dir = project({
    [".env"] = table.concat({
      "# a comment",
      "TOKEN=plain-value",
      'QUOTED="with spaces"',
      "SINGLE='literal $notexpanded'",
      "TRAILING=value   # inline comment",
      "ESCAPED=\"line1\\nline2\"",
      "",
    }, "\n"),
    ["api.http"] = "GET x\n",
  })
  env.reset()
  local vars = env.dotenv(dir .. "/api.http")
  t.eq(vars.TOKEN, "plain-value")
  t.eq(vars.QUOTED, "with spaces")
  t.eq(vars.SINGLE, "literal $notexpanded")
  t.eq(vars.TRAILING, "value")
  t.eq(vars.ESCAPED, "line1\nline2")
end

function M.missing_env_files_are_not_an_error(t)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  env.reset()
  t.eq(env.names(dir .. "/api.http"), {})
  t.eq(env.active(dir .. "/api.http"), {})
end

return M
