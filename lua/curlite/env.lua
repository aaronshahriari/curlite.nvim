--- Environment files.
---
--- curlite reads the JetBrains layout: a `http-client.env.json` beside your
--- `.http` file (or in any directory above it), holding one object per
--- environment, plus an optional `http-client.private.env.json` that is merged
--- over it and that you gitignore.
---
---   {
---     "$shared": { "apiVersion": "v1" },
---     "dev":  { "host": "http://localhost:3000" },
---     "prod": { "host": "https://api.example.com" }
---   }
---
--- A `.env` file in the same directories is also read and exposed through
--- `{{$dotenv NAME}}`.

local config = require("curlite.config")

local M = {}

-- Selected environment, per project root.
---@type table<string, string>
M.selected = {}

-- Variables set at runtime by post-request scripts (`client.global.set`).
-- These outrank environment variables and survive until Neovim exits or
-- `client.global.clear()` runs.
---@type table<string, any>
M.globals = {}

local state_file = vim.fn.stdpath("data") .. "/curlite/state.json"

local function read_json(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  if not content or content == "" then
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
    return nil
  end
  return decoded
end

--- Directories from `dir` up to the filesystem root.
---@param dir string
---@return string[]
local function ancestors(dir)
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
  local cfg = config.get()
  for _, dir in ipairs(ancestors(base)) do
    for _, name in ipairs(cfg.env.files) do
      if vim.fn.filereadable(dir .. "/" .. name) == 1 then
        return dir
      end
    end
    if vim.fn.isdirectory(dir .. "/.git") == 1 then
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

--- Every environment name defined for `source`, sorted, `$shared` excluded.
---@param source string|nil
---@return string[]
function M.names(source)
  local cfg = config.get()
  local out = {}
  for name in pairs(M.load(source)) do
    if name ~= cfg.env.shared_key then
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

--- Variables for the active environment: `$shared` with the selected
--- environment merged over it.
---@param source string|nil
---@return table<string, any>, string|nil  variables, environment name
function M.active(source)
  local cfg = config.get()
  local all = M.load(source)
  local name = M.current(source)
  local vars = vim.deepcopy(all[cfg.env.shared_key] or {})
  if name and all[name] then
    vars = vim.tbl_deep_extend("force", vars, all[name])
  end
  return vars, name
end

--- The selected environment name: whatever was picked this session, else the
--- one remembered on disk, else `env.default`, else the first defined.
---@param source string|nil
---@return string|nil
function M.current(source)
  local root = M.root(source)
  if M.selected[root] then
    return M.selected[root]
  end

  local persisted = read_json(state_file)
  if persisted and persisted.envs and persisted.envs[root] then
    M.selected[root] = persisted.envs[root]
    return M.selected[root]
  end

  local cfg = config.get()
  if cfg.env.default then
    return cfg.env.default
  end
  return M.names(source)[1]
end

--- Select an environment and remember it for this project.
---@param name string|nil  nil clears the selection
---@param source string|nil
function M.select(name, source)
  local root = M.root(source)
  M.selected[root] = name

  local persisted = read_json(state_file) or {}
  persisted.envs = persisted.envs or {}
  persisted.envs[root] = name
  vim.fn.mkdir(vim.fn.fnamemodify(state_file, ":h"), "p")
  local fd = io.open(state_file, "w")
  if fd then
    fd:write(vim.json.encode(persisted))
    fd:close()
  end
end

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
    local fd = io.open(path, "r")
    if fd then
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
          out[key] = value
        end
      end
      fd:close()
    end
  end
  return out
end

--- Clear every cached/remembered piece of environment state. Mostly for tests.
function M.reset()
  M.selected = {}
  M.globals = {}
end

return M
