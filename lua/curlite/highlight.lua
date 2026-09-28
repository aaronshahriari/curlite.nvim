--- Request-aware highlighting for .http buffers.
---
--- Vim syntax is the zero-dependency fallback, but Treesitter and semantic
--- tokens can replace it. These extmarks sit above both and restore the small
--- set of structural details that make a request file easy to scan.

local parser = require("curlite.parser")

local M = {}

local NS = vim.api.nvim_create_namespace("curlite_http")
local PRIORITY = 200
local attached = {}
local pending = {}

local METHOD_GROUPS = {
  GET = "CurliteHttpMethodRead",
  HEAD = "CurliteHttpMethodRead",
  OPTIONS = "CurliteHttpMethodRead",
  POST = "CurliteHttpMethodWrite",
  PUT = "CurliteHttpMethodChange",
  PATCH = "CurliteHttpMethodChange",
  DELETE = "CurliteHttpMethodDelete",
  CONNECT = "CurliteHttpMethodChange",
  TRACE = "CurliteHttpMethodChange",
  QUERY = "CurliteHttpMethodQuery",
  GRAPHQL = "CurliteHttpMethodQuery",
}

function M.setup_highlights()
  local links = {
    CurliteHttpRequestLine = "CursorLine",
    CurliteHttpSeparator = "Comment",
    CurliteHttpRequestName = "Title",
    CurliteHttpConfirm = "DiagnosticWarn",
    CurliteHttpComment = "Comment",
    CurliteHttpMetadata = "PreProc",
    CurliteHttpMetaValue = "Comment",
    CurliteHttpVariable = "Identifier",
    CurliteHttpTemplate = "Macro",
    CurliteHttpDynamic = "Function",
    CurliteHttpMethodRead = "DiagnosticInfo",
    CurliteHttpMethodWrite = "Function",
    CurliteHttpMethodChange = "DiagnosticWarn",
    CurliteHttpMethodDelete = "DiagnosticError",
    CurliteHttpMethodQuery = "Type",
    CurliteHttpUrl = "Underlined",
    CurliteHttpVersion = "Constant",
    CurliteHttpHeaderName = "Type",
    CurliteHttpHeaderSep = "Delimiter",
    CurliteHttpHeaderValue = "String",
    CurliteHttpSensitiveValue = "DiagnosticWarn",
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local function mark(buf, row, start_col, end_col, group, priority)
  vim.api.nvim_buf_set_extmark(buf, NS, row, start_col, {
    end_col = end_col,
    hl_group = group,
    priority = priority or PRIORITY,
  })
end

local function line_mark(buf, row, group)
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
    line_hl_group = group,
    priority = PRIORITY - 1,
  })
end

local function mark_templates(buf, row, line)
  local offset = 1
  while true do
    local first, last = line:find("{{.-}}", offset)
    if not first then
      return
    end
    mark(buf, row, first - 1, last, "CurliteHttpTemplate", PRIORITY + 20)
    local inner = line:sub(first + 2, last - 2)
    local dollar = inner:find("%$")
    if dollar then
      mark(buf, row, first + dollar, last - 2, "CurliteHttpDynamic", PRIORITY + 30)
    end
    offset = last + 1
  end
end

