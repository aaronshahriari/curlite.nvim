--- blink.cmp source for curlite.nvim.
---
--- Register it in your blink.cmp config:
---
---   sources = {
---     providers = {
---       curlite = { module = "curlite.blink", name = "curlite" },
---     },
---     per_filetype = { http = { "curlite", "path", "buffer" } },
---   }
---
--- It completes, depending on where the cursor is:
---   * `{{` -- document variables, environment variables, script globals,
---            dynamic functions, and the named requests you can chain from
---   * the start of a line -- request methods and header names
---   * after `Header:` -- plausible values for the common headers
---   * after `# @` -- metadata keys

local KIND = {
  Text = 1,
  Method = 2,
  Function = 3,
  Field = 5,
  Variable = 6,
  Keyword = 14,
  Constant = 21,
  EnumMember = 20,
}

local METHODS = {
  "GET",
  "POST",
  "PUT",
  "PATCH",
  "DELETE",
  "HEAD",
  "OPTIONS",
  "TRACE",
  "CONNECT",
  "QUERY",
  "GRAPHQL",
}

local HEADERS = {
  "Accept",
  "Accept-Encoding",
  "Accept-Language",
  "Authorization",
  "Cache-Control",
  "Connection",
  "Content-Disposition",
  "Content-Encoding",
  "Content-Length",
  "Content-Type",
  "Cookie",
  "ETag",
  "Expect",
  "Host",
  "If-Match",
  "If-Modified-Since",
  "If-None-Match",
  "Origin",
  "Prefer",
  "Range",
  "Referer",
  "User-Agent",
  "X-API-Key",
  "X-Correlation-ID",
  "X-Request-ID",
  "X-REQUEST-TYPE",
}

local HEADER_VALUES = {
  ["accept"] = {
    "application/json",
    "application/xml",
    "application/problem+json",
    "text/plain",
    "text/html",
    "*/*",
  },
  ["content-type"] = {
    "application/json",
    "application/x-www-form-urlencoded",
    "multipart/form-data; boundary=CurliteBoundary",
    "application/xml",
    "application/graphql",
    "text/plain",
    "application/octet-stream",
  },
  ["authorization"] = {
    "Bearer {{token}}",
    "Basic {{user}} {{password}}",
    "Digest {{user}} {{password}}",
    "NTLM {{user}} {{password}}",
    "AWS {{key}} {{secret}} us-east-1 execute-api",
  },
  ["accept-encoding"] = { "gzip", "gzip, deflate, br", "identity" },
  ["cache-control"] = { "no-cache", "no-store", "max-age=0" },
  ["connection"] = { "keep-alive", "close" },
  ["x-request-type"] = { "GraphQL" },
  ["prefer"] = { "respond-async", "return=representation", "return=minimal" },
}

-- `# @key` metadata, with what each one does.
local METADATA = {
  { "name", "name this request, so `{{name.response...}}` can reference it" },
  { "prompt", "ask for a value before sending: `# @prompt token Paste the token`" },
  { "assert", "check the response: `# @assert status == 200`" },
  { "run", "send another named request first: `# @run LOGIN`" },
  { "import", "make another file's named requests available: `# @import ./auth.http`" },
  { "accept", "shorthand for the Accept header" },
  { "timeout", "milliseconds before the request is abandoned" },
  { "delay", "milliseconds to wait before sending" },
  { "insecure", "skip TLS certificate verification" },
  { "no-redirect", "do not follow redirects" },
  { "max-redirs", "maximum redirects to follow" },
  { "compressed", "ask for and decode a compressed response" },
  { "http2", "force HTTP/2" },
  { "http1.1", "force HTTP/1.1" },
  { "http3", "force HTTP/3" },
  { "proxy", "send through this proxy" },
  { "unix-socket", "connect over a unix socket instead of TCP" },
  { "cert", "client certificate path" },
  { "key", "client key path" },
  { "cacert", "CA bundle path" },
  { "resolve", "pin a host to an address: `host:port:addr`" },
  { "interface", "bind to this network interface" },
  { "retry", "retry this many times on a transient failure" },
  { "user", "credentials for curl's --user" },
  { "graphql", "treat the body as a GraphQL query" },
  { "confirm", "show the resolved request and require confirmation" },
  { "skip", "never send this request" },
  { "no-cookie-jar", "don't read or write the shared cookie jar" },
  { "curl", "raw curl flags, appended verbatim" },
}

