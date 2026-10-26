--- Importing requests from an OpenAPI / Swagger description.
---
--- A spec already says what every endpoint takes. This reads one -- a local
--- `openapi.json`/`openapi.yaml`, a URL that serves either, or a Swagger UI
--- page that links to one -- and turns each operation into a `.http` block
--- ready to drop into the file you are editing:
---
---   ### List pets
---   # @name listPets
---   GET {{host}}/pets
---     ?status=available
---   Accept: application/json
---
--- Values come from the spec: a parameter's `example`, then its schema's
--- `default`, then the first `enum` member, then a sample for its type. A
--- parameter with nothing to go on becomes `{{name}}`, so it is obvious what
--- is left to fill in -- and completion offers it like any other variable.
---
--- Both OpenAPI 3.x and Swagger 2.0 are read. The picker in
--- `curlite.openapi_picker` is the front end; `:Curlite openapi` is the way in.

local config = require("curlite.config")
local util = require("curlite.util")

local M = {}

-- The order operations are listed in for one path, so a resource reads
-- the way you think about it rather than alphabetically.
local METHOD_ORDER = {
  GET = 1,
  POST = 2,
  PUT = 3,
  PATCH = 4,
  DELETE = 5,
  HEAD = 6,
  OPTIONS = 7,
  TRACE = 8,
}

local METHODS = { "get", "put", "post", "delete", "options", "head", "patch", "trace" }

--- Spec files, keyed by path, with the size/mtime they were read at. The same
--- shape as the environment cache: editing the spec is picked up at once, an
--- unchanged one costs a `stat`.
---@type table<string, { sig: string, spec: table|nil }>
local file_cache = {}

--- Specs fetched over http, keyed by URL, for this session.
---@type table<string, table>
local url_cache = {}

--- Forget every cached spec. For tests, and for `:Curlite openapi` to be
--- able to pick up a redeployed one.
function M.reset()
  file_cache = {}
  url_cache = {}
end

--- ------------------------------------------------------------------ paths

---@param target string
---@return boolean
function M.is_url(target)
  return target:match("^https?://") ~= nil
end

--- Resolve `href` against the page it was found on.
---@param href string
---@param base string
---@return string
function M.resolve_url(href, base)
  if M.is_url(href) then
    return href
  end
  local scheme, host, path = base:match("^(https?://)([^/]+)(.*)$")
  if not scheme then
    return href
  end
  if href:sub(1, 2) == "//" then
    return scheme:gsub("://$", ":") .. href
  end
  if href:sub(1, 1) == "/" then
    return scheme .. host .. href
  end
  local dir = (path or ""):gsub("[^/]*$", "")
  if dir == "" then
    dir = "/"
  end
  return scheme .. host .. dir .. href
end

--- Every spec file visible from `source`, nearest first.
---
--- `openapi.files` is searched in each directory from the `.http` file's own
--- up to the project root, so a spec beside the requests wins over one at the
--- top of a monorepo.
---@param source string|nil
---@return string[]
function M.discover(source)
  local cfg = config.get().openapi
  local env = require("curlite.env")
  local base = env.base_dir(source)
  local root = env.root(source)

  local out, seen = {}, {}
  local dir = base
  while true do
    for _, name in ipairs(cfg.files) do
      local path = dir .. "/" .. name
      if not seen[path] and vim.uv.fs_stat(path) then
        seen[path] = true
        table.insert(out, path)
      end
    end
    if dir == root or dir == "/" or dir == "" then
      break
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return out
end

--- ----------------------------------------------------------------- parsing

--- Decode a spec, JSON or YAML.
---@param content string
---@param label string|nil  what to name in an error
---@return table|nil spec, string|nil err
function M.parse(content, label)
  label = label or "the spec"
  local trimmed = vim.trim(content)
  if trimmed == "" then
    return nil, ("%s is empty"):format(label)
  end

  if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
    local decoded = util.json_decode(trimmed)
    if type(decoded) ~= "table" then
      return nil, ("%s is not valid JSON"):format(label)
    end
    return decoded
  end

  if trimmed:sub(1, 1) == "<" then
    return nil, ("%s served HTML, not a spec"):format(label)
  end

  local decoded, err = require("curlite.yaml").decode(trimmed)
  if type(decoded) ~= "table" then
    return nil,
      ("%s is neither JSON nor YAML curlite can read (%s)"):format(label, err or "unparseable")
  end
  return decoded
end

--- Is this a document curlite recognises as a spec?
---@param spec table
---@return boolean
local function looks_like_spec(spec)
  return type(spec) == "table" and type(spec.paths) == "table" and (spec.openapi or spec.swagger)
end

