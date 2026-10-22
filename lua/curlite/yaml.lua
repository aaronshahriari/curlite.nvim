--- A small YAML reader, for OpenAPI specs written in YAML.
---
--- curlite depends on nothing, and an OpenAPI spec is as likely to be YAML as
--- JSON, so there has to be something here. This reads the subset those files
--- actually use:
---
---   * nested mappings and sequences, indentation-based
---   * a sequence at the same indent as its key (`tags:` then `- users`)
---   * plain, single- and double-quoted scalars, including the multi-line
---     folded form a long `description:` is written in
---   * block scalars (`|`, `|-`, `>`, `>-`, and the `+` keeps)
---   * flow collections (`[a, b]`, `{ a: 1 }`), nested
---   * anchors, aliases and merge keys (`&a`, `*a`, `<<: *a`)
---   * `#` comments, `---`/`...` document markers (the first document wins)
---
--- What it does not do: multiple documents, tags (`!!str`), complex keys
--- (`? :`), tab indentation. It is a reader for configuration-shaped YAML,
--- not a conformant implementation -- and `yq -o=json spec.yaml` is always
--- there for a file it cannot handle.

local M = {}

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The width of a line's leading indentation, or nil for a tab-indented one.
---@param line string
---@return integer|nil
local function indent_of(line)
  local lead = line:match("^[ \t]*")
  if lead:find("\t", 1, true) then
    return nil
  end
  return #lead
end

--- Is this line blank, or a comment, as far as the structure is concerned?
---@param line string
---@return boolean
local function skippable(line)
  local stripped = trim(line)
  return stripped == "" or stripped:sub(1, 1) == "#"
end

--- Cut a trailing ` # comment` that is outside quotes.
---@param s string
---@return string
local function strip_comment(s)
  local quote = nil
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if quote then
      if c == "\\" and quote == '"' then
        i = i + 1
      elseif c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "#" and (i == 1 or s:sub(i - 1, i - 1):match("%s")) then
      return (s:sub(1, i - 1):gsub("%s+$", ""))
    end
    i = i + 1
  end
  return s
end

--- The position of the `:` that separates a mapping key from its value: the
--- first one that is followed by whitespace or ends the line, outside quotes.
--- `http://x` is therefore not a key, and `"application/json":` is.
---@param s string
---@return integer|nil
local function key_colon(s)
  local quote = nil
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if quote then
      if c == "\\" and quote == '"' then
        i = i + 1
      elseif c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "#" and i > 1 and s:sub(i - 1, i - 1):match("%s") then
      return nil
    elseif c == ":" then
      local after = s:sub(i + 1, i + 1)
      if after == "" or after:match("%s") then
        return i
      end
    end
    i = i + 1
  end
  return nil
end

--- Unescape a double-quoted scalar.
---@param s string
---@return string
local function unescape(s)
  local out = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      local nxt = s:sub(i + 1, i + 1)
      local simple = { n = "\n", t = "\t", r = "\r", ["0"] = "\0", a = "\a", b = "\b" }
      if simple[nxt] then
        table.insert(out, simple[nxt])
        i = i + 2
      elseif nxt == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        table.insert(out, code and vim.fn.nr2char(code) or ("\\u" .. hex))
        i = i + 6
      elseif nxt == "" then
        i = i + 1
      else
        table.insert(out, nxt)
        i = i + 2
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return table.concat(out)
end

local CONSTANTS = {
  ["true"] = true,
  ["True"] = true,
  ["TRUE"] = true,
  ["false"] = false,
  ["False"] = false,
  ["FALSE"] = false,
}

local NULLS = { [""] = true, ["~"] = true, ["null"] = true, ["Null"] = true, ["NULL"] = true }

--- A plain (unquoted) scalar, typed the way the JSON schema would have it.
---@param s string
---@return any
local function plain(s)
  if NULLS[s] then
    return nil
  end
  if CONSTANTS[s] ~= nil then
    return CONSTANTS[s]
  end
  -- Only a token that is *entirely* numeric becomes a number, so `3.0.0` and
  -- `1-2` stay the strings they are.
  local numeric = s:match("^[-+]?%d+$")
    or s:match("^[-+]?%d*%.%d+$")
    or s:match("^[-+]?%d+%.?%d*[eE][-+]?%d+$")
  if numeric then
    local n = tonumber(s)
    if n then
      return n
    end
  end
  return s
end