-- The dynamic `{{$...}}` functions, with a hint of what each returns.
local DYNAMIC = {
  { "$uuid", "a random v4 UUID" },
  { "$guid", "a random v4 UUID" },
  { "$timestamp", "seconds since the epoch; `$timestamp -1 d` shifts it" },
  { "$isoTimestamp", "ISO-8601 UTC, e.g. 2026-09-27T12:00:00Z" },
  { "$datetime iso8601", "ISO-8601; also `rfc1123`, `unix`, or a strftime format" },
  { "$localDatetime iso8601", "the same, in local time" },
  { "$date", "today, or `$date %d/%m/%Y`" },
  { "$time", "now, or `$time %H:%M`" },
  { "$randomInt 1 100", "an integer in a range" },
  { "$randomAlphaNumeric 16", "a random alphanumeric string" },
  { "$randomHex 16", "a random hex string" },
  { "$randomEmail", "a random example.com address" },
  { "$randomFullName", "a random name" },
  { "$random.integer(1, 100)", "IntelliJ spelling of a random integer" },
  { "$random.uuid", "IntelliJ spelling of a random UUID" },
  { "$env.NAME", "a process environment variable" },
  { "$processEnv NAME", "a process environment variable" },
  { "$dotenv NAME", "a value from the nearest .env file" },
  { "$exec command", "stdout of a shell command, e.g. `$exec pass show api/token`" },
}

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return vim.tbl_contains(require("curlite.config").get().filetypes, vim.bo.filetype)
end

function source:get_trigger_characters()
  return { "{", "@", ":", "$", "." }
end

---@param label string
---@param kind integer
---@param detail string|nil
---@param insert string|nil
local function item(label, kind, detail, insert)
  return {
    label = label,
    kind = kind,
    detail = detail,
    insertText = insert or label,
    -- Keep our own ordering: methods before headers, variables before
    -- dynamic functions.
    sortText = label,
  }
end

--- Everything that could go inside `{{ }}` at this point in the buffer.
---@return table[]
local function variable_items()
  local items = {}
  local parser = require("curlite.parser")
  local env = require("curlite.env")
  local variables = require("curlite.variables")

  local ok, doc = pcall(parser.parse_buffer, 0)
  local source_path = vim.api.nvim_buf_get_name(0)

  if ok then
    for name, value in pairs(doc.variables) do
      table.insert(items, item(name, KIND.Variable, ("= %s"):format(value), name))
    end
    -- Named requests, offered as a chain reference rather than a bare name,
    -- because the name alone is never what you want inside `{{ }}`.
    for _, req in ipairs(doc.requests) do
      if req.name and req.name ~= "" then
        table.insert(
          items,
          item(
            ("%s.response.body.$."):format(req.name),
            KIND.Field,
            ("%s %s"):format(req.method, req.url)
          )
        )
        table.insert(
          items,
          item(("%s.response.status"):format(req.name), KIND.Field, "that request's status code")
        )
        table.insert(
          items,
          item(("%s.response.headers."):format(req.name), KIND.Field, "that request's response headers")
        )
      end
    end
  end

  local envvars, envname = env.active(source_path)
  for name, value in pairs(envvars) do
    table.insert(
      items,
      item(
        name,
        KIND.Constant,
        ("%s: %s"):format(envname or "env", type(value) == "table" and vim.json.encode(value) or tostring(value))
      )
    )
  end

  for name, value in pairs(env.globals) do
    table.insert(items, item(name, KIND.Variable, ("script global: %s"):format(value)))
  end

  for name in pairs(variables.prompt_answers) do
    table.insert(items, item(name, KIND.Variable, "prompt answer"))
  end

  for _, spec in ipairs(DYNAMIC) do
    table.insert(items, item(spec[1], KIND.Function, spec[2]))
  end

  return items
end

function source:get_completions(ctx, callback)
  local line = ctx.line or vim.api.nvim_get_current_line()
  local col = ctx.cursor and ctx.cursor[2] or vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local items = {}

  -- Inside an unclosed `{{`.
  local open = before:match(".*{{")
  if open and not before:sub(#open + 1):find("}}") then
    items = variable_items()
    callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  -- `# @` metadata.
  if before:match("^%s*[#/][#/]?%s*@[%w-]*$") then
    for _, spec in ipairs(METADATA) do
      table.insert(items, item(spec[1], KIND.Keyword, spec[2]))
    end
    callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  -- After `Header: `, offer values for the headers where it helps.
  local header = before:match("^([%w%-]+)%s*:%s*[^;]*$")
  if header then
    for _, value in ipairs(HEADER_VALUES[header:lower()] or {}) do
      table.insert(items, item(value, KIND.EnumMember, header))
    end
    if #items > 0 then
      callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
      return
    end
  end

  -- At the start of a line: methods and header names.
  if before:match("^%s*[%a]*$") then
    for _, method in ipairs(METHODS) do
      table.insert(items, item(method, KIND.Method, "request method", method .. " "))
    end
    for _, name in ipairs(HEADERS) do
      table.insert(items, item(name, KIND.Field, "header", name .. ": "))
    end
  end

  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

function source:execute(_, _, callback)
  callback()
end

return source
