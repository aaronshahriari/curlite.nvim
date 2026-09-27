--- Turn a resolved request into a curl argument vector.
---
--- Response data comes back out of band rather than mixed into stdout:
---   * headers  -> `--dump-header <file>`  (every redirect hop, in order)
---   * body     -> `--output <file>`       (binary-safe)
---   * stats    -> `--write-out <json>`    (on stdout)
---   * verbose  -> `--verbose`             (on stderr)
--- which means a body containing header-looking lines can never confuse the
--- parser, and a 40MB download never passes through a Lua string twice.

local config = require("curlite.config")
local parser = require("curlite.parser")
local util = require("curlite.util")

local M = {}

-- curl's built-in JSON object handles string escaping and null values. There
-- is no `%{json:name}` modifier; using it makes curl emit an error per field.
local WRITE_OUT = "%{json}"

M.write_out = WRITE_OUT

--- Case-insensitive header delete, returning the value that was removed.
local function take_header(req, name)
  local want = name:lower()
  for k, v in pairs(req.headers) do
    if k:lower() == want then
      req.headers[k] = nil
      for i, hk in ipairs(req.header_order) do
        if hk == k then
          table.remove(req.header_order, i)
          break
        end
      end
      return v
    end
  end
  return nil
end

--- Does this string already look like base64 (so we must not re-encode it)?
local function looks_base64(s)
  return s:match("^[A-Za-z0-9+/=]+$") ~= nil and #s % 4 == 0 and not s:find(" ")
end

--- `Authorization: <scheme> <credentials>` handling. Most schemes map onto a
--- dedicated curl flag, which is both shorter and lets curl do the challenge
--- round trip (Digest and NTLM need two requests).
---@param req curlite.Request
---@param argv string[]
local function apply_auth(req, argv)
  local value = parser.header(req, "Authorization")
  if not value or value == "" then
    return
  end

  local scheme, creds = value:match("^(%S+)%s+(.*)$")
  if not scheme then
    return
  end
  scheme = scheme:lower()
  creds = vim.trim(creds)

  local function userpass()
    -- Accept both `user pass` and `user:pass`.
    local u, p = creds:match("^(%S+)%s+(.*)$")
    if u then
      return u .. ":" .. p
    end
    return creds
  end

  if scheme == "basic" then
    -- A literal base64 blob is already a valid header; leave it. Anything else
    -- is `user pass` or `user:pass` and needs encoding.
    if creds ~= "" and not looks_base64(creds) then
      take_header(req, "Authorization")
      vim.list_extend(argv, { "--basic", "--user", userpass() })
    end
  elseif scheme == "digest" then
    take_header(req, "Authorization")
    vim.list_extend(argv, { "--digest", "--user", userpass() })
  elseif scheme == "ntlm" then
    take_header(req, "Authorization")
    vim.list_extend(argv, { "--ntlm", "--user", userpass() })
  elseif scheme == "negotiate" then
    take_header(req, "Authorization")
    vim.list_extend(argv, { "--negotiate", "--user", creds ~= "" and userpass() or ":" })
  elseif scheme == "aws" then
    -- `Authorization: AWS <key> <secret> [region] [service]`
    local parts = vim.split(creds, "%s+")
    if #parts >= 2 then
      take_header(req, "Authorization")
      local region = parts[3] or "us-east-1"
      local service = parts[4] or "execute-api"
      vim.list_extend(argv, {
        "--aws-sigv4",
        ("aws:amz:%s:%s"):format(region, service),
        "--user",
        parts[1] .. ":" .. parts[2],
      })
    end
  end
end

--- Percent-encode the characters that can't appear literally in a URL.
---
--- This matters once variables are substituted: `?title={{name}}` is a perfectly
--- good URL in the file, and becomes `?title=Sample Slide Show` once `name`
--- resolves -- which curl rejects outright. Browsers encode these on the way
--- out, so curlite does too. An existing `%XX` escape is left alone; a bare `%`
--- that isn't one becomes `%25`.
---@param url string
---@return string
function M.sanitize_url(url)
  local out = {}
  local i = 1
  while i <= #url do
    local c = url:sub(i, i)
    local byte = c:byte()
    if c == "%" then
      if url:sub(i + 1, i + 2):match("^%x%x$") then
        table.insert(out, url:sub(i, i + 2))
        i = i + 2
      else
        table.insert(out, "%25")
      end
    elseif byte < 0x21 or byte == 0x7f then
      -- Spaces and control characters.
      table.insert(out, ("%%%02X"):format(byte))
    elseif c:find('["<>\\^`{}|]') then
      table.insert(out, ("%%%02X"):format(byte))
    else
      table.insert(out, c)
    end
    i = i + 1
  end
  return table.concat(out)