--- A file's identity for cache purposes.
---@param path string
---@return string
local function file_sig(path)
  local st = vim.uv.fs_stat(path)
  if not st then
    return ""
  end
  return ("%d:%d:%d"):format(st.size, st.mtime.sec, st.mtime.nsec)
end

--- Read and decode a spec file, through the mtime cache.
---@param path string
---@return table|nil spec, string|nil err
function M.load_file(path)
  local sig = file_sig(path)
  if sig == "" then
    return nil, ("%s does not exist"):format(vim.fn.fnamemodify(path, ":~:."))
  end
  local cached = file_cache[path]
  if cached and cached.sig == sig then
    return cached.spec
  end

  local content, read_err = util.read_file(path)
  if not content then
    return nil, read_err
  end
  local spec, err = M.parse(content, vim.fn.fnamemodify(path, ":~:."))
  if not spec then
    return nil, err
  end
  spec.__source = path
  file_cache[path] = { sig = sig, spec = spec }
  return spec
end

--- The spec URL a Swagger UI page points at.
---
--- A URL someone pastes is as likely to be the page they were reading as the
--- JSON behind it. The page names its spec in its own configuration, so this
--- looks for that, and failing that tries the handful of paths the common
--- frameworks serve one at.
---@param html string
---@param url string  the page it came from
---@return string|nil
function M.spec_url_in(html, url)
  local candidates = {}
  local function add(href)
    if type(href) == "string" and href ~= "" and not href:match("^%s*$") then
      table.insert(candidates, M.resolve_url(href, url))
    end
  end

  -- `url: "/v3/api-docs"` in swagger-initializer.js, `"url":"..."` in the
  -- JSON config some builds inline, and the `<script data-url>` variants.
  add(html:match('[%s,{]url%s*:%s*"([^"]+)"'))
  add(html:match("[%s,{]url%s*:%s*'([^']+)'"))
  add(html:match('"url"%s*:%s*"([^"]+)"'))
  add(html:match('data%-url%s*=%s*"([^"]+)"'))
  add(html:match('spec%-url%s*=%s*"([^"]+)"'))
  add(html:match('configUrl%s*:%s*"([^"]+)"'))

  for _, candidate in ipairs(candidates) do
    -- A UI page listing itself is not the spec.
    if candidate ~= url and not candidate:match("%.html?$") then
      return candidate
    end
  end

  for _, path in ipairs(config.get().openapi.url_paths) do
    local candidate = M.resolve_url(path, url)
    if candidate ~= url then
      return candidate
    end
  end
  return nil
end

--- Fetch a URL with curl. Asynchronous: curlite never blocks the editor on
--- the network.
---@param url string
---@param cb fun(body: string|nil, err: string|nil)
local function fetch(url, cb)
  local cfg = config.get()
  local timeout = tonumber(cfg.openapi.timeout) or 10000
  local args = {
    cfg.curl.path,
    "--silent",
    "--show-error",
    "--location",
    "--fail",
    "--header",
    "Accept: application/json, application/yaml, text/yaml, */*",
    "--max-time",
    ("%.3f"):format(math.max(timeout, 1000) / 1000),
    url,
  }
  if cfg.curl.verify_ssl == false then
    table.insert(args, 2, "--insecure")
  end

  local ok, err = pcall(
    vim.system,
    args,
    { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        local detail = vim.trim(res.stderr or "")
        cb(nil, ("could not fetch %s%s"):format(url, detail ~= "" and (": " .. detail) or ""))
        return
      end
      cb(res.stdout or "")
    end)
  )
  if not ok then
    cb(nil, ("could not run curl: %s"):format(err))
  end
end

--- Load a spec from a URL, following a Swagger UI page to the spec it serves.
---@param url string
---@param cb fun(spec: table|nil, err: string|nil)
function M.load_url(url, cb)
  if url_cache[url] then
    return cb(url_cache[url])
  end

  fetch(url, function(body, err)
    if not body then
      return cb(nil, err)
    end

    local trimmed = vim.trim(body)
    if trimmed:sub(1, 1) == "<" then
      -- A Swagger UI page. One hop to the spec it names, and no further.
      local spec_url = M.spec_url_in(body, url)
      if not spec_url then
        return cb(
          nil,
          ("%s is a web page and names no spec — point at the JSON itself"):format(url)
        )
      end
      util.emit("openapi_loading", ("curlite: %s → %s"):format(url, spec_url))
      return fetch(spec_url, function(inner, inner_err)
        if not inner then
          return cb(nil, inner_err)
        end
        local spec, perr = M.parse(inner, spec_url)
        if not spec then
          return cb(nil, perr)
        end
        spec.__source = spec_url
        url_cache[url] = spec
        url_cache[spec_url] = spec
        cb(spec)
      end)
    end

    local spec, perr = M.parse(body, url)
    if not spec then
      return cb(nil, perr)
    end
    spec.__source = url
    url_cache[url] = spec
    cb(spec)
  end)
