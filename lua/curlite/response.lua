--- Parsing curl's out-of-band output into a response object.

local util = require("curlite.util")

local M = {}

--- HTTP header names are case-insensitive, and HTTP/2 lower-cases all of them
--- while HTTP/1.1 servers title-case them. Rather than make every caller
--- remember that, header tables get an `__index` that falls back to a
--- case-insensitive scan, so `headers["Content-Type"]` works either way.
--- `pairs`, `vim.deepcopy` and `vim.json.encode` all still see the real keys.
---@param tbl table<string, string>
---@return table<string, string>
function M.ci_headers(tbl)
  return setmetatable(tbl, {
    __index = function(t, key)
      if type(key) ~= "string" then
        return nil
      end
      local want = key:lower()
      for k, v in pairs(t) do
        if type(k) == "string" and k:lower() == want then
          return v
        end
      end
      return nil
    end,
  })
end

---@class curlite.Hop
---@field http_version string
---@field status integer
---@field status_text string
---@field headers table<string, string>
---@field header_order string[]
---@field raw { name: string, value: string }[]

---@class curlite.Response
---@field status integer
---@field status_text string
---@field http_version string
---@field headers table<string, string>
---@field header_order string[]
---@field raw_headers string
---@field hops curlite.Hop[]
---@field body string
---@field json any|nil
---@field cookies table<string, string>
---@field stats table
---@field duration_ms number
---@field verbose string
---@field body_path string
---@field error string|nil

--- Split curl's `--dump-header` output into one hop per response.
--- Redirects produce several blocks; the last one is the response you got.
---@param raw string
---@return curlite.Hop[]
function M.parse_headers(raw)
  local hops = {}
  local current

  for line in (raw or ""):gmatch("[^\r\n]*") do
    local version, status, text = line:match("^(HTTP/[%d%.]+)%s+(%d%d%d)%s*(.*)$")
    if version then
      current = {
        http_version = version,
        status = tonumber(status),
        status_text = vim.trim(text),
        headers = M.ci_headers({}),
        header_order = {},
        -- Repeated headers (Set-Cookie above all) are joined into `headers`
        -- for display, which is lossy: `raw` keeps every occurrence.
        raw = {},
      }
      table.insert(hops, current)
    elseif current and line ~= "" then
      local name, value = line:match("^([^:]+):%s*(.*)$")
      if name then
        name = vim.trim(name)
        value = vim.trim(value)
        table.insert(current.raw, { name = name, value = value })
        if rawget(current.headers, name) ~= nil then
          -- Repeated headers (Set-Cookie, Link) are joined rather than lost.
          current.headers[name] = current.headers[name] .. ", " .. value
        else
          current.headers[name] = value
          table.insert(current.header_order, name)
        end
      end
    end
  end

  return hops
end

