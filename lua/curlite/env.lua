--- Environment files.
---
--- curlite reads the JetBrains layout: a `http-client.env.json` beside your
--- `.http` file (or in any directory above it), holding one object per
--- environment, plus an optional `http-client.private.env.json` that is merged
--- over it and that you gitignore.
---
---   {
---     "$curliteshared": { "apiVersion": "v1" },
---     "dev":  { "host": "http://localhost:3000" },
---     "prod": { "host": "https://api.example.com" }
---   }
---
--- `$curliteshared` holds the variables every environment gets. JetBrains'
--- `$shared` is still read, so a file written for another client works here
--- unchanged; both names may appear in the same file and are merged together.
---
--- A `$default_headers` object -- in a shared key, in an environment, or both
--- -- holds headers sent with every request in the project:
---
---   {
---     "$shared": {
---       "$default_headers": { "Accept": "application/json" }
---     },
---     "prod": {
---       "host": "https://api.example.com",
---       "$default_headers": { "Authorization": "Bearer {{token}}" }
---     }
---   }
---
--- The environment's headers are merged over the shared ones, and a request
--- that sets a header itself always wins. A value of `false` drops an
--- inherited header rather than sending it.
---
--- Nothing is selected until you pick an environment. Opening a `.http` file
--- always starts with no environment, so a request can never go out against
--- whichever one happened to be active last time.
---
--- A `.env` file in the same directories is also read and exposed through
--- `{{$dotenv NAME}}`.

local config = require("curlite.config")

local M = {}

-- Selected environment, per project root. Lives for this Neovim session only,
-- and is dropped again when an http buffer is (re-)read: choosing the
-- environment is a deliberate act, every time.
---@type table<string, string>
M.selected = {}

-- Variables set at runtime by post-request scripts (`client.global.set`).
-- These outrank environment variables and survive until Neovim exits or
-- `client.global.clear()` runs.
---@type table<string, any>
M.globals = {}

-- Parsed env files, keyed by path. Every entry carries the size and mtime it
-- was read at, so editing a file on disk is picked up immediately while an
-- unchanged one costs a single `stat` instead of a read plus a JSON decode.
--
-- This matters because `variables.context()` builds a fresh environment for
-- every request, and the completion source rebuilds one per keystroke.
---@type table<string, { sig: string, data: table|nil }>
local json_cache = {}

--- A file's identity for cache purposes: size and mtime to nanosecond
--- precision, or "" when it does not exist.
---@param path string
---@return string
local function file_sig(path)
  local st = vim.uv.fs_stat(path)
  if not st then
    return ""
  end
  return ("%d:%d:%d"):format(st.size, st.mtime.sec, st.mtime.nsec)
end

local function read_json(path)
  local sig = file_sig(path)
  local cached = json_cache[path]
  if cached and cached.sig == sig then
    return cached.data
  end

  if sig == "" then
    json_cache[path] = { sig = sig, data = nil }
    return nil
  end

  local fd = io.open(path, "r")
  if not fd then
    json_cache[path] = { sig = sig, data = nil }
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  if not content or content == "" then
    json_cache[path] = { sig = sig, data = nil }
    return nil
  end
  -- Strip `//` and `/* */` comments so a commented env file still loads; this
  -- is what every editor that touches these files tolerates in practice.
  content = content
    :gsub("/%*.-%*/", "")
    :gsub("([^:])//[^\n\r]*", "%1")
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    require("curlite.util").warn(("could not parse %s: %s"):format(path, decoded))
    -- Cached as a failure so a broken file is complained about once per edit
    -- rather than once per request.
    json_cache[path] = { sig = sig, data = nil }
    return nil
  end

  json_cache[path] = { sig = sig, data = decoded }
  return decoded
end

-- Ancestor lists and resolved project roots, keyed by directory. A directory's
-- ancestry never changes, and its root effectively never does.
local ancestor_cache = {}
local root_cache = {}

--- Directories from `dir` up to the filesystem root.
---@param dir string
---@return string[]
local function walk_up(dir)
  local out, seen = {}, {}
  local cur = vim.fn.fnamemodify(dir, ":p")
  while cur and cur ~= "" and not seen[cur] do
    seen[cur] = true
    table.insert(out, (cur:gsub("/$", "")))
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur or parent == "" then
      break
    end
    cur = parent
  end
  return out
end

--- The same, memoised: a directory's ancestry never changes.
---@param dir string
---@return string[]
local function ancestors(dir)
  local cached = ancestor_cache[dir]
  if cached then
    return cached
  end
  local out = walk_up(dir)
  ancestor_cache[dir] = out
  return out
end

--- The directory a request's env files are resolved from.
---@param source string|nil  path of the .http file
---@return string
function M.base_dir(source)
  if source and source ~= "" then
    local dir = vim.fn.fnamemodify(source, ":p:h")
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return vim.fn.getcwd()
end