end

--- Load a spec from wherever `target` points, or from the first one found
--- near `source` when there is no target.
---@param target string|nil  a path, a URL, or nil to discover one
---@param source string|nil  the .http file the import is for
---@param cb fun(spec: table|nil, err: string|nil)
function M.load(target, source, cb)
  if target and target ~= "" then
    target = vim.trim(target)
    if M.is_url(target) then
      return M.load_url(target, cb)
    end
    local path = util.resolve_path(target, source)
    local spec, err = M.load_file(path)
    return cb(spec, err)
  end

  local configured = config.get().openapi.spec
  if type(configured) == "string" and configured ~= "" then
    return M.load(configured, source, cb)
  end

  local found = M.discover(source)
  if #found == 0 then
    return cb(
      nil,
      ("no OpenAPI spec found near %s — pass one to `:Curlite openapi`, or set `openapi.spec`"):format(
        source and source ~= "" and vim.fn.fnamemodify(source, ":~:.") or vim.fn.getcwd()
      )
    )
  end
  local spec, err = M.load_file(found[1])
  return cb(spec, err)
end

--- ------------------------------------------------------------------- refs

--- Follow a local `$ref` (`#/components/schemas/Pet`). External refs are not
--- resolved -- there is nothing to fetch them from without guessing.
---@param spec table
---@param ref string
---@return table|nil
local function follow(spec, ref)
  if type(ref) ~= "string" or ref:sub(1, 2) ~= "#/" then
    return nil
  end
  local node = spec
  for part in ref:sub(3):gmatch("[^/]+") do
    -- JSON Pointer escapes.
    local key = part:gsub("~1", "/"):gsub("~0", "~")
    if type(node) ~= "table" then
      return nil
    end
    node = node[key]
    if node == nil then
      return nil
    end
  end
  return type(node) == "table" and node or nil
end

--- Resolve a node that may be a `$ref`, following chains of them.
---@param spec table
---@param node any
---@return any
local function deref(spec, node)
  local seen = {}
  local depth = 0
  while type(node) == "table" and type(node["$ref"]) == "string" and depth < 32 do
    local ref = node["$ref"]
    if seen[ref] then
      return nil
    end
    seen[ref] = true
    depth = depth + 1
    local target = follow(spec, ref)
    if not target then
      return nil
    end
    -- A sibling of `$ref` is a legal (if rare) override.
    local merged = vim.deepcopy(target)
    for key, value in pairs(node) do
      if key ~= "$ref" then
        merged[key] = value
      end
    end
    node = merged
  end
  return node
end

M.deref = deref

--- --------------------------------------------------------- example values

-- An object whose keys keep the order they were added in, so a generated body
-- lists the required fields first instead of however `pairs` felt.
local OMap = {}
OMap.__index = OMap

local function omap()
  return setmetatable({ keys = {}, values = {} }, OMap)
end

function OMap:set(key, value)
  if self.values[key] == nil then
    table.insert(self.keys, key)
  end
  self.values[key] = value == nil and vim.NIL or value
end

function OMap:empty()
  return #self.keys == 0
end

--- A sample for a string with a known `format`, so a date field looks like a
--- date rather than an empty string.
local FORMATS = {
  ["date-time"] = "1970-01-01T00:00:00Z",
  date = "1970-01-01",
  time = "00:00:00",
  uuid = "00000000-0000-0000-0000-000000000000",
  email = "user@example.com",
  hostname = "example.com",
  ipv4 = "127.0.0.1",
  ipv6 = "::1",
  uri = "https://example.com",
  url = "https://example.com",
  password = "",
  byte = "",
  binary = "",
}

--- The ordered property names of an object schema: the required ones in the
--- order the spec lists them, then the rest alphabetically.
---@param schema table
---@return string[]
local function property_order(schema)
  local props = type(schema.properties) == "table" and schema.properties or {}
  local out, seen = {}, {}
  for _, name in ipairs(type(schema.required) == "table" and schema.required or {}) do
    if type(name) == "string" and props[name] ~= nil and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  local rest = {}
  for name in pairs(props) do
    if not seen[name] then
      table.insert(rest, name)
    end
  end
  table.sort(rest)
  vim.list_extend(out, rest)
  return out
end

