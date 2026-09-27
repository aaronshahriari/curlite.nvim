--- Parser for the JetBrains `.http` file format.
---
--- The grammar curlite accepts, in the order a section may use it:
---
---   @name = value             document variable
---   ###  [Optional name]      request separator (also `#####`, any run of 3+)
---   # @meta [value]           request metadata (`// @meta` works too)
---   < ./pre.lua               external pre-request script
---   < {% lua ... %}           inline pre-request script
---   METHOD url [HTTP/1.1]     the request line (METHOD optional, GET assumed)
---     ?query=continuation     leading-whitespace continuation of the URL
---   Header: value             headers, until a blank line
---   <blank>
---   body...                   everything else, verbatim
---   < ./body.json             body read from a file
---   > ./post.lua              external post-request script
---   > {% lua ... %}           inline post-request script
---   >> ./response.json        write the response body to a file
---   >>! ./response.json       ... overwriting it if it exists
---
--- Nothing here resolves variables — `{{...}}` is left intact so the same
--- parse can be re-rendered against a different environment.

local M = {}

local METHODS = {
  GET = true,
  POST = true,
  PUT = true,
  PATCH = true,
  DELETE = true,
  HEAD = true,
  OPTIONS = true,
  TRACE = true,
  CONNECT = true,
  QUERY = true,
  GRAPHQL = true,
}

M.methods = METHODS

---@class curlite.Script
---@field kind "inline"|"file"
---@field body string            -- lua source, or a path when kind == "file"

---@class curlite.Request
---@field name string|nil
---@field method string
---@field url string
---@field http_version string|nil
---@field headers table<string,string>
---@field header_order string[]
---@field body string|nil
---@field body_file string|nil       -- `< ./payload.json`
---@field body_file_encoding string|nil
---@field metadata table<string,any>
---@field variables table<string,string>  -- document vars in scope here
---@field pre_scripts curlite.Script[]
---@field post_scripts curlite.Script[]
---@field redirect { path: string, overwrite: boolean }|nil
---@field curl_args string[]
---@field start_line integer          -- 1-indexed, inclusive
---@field end_line integer            -- 1-indexed, inclusive
---@field url_line integer|nil        -- line the request line sits on
---@field source string|nil           -- file the request came from

---@class curlite.Document
---@field requests curlite.Request[]
---@field variables table<string,string>   -- every document variable, flat
---@field var_lines { name: string, value: string, line: integer }[]
---@field source string|nil

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Is this line a comment? `#` and `//` both count, but `###` is a separator
--- and is handled before this is ever called.
local function comment_text(line)
  local rest = line:match("^%s*#%s?(.*)$")
  if rest then
    return rest
  end
  return line:match("^%s*//%s?(.*)$")
end

--- `# @name value` -> "name", "value". Returns nil when the comment is prose.
local function parse_metadata(line)
  local body = comment_text(line)
  if not body then
    return nil
  end
  local key, value = body:match("^@([%w_-]+)%s*(.*)$")
  if not key then
    return nil
  end
  return key:lower(), trim(value)
end

--- `@token = abc` / `@token=abc` -> "token", "abc".
local function parse_variable(line)
  local name, value = line:match("^%s*@([%w_%.%-]+)%s*=%s*(.*)$")
  if not name then
    return nil
  end
  return name, trim(value)
end

--- Split a request line into method / url / version.
--- Returns nil when the line can't be one (so we don't swallow stray prose).
local function parse_request_line(line)
  local s = trim(line)
  if s == "" then
    return nil
  end

  local first, rest = s:match("^(%S+)%s+(.*)$")
  if first and METHODS[first:upper()] then
    local url, version = rest, nil
    local u, v = rest:match("^(.*)%s+(HTTP/[%d%.]+)%s*$")
    if u then
      url, version = trim(u), v
    end
    -- A URL with a space in it is prose, not a request ("POST /api is slow").
    -- This is what keeps an implicit separator from firing inside a body.
    if url == "" or url:match("%s") then
      return nil
    end
    return { method = first:upper(), url = url, http_version = version, explicit_method = true }
  end

  -- No method: a bare URL line defaults to GET, but only if it actually looks
  -- like one. `foo: bar` is a header and `{ "a": 1 }` is a body.
  if s:match("^%a[%w+.-]*://") or s:match("^{{") or s:match("^/") then
    local url, version = s, nil
    local u, v = s:match("^(.*)%s+(HTTP/[%d%.]+)%s*$")
    if u then
      url, version = trim(u), v
    end
    if url:match("%s") then
      return nil
    end
    return { method = "GET", url = url, http_version = version }
  end

  return nil