--- Status text for a code curl didn't give us one for (HTTP/2 omits it).
local REASONS = {
  [100] = "Continue",
  [101] = "Switching Protocols",
  [200] = "OK",
  [201] = "Created",
  [202] = "Accepted",
  [204] = "No Content",
  [206] = "Partial Content",
  [301] = "Moved Permanently",
  [302] = "Found",
  [303] = "See Other",
  [304] = "Not Modified",
  [307] = "Temporary Redirect",
  [308] = "Permanent Redirect",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [402] = "Payment Required",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [406] = "Not Acceptable",
  [408] = "Request Timeout",
  [409] = "Conflict",
  [410] = "Gone",
  [412] = "Precondition Failed",
  [413] = "Payload Too Large",
  [415] = "Unsupported Media Type",
  [418] = "I'm a teapot",
  [422] = "Unprocessable Entity",
  [429] = "Too Many Requests",
  [500] = "Internal Server Error",
  [501] = "Not Implemented",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

M.reasons = REASONS

---@param status integer
---@return string
function M.reason(status)
  return REASONS[status] or ""
end

--- Cookies from a hop's `Set-Cookie` headers.
---@param hop curlite.Hop
---@return table<string, string>
function M.parse_cookies(hop)
  local out = {}
  for _, entry in ipairs(hop.raw or {}) do
    if entry.name:lower() == "set-cookie" then
      -- Only the leading `name=value` matters; `Path`, `HttpOnly` and the
      -- rest of the attributes are curl's business, not ours.
      local k, v = entry.value:match("^%s*([^=;%s]+)=([^;]*)")
      if k then
        out[k] = v
      end
    end
  end
  return out
end

--- Build a response from the files curl wrote.
---@param cmd curlite.Command
---@param result vim.SystemCompleted
---@param duration_ms number
---@return curlite.Response
function M.build(cmd, result, duration_ms)
  local raw_headers = util.read_file(cmd.header_path) or ""
  local body = util.read_file(cmd.body_path) or ""

  -- With `--head` curl sends the header block to `--output` as well. A HEAD
  -- response has no body by definition, so don't pretend it does.
  if cmd.request and cmd.request.method == "HEAD" then
    body = ""
  end
  local hops = M.parse_headers(raw_headers)
  local last = hops[#hops]
    or {
      status = 0,
      status_text = "",
      http_version = "",
      headers = M.ci_headers({}),
      header_order = {},
    }

  local stats = util.json_decode(vim.trim(result.stdout or "")) or {}

  -- `--write-out %{json}` includes the full PEM chain under `certs`, which is
  -- kilobytes of text nothing here reads. Drop it rather than carry a copy per
  -- response through the history ring.
  stats.certs = nil

  if last.status_text == "" then
    last.status_text = M.reason(last.status)
  end

  local resp = {
    status = last.status,
    status_text = last.status_text,
    http_version = last.http_version,
    headers = last.headers,
    header_order = last.header_order,
    raw_headers = raw_headers,
    hops = hops,
    body = body,
    json = nil,
    cookies = M.parse_cookies(last),
    stats = stats,
    -- curl's own timing is the honest one: it excludes the process spawn.
    duration_ms = stats.time_total and stats.time_total * 1000 or duration_ms,
    verbose = result.stderr or "",
    body_path = cmd.body_path,
    error = nil,
  }

  local ctype = resp.headers["Content-Type"] or stats.content_type or ""
  if ctype:lower():find("json") or (body ~= "" and body:sub(1, 1):match("[%[{]")) then
    resp.json = util.json_decode(body)
  end

  if result.code ~= 0 then
    -- curl's own `errormsg` is more precise than anything we could infer from
    -- the exit code, and it survives even when stderr was noisy.
    resp.error = M.curl_error(result.code, result.stderr or "", stats.errormsg)
  end

  return resp
end

-- The curl exit codes worth translating; the rest fall back to stderr.
local CURL_ERRORS = {
  [1] = "unsupported protocol",
  [3] = "malformed URL",
  [5] = "could not resolve proxy",
  [6] = "could not resolve host",
  [7] = "failed to connect",
  [22] = "HTTP error returned (--fail)",
  [23] = "write error",
  [26] = "read error (request body)",
  [28] = "operation timed out",
  [35] = "TLS handshake failed",
  [47] = "too many redirects",
  [52] = "empty reply from server",
  [55] = "failed sending data",
  [56] = "failure receiving data",
  [60] = "TLS certificate could not be verified -- add `# @insecure` to skip",
  [77] = "problem reading the CA certificate",
  [92] = "HTTP/2 stream error",
}

---@param code integer
---@param stderr string
---@param errormsg string|nil  curl's own `%{errormsg}`
---@return string
function M.curl_error(code, stderr, errormsg)
  if errormsg and errormsg ~= "" then
    return ("curl (%d): %s"):format(code, errormsg)
  end
  -- curl's `curl: (6) Could not resolve host: x` line beats our table.
  local detail = stderr:match("curl: %(%d+%)%s*(.-)%s*$")
  if detail and detail ~= "" then
    return ("curl (%d): %s"):format(code, detail)
  end
  local known = CURL_ERRORS[code]
  if known then
    return ("curl (%d): %s"):format(code, known)
  end
  return ("curl exited with %d"):format(code)
end

--- Grade a status for highlighting.
---@param status integer
---@return "success"|"redirect"|"client_error"|"server_error"
function M.grade(status)
  if status >= 500 or status == 0 then
    return "server_error"
  elseif status >= 400 then
    return "client_error"
  elseif status >= 300 then
    return "redirect"
  end
  return "success"
end

--- Clean up the temp files a command created.
---@param cmd curlite.Command
function M.cleanup(cmd)
  os.remove(cmd.header_path)
  os.remove(cmd.body_path)
end

return M