--- A sample value for a schema: what the spec says, and a placeholder for its
--- type when it says nothing.
---@param spec table
---@param schema any
---@param depth integer
---@return any
local function sample(spec, schema, depth)
  schema = deref(spec, schema)
  if type(schema) ~= "table" then
    return nil
  end
  if depth <= 0 then
    return nil
  end

  if schema.example ~= nil then
    return schema.example
  end
  if schema.default ~= nil then
    return schema.default
  end
  if type(schema.examples) == "table" then
    -- OpenAPI 3.1 writes `examples: [...]`; 3.0 media types use a map.
    local first = schema.examples[1]
    if first ~= nil then
      return first
    end
    for _, entry in pairs(schema.examples) do
      if type(entry) == "table" and entry.value ~= nil then
        return entry.value
      end
      return entry
    end
  end
  if type(schema.enum) == "table" and schema.enum[1] ~= nil then
    return schema.enum[1]
  end
  if schema.const ~= nil then
    return schema.const
  end

  -- A composed schema: `allOf` is the whole of them, the others are a choice,
  -- and the first branch is as good a guess as any.
  if type(schema.allOf) == "table" then
    local merged = omap()
    for _, part in ipairs(schema.allOf) do
      local value = sample(spec, part, depth)
      if getmetatable(value) == OMap then
        for _, key in ipairs(value.keys) do
          merged:set(key, value.values[key] == vim.NIL and nil or value.values[key])
        end
      end
    end
    if not merged:empty() then
      return merged
    end
  end
  for _, key in ipairs({ "oneOf", "anyOf" }) do
    if type(schema[key]) == "table" and schema[key][1] then
      return sample(spec, schema[key][1], depth)
    end
  end

  local kind = schema.type
  if type(kind) == "table" then
    -- OpenAPI 3.1 allows a list of types; the first non-null one is the one
    -- worth showing.
    for _, entry in ipairs(kind) do
      if entry ~= "null" then
        kind = entry
        break
      end
    end
  end
  if not kind then
    kind = (schema.properties and "object") or (schema.items and "array") or nil
  end

  if kind == "object" then
    local out = omap()
    for _, name in ipairs(property_order(schema)) do
      out:set(name, sample(spec, schema.properties[name], depth - 1))
    end
    if out:empty() and schema.additionalProperties then
      return omap()
    end
    return out
  end
  if kind == "array" then
    local item = sample(spec, schema.items, depth - 1)
    if item == nil then
      return {}
    end
    return { item }
  end
  if kind == "integer" or kind == "number" then
    if type(schema.minimum) == "number" then
      return schema.minimum
    end
    return kind == "integer" and 0 or 0
  end
  if kind == "boolean" then
    return false
  end
  if kind == "string" then
    if schema.format and FORMATS[schema.format] ~= nil then
      return FORMATS[schema.format]
    end
    return ""
  end
  return nil
end

--- JSON, pretty-printed, with ordered maps kept in their order and plain
--- tables sorted so the output of two runs is the same.
---@param value any
---@param indent integer
---@param level integer
---@return string
local function encode(value, indent, level)
  local pad = (" "):rep(indent * level)
  local pad_in = (" "):rep(indent * (level + 1))

  if getmetatable(value) == OMap then
    if value:empty() then
      return "{}"
    end
    local parts = {}
    for _, key in ipairs(value.keys) do
      local entry = value.values[key]
      table.insert(
        parts,
        ("%s%s: %s"):format(
          pad_in,
          vim.json.encode(key),
          encode(entry == vim.NIL and nil or entry, indent, level + 1)
        )
      )
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
  end

  if type(value) == "table" then
    if vim.islist(value) then
      if #value == 0 then
        return "[]"
      end
      local parts = {}
      for _, entry in ipairs(value) do
        table.insert(parts, pad_in .. encode(entry, indent, level + 1))
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      table.insert(keys, tostring(key))
    end
    table.sort(keys)
    if #keys == 0 then
      return "{}"
    end
    local parts = {}
    for _, key in ipairs(keys) do
      table.insert(
        parts,
        ("%s%s: %s"):format(pad_in, vim.json.encode(key), encode(value[key], indent, level + 1))
      )
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
  end

  if value == nil or value == vim.NIL then
    return "null"
  end
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or ('"%s"'):format(tostring(value))
end

M.encode = encode

--- The value a parameter should carry: its own example, its schema's, or
--- `{{name}}` when the spec gives nothing to go on.
---
--- `strict` is for path parameters. A sample for the *type* is useful in a
--- query string, where `?limit=0` still shows the shape of the request, and
--- actively misleading in a path, where `/pets/0` looks like a real resource
--- you did not mean to touch. A variable there says what is missing.
---@param spec table
---@param param table
---@param strict boolean|nil
---@return string
local function param_value(spec, param, strict)
  local candidates = { param.example, param.default }
  if type(param.examples) == "table" then
    for _, entry in pairs(param.examples) do
      table.insert(candidates, type(entry) == "table" and entry.value or entry)
      break
    end
  end
  for _, value in ipairs(candidates) do
    if value ~= nil and value ~= "" then
      return util.stringify(value)
    end
  end

  local schema = deref(spec, param.schema) or param
  if type(schema) == "table" then
    if schema.example ~= nil then
      return util.stringify(schema.example)
    end
    if schema.default ~= nil then
      return util.stringify(schema.default)
    end
    if type(schema.enum) == "table" and schema.enum[1] ~= nil then
      return util.stringify(schema.enum[1])
    end
    local kind = schema.type
    if not strict then
      if kind == "integer" or kind == "number" then
        return util.stringify(schema.minimum or 0)
      end
      if kind == "boolean" then
        return "false"
      end
    end
    if kind == "string" and schema.format and FORMATS[schema.format] then
      local formatted = FORMATS[schema.format]
      if formatted ~= "" then
        return formatted
      end
    end
  end

  -- Nothing in the spec: leave a variable, so it is obvious what is missing
  -- and completion can fill it in.
  return ("{{%s}}"):format(param.name)
