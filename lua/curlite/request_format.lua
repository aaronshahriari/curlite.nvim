--- Formatting for editable .http request files.
---
--- This is the counterpart to `curlite.format`, which pretty-prints a
--- *response*. Here the buffer is source you keep, so the rules are
--- deliberately conservative: normalise the structure curlite already
--- understands (separators, variables, request lines, headers) and indent JSON
--- bodies. Anything curlite does not model -- prose comments, non-JSON bodies,
--- script blocks -- is returned byte-for-byte.

local body_format = require("curlite.format")
local config = require("curlite.config")
local parser = require("curlite.parser")

local M = {}

-- A `{{var}}` is not valid JSON, so a body full of them cannot be decoded and
-- re-indented directly. Each one is swapped for a placeholder that *is* a
-- legal JSON token, and swapped back afterwards. The number is distinctive
-- enough that a real payload containing it is not a realistic concern.
local SENTINEL = "-987654321"

---@param index integer
---@return string
local function sentinel(index)
  return ("%s%03d"):format(SENTINEL, index)
end

---@param body string
---@param indent integer
---@return string|nil
local function format_json(body, indent)
  local templates = {}
  local masked = body:gsub("{{.-}}", function(value)
    templates[#templates + 1] = value
    return sentinel(#templates)
  end)

  -- `vim.json.decode` throws on malformed input rather than returning nil, and
  -- a body that is still being typed is malformed more often than not.
  local ok = pcall(vim.json.decode, masked)
  if not ok then
    return nil
  end

  local formatted = body_format.json(masked, indent)
  if not formatted then
    return nil
  end

  for index, value in ipairs(templates) do
    -- The sentinel opens with `-`, which is a magic character in a Lua
    -- pattern; `%` escapes it. The replacement is a function so that a `%` in
    -- the template is not read as a capture reference.
    formatted = formatted:gsub("%" .. sentinel(index), function()
      return value
    end)
  end
  return formatted
end

--- Rewrite the body of every request in place, bottom to top so that a changed
--- line count cannot move a request that has not been handled yet.
---@param out string[]
---@param doc curlite.Document
---@param indent integer
local function format_bodies(out, doc, indent)
  for index = #doc.requests, 1, -1 do
    local req = doc.requests[index]
    if req.body and req.body ~= "" and req.body_line then
      local first = vim.trim(req.body):sub(1, 1)
      if first == "{" or first == "[" then
        local formatted = format_json(req.body, indent)
        if formatted then
          local replacement = vim.split(formatted, "\n", { plain = true })
          local count = #vim.split(req.body, "\n", { plain = true })
          -- `nvim_buf_set_lines` semantics, on a plain list: drop the old body
          -- and splice the new one in at the same place.
          for _ = 1, count do
            table.remove(out, req.body_line)
          end
          for offset, line in ipairs(replacement) do
            table.insert(out, req.body_line + offset - 1, line)
          end
        end
      end
    end
  end
end

--- Normalise separators and variables, then only the request/header lines the
--- parser identified. Looking for method names across the whole file would
--- turn a GraphQL body's `query Name {` into an HTTP `QUERY` request line.
---@param out string[]
---@param doc curlite.Document
local function format_structure(out, doc)
  for index, line in ipairs(out) do
    local title = line:match("^%s*###+%s*(.-)%s*$")
    local name, value = line:match("^%s*@([%w_.-]+)%s*=%s*(.-)%s*$")

    if title then
      out[index] = title == "" and "###" or "### " .. title
    elseif name then
      out[index] = ("@%s = %s"):format(name, value)
    end
  end

  for _, req in ipairs(doc.requests) do
    local line_nr = req.url_line
    local line = line_nr and out[line_nr]
    if line then
      local method, rest = line:match("^%s*(%a+)%s+(%S.*)$")
      if method and parser.methods[method:upper()] then
        local url, version = rest:match("^(%S+)%s+(HTTP/[%d.]+)%s*$")
        url = url or rest:match("^(%S+)%s*$") or rest
        out[line_nr] = method:upper() .. " " .. url .. (version and (" " .. version) or "")
      else
        out[line_nr] = vim.trim(line)
      end

      line_nr = line_nr + 1
      while line_nr <= req.end_line do
        line = out[line_nr]
        if vim.trim(line) == "" then
          break
        elseif line:match("^%s+[?&#]") then
          out[line_nr] = "  " .. vim.trim(line)
        elseif line:match("^%s") then
          -- Preserve obsolete folded-header continuations byte-for-byte.
        else
          local header, header_value = line:match("^([%w._-]+)%s*:%s*(.-)%s*$")
          if not header then
            break
          end
          out[line_nr] = header .. ": " .. header_value
        end
        line_nr = line_nr + 1
      end
    end
  end
end

--- Format a whole document.
---@param lines string[]
---@return string[]
function M.lines(lines)
  local cfg = config.get().format or {}
  local out = vim.deepcopy(lines)
  local doc = parser.parse(lines)
  format_structure(out, doc)
  if cfg.bodies ~= false then
    format_bodies(out, doc, cfg.indent or 2)
  end
  return out
end

--- Format a buffer in place, leaving it untouched when nothing changed so the
--- 'modified' flag and the undo tree stay honest.
---@param bufnr integer|nil
function M.buffer(bufnr)
  bufnr = bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local formatted = M.lines(lines)
  if not vim.deep_equal(lines, formatted) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, formatted)
  end
end

return M