--- A whole quoted or plain scalar, already free of comments.
---@param s string
---@return any
local function scalar(s)
  local dq = s:match('^"(.*)"$')
  if dq then
    return unescape(dq)
  end
  local sq = s:match("^'(.*)'$")
  if sq then
    return (sq:gsub("''", "'"))
  end
  return plain(s)
end

--- ------------------------------------------------------------------- flow

--- Parse a flow collection -- `[1, 2]`, `{ a: 1, b: [2] }` -- starting at
--- `pos`. Returns the value and the position just past its closing bracket.
---@param s string
---@param pos integer
---@return any value, integer pos
local function parse_flow(s, pos)
  local function skip_ws(i)
    while i <= #s and s:sub(i, i):match("%s") do
      i = i + 1
    end
    return i
  end

  --- A scalar inside a flow collection: up to the next `,`/`]`/`}` at this
  --- level, or a quoted run.
  local function flow_scalar(i)
    local quote = s:sub(i, i)
    if quote == '"' or quote == "'" then
      local j = i + 1
      while j <= #s do
        local c = s:sub(j, j)
        if c == "\\" and quote == '"' then
          j = j + 2
        elseif c == quote then
          return scalar(s:sub(i, j)), j + 1
        else
          j = j + 1
        end
      end
      return scalar(s:sub(i)), #s + 1
    end
    local j = i
    while j <= #s and not s:sub(j, j):match("[,%]}]") do
      j = j + 1
    end
    return scalar(trim(s:sub(i, j - 1))), j
  end

  local function parse_value(i)
    i = skip_ws(i)
    local c = s:sub(i, i)
    if c == "[" or c == "{" then
      return parse_flow(s, i)
    end
    return flow_scalar(i)
  end

  local open = s:sub(pos, pos)
  local i = pos + 1
  if open == "[" then
    local out = {}
    i = skip_ws(i)
    if s:sub(i, i) == "]" then
      return out, i + 1
    end
    while i <= #s do
      local value
      value, i = parse_value(i)
      table.insert(out, value)
      i = skip_ws(i)
      local c = s:sub(i, i)
      if c == "," then
        i = i + 1
      elseif c == "]" then
        return out, i + 1
      else
        return out, i
      end
    end
    return out, i
  end

  local out = {}
  i = skip_ws(i)
  if s:sub(i, i) == "}" then
    return out, i + 1
  end
  while i <= #s do
    i = skip_ws(i)
    -- The key runs to the `:` that follows it.
    local key
    local colon = nil
    local quote = s:sub(i, i)
    if quote == '"' or quote == "'" then
      local raw
      raw, colon = flow_scalar(i)
      key = raw
      colon = skip_ws(colon)
    else
      local j = i
      while j <= #s and s:sub(j, j) ~= ":" and s:sub(j, j) ~= "," and s:sub(j, j) ~= "}" do
        j = j + 1
      end
      key = scalar(trim(s:sub(i, j - 1)))
      colon = j
    end
    if s:sub(colon, colon) == ":" then
      local value
      value, i = parse_value(colon + 1)
      if key ~= nil then
        out[tostring(key)] = value
      end
    else
      -- `{ a, b }`: a set written in flow. Keys with no value.
      if key ~= nil then
        out[tostring(key)] = nil
      end
      i = colon
    end
    i = skip_ws(i)
    local c = s:sub(i, i)
    if c == "," then
      i = i + 1
    elseif c == "}" then
      return out, i + 1
    else
      return out, i
    end
  end
  return out, i
end

--- ----------------------------------------------------------------- reader

---@class curlite.yaml.Reader
---@field lines string[]
---@field i integer
---@field anchors table<string, any>
local Reader = {}
Reader.__index = Reader

---@param lines string[]
---@return curlite.yaml.Reader
function Reader.new(lines)
  return setmetatable({ lines = lines, i = 1, anchors = {} }, Reader)
end

--- The index of the next line that carries structure, or nil at the end.
---@return integer|nil
function Reader:peek()
  while self.i <= #self.lines do
    if skippable(self.lines[self.i]) then
      self.i = self.i + 1
    else
      return self.i
    end
  end
  return nil
end

---@param idx integer
---@return integer
function Reader:indent(idx)
  local width = indent_of(self.lines[idx])
  if not width then
    error(("line %d is indented with a tab, which YAML does not allow"):format(idx), 0)
  end
  return width
end

---@param idx integer
---@return string
function Reader:text(idx)
  return trim(self.lines[idx])
end