end

--- ------------------------------------------------------------------ bodies

-- The boundary a generated multipart body is written with. It has to appear
-- in the `Content-Type` header as well, which is where curlite's own parser
-- reads it from.
M.BOUNDARY = "CurliteBoundary"

-- Media types curlite knows how to write out, best first.
local PREFERRED = {
  "application/json",
  "application/problem+json",
  "text/json",
  "application/x-www-form-urlencoded",
  "multipart/form-data",
  "text/plain",
}

--- Pick the media type to generate a body for.
---@param content table
---@return string|nil
local function pick_media(content)
  for _, name in ipairs(PREFERRED) do
    if content[name] then
      return name
    end
  end
  for name in pairs(content) do
    if name:find("json", 1, true) then
      return name
    end
  end
  local names = {}
  for name in pairs(content) do
    table.insert(names, name)
  end
  table.sort(names)
  return names[1]
end

--- The example body for a media type entry, as lines.
---@param spec table
---@param media table
---@param name string
---@param opts table
---@return string[]
local function body_lines(spec, media, name, opts)
  local indent = opts.indent or 2
  local value = nil

  if media.example ~= nil then
    value = media.example
  elseif type(media.examples) == "table" then
    for _, entry in pairs(media.examples) do
      value = type(entry) == "table" and entry.value ~= nil and entry.value or entry
      break
    end
  end
  if value == nil then
    value = sample(spec, media.schema, opts.max_depth or 6)
  end
  if value == nil then
    return {}
  end

  if name:find("x%-www%-form%-urlencoded") then
    -- `a=1` then `&b=2`, which is how curlite reads a form body back.
    local pairs_out = {}
    if getmetatable(value) == OMap then
      for _, key in ipairs(value.keys) do
        local entry = value.values[key]
        local text = util.stringify(entry == vim.NIL and "" or entry)
        table.insert(pairs_out, ("%s=%s"):format(key, text))
      end
    elseif type(value) == "table" then
      local keys = {}
      for key in pairs(value) do
        table.insert(keys, tostring(key))
      end
      table.sort(keys)
      for _, key in ipairs(keys) do
        table.insert(pairs_out, ("%s=%s"):format(key, util.stringify(value[key])))
      end
    end
    local out = {}
    for idx, entry in ipairs(pairs_out) do
      table.insert(out, idx == 1 and entry or ("&" .. entry))
    end
    return out
  end

  if name:find("multipart/form%-data") then
    local boundary = M.BOUNDARY
    local out = {}
    local function part(key, entry)
      table.insert(out, "--" .. boundary)
      table.insert(out, ('Content-Disposition: form-data; name="%s"'):format(key))
      table.insert(out, "")
      table.insert(out, util.stringify(entry == vim.NIL and "" or entry))
    end
    if getmetatable(value) == OMap then
      for _, key in ipairs(value.keys) do
        part(key, value.values[key])
      end
    elseif type(value) == "table" then
      local keys = {}
      for key in pairs(value) do
        table.insert(keys, tostring(key))
      end
      table.sort(keys)
      for _, key in ipairs(keys) do
        part(key, value[key])
      end
    end
    if #out == 0 then
      return {}
    end
    table.insert(out, "--" .. boundary .. "--")
    return out
  end

  if type(value) == "string" and not name:find("json", 1, true) then
    return vim.split(value, "\n", { plain = true })
  end

  return vim.split(encode(value, indent, 0), "\n", { plain = true })
end

--- --------------------------------------------------------------- the base

