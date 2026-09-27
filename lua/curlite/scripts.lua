--- Pre- and post-request scripts, and `# @assert` checks.
---
--- kulala runs JavaScript through a bundled binary. curlite runs **Lua**,
--- because you are already in a Lua editor and the interpreter is free.
--- A script block is ordinary Lua with these names in scope:
---
---   request           the request about to be sent (mutable)
---     .method, .url, .body
---     .headers.set(name, value) / .headers.get(name) / .headers.remove(name)
---     .variables.set(name, value) / .get(name)
---     .skip([reason])     -- don't send this request
---     .abort([reason])    -- stop a "send all" run here
---   response          post-request only
---     .status, .status_text, .body, .json, .headers, .cookies, .duration_ms
---   client
---     .global.set(name, value) / .get(name) / .clear([name])
---     .log(...)           -- writes to the Script pane
---     .test(name, fn)     -- a named assertion block
---     .assert(cond, msg)  -- a bare assertion
---   json              vim.json (encode/decode)
---   env               the active environment's variables (read-only copy)
---
--- Everything printed with `client.log` and every assertion result shows up in
--- the response window's `script` pane.

local config = require("curlite.config")
local env = require("curlite.env")
local util = require("curlite.util")

local M = {}

---@class curlite.ScriptResult
---@field logs string[]
---@field tests { name: string, ok: boolean, message: string|nil }[]
---@field skip boolean
---@field abort boolean
---@field reason string|nil
---@field error string|nil

--- A restricted global table. Scripts get string/table/math/os.date and the
--- usual pure helpers, but not `io`, `os.execute` or the loaders.
local function sandbox_env()
  return {
    assert = assert,
    error = error,
    ipairs = ipairs,
    next = next,
    pairs = pairs,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    unpack = unpack or table.unpack,
    string = string,
    table = table,
    math = math,
    os = { time = os.time, date = os.date, clock = os.clock, getenv = os.getenv },
    vim = {
      inspect = vim.inspect,
      json = vim.json,
      split = vim.split,
      trim = vim.trim,
      tbl_contains = vim.tbl_contains,
      tbl_keys = vim.tbl_keys,
      tbl_isempty = vim.tbl_isempty,
      deep_equal = vim.deep_equal,
      base64 = vim.base64,
    },
  }
end

--- Case-insensitive header accessors bound to a live header table.
local function header_api(req)
  return {
    get = function(name)
      local want = tostring(name):lower()
      for k, v in pairs(req.headers) do
        if k:lower() == want then
          return v
        end
      end
      return nil
    end,
    set = function(name, value)
      local want = tostring(name):lower()
      for k in pairs(req.headers) do
        if k:lower() == want then
          req.headers[k] = tostring(value)
          return
        end
      end
      req.headers[name] = tostring(value)
      table.insert(req.header_order, name)
    end,
    remove = function(name)
      local want = tostring(name):lower()
      for k in pairs(req.headers) do
        if k:lower() == want then
          req.headers[k] = nil
          for i, hk in ipairs(req.header_order) do
            if hk == k then
              table.remove(req.header_order, i)
              break
            end
          end
          return
        end
      end
    end,
    all = function()
      return vim.deepcopy(req.headers)
    end,
  }
end

