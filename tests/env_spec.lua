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

function M.nothing_is_selected_until_you_pick(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "staging": {}, "alpha": {} }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  -- No guessing: an environment is active because you chose it, never because
  -- it happened to sort first.
  t.eq(env.current(dir .. "/api.http"), nil)
  t.falsy(env.chosen(dir .. "/api.http"))

  env.select("staging", dir .. "/api.http")
  t.eq(env.current(dir .. "/api.http"), "staging")
  t.truthy(env.chosen(dir .. "/api.http"))
end

function M.opening_a_file_forgets_the_selection(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": {}, "prod": {} }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  env.select("prod", dir .. "/api.http")
  env.forget(dir .. "/api.http")
  t.eq(env.current(dir .. "/api.http"), nil)
  t.falsy(env.chosen(dir .. "/api.http"), "you have to be asked again")
end

function M.choosing_no_environment_is_a_choice(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": { "host": "h" } }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  env.select(nil, dir .. "/api.http")
  t.eq(env.current(dir .. "/api.http"), nil)
  t.truthy(env.chosen(dir .. "/api.http"), "picking none must not re-open the picker forever")
end

function M.env_default_is_honoured(t)
  local dir = project({
    ["http-client.env.json"] = [[{ "dev": {}, "prod": {} }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  require("curlite.config").setup({ env = { default = "prod" } })
  t.eq(env.current(dir .. "/api.http"), "prod")
  require("curlite.config").setup({})
  env.reset()
end

function M.curliteshared_holds_the_shared_variables(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "$curliteshared": { "apiVersion": "v1", "host": "shared-host" },
      "dev": { "host": "dev-host" }
    }]],
    ["api.http"] = "GET {{host}}\n",
  })
  env.reset()
  t.eq(env.names(dir .. "/api.http"), { "dev" }, "$curliteshared is not an environment")

  -- Nothing selected: the shared block alone is what resolves.
  local vars, name = env.active(dir .. "/api.http")
  t.eq(name, nil)
  t.eq(vars.host, "shared-host")
  t.eq(vars.apiVersion, "v1")

  env.select("dev", dir .. "/api.http")
  t.eq(env.active(dir .. "/api.http").host, "dev-host")
end

function M.jetbrains_shared_key_still_works(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "$shared": { "apiVersion": "v1", "from": "shared" },
      "$curliteshared": { "from": "curliteshared" },
      "dev": {}
    }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  t.eq(env.names(dir .. "/api.http"), { "dev" }, "neither shared key is an environment")
  local vars = env.active(dir .. "/api.http")
  t.eq(vars.apiVersion, "v1", "a file written for JetBrains still resolves")
  t.eq(vars.from, "curliteshared", "$curliteshared wins where both define a key")
end

function M.vars_previews_an_environment_without_selecting_it(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "$curliteshared": { "apiVersion": "v1" },
      "dev": { "host": "dev-host" },
      "prod": { "host": "prod-host" }
    }]],
    ["api.http"] = "GET x\n",
  })
  env.reset()
  t.eq(env.vars(dir .. "/api.http", "prod").host, "prod-host")
  t.eq(env.vars(dir .. "/api.http", "prod").apiVersion, "v1")
  t.eq(env.current(dir .. "/api.http"), nil, "looking at one must not select it")
  t.eq(env.vars(dir .. "/api.http", nil).host, nil, "nil means the shared block alone")
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