end

--- Collapse a form-urlencoded body onto one line.
---
--- `.http` files are routinely written as
---     sessionToken={{token}}
---     &firstResult=0
--- and the newlines are formatting, not data. Every REST client strips them;
--- sending them literally is always a 400.
---@param body string
---@return string
function M.collapse_form_body(body)
  local out = body:gsub("\r?\n%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return out
end

--- Split a multipart body written with explicit boundaries into `-F` args.
---@param body string
---@param boundary string
---@param source string|nil
---@return string[]|nil  nil when the body doesn't actually use the boundary
local function multipart_args(body, boundary, source)
  local marker = "--" .. boundary
  if not body:find(marker, 1, true) then
    return nil
  end

  local args = {}
  -- Split on the boundary, dropping the preamble and the trailing `--`.
  local parts = vim.split(body, marker, { plain = true })
  for _, part in ipairs(parts) do
    part = part:gsub("^\r?\n", "")
    if part ~= "" and not part:match("^%-%-") then
      -- Headers, blank line, then content.
      local head, content = part:match("^(.-)\r?\n\r?\n(.*)$")
      if not head then
        head, content = part, ""
      end
      local name, filename, ctype
      for line in head:gmatch("[^\r\n]+") do
        local hn, hv = line:match("^([%w%-]+)%s*:%s*(.*)$")
        if hn and hn:lower() == "content-disposition" then
          name = hv:match('name="([^"]*)"') or hv:match("name=([^;%s]+)")
          filename = hv:match('filename="([^"]*)"') or hv:match("filename=([^;%s]+)")
        elseif hn and hn:lower() == "content-type" then
          ctype = vim.trim(hv)
        end
      end
      if name then
        content = content:gsub("\r?\n$", "")
        -- A part whose content is `< ./path` sends that file.
        local fpath = content:match("^%s*<%s+(.+)%s*$")
        local spec
        if fpath then
          spec = ("%s=@%s"):format(name, util.resolve_path(vim.trim(fpath), source))
          if filename then
            spec = spec .. ";filename=" .. filename
          end
        elseif filename then
          -- An inline file part with a declared name: hand curl the literal
          -- bytes but keep the filename it should advertise.
          spec = ("%s=%s;filename=%s"):format(name, content, filename)
        else
          spec = ("%s=%s"):format(name, content)
        end
        if ctype then
          spec = spec .. ";type=" .. ctype
        end
        vim.list_extend(args, { "--form", spec })
      end
    end
  end

  return #args > 0 and args or nil
end

--- Build the JSON payload a GraphQL request actually sends.
---
--- A GraphQL section is the query, optionally followed by a blank line and a
--- JSON object of variables:
---
---     query ($id: ID!) { user(id: $id) { name } }
---
---     { "id": "42" }
---@param body string
---@return string
function M.graphql_payload(body)
  local query, variables = body, nil

  -- Find the last blank-line-separated chunk that parses as a JSON object.
  local split_at = nil
  local offset = 1
  while true do
    local s, e = body:find("\r?\n%s*\r?\n", offset)
    if not s then
      break
    end
    local candidate = body:sub(e + 1)
    if vim.trim(candidate):sub(1, 1) == "{" and util.json_decode(candidate) then
      split_at = { s, e }
    end
    offset = e + 1
  end

  if split_at then
    query = body:sub(1, split_at[1] - 1)
    variables = util.json_decode(body:sub(split_at[2] + 1))
  end

  local payload = { query = vim.trim(query) }
  if variables then
    payload.variables = variables
  end
  -- Empty variables must serialise as `{}`, not `[]`.
  return vim.json.encode(payload)
end

--- Does this request look like GraphQL?
---@param req curlite.Request
---@return boolean
function M.is_graphql(req)
  if req.method == "GRAPHQL" then
    return true
  end
  if req.metadata and req.metadata.graphql then
    return true
  end
  local rt = parser.header(req, "X-REQUEST-TYPE")
  return rt ~= nil and rt:lower() == "graphql"
end

---@class curlite.Command
---@field argv string[]
---@field stdin string|nil
---@field body_path string       -- where the response body is written
---@field header_path string     -- where the response headers are dumped
---@field timeout integer        -- ms, 0 = none
---@field request curlite.Request  the request as actually sent (auth stripped)
---@field sent_body string|nil   the body as actually sent, for display

--- Build the command for one already-variable-resolved request.
---@param req curlite.Request
---@return curlite.Command
function M.build(req)
  local cfg = config.get()
  req = vim.deepcopy(req)
  local meta = req.metadata or {}

  local tmp = vim.fn.tempname()
  local header_path = tmp .. ".headers"
  local body_path = tmp .. ".body"

  local argv = { cfg.curl.path }
  vim.list_extend(argv, vim.deepcopy(cfg.curl.args))
  vim.list_extend(argv, {
    "--silent",
    "--show-error",
    "--dump-header",
    header_path,
    "--output",
    body_path,
    "--write-out",
    WRITE_OUT,
    "--verbose",
  })

  -- ---- protocol / connection flags --------------------------------------
  if meta["no-redirect"] or meta["no-location"] then
    for i = #argv, 1, -1 do
      if argv[i] == "--location" then
        table.remove(argv, i)
      end
    end
  end
  if meta["max-redirs"] then
    vim.list_extend(argv, { "--max-redirs", tostring(meta["max-redirs"]) })
  end
  if meta.insecure or not cfg.curl.verify_ssl then
    table.insert(argv, "--insecure")
  end
  if meta.compressed then
    table.insert(argv, "--compressed")
  end
  if meta.http2 or meta["http/2"] then
    table.insert(argv, "--http2")
  elseif meta.http3 or meta["http/3"] then
    table.insert(argv, "--http3")
  elseif meta["http1.1"] or meta["http/1.1"] or req.http_version == "HTTP/1.1" then
    table.insert(argv, "--http1.1")
  end
  if meta.proxy then
    vim.list_extend(argv, { "--proxy", tostring(meta.proxy) })
  end
  if meta["unix-socket"] then
    vim.list_extend(argv, { "--unix-socket", util.resolve_path(tostring(meta["unix-socket"]), req.source) })
  end
  if meta.cert then
    vim.list_extend(argv, { "--cert", util.resolve_path(tostring(meta.cert), req.source) })
  end
  if meta.key then
    vim.list_extend(argv, { "--key", util.resolve_path(tostring(meta.key), req.source) })
  end
  if meta.cacert then
    vim.list_extend(argv, { "--cacert", util.resolve_path(tostring(meta.cacert), req.source) })
  end
  if meta.retry then
    vim.list_extend(argv, { "--retry", tostring(meta.retry) })
  end
  if meta.user then
    vim.list_extend(argv, { "--user", tostring(meta.user) })
  end
  if meta.resolve then
    vim.list_extend(argv, { "--resolve", tostring(meta.resolve) })
  end
  if meta.interface then
    vim.list_extend(argv, { "--interface", tostring(meta.interface) })
  end

  -- ---- cookies -----------------------------------------------------------
  if cfg.curl.cookie_jar and not meta["no-cookie-jar"] then
    local jar = util.resolve_path(cfg.curl.cookie_jar, nil)
    vim.fn.mkdir(vim.fn.fnamemodify(jar, ":h"), "p")
    vim.list_extend(argv, { "--cookie", jar, "--cookie-jar", jar })
  end

  -- ---- timeout -----------------------------------------------------------
  local timeout = tonumber(meta.timeout) or cfg.curl.timeout or 0
  if timeout > 0 then
    -- curl wants seconds (it accepts decimals since 7.32).
    vim.list_extend(argv, { "--max-time", ("%.3f"):format(timeout / 1000) })
  end

  -- ---- auth (may strip the Authorization header) --------------------------
  apply_auth(req, argv)

  -- ---- accept shorthand --------------------------------------------------
  if meta.accept and not parser.header(req, "Accept") then
    req.headers["Accept"] = tostring(meta.accept)
    table.insert(req.header_order, "Accept")
  end

  -- ---- body --------------------------------------------------------------
  local content_type = parser.header(req, "Content-Type") or ""
  local stdin, sent_body = nil, nil
  local form_args = nil

  if M.is_graphql(req) and req.body then
    sent_body = M.graphql_payload(req.body)
    stdin = sent_body
    if content_type == "" then
      req.headers["Content-Type"] = "application/json"
      table.insert(req.header_order, "Content-Type")
      content_type = "application/json"
    end
    take_header(req, "X-REQUEST-TYPE")
    if req.method == "GRAPHQL" or req.method == "GET" then
      req.method = "POST"
    end
  elseif req.body_file then
    local path = util.resolve_path(req.body_file, req.source)
    if vim.fn.filereadable(path) == 0 then
      error(("body file not found: %s"):format(path), 0)
    end
    -- `@file` lets curl stream it; no need to read it into Lua at all.
    vim.list_extend(argv, { "--data-binary", "@" .. path })
    sent_body = ("< %s (%s)"):format(path, util.human_size(vim.fn.getfsize(path)))
  elseif req.body and req.body ~= "" then
    local boundary = content_type:match("boundary=[\"']?([^\"';%s]+)")
    if content_type:lower():find("multipart/form%-data") and boundary then
      form_args = multipart_args(req.body, boundary, req.source)
      if form_args then
        -- curl generates its own boundary for `-F`; ours would conflict.
        take_header(req, "Content-Type")
        vim.list_extend(argv, form_args)
        sent_body = req.body
      end
    end
    if not form_args then
      if content_type:lower():find("application/x%-www%-form%-urlencoded") then
        sent_body = M.collapse_form_body(req.body)
      else
        sent_body = req.body
      end
      stdin = sent_body
      if content_type == "" and cfg.request.infer_content_type then
        local first = vim.trim(sent_body):sub(1, 1)
        if (first == "{" or first == "[") and util.json_decode(sent_body) then
          req.headers["Content-Type"] = "application/json"
          table.insert(req.header_order, "Content-Type")
        end
      end
    end
  end

  if stdin then
    -- `@-` reads the body from stdin, so no length limit and no shell quoting.
    vim.list_extend(argv, { "--data-binary", "@-" })
  end

  -- ---- method ------------------------------------------------------------
  if req.method == "HEAD" then
    -- `-X HEAD` makes curl wait for a body that never comes.
    table.insert(argv, "--head")
  elseif req.method ~= "GET" or stdin or form_args or req.body_file then
    vim.list_extend(argv, { "--request", req.method })
  end

  -- ---- headers -----------------------------------------------------------
  local seen = {}
  for _, name in ipairs(req.header_order) do
    local lower = name:lower()
    if not seen[lower] and req.headers[name] ~= nil then
      seen[lower] = true
      local value = req.headers[name]
      if value == "" then
        -- `Header;` tells curl to send an empty header rather than drop it.
        table.insert(argv, "--header")
        table.insert(argv, name .. ";")
      else
        table.insert(argv, "--header")
        table.insert(argv, ("%s: %s"):format(name, value))
      end
    end
  end

  -- Defaults only fill gaps the request left.
  for name, value in pairs(cfg.request.default_headers or {}) do
    if not seen[name:lower()] then
      vim.list_extend(argv, { "--header", ("%s: %s"):format(name, value) })
    end
  end

  -- ---- raw `# @curl` flags, last so they can override ---------------------
  vim.list_extend(argv, req.curl_args or {})

  -- ---- the URL -----------------------------------------------------------
  req.url = M.sanitize_url(req.url)
  table.insert(argv, req.url)

  return {
    argv = argv,
    stdin = stdin,
    body_path = body_path,
    header_path = header_path,
    timeout = timeout,
    request = req,
    sent_body = sent_body,
  }
end

--- Quote a single argument only when the shell would care.
---@param arg string
---@return string
local function shell_quote(arg)
  if arg ~= "" and arg:match("^[%w@%%_+=:,./%-]+$") then
    return arg
  end
  return "'" .. arg:gsub("'", [['\'']]) .. "'"
end

--- Render a command as a shell-pasteable curl line.
---@param cmd curlite.Command
---@param multiline boolean|nil  break on `\` after each flag group
---@return string
function M.to_shell(cmd, multiline)
  local parts = {}
  local skip_next = false

  for i, arg in ipairs(cmd.argv) do
    if skip_next then
      skip_next = false
      goto continue
    end
    -- Drop the plumbing that only makes sense inside curlite.
    if arg == "--silent" or arg == "--show-error" or arg == "--verbose" or arg == "--no-buffer" then
      goto continue
    end
    if arg == "--dump-header" or arg == "--output" or arg == "--write-out" then
      skip_next = true
      goto continue
    end
    if arg == "--data-binary" and cmd.argv[i + 1] == "@-" then
      skip_next = true
      if cmd.stdin then
        table.insert(parts, { "--data-binary", shell_quote(cmd.stdin) })
      end
      goto continue
    end
    -- Group a flag with its value so multiline output breaks in useful places.
    if arg:match("^%-%-?[%w%-%.]+$") and cmd.argv[i + 1] and not cmd.argv[i + 1]:match("^%-%-?[%a]") then
      -- Only a flag that actually takes a value; booleans stand alone.
      local takes_value = not vim.tbl_contains({
        "--location",
        "--insecure",
        "--compressed",
        "--head",
        "--basic",
        "--digest",
        "--ntlm",
        "--negotiate",
        "--http2",
        "--http3",
        "--http1.1",
      }, arg)
      if takes_value then
        skip_next = true
        table.insert(parts, { arg, shell_quote(cmd.argv[i + 1]) })
        goto continue
      end
    end
    table.insert(parts, { shell_quote(arg) })
    ::continue::
  end

  local rendered = vim.tbl_map(function(group)
    return table.concat(group, " ")
  end, parts)

  if multiline then
    return table.concat(rendered, " \\\n  ")
  end
  return table.concat(rendered, " ")
end

return M