--- Build the table of names a script sees.
---@param req curlite.Request
---@param resp curlite.Response|nil
---@param result curlite.ScriptResult
---@return table
local function build_scope(req, resp, result)
  local control = {}

  local request_api = {
    method = req.method,
    url = req.url,
    body = req.body,
    headers = header_api(req),
    variables = {
      set = function(name, value)
        req.variables = req.variables or {}
        req.variables[tostring(name)] = util.stringify(value)
      end,
      get = function(name)
        return (req.variables or {})[tostring(name)]
      end,
    },
    metadata = vim.deepcopy(req.metadata or {}),
    skip = function(reason)
      result.skip = true
      result.reason = reason and tostring(reason) or nil
      error({ curlite_control = "skip" }, 0)
    end,
    abort = function(reason)
      result.abort = true
      result.reason = reason and tostring(reason) or nil
      error({ curlite_control = "abort" }, 0)
    end,
  }
  control.request_api = request_api

  local client = {
    global = {
      set = function(name, value)
        env.globals[tostring(name)] = util.stringify(value)
      end,
      get = function(name)
        return env.globals[tostring(name)]
      end,
      clear = function(name)
        if name then
          env.globals[tostring(name)] = nil
        else
          env.globals = {}
        end
      end,
      all = function()
        return vim.deepcopy(env.globals)
      end,
    },
    log = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[i] = type(v) == "string" and v or vim.inspect(v)
      end
      table.insert(result.logs, table.concat(parts, " "))
    end,
    assert = function(cond, message)
      local entry = { name = message and tostring(message) or "assert", ok = cond and true or false }
      if not cond then
        entry.message = message and tostring(message) or "assertion failed"
      end
      table.insert(result.tests, entry)
      return cond
    end,
    test = function(name, fn)
      local ok, err = pcall(fn)
      table.insert(result.tests, {
        name = tostring(name),
        ok = ok,
        message = not ok and tostring(err) or nil,
      })
    end,
    exit = function()
      error({ curlite_control = "exit" }, 0)
    end,
  }

  local scope = config.get().scripts.sandbox and sandbox_env() or {}
  scope.request = request_api
  scope.client = client
  scope.json = vim.json
  scope.log = client.log
  scope.env = vim.deepcopy(select(1, env.active(req.source)))
  scope.print = client.log

  if resp then
    scope.response = {
      status = resp.status,
      status_text = resp.status_text,
      http_version = resp.http_version,
      body = resp.body,
      json = resp.json,
      headers = vim.deepcopy(resp.headers),
      cookies = vim.deepcopy(resp.cookies),
      duration_ms = resp.duration_ms,
      stats = vim.deepcopy(resp.stats),
      -- `response.header("x")` is the case-insensitive accessor.
      header = function(name)
        local want = tostring(name):lower()
        for k, v in pairs(resp.headers) do
          if k:lower() == want then
            return v
          end
        end
        return nil
      end,
    }
  end

  scope._G = scope
  return scope, control
end

--- Run `fn` under a wall-clock budget.
---
--- A script is ordinary Lua on the main loop, so `while true do end` in one
--- would hang the editor with no way out. A count hook checks the clock every
--- couple of thousand VM instructions and raises when the budget is gone.
---
--- The JIT has to come off for that to work: LuaJIT compiles a hot loop into a
--- trace that never returns to the interpreter, so the count hook would never
--- fire on the exact case it exists to catch. Scripts are small and run once
--- per request, so interpreting them costs nothing worth measuring.
---
--- In sandbox mode a script cannot reach `debug` or `jit`, so it cannot undo
--- any of this.
---@param fn function
---@param ms integer|nil  0 or nil disables the budget
---@return boolean ok, any err
local function with_timeout(fn, ms)
  if not ms or ms <= 0 then
    return pcall(fn)
  end

  local deadline = vim.uv.hrtime() + ms * 1e6
  local jit_was_on = jit ~= nil and jit.status() or false
  if jit_was_on then
    jit.off()
  end

  debug.sethook(function()
    if vim.uv.hrtime() > deadline then
      debug.sethook()
      error(("script exceeded scripts.timeout (%dms) -- runaway loop?"):format(ms), 0)
    end
  end, "", 2000)

  local ok, err = pcall(fn)

  debug.sethook()
  if jit_was_on then
    jit.on()
  end

  return ok, err
end

--- Run one script block.
---@param script curlite.Script
---@param req curlite.Request
---@param resp curlite.Response|nil
---@param result curlite.ScriptResult
local function run_one(script, req, resp, result)
  local source = script.body
  local chunkname = "@curlite:inline"

  if script.kind == "file" then
    local path = util.resolve_path(script.body, req.source)
    local content, err = util.read_file(path)
    if not content then
      result.error = err
      return
    end
    source, chunkname = content, "@" .. path
  end

  local scope, control = build_scope(req, resp, result)
  local chunk, load_err = load(source, chunkname, "t", scope)
  if not chunk then
    result.error = ("script syntax error: %s"):format(load_err)
    return
  end

  local ok, err = with_timeout(chunk, config.get().scripts.timeout)
  if not ok then
    if type(err) == "table" and err.curlite_control then
      -- skip/abort/exit already recorded their intent in `result`.
      return
    end
    result.error = tostring(err)
    return
  end

  -- A script may reassign `request.url` / `.method` / `.body`; copy back.
  local api = control.request_api
  if api.url ~= nil then
    req.url = tostring(api.url)
  end
  if api.method ~= nil then
    req.method = tostring(api.method):upper()
  end
  req.body = api.body ~= nil and tostring(api.body) or nil
