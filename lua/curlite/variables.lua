--- `{{...}}` substitution.
---
--- Lookup order, first hit wins:
---   1. dynamic functions  -- {{$uuid}}, {{$timestamp}}, {{$env.FOO}}, ...
---   2. request variables  -- {{LOGIN.response.body.$.token}}
---   3. script globals     -- client.global.set("x", ...) from a post-script
---   4. prompt answers     -- # @prompt token
---   5. document variables -- @token = abc
---   6. environment vars   -- http-client.env.json
---
--- Substitution is recursive: a variable whose value itself contains `{{...}}`
--- is expanded too, up to `MAX_DEPTH` rounds, so `@base = {{host}}/v1` works.

local env = require("curlite.env")
local util = require("curlite.util")

local M = {}

local MAX_DEPTH = 10

-- Responses of named requests from this session, keyed by request name.
-- Populated by the runner; read by `{{NAME.response...}}`.
---@type table<string, { request: table, response: table }>
M.responses = {}

-- Answers to `# @prompt`, keyed by prompt name, so a prompt is asked once per
-- session rather than once per send.
---@type table<string, string>
M.prompt_answers = {}

local function rand_hex(n)
  local out = {}
  for i = 1, n do
    out[i] = ("%x"):format(math.random(0, 15))
  end
  return table.concat(out)
end

--- RFC 4122 version 4 UUID.
function M.uuid()
  local hex = rand_hex(32)
  return table.concat({
    hex:sub(1, 8),
    hex:sub(9, 12),
    "4" .. hex:sub(14, 16),
    ("%x"):format(8 + math.random(0, 3)) .. hex:sub(18, 20),
    hex:sub(21, 32),
  }, "-")
end

local ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

