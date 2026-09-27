--- Converting a `curl` command line into a `.http` request.
---
--- This is the "copy as cURL" round trip: grab a request out of your browser's
--- network tab, paste it here, and get a readable request back.

local parser = require("curlite.parser")

local M = {}

-- Flags that take a value and that map onto something in a `.http` file.
local VALUE_FLAGS = {
  ["-H"] = "header",
  ["--header"] = "header",
  ["-X"] = "method",
  ["--request"] = "method",
  ["-d"] = "data",
  ["--data"] = "data",
  ["--data-raw"] = "data",
  ["--data-ascii"] = "data",
  ["--data-binary"] = "data",
  ["--data-urlencode"] = "data-urlencode",
  ["-F"] = "form",
  ["--form"] = "form",
  ["-u"] = "user",
  ["--user"] = "user",
  ["-A"] = "user-agent",
  ["--user-agent"] = "user-agent",
  ["-e"] = "referer",
  ["--referer"] = "referer",
  ["-b"] = "cookie",
  ["--cookie"] = "cookie",
  ["--url"] = "url",
  ["-o"] = "output",
  ["--output"] = "output",
  ["--connect-timeout"] = "connect-timeout",
  ["-m"] = "max-time",
  ["--max-time"] = "max-time",
  ["-x"] = "proxy",
  ["--proxy"] = "proxy",
  ["--cert"] = "cert",
  ["--key"] = "key",
  ["--max-redirs"] = "max-redirs",
  ["--aws-sigv4"] = "aws-sigv4",
  -- Flags that take a value and have no `.http` equivalent. They are listed
  -- so their *value* isn't mistaken for the URL.
  ["-c"] = "ignore",
  ["--cookie-jar"] = "ignore",
  ["-w"] = "ignore",
  ["--write-out"] = "ignore",
  ["-D"] = "ignore",
  ["--dump-header"] = "ignore",
  ["--trace"] = "ignore",
  ["--trace-ascii"] = "ignore",
  ["--stderr"] = "ignore",
  ["--config"] = "ignore",
  ["-K"] = "ignore",
}

-- Boolean flags worth carrying over as metadata.
local BOOL_FLAGS = {
  ["-k"] = "insecure",
  ["--insecure"] = "insecure",
  ["--compressed"] = "compressed",
  ["-I"] = "head",
  ["--head"] = "head",
  ["--http2"] = "http2",
  ["--http1.1"] = "http1.1",
  ["--http3"] = "http3",
  ["-G"] = "get",
  ["--get"] = "get",
  ["-L"] = "location",
  ["--location"] = "location",
  ["-s"] = nil,
  ["--silent"] = nil,
  ["-v"] = nil,
  ["--verbose"] = nil,
}

--- Strip shell line continuations and a leading `$`/`>` prompt.
---@param command string
---@return string
local function normalise(command)
  return (command
    :gsub("\\\r?\n", " ")
    :gsub("^%s*[%$>]%s+", "")
    :gsub("\r?\n", " "))
end