end

--- Evaluate the `# @assert` expressions declared on a request.
---
--- The expression is Lua, evaluated with `status`, `body`, `json`, `headers`,
--- `duration`, `cookies` in scope:
---
---   # @assert status == 200
---   # @assert json.data.id ~= nil
---   # @assert headers["content-type"]:find("json")
---   # @assert duration < 1000
---@param req curlite.Request
---@param resp curlite.Response
---@param result curlite.ScriptResult
local function run_asserts(req, resp, result)
  local asserts = req.metadata and req.metadata.asserts
  if not asserts then
    return
  end

  -- Lower-cased header keys make `headers["content-type"]` reliable.
  local headers = {}
  for k, v in pairs(resp.headers) do
    headers[k:lower()] = v
  end

  local scope = config.get().scripts.sandbox and sandbox_env() or {}
  scope.status = resp.status
  scope.body = resp.body
  scope.json = resp.json
  scope.headers = headers
  scope.cookies = resp.cookies
  scope.duration = resp.duration_ms
  scope.response = resp

  for _, expr in ipairs(asserts) do
    -- Allow `status == 200` (an expression) as well as a full statement.
    local chunk, err = load("return (" .. expr .. ")", "@curlite:assert", "t", scope)
    if not chunk then
      chunk, err = load(expr, "@curlite:assert", "t", scope)
    end
    if not chunk then
      table.insert(result.tests, { name = expr, ok = false, message = tostring(err) })
    else
      local ok, value = with_timeout(chunk, config.get().scripts.timeout)
      if not ok then
        table.insert(result.tests, { name = expr, ok = false, message = tostring(value) })
      elseif value then
        table.insert(result.tests, { name = expr, ok = true })
      else
        -- `x and nil or y` would collapse to `y` here, so this stays an if.
        table.insert(result.tests, {
          name = expr,
          ok = false,
          message = ("evaluated to %s"):format(vim.inspect(value)),
        })
      end
    end
  end
end

---@return curlite.ScriptResult
local function new_result()
  return { logs = {}, tests = {}, skip = false, abort = false, reason = nil, error = nil }
end

--- Run every pre-request script. Mutates `req`.
---@param req curlite.Request
---@return curlite.ScriptResult
function M.run_pre(req)
  local result = new_result()
  if not config.get().scripts.enable then
    return result
  end
  for _, script in ipairs(req.pre_scripts or {}) do
    run_one(script, req, nil, result)
    if result.error or result.skip or result.abort then
      break
    end
  end
  return result
end

--- Run every post-request script and the `# @assert` list.
---@param req curlite.Request
---@param resp curlite.Response
---@return curlite.ScriptResult
function M.run_post(req, resp)
  local result = new_result()
  if not config.get().scripts.enable then
    return result
  end
  for _, script in ipairs(req.post_scripts or {}) do
    run_one(script, req, resp, result)
    if result.error or result.abort then
      break
    end
  end
  run_asserts(req, resp, result)
  return result
end

--- Merge two script results (pre + post) for display.
---@param a curlite.ScriptResult|nil
---@param b curlite.ScriptResult|nil
---@return curlite.ScriptResult
function M.merge(a, b)
  local out = new_result()
  for _, r in ipairs({ a, b }) do
    if r then
      vim.list_extend(out.logs, r.logs)
      vim.list_extend(out.tests, r.tests)
      out.skip = out.skip or r.skip
      out.abort = out.abort or r.abort
      out.reason = out.reason or r.reason
      out.error = out.error or r.error
    end
  end
  return out
end

--- Pass/fail tallies over a script result.
---@param result curlite.ScriptResult|nil
---@return integer passed, integer failed
function M.tally(result)
  local passed, failed = 0, 0
  for _, test in ipairs(result and result.tests or {}) do
    if test.ok then
      passed = passed + 1
    else
      failed = failed + 1
    end
  end
  return passed, failed
end

return M