end

---@return string|nil name, string|nil value
local function parse_header(line)
  -- A header name can't contain spaces, and the colon must come before any.
  local name, value = line:match("^([%w%-_%.]+)%s*:%s*(.*)$")
  if not name then
    return nil
  end
  return name, trim(value)
end

--- Case-insensitive header lookup on a parsed request.
---@param req curlite.Request
---@param name string
---@return string|nil
function M.header(req, name)
  local want = name:lower()
  for k, v in pairs(req.headers) do
    if k:lower() == want then
      return v
    end
  end
  return nil
end

local function new_request()
  return {
    name = nil,
    method = "GET",
    url = "",
    http_version = nil,
    headers = {},
    header_order = {},
    variables = nil,
    body = nil,
    body_file = nil,
    metadata = {},
    pre_scripts = {},
    post_scripts = {},
    redirect = nil,
    curl_args = {},
    start_line = 1,
    end_line = 1,
  }
end

--- Parse a whole document.
---@param lines string[]
---@param source string|nil  path the lines came from, for error messages
---@return curlite.Document
function M.parse(lines, source)
  ---@type curlite.Document
  local doc = { requests = {}, variables = {}, var_lines = {}, imports = {}, source = source }

  local req = new_request()
  local have_request = false          -- seen a request line in this section
  local section_started = false       -- seen anything at all in this section
  local state = "head"                -- head -> headers -> body
  local body_lines = {}               -- accumulated raw body lines
  local pending_meta = {}             -- metadata seen before the request line
  local script_buf = nil              -- { dir = "<"|">", lines = {} } while in {% %}
  local var_snapshot = {}             -- document vars visible right now

  local function flush()
    if not have_request then
      return
    end

    -- Blank lines wrapping the body are formatting, not payload: one always
    -- precedes the next `###`, and a script block leaves one behind it.
    while #body_lines > 0 and trim(body_lines[#body_lines]) == "" do
      table.remove(body_lines)
    end
    while #body_lines > 0 and trim(body_lines[1]) == "" do
      table.remove(body_lines, 1)
    end
    if #body_lines > 0 then
      req.body = table.concat(body_lines, "\n")
    end

    req.metadata = vim.tbl_extend("keep", req.metadata, pending_meta)
    req.name = req.name or req.metadata.name
    -- `variables` is normally snapshotted the moment the request line is read,
    -- so a variable defined *below* a request isn't visible to it. A section
    -- with no request line at all never gets here.
    req.variables = req.variables or vim.deepcopy(var_snapshot)
    req.source = source
    table.insert(doc.requests, req)
  end

  local function reset(line_nr)
    req = new_request()
    req.start_line = line_nr
    req.end_line = line_nr
    have_request = false
    section_started = false
    state = "head"
    body_lines = {}
    pending_meta = {}
    script_buf = nil
  end

  reset(1)

  for i = 1, #lines do
    local line = lines[i]
    local stripped = trim(line)

    -- ---- inline script block accumulation -------------------------------
    if script_buf then
      local before = line:match("^(.-)%%}%s*$")
      if before then
        if trim(before) ~= "" then
          table.insert(script_buf.lines, before)
        end
        local script = { kind = "inline", body = table.concat(script_buf.lines, "\n") }
        if script_buf.dir == "<" then
          table.insert(req.pre_scripts, script)
        else
          table.insert(req.post_scripts, script)
        end
        script_buf = nil
      else
        table.insert(script_buf.lines, line)
      end
      req.end_line = i
      goto continue
    end

    -- ---- separator -------------------------------------------------------
    if stripped:match("^###") then
      flush()
      reset(i)
      section_started = true
      local label = trim(stripped:gsub("^#+", ""))
      if label ~= "" then
        req.name = label
      end
      req.start_line = i
      goto continue
    end

    -- ---- implicit separator ----------------------------------------------
    -- A `###`-less file still separates its requests: a line at column 0 that
    -- begins with an explicit method and is preceded by a blank line opens a
    -- new request, once the current one already has its request line. The
    -- "no whitespace in the URL" rule in `parse_request_line` is what keeps
    -- this from firing on prose inside a body.
    if have_request and not line:match("^%s") then
      local nxt = parse_request_line(line)
      if nxt and nxt.explicit_method and (i == 1 or trim(lines[i - 1] or "") == "") then
        flush()
        reset(i)
      end
    end

    -- ---- document variables ---------------------------------------------
    do
      local vname, vvalue = parse_variable(line)
      if vname and (state ~= "body" or line:sub(1, 1) == "@") then
        doc.variables[vname] = vvalue
        table.insert(doc.var_lines, { name = vname, value = vvalue, line = i })
        var_snapshot[vname] = vvalue
        req.end_line = i
        goto continue
      end
    end

    -- ---- metadata / comments --------------------------------------------
    -- Before the body, every comment is a comment. Inside a body only the
    -- `# @key` form is lifted out, so a Markdown heading or a YAML comment in
    -- a payload survives untouched while `# @assert` after a script block
    -- still works.
    do
      local mkey, mvalue = parse_metadata(line)
      if mkey and (state ~= "body" or line:match("^%s*#%s*@") or line:match("^%s*//%s*@")) then
        if mkey == "name" then
          req.name = mvalue
        elseif mkey == "curl" then
          -- `# @curl --compressed --http2` -- raw flags appended verbatim.
          for _, arg in ipairs(M.split_args(mvalue)) do
            table.insert(req.curl_args, arg)
          end
        elseif mkey == "prompt" then
          -- `# @prompt token Paste your bearer token`
          pending_meta.prompts = pending_meta.prompts or {}
          local pname, pdesc = mvalue:match("^(%S+)%s*(.*)$")
          if pname then
            table.insert(pending_meta.prompts, { name = pname, description = trim(pdesc) })
          end
        elseif mkey == "assert" then
          pending_meta.asserts = pending_meta.asserts or {}
          table.insert(pending_meta.asserts, mvalue)
        elseif mkey == "run" then
          -- `# @run LOGIN` -- send that request first. Several are run in the
          -- order they are declared.
          pending_meta.run = pending_meta.run or {}
          table.insert(pending_meta.run, mvalue)
        elseif mkey == "import" then
          -- Document-level, not request-level: an import applies to the whole
          -- file no matter where it appears.
          table.insert(doc.imports, mvalue)
        else
          -- Bare flags (`# @insecure`, `# @no-redirect`) become `true`.
          pending_meta[mkey] = mvalue ~= "" and mvalue or true
        end
        req.end_line = i
        section_started = true
        goto continue
      end
      -- Plain comment above the body: ignore, but it does open the section.
      if state ~= "body" and comment_text(line) then
        req.end_line = i
        section_started = true
        goto continue
      end
    end

    -- ---- scripts and redirects ------------------------------------------
    do
      local dir, rest = stripped:match("^(>>!?)%s*(.*)$")
      if not dir then
        dir, rest = stripped:match("^([<>])%s*(.*)$")
      end
      -- `<` before the request line is a pre-script; after it (in the body
      -- position) it is a file body. `>`/`>>` are always post-request.
      if dir == ">>" or dir == ">>!" then
        if rest ~= "" then
          req.redirect = { path = rest, overwrite = dir == ">>!" }
          req.end_line = i
          goto continue
        end
      elseif dir == ">" or (dir == "<" and not have_request) then
        if rest:match("^{%%") then
          local inline = rest:gsub("^{%%%s*", "")
          local closing = inline:match("^(.-)%%}%s*$")
          if closing then
            local script = { kind = "inline", body = closing }
            if dir == "<" then
              table.insert(req.pre_scripts, script)
            else
              table.insert(req.post_scripts, script)
            end
          else
            script_buf = { dir = dir, lines = {} }
            if trim(inline) ~= "" then
              table.insert(script_buf.lines, inline)
            end
          end
          req.end_line = i
          section_started = true
          goto continue
        elseif rest ~= "" then
          local script = { kind = "file", body = rest }
          if dir == "<" then
            table.insert(req.pre_scripts, script)
          else
            table.insert(req.post_scripts, script)
          end
          req.end_line = i
          section_started = true
          goto continue
        end
      end
    end

    -- ---- the request line ------------------------------------------------
    if not have_request then
      if stripped == "" then
        goto continue
      end
      local parsed = parse_request_line(line)
      if parsed then
        req.method = parsed.method
        req.url = parsed.url
        req.http_version = parsed.http_version
        req.url_line = i
        req.end_line = i
        req.variables = vim.deepcopy(var_snapshot)
        have_request = true
        section_started = true
        state = "headers"
        goto continue
      end
      -- Not a request line and not anything else we know: skip it rather than
      -- guessing, so a stray line can't corrupt the section.
      req.end_line = i
      goto continue
    end

    -- ---- URL continuation -------------------------------------------------
    if state == "headers" and line:match("^%s+[?&#]") then
      req.url = req.url .. trim(line)
      req.end_line = i
      goto continue
    end

    -- ---- headers ----------------------------------------------------------
    if state == "headers" then
      if stripped == "" then
        state = "body"
        req.end_line = i
        goto continue
      end
      -- A folded header continuation line (RFC 7230 obs-fold): leading space.
      if line:match("^%s") and #req.header_order > 0 then
        local last = req.header_order[#req.header_order]
        req.headers[last] = req.headers[last] .. " " .. stripped
        req.end_line = i
        goto continue
      end
      local hname, hvalue = parse_header(line)
      if hname then
        if req.headers[hname] == nil then
          table.insert(req.header_order, hname)
        end
        req.headers[hname] = hvalue
        req.end_line = i
        goto continue
      end
      -- Not a header -- treat the rest of the section as body. This makes a
      -- missing blank line forgiving instead of fatal.
      state = "body"
    end

    -- ---- body --------------------------------------------------------------
    do
      -- `< ./payload.json` inside a body means "send this file".
      local fpath = stripped:match("^<%s+(.+)$")
      if fpath and #body_lines == 0 then
        local enc, p = fpath:match("^(%S+)%s+(.+)$")
        if enc and enc:match("^[%w%-]+$") and p:match("[/\\.]") then
          req.body_file_encoding, req.body_file = enc, p
        else
          req.body_file = fpath
        end
        req.end_line = i
        goto continue
      end
      table.insert(body_lines, line)
      req.end_line = i
    end

    ::continue::
  end

  flush()

  -- With document scope, every request sees every variable in the file, not
  -- just the ones above it.
  local cfg = require("curlite.config").get()
  if cfg.request and cfg.request.variables_scope == "document" then
    for _, r in ipairs(doc.requests) do
      r.variables = vim.deepcopy(doc.variables)
    end
  end

  return doc
end

--- Split a shell-ish argument string, honouring single and double quotes.
---@param s string
---@return string[]
function M.split_args(s)
  local args, buf, quote = {}, {}, nil
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      elseif c == "\\" and quote == '"' and i < #s then
        i = i + 1
        table.insert(buf, s:sub(i, i))
      else
        table.insert(buf, c)
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c:match("%s") then
      if #buf > 0 then
        table.insert(args, table.concat(buf))
        buf = {}
      end
    elseif c == "\\" and i < #s then
      i = i + 1
      table.insert(buf, s:sub(i, i))
    else
      table.insert(buf, c)
    end
    i = i + 1
  end
  if #buf > 0 then
    table.insert(args, table.concat(buf))
  end
  return args
end

--- Names defined by more than one request in a document.
---
--- A duplicate is quietly dangerous: `# @run LOGIN` picks one of them, and
--- `{{LOGIN.response.body.$.x}}` reads whichever ran most recently, so a chain
--- can silently read the wrong response.
---@param doc curlite.Document
---@return string[]  the duplicated names, sorted
function M.duplicate_names(doc)
  local seen, dupes = {}, {}
  for _, req in ipairs(doc.requests) do
    if req.name and req.name ~= "" then
      if seen[req.name] then
        dupes[req.name] = true
      end
      seen[req.name] = true
    end
  end
  local out = vim.tbl_keys(dupes)
  table.sort(out)
  return out
end

--- Parse a buffer.
---@param bufnr integer|nil  defaults to the current buffer
---@return curlite.Document
function M.parse_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return M.parse(lines, name ~= "" and name or nil)
end

--- Parse a file from disk (used by `# @import`).
---@param path string
---@return curlite.Document|nil, string|nil error
function M.parse_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, ("cannot read %s"):format(path)
  end
  local content = fd:read("*a")
  fd:close()
  return M.parse(vim.split(content, "\n", { plain = true }), path)
end

--- The request whose line range contains `line` (1-indexed). When the cursor
--- sits between requests, the nearest one *above* wins, which matches what you
--- mean when you park on a blank line after a request.
---@param doc curlite.Document
---@param line integer
---@return curlite.Request|nil, integer|nil index
function M.request_at(doc, line)
  local best, best_idx
  for idx, r in ipairs(doc.requests) do
    if line >= r.start_line and line <= r.end_line then
      return r, idx
    end
    if r.start_line <= line then
      best, best_idx = r, idx
    end
  end
  if best then
    return best, best_idx
  end
  return doc.requests[1], doc.requests[1] and 1 or nil
end

return M