--- Is this the end of the first document?
---@param text string
---@return boolean
local function document_end(text)
  return text == "---" or text == "..." or text:sub(1, 4) == "--- " or text:sub(1, 4) == "... "
end

--- A sequence entry: `-` alone, or `- something`.
---@param text string
---@return boolean
local function is_entry(text)
  return text == "-" or text:sub(1, 2) == "- "
end

--- Collect a block scalar (`|`/`>`) introduced on line `idx`.
---@param header string  the indicator, e.g. "|-", ">" or "|2"
---@param parent integer  the indent its key sits at
---@return string
function Reader:block_scalar(header, parent)
  local folded = header:sub(1, 1) == ">"
  local chomp = header:match("[-+]") or ""
  local forced = tonumber(header:match("%d"))

  local collected = {}
  local block_indent = forced and (parent + forced) or nil
  while self.i <= #self.lines do
    local line = self.lines[self.i]
    local stripped = trim(line)
    if stripped == "" then
      table.insert(collected, "")
      self.i = self.i + 1
    else
      local width = indent_of(line) or 0
      if not block_indent then
        if width < parent then
          break
        end
        block_indent = width
      end
      if width < block_indent then
        break
      end
      table.insert(collected, line:sub(block_indent + 1))
      self.i = self.i + 1
    end
  end

  -- Trailing blank lines are chomping's business, not the content's.
  while #collected > 0 and collected[#collected] == "" do
    table.remove(collected)
  end

  local text
  if folded then
    -- Folded: a run of plain lines becomes one line; a blank line is a real
    -- newline; a more-indented line keeps its break.
    local parts, buffer = {}, {}
    local function flush()
      if #buffer > 0 then
        table.insert(parts, table.concat(buffer, " "))
        buffer = {}
      end
    end
    for _, line in ipairs(collected) do
      if line == "" then
        flush()
        table.insert(parts, "")
      elseif line:match("^%s") then
        flush()
        table.insert(parts, line)
      else
        table.insert(buffer, line)
      end
    end
    flush()
    text = table.concat(parts, "\n")
  else
    text = table.concat(collected, "\n")
  end

  if chomp == "-" then
    return text
  end
  return text .. "\n"
end

--- A scalar value written on line `idx` after a key or a dash, including the
--- quoted and plain forms that carry on over the following lines.
---@param rest string  the text after the `key:` or `- `
---@param parent integer  the indent of the line that introduced it
---@return any
function Reader:scalar_value(rest, parent)
  self.i = self.i + 1

  -- An anchor or an alias may stand in front of the value.
  local anchor = nil
  local name, tail = rest:match("^&([%w_%-%.]+)%s*(.*)$")
  if name then
    anchor = name
    rest = tail
  end
  local alias = rest:match("^%*([%w_%-%.]+)%s*$")
  if alias then
    return self.anchors[alias]
  end

  local value
  local header = rest:match("^([|>][%d]?[-+]?)$") or rest:match("^([|>][-+]?[%d]?)$")
  if header then
    value = self:block_scalar(header, parent)
  elseif rest == "" then
    -- `key: &a` with the value in the block underneath.
    value = self:parse_node(parent + 1)
  elseif rest:sub(1, 1) == "[" or rest:sub(1, 1) == "{" then
    value = (parse_flow(rest, 1))
  else
    local text = rest
    local quote = text:sub(1, 1)
    if quote == '"' or quote == "'" then
      -- Keep reading while the quote is still open.
      while not text:match(quote .. "%s*$") or #text < 2 do
        local idx = self:peek()
        if not idx or self:indent(idx) <= parent then
          break
        end
        text = text .. " " .. self:text(idx)
        self.i = idx + 1
      end
      value = scalar(strip_comment(text))
    else
      text = strip_comment(text)
      -- A plain scalar folds over the lines below it, which is how a long
      -- `description:` is usually written.
      while true do
        local idx = self:peek()
        if not idx then
          break
        end
        local line = self:text(idx)
        if
          self:indent(idx) <= parent
          or is_entry(line)
          or key_colon(line)
          or document_end(line)
        then
          break
        end
        text = text .. " " .. strip_comment(line)
        self.i = idx + 1
      end
      value = plain(trim(text))
    end
  end

  if anchor then
    self.anchors[anchor] = value
  end
  return value
end