--- Turn a curl command line into `.http` lines.
---@param command string
---@return string[]|nil lines, string|nil err
function M.from_curl(command)
  command = normalise(command)

  local args = parser.split_args(command)
  -- Drop everything up to and including the `curl` word itself.
  while #args > 0 and args[1] ~= "curl" and not args[1]:match("/curl$") do
    table.remove(args, 1)
  end
  if #args == 0 then
    return nil, "no `curl` command found"
  end
  table.remove(args, 1)

  local url, method, body
  local headers, header_order = {}, {}
  local meta, forms, urlencoded = {}, {}, {}
  -- Positional arguments, resolved into the URL at the end. Collecting them
  -- rather than taking the first one means an unrecognised flag that happens
  -- to take a value can't have that value mistaken for the URL.
  local positional = {}

  local function add_header(name, value)
    if headers[name] == nil then
      table.insert(header_order, name)
    end
    headers[name] = value
  end

  local i = 1
  while i <= #args do
    local arg = args[i]
    local kind = VALUE_FLAGS[arg]

    -- Support the `--flag=value` spelling too.
    if not kind and arg:sub(1, 2) == "--" then
      local flag, value = arg:match("^(%-%-[%w%-%.]+)=(.*)$")
      if flag and VALUE_FLAGS[flag] then
        kind = VALUE_FLAGS[flag]
        table.insert(args, i + 1, value)
      end
    end

    if kind then
      local value = args[i + 1]
      i = i + 1
      if value == nil then
        -- A trailing flag with no value: nothing useful to carry over.
      elseif kind == "header" then
        local name, hv = value:match("^([^:]+):%s*(.*)$")
        if name then
          add_header(vim.trim(name), vim.trim(hv))
        end
      elseif kind == "method" then
        method = value:upper()
      elseif kind == "data" then
        body = body and (body .. "&" .. value) or value
      elseif kind == "data-urlencode" then
        table.insert(urlencoded, value)
      elseif kind == "form" then
        table.insert(forms, value)
      elseif kind == "user" then
        local user, pass = value:match("^([^:]*):(.*)$")
        add_header("Authorization", ("Basic %s %s"):format(user or value, pass or ""))
      elseif kind == "user-agent" then
        add_header("User-Agent", value)
      elseif kind == "referer" then
        add_header("Referer", value)
      elseif kind == "cookie" then
        -- curl reads `-b` as a cookie string when it contains `=`, and as a
        -- path to a jar otherwise.
        if value:find("=", 1, true) then
          add_header("Cookie", value)
        end
      elseif kind == "ignore" then
        -- consumed purely so the value isn't read as the URL
      elseif kind == "url" then
        url = value
      elseif kind == "max-time" then
        meta.timeout = tostring(math.floor(tonumber(value) or 0) * 1000)
      elseif kind == "output" then
        meta.output = value
      elseif kind == "aws-sigv4" then
        meta["aws-sigv4"] = value
      else
        meta[kind] = value
      end
    elseif BOOL_FLAGS[arg] then
      meta[BOOL_FLAGS[arg]] = true
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
      -- An unrecognised flag: keep it verbatim rather than lose it.
      meta._curl = meta._curl or {}
      table.insert(meta._curl, arg)
    else
      table.insert(positional, arg)
    end

    i = i + 1
  end

  if not url then
    -- Prefer a positional argument that actually looks like a URL; fall back
    -- to the first one so an unusual but valid command still converts.
    for _, candidate in ipairs(positional) do
      if candidate:match("^%a[%w+.-]*://") or candidate:match("^[%w.-]+%.%a%a+") then
        url = candidate
        break
      end
    end
    url = url or positional[1]
  end

  if not url then
    return nil, "no URL found in the curl command"
  end
  url = url:gsub("^['\"]", ""):gsub("['\"]$", "")

  -- `-G` moves the data into the query string.
  if meta.get and body then
    url = url .. (url:find("?", 1, true) and "&" or "?") .. body
    body = nil
  end

  if #urlencoded > 0 then
    local joined = table.concat(urlencoded, "&")
    body = body and (body .. "&" .. joined) or joined
    if not headers["Content-Type"] then
      add_header("Content-Type", "application/x-www-form-urlencoded")
    end
  end

  if not method then
    if meta.head then
      method = "HEAD"
    elseif body or #forms > 0 then
      method = "POST"
    else
      method = "GET"
    end
  end

  -- Build the output.
  local lines = {}

  local name = url:match("^%a+://[^/]+(/[^?]*)") or url
  table.insert(lines, ("### %s %s"):format(method, name))

  for key, value in pairs(meta) do
    if key == "insecure" or key == "compressed" or key == "http2" or key == "http3" then
      table.insert(lines, "# @" .. key)
    elseif key == "timeout" or key == "proxy" or key == "cert" or key == "key" or key == "max-redirs" then
      table.insert(lines, ("# @%s %s"):format(key, value))
    elseif key == "_curl" then
      table.insert(lines, ("# @curl %s"):format(table.concat(value, " ")))
    end
  end

  table.insert(lines, ("%s %s"):format(method, url))

  table.sort(header_order, function(a, b)
    return a:lower() < b:lower()
  end)
  for _, hname in ipairs(header_order) do
    table.insert(lines, ("%s: %s"):format(hname, headers[hname]))
  end

  if #forms > 0 then
    -- `-F` maps onto a multipart body with an explicit boundary, which is what
    -- curlite's own parser reads back in.
    local boundary = "CurliteBoundary"
    table.insert(lines, ("Content-Type: multipart/form-data; boundary=%s"):format(boundary))
    table.insert(lines, "")
    for _, form in ipairs(forms) do
      local fname, value = form:match("^([^=]+)=(.*)$")
      if fname then
        table.insert(lines, "--" .. boundary)
        local filepath = value:match("^@(.+)$")
        if filepath then
          local base = vim.fn.fnamemodify(filepath:gsub(";.*$", ""), ":t")
          table.insert(
            lines,
            ('Content-Disposition: form-data; name="%s"; filename="%s"'):format(fname, base)
          )
          table.insert(lines, "")
          table.insert(lines, "< " .. filepath:gsub(";.*$", ""))
        else
          table.insert(lines, ('Content-Disposition: form-data; name="%s"'):format(fname))
          table.insert(lines, "")
          table.insert(lines, value)
        end
      end
    end
    table.insert(lines, "--" .. boundary .. "--")
  elseif body then
    table.insert(lines, "")
    -- Re-indent a JSON body so it is readable in the file.
    local trimmed = vim.trim(body)
    if (trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[") and require("curlite.util").json_decode(trimmed) then
      local pretty = require("curlite.format").json(trimmed, require("curlite.config").get().response.indent)
      vim.list_extend(lines, vim.split(pretty, "\n", { plain = true }))
    elseif trimmed:find("&", 1, true) and not trimmed:find("\n", 1, true) then
      -- Break a long form body onto one parameter per line, which is how these
      -- read in a `.http` file (curlite joins them back up on send).
      local params = vim.split(trimmed, "&", { plain = true })
      table.insert(lines, params[1])
      for idx = 2, #params do
        table.insert(lines, "&" .. params[idx])
      end
    else
      vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
    end
  end

  table.insert(lines, "")
  return lines
end

--- The inverse: a parsed request as a curl command line.
---@param req curlite.Request
---@return string|nil, string|nil err
function M.to_curl(req)
  local exec = require("curlite.exec")
  local cmd, err = exec.prepare(req)
  if not cmd then
    return nil, err
  end
  return require("curlite.curl").to_shell(cmd)
end

return M