--- Project root used as the key for the remembered environment: the nearest
--- directory containing an env file, a `.git`, or failing that the file's own
--- directory.
---@param source string|nil
---@return string
function M.root(source)
  local base = M.base_dir(source)
  local cached = root_cache[base]
  if cached then
    return cached
  end
  local resolved = M.resolve_root(base)
  root_cache[base] = resolved
  return resolved
end

--- The uncached form, for tests and for `reset()`.
---@param base string
---@return string
function M.resolve_root(base)
  local cfg = config.get()
  for _, dir in ipairs(ancestors(base)) do
    for _, name in ipairs(cfg.env.files) do
      if vim.uv.fs_stat(dir .. "/" .. name) then
        return dir
      end
    end
    if vim.uv.fs_stat(dir .. "/.git") then
      return dir
    end
  end
  return base
end

--- Load and merge every env file visible from `source`.
--- Files nearer the `.http` file win; `.private.` variants win over public.
---@param source string|nil
---@return table<string, table<string, any>>  environment name -> variables
function M.load(source)
  local cfg = config.get()
  local dirs = ancestors(M.base_dir(source))
  local merged = {}

  -- Walk from the outermost directory inwards so nearer files overwrite.
  for idx = #dirs, 1, -1 do
    for _, name in ipairs(cfg.env.files) do
      local data = read_json(dirs[idx] .. "/" .. name)
      if data then
        for env_name, vars in pairs(data) do
          if type(vars) == "table" then
            merged[env_name] = vim.tbl_deep_extend("force", merged[env_name] or {}, vars)
          end
        end
      end
    end
  end

  return merged
end

--- The keys that hold the variables shared by every environment.
--- `env.shared_key` may be one name or a list of them; JetBrains' `$shared`
--- is always honoured so a file written for another client still works.
---@return string[]
function M.shared_keys()
  local configured = config.get().env.shared_key
  local out = {}
  local seen = {}
  local function add(key)
    if type(key) == "string" and key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(out, key)
    end
  end
  if type(configured) == "table" then
    for _, key in ipairs(configured) do
      add(key)
    end
  else
    add(configured)
  end
  add("$shared")
  return out
end

--- Is `name` one of the shared keys rather than an environment?
---@param name string
---@return boolean
function M.is_shared(name)
  return vim.tbl_contains(M.shared_keys(), name)
end

--- The keys inside an environment object that hold default headers rather
--- than variables. `env.headers_key` may be one name or a list of them.
---@return string[]
function M.header_keys()
  local configured = config.get().env.headers_key
  local out, seen = {}, {}
  local function add(key)
    if type(key) == "string" and key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(out, key)
    end
  end
  if type(configured) == "table" then
    for _, key in ipairs(configured) do
      add(key)
    end
  else
    add(configured)
  end
  return out
end

--- Keys inside an environment that are directives, not variables. They are
--- kept out of `vars()` so they never reach completion, the picker preview or
--- a `{{...}}` substitution.
---@param key string
---@return boolean
function M.is_reserved(key)
  return vim.tbl_contains(M.header_keys(), key)
end

--- Strip the reserved keys from a table of environment variables.
---@param vars table
---@return table
local function without_reserved(vars)
  for _, key in ipairs(M.header_keys()) do
    vars[key] = nil
  end
  return vars
end

--- The default headers defined in one environment object.
---@param obj table|nil
---@return table<string, string|false>
local function headers_of(obj)
  local out = {}
  if type(obj) ~= "table" then
    return out
  end
  -- Reversed, so the first-listed key wins the way `shared()` does.
  local keys = M.header_keys()
  for idx = #keys, 1, -1 do
    local from = obj[keys[idx]]
    if type(from) == "table" then
      for name, value in pairs(from) do
        if type(name) == "string" then
          out[name] = value
        end
      end
    end
  end
  return out
end

--- The default headers a *named* environment resolves to: the shared ones
--- with that environment's merged over them.
---
--- Values are raw -- `{{var}}` in them is substituted later, against the
--- context of the request that is about to go out.
---@param source string|nil
---@param name string|nil  nil means "the shared headers alone"
---@param all table|nil    an already-loaded `M.load(source)`
---@return table<string, string|false>
function M.headers(source, name, all)
  all = all or M.load(source)
  local out = {}

  local keys = M.shared_keys()
  for idx = #keys, 1, -1 do
    out = vim.tbl_extend("force", out, headers_of(all[keys[idx]]))
  end
  if name then
    out = vim.tbl_extend("force", out, headers_of(all[name]))
  end
  return out
end

--- The default headers defined *by one environment object alone*, without the
--- shared ones merged in. The picker uses it to say where a header came from.
---@param source string|nil
---@param name string|nil  nil means the shared keys' own headers
---@param all table|nil
---@return table<string, string|false>
function M.own_headers(source, name, all)
  all = all or M.load(source)
  if name then
    return headers_of(all[name])
  end
  return M.headers(source, nil, all)
end

--- The default headers for the active environment.
---@param source string|nil
---@return table<string, string|false>
function M.active_headers(source)
  return M.headers(source, M.current(source))