--- The server URL the spec describes, with its variables filled in.
---@param spec table
---@return string|nil
function M.server(spec)
  local servers = spec.servers
  if type(servers) == "table" and type(servers[1]) == "table" then
    local url = servers[1].url
    if type(url) == "string" and url ~= "" then
      local variables = servers[1].variables
      if type(variables) == "table" then
        url = url:gsub("{([^}]+)}", function(name)
          local var = variables[name]
          if type(var) == "table" and var.default ~= nil then
            return util.stringify(var.default)
          end
          if type(var) == "table" and type(var.enum) == "table" and var.enum[1] ~= nil then
            return util.stringify(var.enum[1])
          end
          return "{" .. name .. "}"
        end)
      end
      if spec.__source and M.is_url(spec.__source) then
        url = M.resolve_url(url, spec.__source)
      end
      return (url:gsub("/$", ""))
    end
  end

  -- Swagger 2.0.
  if type(spec.host) == "string" and spec.host ~= "" then
    local scheme = (type(spec.schemes) == "table" and spec.schemes[1]) or "https"
    local base = type(spec.basePath) == "string" and spec.basePath or ""
    return (("%s://%s%s"):format(scheme, spec.host, base):gsub("/$", ""))
  end
  if type(spec.basePath) == "string" and spec.basePath ~= "" then
    if spec.__source and M.is_url(spec.__source) then
      return (M.resolve_url(spec.basePath, spec.__source):gsub("/$", ""))
    end
    return (spec.basePath:gsub("/$", ""))
  end
  if spec.__source and M.is_url(spec.__source) then
    local scheme, host = spec.__source:match("^(https?://)([^/]+)")
    if scheme then
      return scheme .. host
    end
  end
  return nil
end

--- The first variable from `openapi.base_vars` the project uses for its host,
--- so an imported request follows the environment rather than the spec.
---
--- What is selected *right now* is asked first, and then every environment the
--- file defines. The question is whether the project is built around a `host`
--- variable, not whether one happens to resolve this second: importing before
--- picking an environment is the normal way round, and the block has to come
--- out the same either way.
---@param source string|nil
---@return string|nil
local function base_variable(source)
  local cfg = config.get().openapi
  local names = cfg.base_vars or {}
  if #names == 0 then
    return nil
  end

  local env = require("curlite.env")
  local ok, vars = pcall(env.active, source)
  if not ok or type(vars) ~= "table" then
    vars = {}
  end
  for _, name in ipairs(names) do
    local value = vars[name]
    if value == nil then
      value = env.globals[name]
    end
    if value ~= nil and value ~= "" then
      return name
    end
  end

  local loaded = pcall(env.load, source) and env.load(source) or {}
  for _, name in ipairs(names) do
    for _, defined in pairs(loaded) do
      if type(defined) == "table" and defined[name] ~= nil and defined[name] ~= "" then
        return name
      end
    end
  end
  return nil
end

--- What inserted requests should be prefixed with.
---
---   "env"   -- `{{host}}` when the project defines such a variable, else the
---              spec's own server
---   "spec"  -- always the spec's server
---   literal -- that string, as given
---@param spec table
---@param source string|nil
---@return string base, boolean templated
function M.base(spec, source)
  local cfg = config.get().openapi
  local mode = cfg.base

  if type(mode) == "string" and mode ~= "env" and mode ~= "spec" then
    return (mode:gsub("/$", "")), mode:find("{{", 1, true) ~= nil
  end

  local server = M.server(spec)
  if mode == "env" then
    local name = base_variable(source)
    if name then
      -- The environment's variable is the host; the spec's server may add a
      -- path on top of it (`/v2`), and that part belongs to the API.
      local suffix = ""
      if server then
        local path = server:match("^https?://[^/]+(/.*)$")
        if path and path ~= "/" then
          suffix = path
        end
      end
      return ("{{%s}}%s"):format(name, suffix), true
    end
  end

  if server then
    return server, server:find("{{", 1, true) ~= nil
  end
  -- Nothing to go on: a variable is better than a wrong guess, and the
  -- environment is where it belongs.
  local names = cfg.base_vars or {}
  return ("{{%s}}"):format(names[1] or "host"), true
end

--- ------------------------------------------------------------- operations

--- Parameters for an operation: the path's, then the operation's own, with a
--- later definition of the same name/location winning. `$ref`s are followed.
---@param spec table
---@param path_item table
---@param operation table
---@return table[]
local function parameters(spec, path_item, operation)
  local out, index = {}, {}
  local function add(list)
    for _, entry in ipairs(type(list) == "table" and list or {}) do
      local param = deref(spec, entry)
      if type(param) == "table" and type(param.name) == "string" then
        local key = (param["in"] or "query") .. ":" .. param.name
        if index[key] then
          out[index[key]] = param
        else
          table.insert(out, param)
          index[key] = #out
        end
      end
    end
  end
  add(path_item.parameters)
  add(operation.parameters)
  return out
end