--- Merge `source` into `target` for a `<<:` key: existing keys win, and a
--- list of anchors merges right-to-left.
---@param target table
---@param source any
local function merge_into(target, source)
  if type(source) ~= "table" then
    return
  end
  if vim.islist(source) then
    for _, entry in ipairs(source) do
      merge_into(target, entry)
    end
    return
  end
  for key, value in pairs(source) do
    if target[key] == nil then
      target[key] = value
    end
  end
end

---@param indent integer
---@return table
function Reader:parse_mapping(indent)
  local map = {}
  while true do
    local idx = self:peek()
    if not idx then
      break
    end
    local width = self:indent(idx)
    if width < indent then
      break
    end
    local text = self:text(idx)
    if document_end(text) then
      break
    end
    if width > indent then
      -- Deeper than this mapping and not claimed by the value above it:
      -- skip it rather than abandon the rest of the file.
      self.i = idx + 1
      goto continue
    end
    if is_entry(text) then
      break
    end
    local colon = key_colon(text)
    if not colon then
      break
    end

    local key = scalar(trim(text:sub(1, colon - 1)))
    local rest = trim(text:sub(colon + 1))
    local value
    if rest == "" then
      self.i = idx + 1
      value = self:parse_node(indent + 1)
      if value == nil then
        -- A sequence may sit at its key's own indent:
        --   tags:
        --   - users
        local nxt = self:peek()
        if nxt and self:indent(nxt) == indent and is_entry(self:text(nxt)) then
          value = self:parse_sequence(indent)
        end
      end
    else
      self.i = idx
      value = self:scalar_value(rest, width)
    end

    if key == "<<" then
      merge_into(map, value)
    elseif key ~= nil then
      map[tostring(key)] = value
    end
    ::continue::
  end
  return map
end

---@param indent integer
---@return any[]
function Reader:parse_sequence(indent)
  local out = {}
  while true do
    local idx = self:peek()
    if not idx then
      break
    end
    local width = self:indent(idx)
    if width < indent then
      break
    end
    local text = self:text(idx)
    if document_end(text) then
      break
    end
    if width > indent then
      self.i = idx + 1
      goto continue
    end
    if not is_entry(text) then
      break
    end

    local rest = trim(text:sub(2))
    if rest == "" then
      self.i = idx + 1
      table.insert(out, self:parse_node(indent + 1) or vim.NIL)
    elseif key_colon(rest) then
      -- `- name: id` -- a mapping whose first key shares the dash's line.
      -- Rewriting the dash as spaces lets the mapping parser take it from
      -- here without a special case.
      self.lines[idx] = (" "):rep(width + 2) .. rest
      table.insert(out, self:parse_mapping(width + 2))
    else
      self.i = idx
      local value = self:scalar_value(rest, width)
      table.insert(out, value == nil and vim.NIL or value)
    end
    ::continue::
  end

  -- `vim.NIL` held the slots a nil would have collapsed; nothing downstream
  -- wants to see it.
  for i, value in ipairs(out) do
    if value == vim.NIL then
      out[i] = nil
    end
  end
  return out
end

--- The node starting at the next content line, if it is indented at least
--- `indent`.
---@param indent integer
---@return any
function Reader:parse_node(indent)
  local idx = self:peek()
  if not idx then
    return nil
  end
  if self:indent(idx) < indent then
    return nil
  end
  local text = self:text(idx)
  if document_end(text) then
    return nil
  end
  if is_entry(text) then
    return self:parse_sequence(self:indent(idx))
  end
  if key_colon(text) then
    return self:parse_mapping(self:indent(idx))
  end
  -- A bare scalar document.
  self.i = idx
  return self:scalar_value(text, self:indent(idx) - 1)
end

--- Decode a YAML document.
---@param text string
---@return any|nil value, string|nil err
function M.decode(text)
  if type(text) ~= "string" or trim(text) == "" then
    return nil, "empty document"
  end

  local lines = vim.split(text:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })

  -- Skip directives and the opening `---`, so the first document is what gets
  -- read.
  local start = 1
  while start <= #lines do
    local stripped = trim(lines[start])
    if stripped:sub(1, 1) == "%" or stripped == "---" then
      start = start + 1
    elseif skippable(lines[start]) then
      start = start + 1
    else
      break
    end
  end
  if start > 1 then
    lines = vim.list_slice(lines, start)
  end

  local reader = Reader.new(lines)
  local ok, value = pcall(function()
    return reader:parse_node(0)
  end)
  if not ok then
    return nil, tostring(value)
  end
  if value == nil then
    return nil, "no content"
  end
  return value
end

return M