local function random_string(len, alphabet)
  alphabet = alphabet or ALNUM
  local out = {}
  for i = 1, len do
    local idx = math.random(1, #alphabet)
    out[i] = alphabet:sub(idx, idx)
  end
  return table.concat(out)
end

local FIRST_NAMES =
  { "Ada", "Alan", "Grace", "Linus", "Ken", "Barbara", "Edsger", "Margaret", "Donald", "Radia" }
local LAST_NAMES =
  { "Lovelace", "Turing", "Hopper", "Torvalds", "Thompson", "Liskov", "Dijkstra", "Hamilton", "Knuth", "Perlman" }

--- Offset-aware date arithmetic for `{{$datetime iso8601 -1 d}}`.
---@param amount number
---@param unit string
---@return integer  epoch seconds
local function shifted_time(amount, unit)
  local now = os.time()
  if not amount then
    return now
  end
  local seconds = {
    ms = 0.001,
    s = 1,
    m = 60,
    h = 3600,
    d = 86400,
    w = 604800,
    M = 2592000, -- 30 days; calendar months are not worth the complexity here
    y = 31536000,
  }
  return math.floor(now + amount * (seconds[unit or "s"] or 1))
end

--- The dynamic `{{$...}}` functions. Each receives the raw argument string.
---@type table<string, fun(args: string, ctx: table): string>
M.dynamic = {
  uuid = function()
    return M.uuid()
  end,
  guid = function()
    return M.uuid()
  end,
  random = function(args)
    -- IntelliJ style: {{$random.integer(1, 100)}} / {{$random.uuid}}
    local kind, rest = args:match("^%.?([%w_]+)%s*(.*)$")
    kind = (kind or ""):lower()
    local a, b = rest:match("%(%s*(-?%d*)%s*,?%s*(-?%d*)%s*%)")
    if kind == "uuid" then
      return M.uuid()
    elseif kind == "integer" then
      local lo = tonumber(a) or 0
      local hi = tonumber(b) or 1000
      return tostring(math.random(math.min(lo, hi), math.max(lo, hi)))
    elseif kind == "float" then
      local lo = tonumber(a) or 0
      local hi = tonumber(b) or 1
      return ("%.6f"):format(lo + math.random() * (hi - lo))
    elseif kind == "alphabetic" then
      return random_string(tonumber(a) or 16, ALNUM:sub(1, 52))
    elseif kind == "alphanumeric" then
      return random_string(tonumber(a) or 16)
    elseif kind == "hexadecimal" then
      return rand_hex(tonumber(a) or 16)
    elseif kind == "email" then
      return (random_string(8):lower()) .. "@example.com"
    end
    return tostring(math.random())
  end,
  timestamp = function(args)
    local amount, unit = args:match("^(-?%d+)%s*(%a*)$")
    return tostring(shifted_time(tonumber(amount), unit ~= "" and unit or nil))
  end,
  isoTimestamp = function(args)
    local amount, unit = args:match("^(-?%d+)%s*(%a*)$")
    return os.date("!%Y-%m-%dT%H:%M:%S", shifted_time(tonumber(amount), unit)) .. "Z"
  end,
  randomInt = function(args)
    local lo, hi = args:match("^(-?%d+)%s+(-?%d+)$")
    if lo then
      return tostring(math.random(tonumber(lo), tonumber(hi)))
    end
    local single = tonumber(args)
    if single then
      return tostring(math.random(0, single))
    end
    return tostring(math.random(0, 1000))
  end,
  randomAlphaNumeric = function(args)
    return random_string(tonumber(args) or 16)
  end,
  randomHex = function(args)
    return rand_hex(tonumber(args) or 16)
  end,
  randomEmail = function()
    return (random_string(8):lower()) .. "@example.com"
  end,
  randomFirstName = function()
    return FIRST_NAMES[math.random(#FIRST_NAMES)]
  end,
  randomLastName = function()
    return LAST_NAMES[math.random(#LAST_NAMES)]
  end,
  randomFullName = function()
    return FIRST_NAMES[math.random(#FIRST_NAMES)] .. " " .. LAST_NAMES[math.random(#LAST_NAMES)]
  end,
  date = function(args)
    return os.date(args ~= "" and args or "%Y-%m-%d")
  end,
  time = function(args)
    return os.date(args ~= "" and args or "%H:%M:%S")
  end,
  datetime = function(args)
    -- {{$datetime iso8601}} | {{$datetime rfc1123}} | {{$datetime "%d/%m/%Y"}}
    local fmt, amount, unit = args:match('^"?([^"%s]*)"?%s*(-?%d*)%s*(%a*)$')
    local when = shifted_time(tonumber(amount), unit ~= "" and unit or nil)
    fmt = (fmt or ""):lower()
    if fmt == "" or fmt == "iso8601" then
      return os.date("!%Y-%m-%dT%H:%M:%S", when) .. "Z"
    elseif fmt == "rfc1123" then
      return os.date("!%a, %d %b %Y %H:%M:%S GMT", when)
    elseif fmt == "unix" or fmt == "timestamp" then
      return tostring(when)
    end
    return os.date(args:gsub('"', ""), when)
  end,
  localDatetime = function(args)
    local fmt = args:match('^"?([^"]*)"?') or ""
    if fmt == "" or fmt:lower() == "iso8601" then
      return os.date("%Y-%m-%dT%H:%M:%S")
    elseif fmt:lower() == "rfc1123" then
      return os.date("%a, %d %b %Y %H:%M:%S")
    end
    return os.date(fmt)
  end,
  processEnv = function(args, ctx)
    local name = args:gsub("^[%.%s]+", "")
    return os.getenv(name) or (ctx.dotenv and ctx.dotenv[name]) or ""
  end,
  env = function(args, ctx)
    -- Both `{{$env.NAME}}` and `{{$env NAME}}` reach here.
    local name = args:gsub("^[%.%s]+", "")
    return os.getenv(name) or (ctx.dotenv and ctx.dotenv[name]) or ""
  end,
  dotenv = function(args, ctx)
    local name = args:gsub("^[%.%s]+", "")
    return (ctx.dotenv and ctx.dotenv[name]) or os.getenv(name) or ""
  end,
  exec = function(args)
    -- {{$exec pass show api/token}} -- stdout, trailing newline stripped.
    if args == "" then
      return ""
    end
    local out = vim.fn.system(args)
    return (out:gsub("[\r\n]+$", ""))
  end,
}

--- Build the context a render needs.
---@param req curlite.Request|nil
---@param source string|nil
---@return table
function M.context(req, source)
  local envvars = select(1, env.active(source))
  return {
    request = req,
    source = source,
    vars = req and req.variables or {},
    envvars = envvars,
    globals = env.globals,
    dotenv = env.dotenv(source),
    prompts = M.prompt_answers,
  }
end

--- Resolve `NAME.response.body.$.path` / `NAME.request.headers.X` style refs.
---@param expr string
---@return any|nil, boolean matched
local function request_variable(expr)
  local name, kind, rest = expr:match("^([%w_$%-%.]+)%.(re%a+)%.(.+)$")
  if not name or not (kind == "response" or kind == "request") then
    return nil, false
  end
  local entry = M.responses[name]
  if not entry then
    return nil, true
  end
  local target = entry[kind]
  if not target then
    return nil, true
  end

  local what, path = rest:match("^([%w_]+)%.?(.*)$")
  what = (what or ""):lower()

  if what == "headers" then
    local want = path:gsub("^%$%.?", ""):lower()
    for k, v in pairs(target.headers or {}) do
      if k:lower() == want then
        return v, true
      end
    end
    return nil, true
  elseif what == "body" then
    if path == "" or path == "$" then
      return target.body, true
    end
    -- `body.$.a.b` for JSON, `body.//x/y` would be xpath (not supported).
    local json = target.json
    if json == nil then
      json = util.json_decode(target.body)
    end
    return util.json_path(json, path), true
  elseif what == "status" then
    return target.status, true
  elseif what == "cookies" then
    local want = path:gsub("^%$%.?", "")
    return (target.cookies or {})[want], true
  end
  return nil, true
end

--- Look up one `{{expr}}`.
---@param expr string  the text between the braces, trimmed
---@param ctx table
---@return string|nil  nil means "not found"
function M.lookup(expr, ctx)
  -- 1. dynamic functions
  local dollar = expr:match("^%$(.+)$")
  if dollar then
    local fname, args = dollar:match("^([%w_]+)(.*)$")
    if fname and M.dynamic[fname] then
      return util.stringify(M.dynamic[fname](vim.trim(args or ""), ctx))
    end
    -- Unknown dollar-prefixed names may still be response references such as
    -- `$last.response.status`, so continue through the regular lookup path.
  end

  -- 2. request variables
  local value, matched = request_variable(expr)
  if matched then
    return value ~= nil and util.stringify(value) or nil
  end

  -- 3..6, in precedence order
  for _, tbl in ipairs({ ctx.globals, ctx.prompts, ctx.vars, ctx.envvars }) do
    if tbl then
      local v = tbl[expr]
      if v ~= nil then
        return util.stringify(v)
      end
      -- Dotted access into a nested environment value: `{{auth.client_id}}`.
      if expr:find("%.") then
        local head = expr:match("^([^%.]+)")
        if tbl[head] ~= nil then
          local nested = util.json_path(tbl[head], expr:sub(#head + 2))
          if nested ~= nil then
            return util.stringify(nested)
          end
        end
      end
    end
  end

  return nil
end

--- Substitute every `{{...}}` in `str`.
---@param str string|nil
---@param ctx table
---@param missing string[]|nil  collects names that could not be resolved
---@return string|nil
function M.render(str, ctx, missing)
  if type(str) ~= "string" or not str:find("{{", 1, true) then
    return str
  end

  local seen_missing = {}
  local result = str

  for _ = 1, MAX_DEPTH do
    local changed = false
    result = result:gsub("{{%s*(.-)%s*}}", function(expr)
      if expr == "" then
        return "{{}}"
      end
      local value = M.lookup(expr, ctx)
      if value == nil then
        if missing and not seen_missing[expr] then
          seen_missing[expr] = true
          table.insert(missing, expr)
        end
        -- Leave it alone; the runner decides whether that is fatal. A sentinel
        -- keeps this pass from rewriting it forever.
        return "\1" .. expr .. "\2"
      end
      changed = true
      return value
    end)
    if not changed or not result:find("{{", 1, true) then
      break
    end
  end

  return (result:gsub("\1(.-)\2", "{{%1}}"))
end

--- Render every string field of a request in place, returning a new request.
---@param req curlite.Request
---@param ctx table
---@return curlite.Request resolved, string[] missing
function M.render_request(req, ctx)
  local missing = {}
  local out = vim.deepcopy(req)

  out.url = M.render(out.url, ctx, missing)
  out.headers = {}
  for _, name in ipairs(req.header_order) do
    local rendered_name = M.render(name, ctx, missing)
    out.headers[rendered_name] = M.render(req.headers[name], ctx, missing)
  end
  out.header_order = vim.tbl_map(function(n)
    return M.render(n, ctx, missing)
  end, req.header_order)
  out.body = M.render(out.body, ctx, missing)
  out.body_file = M.render(out.body_file, ctx, missing)
  if out.redirect then
    out.redirect.path = M.render(out.redirect.path, ctx, missing)
  end
  out.curl_args = vim.tbl_map(function(a)
    return M.render(a, ctx, missing)
  end, req.curl_args or {})

  return out, missing
end

--- Ask for every `# @prompt` this request declares. Answers are cached for the
--- session; `force` re-asks.
---@param req curlite.Request
---@param force boolean|nil
---@return boolean ok  false when the user cancelled
function M.resolve_prompts(req, force)
  local prompts = req.metadata and req.metadata.prompts
  if not prompts then
    return true
  end
  for _, p in ipairs(prompts) do
    if force or M.prompt_answers[p.name] == nil then
      local answer = vim.fn.input({
        prompt = (p.description ~= "" and p.description or p.name) .. ": ",
        default = M.prompt_answers[p.name] or "",
        cancelreturn = "\0",
      })
      if answer == "\0" then
        return false
      end
      M.prompt_answers[p.name] = answer
    end
  end
  return true
end

--- Record a completed request/response pair so later requests can reference it.
---@param name string|nil
---@param request table
---@param response table
function M.record(name, request, response)
  if name and name ~= "" then
    M.responses[name] = { request = request, response = response }
  end
  M.responses["$last"] = { request = request, response = response }
end

function M.reset()
  M.responses = {}
  M.prompt_answers = {}
end

return M