--- The response media type an operation advertises, for an `Accept` header.
---@param spec table
---@param operation table
---@return string|nil
local function response_media(spec, operation)
  local responses = operation.responses
  if type(responses) ~= "table" then
    -- Swagger 2.0 declares it for the whole file, or per operation.
    local produces = operation.produces or spec.produces
    return type(produces) == "table" and produces[1] or nil
  end

  local codes = {}
  for code in pairs(responses) do
    table.insert(codes, tostring(code))
  end
  table.sort(codes)
  for _, code in ipairs(codes) do
    if code:sub(1, 1) == "2" then
      local response = deref(spec, responses[code])
      if type(response) == "table" and type(response.content) == "table" then
        local media = pick_media(response.content)
        if media then
          return media
        end
      end
    end
  end
  local produces = operation.produces or spec.produces
  return type(produces) == "table" and produces[1] or nil
end

--- The request body of an operation, in both spec dialects.
---@param spec table
---@param operation table
---@param params table[]
---@param opts table
---@return string|nil media, string[] lines
local function request_body(spec, operation, params, opts)
  --- A multipart body carries its boundary in the header, which is where
  --- curlite's parser reads it back from.
  ---@param media string
  ---@param lines string[]
  ---@return string, string[]
  local function typed(media, lines)
    if #lines > 0 and media:find("multipart/form%-data") and not media:find("boundary") then
      return ("%s; boundary=%s"):format(media, M.BOUNDARY), lines
    end
    return media, lines
  end

  local body = deref(spec, operation.requestBody)
  if type(body) == "table" and type(body.content) == "table" then
    local media = pick_media(body.content)
    if media then
      return typed(media, body_lines(spec, deref(spec, body.content[media]) or {}, media, opts))
    end
  end

  -- Swagger 2.0: a `body` parameter, or `formData` ones.
  local form = {}
  for _, param in ipairs(params) do
    if param["in"] == "body" then
      local consumes = operation.consumes or spec.consumes
      local media = (type(consumes) == "table" and consumes[1]) or "application/json"
      local media_object = { schema = param.schema, example = param.example }
      return typed(media, body_lines(spec, media_object, media, opts))
    end
    if param["in"] == "formData" then
      table.insert(form, param)
    end
  end
  if #form > 0 then
    local consumes = operation.consumes or spec.consumes
    local media = (type(consumes) == "table" and consumes[1]) or "application/x-www-form-urlencoded"
    local out = {}
    for idx, param in ipairs(form) do
      local entry = ("%s=%s"):format(param.name, param_value(spec, param))
      table.insert(out, idx == 1 and entry or ("&" .. entry))
    end
    return media, out
  end

  return nil, {}
end

--- Every operation in a spec, as records the picker can list and render.
---@param spec table
---@param opts { source: string|nil }|nil
---@return curlite.openapi.Operation[]
function M.operations(spec, opts)
  opts = opts or {}
  if type(spec) ~= "table" or type(spec.paths) ~= "table" then
    return {}
  end

  local cfg = config.get().openapi
  local base = M.base(spec, opts.source)
  local body_opts = {
    indent = config.get().response.indent or 2,
    max_depth = tonumber(cfg.max_depth) or 6,
  }

  local out = {}
  local paths = {}
  for path in pairs(spec.paths) do
    table.insert(paths, tostring(path))
  end
  table.sort(paths)

  for _, path in ipairs(paths) do
    local path_item = deref(spec, spec.paths[path])
    if type(path_item) == "table" then
      for _, verb in ipairs(METHODS) do
        local operation = deref(spec, path_item[verb])
        if type(operation) == "table" then
          local method = verb:upper()
          local params = parameters(spec, path_item, operation)

          -- The URL: the base, the path with its `{placeholders}` filled in,
          -- and the query parameters that belong on it.
          local url_path = path:gsub("{([^}]+)}", function(name)
            for _, param in ipairs(params) do
              if param.name == name and param["in"] == "path" then
                return (param_value(spec, param, true):gsub("%%", "%%%%"))
              end
            end
            return ("{{%s}}"):format(name)
          end)

          local query = {}
          for _, param in ipairs(params) do
            if param["in"] == "query" then
              local wanted = cfg.query == "all" or (cfg.query ~= "none" and param.required == true)
              if wanted then
                table.insert(query, { name = param.name, value = param_value(spec, param) })
              end
            end
          end
          table.sort(query, function(a, b)
            return a.name < b.name
          end)

          local headers = {}
          for _, param in ipairs(params) do
            if param["in"] == "header" and param.required == true then
              table.insert(headers, { name = param.name, value = param_value(spec, param) })
            end
          end
          table.sort(headers, function(a, b)
            return a.name:lower() < b.name:lower()
          end)

          local cookies = {}
          for _, param in ipairs(params) do
            if param["in"] == "cookie" and param.required == true then
              table.insert(cookies, ("%s=%s"):format(param.name, param_value(spec, param)))
            end
          end
          table.sort(cookies)

          local media, body = request_body(spec, operation, params, body_opts)
          local summary = operation.summary and vim.trim(tostring(operation.summary)) or nil
          local description = operation.description and vim.trim(tostring(operation.description))
            or nil

          local tags = {}
          for _, tag in ipairs(type(operation.tags) == "table" and operation.tags or {}) do
            table.insert(tags, tostring(tag))
          end

          table.insert(out, {
            method = method,
            path = path,
            base = base,
            url = base .. url_path,
            id = operation.operationId and tostring(operation.operationId) or nil,
            summary = summary ~= "" and summary or nil,
            description = description ~= "" and description or nil,
            tags = tags,
            deprecated = operation.deprecated == true,
            query = query,
            headers = headers,
            cookies = cookies,
            accept = response_media(spec, operation),
            content_type = media,
            body = body,
            label = ("%s %s"):format(method, path),
          })
        end
      end
    end
  end

  table.sort(out, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return (METHOD_ORDER[a.method] or 99) < (METHOD_ORDER[b.method] or 99)
  end)

  for idx, op in ipairs(out) do
    -- The position in the list, so a front end that lets you mark several
    -- operations can insert them in the spec's order.
    op.index = idx
    -- What the fuzzy matcher sees: the method and path you would type, plus
    -- the words you would remember it by.
    op.ordinal = table.concat({
      op.method,
      op.path,
      op.summary or "",
      op.id or "",
      table.concat(op.tags, " "),
    }, " ")
  end
  return out