end

--- Every environment name defined for `source`, sorted, the shared keys
--- excluded.
---@param source string|nil
---@return string[]
function M.names(source)
  local out = {}
  for name in pairs(M.load(source)) do
    if not M.is_shared(name) then
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

--- The variables every environment inherits: each shared key merged in the
--- order `shared_keys()` lists them, so `$curliteshared` wins over `$shared`
--- when a file carries both.
---@param source string|nil
---@param all table|nil  an already-loaded `M.load(source)`, to save a pass
---@return table<string, any>
function M.shared(source, all)
  all = all or M.load(source)
  local vars = {}
  local keys = M.shared_keys()
  -- Reversed: the first-listed key is the one that should win, so it is
  -- merged last.
  for idx = #keys, 1, -1 do
    local from = all[keys[idx]]
    if type(from) == "table" then
      vars = vim.tbl_deep_extend("force", vars, vim.deepcopy(from))
    end
  end
  return without_reserved(vars)
end

--- The variables a *named* environment resolves to: the shared ones with that
--- environment merged over them. Used by the picker to show what you are about
--- to switch to, before switching to it.
---@param source string|nil
---@param name string|nil  nil means "the shared variables alone"
---@return table<string, any>
function M.vars(source, name)
  local all = M.load(source)
  local vars = M.shared(source, all)
  if name and type(all[name]) == "table" then
    vars = vim.tbl_deep_extend("force", vars, vim.deepcopy(all[name]))
  end
  return without_reserved(vars)
end

--- Variables for the active environment: the shared ones with the selected
--- environment merged over them. With nothing selected, only the shared ones
--- are in play.
---@param source string|nil
---@return table<string, any>, string|nil  variables, environment name
function M.active(source)
  local name = M.current(source)
  return M.vars(source, name), name
end

--- The selected environment name, or nil when nothing has been picked.
---
--- Deliberately *not* remembered across sessions and never guessed from the
--- file: an environment is only ever active because you chose it this session,
--- or because `env.default` names one outright.
---@param source string|nil
---@return string|nil
function M.current(source)
  local root = M.root(source)
  local chosen = M.selected[root]
  -- `false` is "you picked none", which outranks `env.default`; nil is
  -- "you have not been asked yet".
  if chosen ~= nil then
    return chosen or nil
  end

  local default = config.get().env.default
  if default then
    M.selected[root] = default
    return default
  end
  return nil
end

--- Has an environment been *asked for* in this project yet? A deliberate
--- "no environment" counts: what curlite refuses to do is send before you have
--- made the choice at all.
---@param source string|nil
---@return boolean
function M.chosen(source)
  return M.selected[M.root(source)] ~= nil
end

--- Select an environment for this project, for the rest of this session.
---@param name string|nil  nil selects no environment at all
---@param source string|nil
function M.select(name, source)
  M.selected[M.root(source)] = name or false
end

--- Forget the environment chosen for `source`'s project, so the next request
--- has to ask again. This is what opening an http file does.
---@param source string|nil
function M.forget(source)
  M.selected[M.root(source)] = nil
end

local dotenv_cache = {}

--- Parse `.env` files visible from `source`. Later (nearer) files win.
---@param source string|nil
---@return table<string, string>
function M.dotenv(source)
  local cfg = config.get()
  if not cfg.env.dotenv then
    return {}
  end
  local out = {}
  local dirs = ancestors(M.base_dir(source))
  for idx = #dirs, 1, -1 do
    local path = dirs[idx] .. "/" .. cfg.env.dotenv
    local sig = file_sig(path)
    local cached = dotenv_cache[path]
    if cached and cached.sig == sig then
      if cached.data then
        out = vim.tbl_extend("force", out, cached.data)
      end
      goto continue
    end

    local parsed = nil
    local fd = sig ~= "" and io.open(path, "r") or nil
    if fd then
      parsed = {}
      for line in fd:lines() do
        local key, value = line:match("^%s*([%w_%.]+)%s*=%s*(.*)$")
        if key and not line:match("^%s*#") then
          value = value:gsub("%s+#.*$", "")
          -- Strip one matched layer of quotes, and unescape only inside "".
          local dq = value:match('^"(.*)"$')
          local sq = value:match("^'(.*)'$")
          if dq then
            value = dq:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"')
          elseif sq then
            value = sq
          else
            value = value:gsub("%s+$", "")
          end
          parsed[key] = value
        end
      end
      fd:close()
      out = vim.tbl_extend("force", out, parsed)
    end
    dotenv_cache[path] = { sig = sig, data = parsed }
    ::continue::
  end
  return out
end

--- Clear every cached/remembered piece of environment state, including the
--- file caches. Mostly for tests; a running editor picks changes up from the
--- mtime checks without this.
function M.reset()
  M.selected = {}
  M.globals = {}
  json_cache = {}
  dotenv_cache = {}
  ancestor_cache = {}
  root_cache = {}
end

return M