local function mark_request_line(buf, row, line, req)
  local indent, method = line:match("^(%s*)([%a]+)")
  local cursor = #(indent or "")
  if method and method:upper() == req.method and parser.methods[method:upper()] then
    mark(buf, row, cursor, cursor + #method, METHOD_GROUPS[req.method] or "CurliteHttpMethodWrite")
    cursor = cursor + #method
    local url_start, url_end = line:find("%S+", cursor + 1)
    if url_start then
      mark(buf, row, url_start - 1, url_end, "CurliteHttpUrl")
      cursor = url_end
    end
  else
    local url_start, url_end = line:find("%S+")
    if url_start then
      mark(buf, row, url_start - 1, url_end, "CurliteHttpUrl")
      cursor = url_end
    end
  end
  local version_start, version_end = line:find("HTTP/[%d%.]+", cursor + 1)
  if version_start then
    mark(buf, row, version_start - 1, version_end, "CurliteHttpVersion")
  end
end

local function mark_headers(buf, lines, req)
  local line_nr = (req.url_line or 0) + 1
  while line_nr <= math.min(req.end_line, #lines) do
    local line = lines[line_nr]
    if vim.trim(line) == "" then
      break
    end
    if line:match("^%s+[?&#]") then
      local first = line:find("[?&#]")
      mark(buf, line_nr - 1, first - 1, #line, "CurliteHttpUrl")
    elseif line:match("^%s") then
      mark(buf, line_nr - 1, 0, #line, "CurliteHttpHeaderValue")
    else
      local name, colon = line:match("^([%w%._-]+)%s*():")
      if not name then
        break
      end
      line_mark(buf, line_nr - 1, "CurliteHttpRequestLine")
      mark(buf, line_nr - 1, 0, #name, "CurliteHttpHeaderName")
      mark(buf, line_nr - 1, colon - 1, colon, "CurliteHttpHeaderSep")
      local value_start = line:find("%S", colon + 1)
      if value_start then
        local lower = name:lower()
        local group = (lower == "authorization" or lower == "cookie" or lower == "set-cookie")
            and "CurliteHttpSensitiveValue"
          or "CurliteHttpHeaderValue"
        mark(buf, line_nr - 1, value_start - 1, #line, group)
      end
    end
    line_nr = line_nr + 1
  end
end

---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  for index, line in ipairs(lines) do
    local row = index - 1
    local indent, hashes, title = line:match("^(%s*)(#+)%s*(.*)$")
    if hashes and #hashes >= 3 then
      line_mark(buf, row, "CurliteHttpRequestLine")
      mark(buf, row, #indent, #indent + #hashes, "CurliteHttpSeparator")
      if title ~= "" then
        local title_start = line:find(title, #indent + #hashes + 1, true)
        if title_start then
          mark(buf, row, title_start - 1, #line, "CurliteHttpRequestName")
          local confirm_start, confirm_end = line:lower():find("%[confirm%]")
          if confirm_start then
            mark(buf, row, confirm_start - 1, confirm_end, "CurliteHttpConfirm", PRIORITY + 10)
          end
        end
      end
    else
      local comment_start = line:find("^%s*#") or line:find("^%s*//")
      if comment_start then
        mark(buf, row, comment_start - 1, #line, "CurliteHttpComment")
        local meta_start, meta_end = line:find("@[%w_-]+")
        if meta_start then
          mark(buf, row, meta_start - 1, meta_end, "CurliteHttpMetadata", PRIORITY + 10)
          if meta_end < #line then
            mark(buf, row, meta_end, #line, "CurliteHttpMetaValue")
          end
        end
      end
      local variable = line:match("^%s*(@[%w%._-]+)%s*=")
      if variable then
        local start = line:find(variable, 1, true)
        mark(buf, row, start - 1, start - 1 + #variable, "CurliteHttpVariable")
      end
    end
    mark_templates(buf, row, line)
  end

  local source = vim.api.nvim_buf_get_name(buf)
  local doc = parser.parse(lines, source ~= "" and source or nil)
  for _, req in ipairs(doc.requests) do
    if req.url_line and lines[req.url_line] then
      mark_request_line(buf, req.url_line - 1, lines[req.url_line], req)
      mark_headers(buf, lines, req)
    end
  end
end

local function queue_refresh(buf)
  pending[buf] = (pending[buf] or 0) + 1
  local generation = pending[buf]
  vim.defer_fn(function()
    if pending[buf] == generation then
      M.refresh(buf)
    end
  end, 35)
end

---@param buf integer
function M.attach(buf)
  if attached[buf] then
    M.refresh(buf)
    return
  end
  attached[buf] = true
  M.refresh(buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      queue_refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      attached[buf] = nil
      pending[buf] = nil
    end,
  })
end

return M
