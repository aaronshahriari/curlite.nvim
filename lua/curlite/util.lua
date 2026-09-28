--- Small shared helpers: notifications, logging, paths, JSONPath.

local M = {}

--- Emit a message tagged with an event name from `curlite.notify`. Whether it
--- is shown is up to `config.notify`; see `:h curlite-notifications`.
---@param event string
---@param msg string
---@param opts { level: integer|string|nil, data: table|nil }|nil
function M.emit(event, msg, opts)
  return require("curlite.notify").emit(event, msg, opts)
end

--- Back-compat shims. They map onto the generic events, so `notify.events`
--- can still reach anything that has not been given a name of its own.
---@param msg string
---@param level integer|nil  vim.log.levels.*
function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  local event = level >= vim.log.levels.ERROR and "error"
    or level >= vim.log.levels.WARN and "warn"
    or "info"
  return M.emit(event, msg, { level = level })
end

---@param msg string
---@param level integer|nil
function M.alert(msg, level)
  level = level or vim.log.levels.ERROR
  return M.emit(level >= vim.log.levels.ERROR and "error" or "warn", msg, { level = level })
end

function M.warn(msg)
  return M.emit("warn", msg)
end

function M.err(msg)
  return M.emit("error", msg)
end

local log_path = vim.fn.stdpath("log") .. "/curlite.log"

--- Append to the debug log when `debug = true`.
---@param ... any
function M.log(...)
  if not require("curlite.config").get().debug then
    return
  end
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[i] = type(v) == "string" and v or vim.inspect(v)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(log_path, ":h"), "p")
  local fd = io.open(log_path, "a")
  if fd then
    fd:write(("[%s] %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), table.concat(parts, " ")))
    fd:close()
  end
end

function M.log_path()
  return log_path
end

--- Resolve a path that may be relative to the `.http` file that mentioned it.
---@param path string
---@param source string|nil  the .http file
---@return string
function M.resolve_path(path, source)
  path = vim.fn.expand(path)
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return path
  end
  local base = source and source ~= "" and vim.fn.fnamemodify(source, ":p:h") or vim.fn.getcwd()
  return vim.fs.normalize(base .. "/" .. path)
end

--- Read a whole file.
---@param path string
---@return string|nil content, string|nil err
function M.read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil, ("cannot read %s"):format(path)
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

--- Write a file, creating parent directories.
---@param path string
---@param content string
---@return boolean ok, string|nil err
function M.write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "wb")
  if not fd then
    return false, err or ("cannot write %s"):format(path)
  end
  fd:write(content)
  fd:close()
  return true
end

--- Decode JSON, returning nil instead of raising.
---@param str string
---@return any|nil
function M.json_decode(str)
  if type(str) ~= "string" or str == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if ok then
    return decoded
  end
  return nil
end

--- Walk a dotted/bracketed path into a decoded value.
--- Accepts `$.a.b[0].c`, `a.b.0.c`, `$[2].name` and `$` (the whole value).
---@param value any
---@param path string
---@return any|nil
function M.json_path(value, path)
  if value == nil then
    return nil
  end
  path = (path or ""):gsub("^%$", "")
  if path == "" then
    return value
  end

  local cur = value
  -- Normalise `[n]` and `["k"]` into `.n` / `.k` so one split handles both.
  path = path:gsub("%[%s*['\"]?(.-)['\"]?%s*%]", ".%1")
  for key in path:gmatch("[^%.]+") do
    if type(cur) ~= "table" then
      return nil
    end
    local idx = tonumber(key)
    if idx ~= nil and cur[key] == nil then
      -- JSONPath arrays are 0-indexed; Lua tables are 1-indexed.
      cur = cur[idx + 1]
    else
      cur = cur[key]
    end
    if cur == nil then
      return nil
    end
  end
  return cur
end

--- Render a value the way a template substitution should see it: strings stay
--- as-is, tables become compact JSON, booleans/numbers stringify.
---@param value any
---@return string
function M.stringify(value)
  if value == nil then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    return ok and encoded or tostring(value)
  end
  if type(value) == "number" then
    -- Keep integers looking like integers: `1` not `1.0`.
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
      return ("%d"):format(value)
    end
    return tostring(value)
  end
  return tostring(value)
end

--- Human-readable byte count.
---@param bytes integer
---@return string
function M.human_size(bytes)
  if bytes < 1024 then
    return ("%dB"):format(bytes)
  end
  local units = { "KB", "MB", "GB", "TB" }
  local value = bytes / 1024
  for _, unit in ipairs(units) do
    if value < 1024 then
      return ("%.1f%s"):format(value, unit)
    end
    value = value / 1024
  end
  return ("%.1fPB"):format(value)
end

--- Human-readable duration from milliseconds.
---@param ms number
---@return string
function M.human_time(ms)
  if ms < 1000 then
    return ("%dms"):format(math.floor(ms + 0.5))
  end
  if ms < 60000 then
    return ("%.2fs"):format(ms / 1000)
  end
  return ("%dm %.1fs"):format(math.floor(ms / 60000), (ms % 60000) / 1000)
end

--- `true` when `exe` is runnable.
---@param exe string
---@return boolean
function M.has_exe(exe)
  return vim.fn.executable(exe) == 1
end

return M
