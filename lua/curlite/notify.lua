--- Notification routing.
---
--- Every message curlite shows goes through `M.emit`, tagged with an *event*
--- name from the registry below. `config.notify` decides, per event, whether
--- the message is shown at all and where it goes, so a noisy message can be
--- silenced by name instead of by turning the whole plugin quiet.

local config = require("curlite.config")

local M = {}

local levels = vim.log.levels

--- Every event curlite can notify about.
---
--- `level`     the default severity of the message.
--- `important` the event ignores `notify.level`. These are the messages that
---             answer a question you just asked ("did the yank work?") or
---             report that something you asked for did not happen -- they are
---             wrong to hide behind a severity threshold, so only naming them
---             in `notify.events` turns them off.
---@type table<string, { level: integer, important: boolean, desc: string }>
M.events = {
  -- Request lifecycle -------------------------------------------------------
  request_sent = { level = levels.INFO, important = false, desc = "a request is going out" },
  request_done = { level = levels.INFO, important = false, desc = "a response landed (WARN for 4xx/5xx)" },
  request_skipped = { level = levels.INFO, important = false, desc = "a pre-request script skipped the request" },
  request_aborted = { level = levels.WARN, important = true, desc = "a script aborted a `send_all` run" },
  request_error = { level = levels.ERROR, important = true, desc = "the request could not be built or sent" },
  run_summary = { level = levels.INFO, important = true, desc = "the tally after `send_all` / `run_file`" },
  cancelled = { level = levels.INFO, important = true, desc = "in-flight requests were cancelled" },

  -- Environments ------------------------------------------------------------
  env_selected = { level = levels.INFO, important = true, desc = "an environment was chosen" },
  env_required = { level = levels.WARN, important = true, desc = "a send was held back until you pick one" },
  env_missing = { level = levels.ERROR, important = true, desc = "no environment file was found" },

  -- The document ------------------------------------------------------------
  no_request = { level = levels.ERROR, important = true, desc = "no request under the cursor / in the file" },
  duplicate_names = { level = levels.WARN, important = true, desc = "two requests in a file share a name" },
  parse_error = { level = levels.ERROR, important = true, desc = "a file or curl command would not parse" },

  -- Resolving a request -----------------------------------------------------
  import_error = { level = levels.WARN, important = true, desc = "`# @import` could not read a file" },
  chain_error = { level = levels.WARN, important = true, desc = "`# @run` names a request that does not exist" },
  variable_error = { level = levels.WARN, important = true, desc = "`{{$exec ...}}` and friends failed" },
  script_error = { level = levels.WARN, important = true, desc = "a pre/post-request script raised" },

  -- Clipboard and files -----------------------------------------------------
  yank = { level = levels.INFO, important = true, desc = "something was copied to a register" },
  save = { level = levels.INFO, important = true, desc = "a response body was written to disk" },
  write_error = { level = levels.WARN, important = true, desc = "a `>>` redirect could not be written" },

  -- The response window -----------------------------------------------------
  no_response = { level = levels.INFO, important = false, desc = "`toggle` with nothing to show" },
  cleared = { level = levels.INFO, important = false, desc = "session state was cleared" },

  -- Anything without a better name ------------------------------------------
  info = { level = levels.INFO, important = false, desc = "uncategorised informational message" },
  warn = { level = levels.WARN, important = true, desc = "uncategorised warning" },
  error = { level = levels.ERROR, important = true, desc = "uncategorised error" },
}

local NAMES = {
  off = levels.OFF,
  trace = levels.TRACE,
  debug = levels.DEBUG,
  info = levels.INFO,
  warn = levels.WARN,
  warning = levels.WARN,
  error = levels.ERROR,
  -- The three legacy `notify = "..."` words, so `level` accepts them too.
  all = levels.TRACE,
  errors = levels.WARN,
  none = levels.OFF,
}

--- Coerce a level written as a name, a `vim.log.levels.*` number, or nil.
---@param value any
---@param fallback integer|nil
---@return integer|nil
function M.level(value, fallback)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return NAMES[value:lower()] or fallback
  end
  return fallback
end

--- Normalise `config.notify`, which may be a legacy string, into the table
--- form everything below expects.
---@return table
function M.settings()
  local raw = config.get().notify
  if type(raw) == "string" then
    -- "all" | "errors" | "none", the pre-0.2 spelling.
    if raw == "none" then
      return { enabled = false, events = {}, level = levels.OFF }
    end
    return { enabled = true, events = {}, level = M.level(raw, levels.WARN) }
  end
  if type(raw) == "boolean" then
    return { enabled = raw, events = {}, level = levels.WARN }
  end
  if type(raw) ~= "table" then
    return { enabled = true, events = {}, level = levels.WARN }
  end
  return raw
end

--- Should this event be shown, and at what level?
---
--- The order is: master switch, then the per-event entry in `notify.events`,
--- then `notify.level` (which `important` events are exempt from), then
--- `notify.filter` -- which sees the decision and has the last word.
---@param event string
---@param level integer
---@param data table|nil
---@return boolean
function M.enabled(event, level, data)
  local cfg = M.settings()
  if cfg.enabled == false then
    return false
  end

  local spec = M.events[event] or M.events.info
  local rule = (cfg.events or {})[event]
  local show

  if rule == false then
    show = false
  elseif rule == true then
    show = true
  elseif rule ~= nil then
    -- A per-event threshold: `events = { request_done = "warn" }` shows the
    -- failures and hides the 200s.
    show = level >= (M.level(rule, spec.level) or spec.level)
  elseif spec.important then
    show = true
  else
    show = level >= (M.level(cfg.level, levels.WARN) or levels.WARN)
  end

  if type(cfg.filter) == "function" then
    local ok, verdict = pcall(cfg.filter, {
      event = event,
      level = level,
      shown = show,
      msg = data and data.msg,
      data = data,
    })
    if ok and verdict ~= nil then
      show = verdict and true or false
    end
  end

  return show
end

--- Show a message, unless the configuration says not to.
---@param event string          a key of `M.events`
---@param msg string
---@param opts { level: integer|string|nil, data: table|nil }|nil
function M.emit(event, msg, opts)
  opts = opts or {}
  local spec = M.events[event] or M.events.info
  local level = M.level(opts.level, spec.level) or spec.level
  local data = opts.data or {}
  data.msg = msg

  if not M.enabled(event, level, data) then
    return false
  end

  local cfg = M.settings()
  local title = cfg.title or "curlite"
  local sink = cfg.backend

  vim.schedule(function()
    if type(sink) == "function" then
      sink(msg, level, { title = title, event = event, data = data })
    else
      vim.notify(msg, level, { title = title, event = event })
    end
  end)
  return true
end

return M