end

--- The title of the `###` separator for an operation.
---@param op table
---@return string
function M.title(op)
  local cfg = config.get().openapi
  local by = cfg.name
  if by == "operationId" and op.id then
    return op.id
  end
  if by == "path" then
    return op.label
  end
  if op.summary then
    -- A separator is one line, so a multi-line summary is cut to its first.
    return vim.split(op.summary, "\n", { plain = true })[1]
  end
  return op.id or op.label
end

--- One operation as the `.http` block that will be inserted.
---@param op table
---@param opts { env_headers: table<string, any>|nil }|nil
---@return string[]
function M.block(op, opts)
  opts = opts or {}
  local cfg = config.get().openapi
  local lines = {}
  local title = M.title(op)

  table.insert(lines, ("### %s"):format(title))

  -- `# @name` gives the request a stable handle for `# @run` and
  -- `{{id.response.body.$...}}`, which the summary in the title does not.
  if cfg.name_meta and op.id and op.id ~= title then
    table.insert(lines, ("# @name %s"):format(op.id))
  end
  if cfg.comments then
    if op.deprecated then
      table.insert(lines, "# deprecated")
    end
    local note = op.description
    if note and note ~= op.summary then
      local first = vim.split(note, "\n", { plain = true })[1]
      first = vim.trim(first or "")
      if first ~= "" and first ~= title then
        table.insert(lines, ("# %s"):format(first))
      end
    end
  end

  -- The request line, with the query on continuation lines when there is more
  -- than one: `  ?a=1` / `  &b=2` is how curlite reads a long URL.
  local url = op.url
  if #op.query == 1 then
    url = ("%s?%s=%s"):format(url, op.query[1].name, op.query[1].value)
    table.insert(lines, ("%s %s"):format(op.method, url))
  else
    table.insert(lines, ("%s %s"):format(op.method, url))
    for idx, entry in ipairs(op.query) do
      table.insert(lines, ("  %s%s=%s"):format(idx == 1 and "?" or "&", entry.name, entry.value))
    end
  end

  -- A header the environment already sends is left off: repeating it here
  -- would override the environment with a placeholder.
  local provided = {}
  if cfg.skip_env_headers then
    for name, value in pairs(opts.env_headers or {}) do
      if value ~= false then
        provided[name:lower()] = true
      end
    end
  end

  if op.content_type then
    table.insert(lines, ("Content-Type: %s"):format(op.content_type))
  end
  if cfg.accept and op.accept and not provided["accept"] then
    table.insert(lines, ("Accept: %s"):format(op.accept))
  end
  for _, header in ipairs(op.headers) do
    if not provided[header.name:lower()] then
      table.insert(lines, ("%s: %s"):format(header.name, header.value))
    end
  end
  if #op.cookies > 0 and not provided["cookie"] then
    table.insert(lines, ("Cookie: %s"):format(table.concat(op.cookies, "; ")))
  end

  if #op.body > 0 then
    table.insert(lines, "")
    vim.list_extend(lines, op.body)
  end

  table.insert(lines, "")
  return lines
end

--- The line within a block that holds the request, so the cursor can land on
--- it and `<CR>` sends what was just inserted.
---@param lines string[]
---@return integer
function M.request_line(lines)
  for idx, line in ipairs(lines) do
    if require("curlite.parser").methods[line:match("^(%u+)%s")] then
      return idx
    end
  end
  return 1
end

return M
