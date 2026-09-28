-- Which messages `config.notify` lets through.

local config = require("curlite.config")
local notify = require("curlite.notify")
local util = require("curlite.util")

local levels = vim.log.levels

--- `emit` schedules, so drain the loop before looking at what arrived.
local function shown(t, fn)
  t.drain()
  fn()
  vim.wait(50, function()
    return false
  end)
  return t.drain()
end

local function setup(notify_opts)
  config.setup({ notify = notify_opts })
end

return {
  ["level gates the ordinary events"] = function(t)
    setup({ level = "warn" })
    t.falsy(notify.enabled("request_sent", levels.INFO), "INFO request_sent is under the floor")
    t.truthy(notify.enabled("request_done", levels.WARN), "a 4xx clears it")
  end,

  ["important events ignore the level"] = function(t)
    setup({ level = "error" })
    -- `yank` is INFO but answers a question the user just asked.
    t.truthy(notify.enabled("yank", levels.INFO), "yank is important")
    t.falsy(notify.enabled("no_response", levels.INFO), "no_response is not")
  end,

  ["an event can be silenced by name"] = function(t)
    setup({ events = { yank = false, run_summary = false } })
    t.falsy(notify.enabled("yank", levels.INFO))
    t.falsy(notify.enabled("run_summary", levels.INFO))
    t.truthy(notify.enabled("save", levels.INFO), "its neighbours are untouched")
  end,

  ["an event can be forced on under the level"] = function(t)
    setup({ level = "error", events = { request_sent = true } })
    t.truthy(notify.enabled("request_sent", levels.INFO))
    t.falsy(notify.enabled("request_done", levels.INFO), "only the one named")
  end,

  ["an event can carry its own threshold"] = function(t)
    setup({ level = "info", events = { request_done = "warn" } })
    t.falsy(notify.enabled("request_done", levels.INFO), "200s are quiet")
    t.truthy(notify.enabled("request_done", levels.WARN), "500s are not")
  end,

  ["enabled = false silences everything"] = function(t)
    setup({ enabled = false })
    t.falsy(notify.enabled("request_error", levels.ERROR))
    local msgs = shown(t, function()
      util.emit("request_error", "boom")
    end)
    t.eq(#msgs, 0, "nothing reached vim.notify")
  end,

  ["filter has the last word, both ways"] = function(t)
    setup({
      level = "warn",
      filter = function(ev)
        if ev.event == "request_done" then
          return ev.data.status ~= nil and ev.data.status >= 500
        end
      end,
    })
    t.falsy(notify.enabled("request_done", levels.WARN, { status = 404 }), "filter vetoes a 404")
    t.truthy(notify.enabled("request_done", levels.WARN, { status = 503 }), "and keeps a 503")
    -- Returning nil leaves the level decision alone.
    t.truthy(notify.enabled("request_error", levels.ERROR, {}))
  end,

  ["a filter that raises does not break the notification"] = function(t)
    setup({
      filter = function()
        error("nope")
      end,
    })
    t.truthy(notify.enabled("request_error", levels.ERROR), "the decision stands")
  end,

  ["backend replaces vim.notify"] = function(t)
    local seen = {}
    setup({
      backend = function(msg, level, opts)
        table.insert(seen, { msg = msg, level = level, event = opts.event })
      end,
    })
    local msgs = shown(t, function()
      util.emit("yank", "curlite: yanked 12B", { data = { bytes = 12 } })
    end)
    t.eq(#msgs, 0, "vim.notify was not called")
    t.eq(#seen, 1, "the backend was")
    t.eq(seen[1].event, "yank")
    t.eq(seen[1].level, levels.INFO)
  end,

  ["the backend sees the event's data"] = function(t)
    local got
    setup({
      backend = function(_, _, opts)
        got = opts.data
      end,
    })
    shown(t, function()
      util.emit("env_selected", "curlite: environment → dev", { data = { env = "dev" } })
    end)
    t.eq(got.env, "dev")
    t.eq(got.msg, "curlite: environment → dev", "the message is on `data` too")
  end,

  ["the legacy string forms still work"] = function(t)
    setup("none")
    t.falsy(notify.enabled("request_error", levels.ERROR), "none is silent")

    setup("errors")
    t.falsy(notify.enabled("request_sent", levels.INFO))
    t.truthy(notify.enabled("request_done", levels.WARN))

    setup("all")
    t.truthy(notify.enabled("request_sent", levels.INFO), "all lets the lifecycle through")
    t.truthy(notify.enabled("request_done", levels.INFO))
  end,

  ["notify = false is the off switch too"] = function(t)
    setup(false)
    t.falsy(notify.enabled("request_error", levels.ERROR))
  end,

  ["the defaults match the documented behaviour"] = function(t)
    config.setup({})
    -- Quiet by default: a successful request says nothing.
    t.falsy(notify.enabled("request_sent", levels.INFO))
    t.falsy(notify.enabled("request_done", levels.INFO))
    t.falsy(notify.enabled("request_skipped", levels.INFO))
    t.falsy(notify.enabled("cleared", levels.INFO))
    -- But a failure, or something you asked for, is not swallowed.
    t.truthy(notify.enabled("request_done", levels.WARN))
    t.truthy(notify.enabled("request_error", levels.ERROR))
    t.truthy(notify.enabled("env_selected", levels.INFO))
    t.truthy(notify.enabled("yank", levels.INFO))
    t.truthy(notify.enabled("run_summary", levels.INFO))
  end,

  -- Sorts last in this file, so it also leaves the defaults in place for
  -- whatever spec runs next.
  ["unknown event names fall back to `info`"] = function(t)
    config.setup({})
    t.falsy(notify.enabled("made_up", levels.INFO), "treated as an ordinary INFO event")
    t.truthy(notify.enabled("made_up", levels.ERROR))
  end,

  ["levels are accepted as names and as numbers"] = function(t)
    t.eq(notify.level("warn"), levels.WARN)
    t.eq(notify.level("ERROR"), levels.ERROR)
    t.eq(notify.level(levels.INFO), levels.INFO)
    t.eq(notify.level("nonsense", levels.WARN), levels.WARN)
    t.eq(notify.level(nil), nil)
  end,

  ["every event has a level and a description"] = function(t)
    for name, spec in pairs(notify.events) do
      t.truthy(type(spec.level) == "number", name .. " has a level")
      t.truthy(type(spec.desc) == "string" and spec.desc ~= "", name .. " has a description")
      t.truthy(type(spec.important) == "boolean", name .. " declares `important`")
    end
  end,
}
