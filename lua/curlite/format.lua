--- Pretty-printing response bodies.

local config = require("curlite.config")
local util = require("curlite.util")

local M = {}

-- The order `filetype()` checks `response.filetypes` in. More specific types
-- come first: "html" precedes "xml" so `application/xhtml+xml` is treated as
-- the HTML document it is, and "text" is last because almost every textual
-- type contains it.
M.filetype_order = { "json", "html", "xml", "javascript", "css", "yaml", "csv", "text" }

--- Pure-Lua JSON pretty printer. Used when `jq` isn't installed.
---
--- It walks the source text rather than decoding and re-encoding, so key order
--- is preserved, big integers don't round-trip through doubles, and a body
--- that is *almost* JSON still comes out readable.
---@param str string
---@param indent integer
---@return string
function M.json(str, indent)
  indent = indent or 2
  local pad = (" "):rep(indent)
  local out, level, in_string, escaped = {}, 0, false, false

  local function newline()
    table.insert(out, "\n" .. pad:rep(level))
  end

  local i = 1
  while i <= #str do
    local c = str:sub(i, i)

    if in_string then
      table.insert(out, c)
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string = false
      end
    elseif c == '"' then
      in_string = true
      table.insert(out, c)
    elseif c == "{" or c == "[" then
      -- An empty container stays on one line: `{}` reads better than `{\n}`.
      local nxt = str:find("[^%s]", i + 1)
      if nxt and (str:sub(nxt, nxt) == "}" or str:sub(nxt, nxt) == "]") then
        table.insert(out, c .. str:sub(nxt, nxt))
        i = nxt
      else
        level = level + 1
        table.insert(out, c)
        newline()
      end
    elseif c == "}" or c == "]" then
      level = math.max(0, level - 1)
      newline()
      table.insert(out, c)
    elseif c == "," then
      table.insert(out, c)
      newline()
    elseif c == ":" then
      table.insert(out, ": ")
    elseif not c:match("%s") then
      table.insert(out, c)
    end

    i = i + 1
  end

  return (table.concat(out):gsub("[ \t]+\n", "\n"))
end

--- Indent XML/HTML one element per line.
---@param str string
---@param indent integer
---@return string
function M.xml(str, indent)
  indent = indent or 2
  local pad = (" "):rep(indent)
  local lines, level = {}, 0

  -- Put every tag on its own line first, then indent by nesting depth.
  local normalised = str:gsub(">%s*<", ">\n<")
  for line in normalised:gmatch("[^\n]+") do
    line = vim.trim(line)
    if line ~= "" then
      local is_close = line:match("^</")
      if is_close then
        level = math.max(0, level - 1)
      end
      table.insert(lines, pad:rep(level) .. line)
      -- Opens a level only when it isn't self-closing, a declaration, or an
      -- open-and-close pair on one line.
      local opens = line:match("^<[^/!?]")
        and not line:match("/>%s*$")
        and not line:match("^<[^>]+>.*</[^>]+>%s*$")
      if opens and not is_close then
        level = level + 1
      end
    end
  end

  return table.concat(lines, "\n")
end

--- Best-effort JSON pretty print, preferring `jq` when it is available.
---@param str string
---@param indent integer
---@return string
local function json_pretty(str, indent)
  if util.has_exe("jq") then
    local result = vim
      .system({ "jq", "--indent", tostring(indent), "." }, { stdin = str, text = true })
      :wait()
    if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= "" then
      return (result.stdout:gsub("\n$", ""))
    end
  end
  return M.json(str, indent)
end

--- The filetype to give a response buffer, from its Content-Type.
---@param content_type string|nil
---@return string|nil
function M.filetype(content_type)
  if not content_type or content_type == "" then
    return nil
  end
  local cfg = config.get()
  local lower = content_type:lower()

  -- Order matters and `pairs` has none: `application/xhtml+xml` contains both
  -- "html" and "xml", and `text/html` contains "text". Matching in a fixed
  -- order makes the answer the same every time.
  for _, key in ipairs(M.filetype_order) do
    local ft = cfg.response.filetypes[key]
    if ft and lower:find(key, 1, true) then
      return ft
    end
  end

  -- Anything the user added to `response.filetypes` that isn't in the order
  -- above still gets a chance, most specific (longest key) first.
  local extra = {}
  for key in pairs(cfg.response.filetypes) do
    if not vim.tbl_contains(M.filetype_order, key) then
      table.insert(extra, key)
    end
  end
  table.sort(extra, function(a, b)
    return #a > #b
  end)
  for _, key in ipairs(extra) do
    if lower:find(key, 1, true) then
      return cfg.response.filetypes[key]
    end
  end

  return nil
end

--- Format a response body for display.
---@param body string
---@param content_type string|nil
---@return string formatted, string|nil filetype
function M.body(body, content_type)
  local cfg = config.get()
  local ft = M.filetype(content_type)

  if body == "" then
    return "", ft
  end

  local limit = cfg.response.max_format_size
  if not cfg.response.format or (limit > 0 and #body > limit) then
    return body, ft
  end

  local lower = (content_type or ""):lower()
  local first = vim.trim(body):sub(1, 1)

  if lower:find("json", 1, true) or ((first == "{" or first == "[") and util.json_decode(body)) then
    return json_pretty(body, cfg.response.indent), ft or "json"
  end

  if lower:find("xml", 1, true) or lower:find("html", 1, true) or first == "<" then
    return M.xml(body, cfg.response.indent), ft or (first == "<" and "xml" or nil)
  end

  return body, ft
end

--- Is this body binary? Used to avoid dumping a PNG into a buffer.
---@param body string
---@param content_type string|nil
---@return boolean
function M.is_binary(body, content_type)
  local lower = (content_type or ""):lower()
  if lower:find("image/", 1, true) or lower:find("audio/", 1, true) or lower:find("video/", 1, true) then
    return true
  end
  if lower:find("application/octet%-stream") or lower:find("application/pdf") then
    return true
  end
  -- A NUL byte in the first kilobyte is the usual heuristic.
  return body:sub(1, 1024):find("%z") ~= nil
end

--- Run a `jq` expression over a JSON body. Returns nil (plus a message) when
--- jq is missing or the filter is invalid.
---@param body string
---@param filter string
---@return string|nil, string|nil err
function M.jq(body, filter)
  if not util.has_exe("jq") then
    return nil, "jq is not installed"
  end
  local cfg = config.get()
  local result = vim
    .system({ "jq", "--indent", tostring(cfg.response.indent), filter }, { stdin = body, text = true })
    :wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "jq failed")
  end
  return (result.stdout:gsub("\n$", ""))
end

return M
