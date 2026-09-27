--- Running requests.
---
--- One send is: resolve prompts -> render variables -> pre-request scripts ->
--- spawn curl -> parse the response -> post-request scripts and assertions ->
--- record it for `{{NAME.response...}}` -> hand it to the caller.
---
--- Nothing here touches the UI; `init.lua` wires the callbacks to `ui.lua`, so
--- a request can also be run headlessly from your own Lua.

local config = require("curlite.config")
local curl = require("curlite.curl")
local env = require("curlite.env")
local response = require("curlite.response")
local scripts = require("curlite.scripts")
local util = require("curlite.util")
local variables = require("curlite.variables")

local M = {}

-- The last thing that ran, so `replay()` has something to replay.
---@type { request: curlite.Request, source: string|nil, bufnr: integer|nil }|nil
M.last = nil

-- Handles of in-flight jobs, so they can be cancelled.
---@type table<integer, vim.SystemObj>
M.running = {}
local next_id = 0

---@class curlite.Result
---@field request curlite.Request      as sent (variables resolved)
---@field raw curlite.Request          as written in the buffer
---@field command curlite.Command
---@field response curlite.Response|nil
---@field script curlite.ScriptResult|nil
---@field skipped boolean
---@field aborted boolean
---@field error string|nil
---@field duration_ms number

---@class curlite.SendOpts
---@field bufnr integer|nil
---@field on_done fun(result: curlite.Result)|nil
---@field on_start fun(request: curlite.Request)|nil
---@field dry_run boolean|nil        build the command but don't spawn curl
---@field force_prompts boolean|nil  re-ask `# @prompt` values
---@field record boolean|nil         default true

--- Resolve a request into something sendable, without sending it.
---@param raw curlite.Request
---@param opts curlite.SendOpts|nil
---@return curlite.Command|nil, string|nil err, curlite.Request|nil resolved, curlite.ScriptResult|nil
function M.prepare(raw, opts)
  opts = opts or {}

  if raw.metadata and (raw.metadata.skip or raw.metadata.disabled) then
    return nil, "request is marked @skip"
  end

  if not variables.resolve_prompts(raw, opts.force_prompts) then
    return nil, "cancelled"
  end

  local ctx = variables.context(raw, raw.source)
  local resolved, missing = variables.render_request(raw, ctx)

  -- Pre-request scripts see the resolved request and may rewrite it.
  local pre = scripts.run_pre(resolved)
  if pre.error then
    return nil, ("pre-request script: %s"):format(pre.error), resolved, pre
  end
  if pre.skip or pre.abort then
    return nil, nil, resolved, pre
  end

  -- A script may have filled in what was missing, so re-render and re-check.
  if #missing > 0 then
    ctx = variables.context(resolved, raw.source)
    local rerendered, still_missing = variables.render_request(resolved, ctx)
    resolved, missing = rerendered, still_missing
  end

  if #missing > 0 then
    return nil,
      ("unresolved variable%s: %s"):format(
        #missing == 1 and "" or "s",
        table.concat(missing, ", ")
      ),
      resolved,
      pre
  end

  if resolved.url == "" then
    return nil, "request has no URL", resolved, pre
  end

  local ok, cmd = pcall(curl.build, resolved)
  if not ok then
    return nil, tostring(cmd), resolved, pre
  end

  return cmd, nil, resolved, pre
end

--- Send one request.
---@param raw curlite.Request
---@param opts curlite.SendOpts|nil
---@return integer|nil job_id  nil when nothing was spawned
function M.send(raw, opts)
  opts = opts or {}
  local cfg = config.get()

  local function finish(result)
    if opts.on_done then
      vim.schedule(function()
        opts.on_done(result)
      end)
    end
  end

  local cmd, err, resolved, pre = M.prepare(raw, opts)

  if not cmd then
    local result = {
      request = resolved or raw,
      raw = raw,
      command = nil,
      response = nil,
      script = pre,
      skipped = (pre and pre.skip) or false,
      aborted = (pre and pre.abort) or false,
      error = err,
      duration_ms = 0,
    }
    if err then
      util.err(("curlite: %s"):format(err))
    end
    finish(result)
    return nil
  end

  M.last = { request = raw, source = raw.source, bufnr = opts.bufnr }

  if opts.on_start then
    opts.on_start(resolved)
  end

  if opts.dry_run then
    finish({
      request = resolved,
      raw = raw,
      command = cmd,
      response = nil,
      script = pre,
      skipped = false,
      aborted = false,
      error = nil,
      duration_ms = 0,
    })
    return nil
  end

  -- `# @delay 500` waits before firing; useful for rate-limited APIs in a
  -- "send all" run.
  local delay = tonumber(resolved.metadata and resolved.metadata.delay) or 0

  local function spawn()
    local started = vim.uv.hrtime()
    next_id = next_id + 1
    local id = next_id

    util.log("send", table.concat(cmd.argv, " "))

    local sysopts = {
      stdin = cmd.stdin,
      text = false,
      -- vim.system's own timeout is a backstop: curl's --max-time should fire
      -- first, and this catches a curl that wedged before it applied.
      timeout = cmd.timeout > 0 and (cmd.timeout + 2000) or nil,
    }

    local handle = vim.system(cmd.argv, sysopts, function(sysresult)
      M.running[id] = nil
      local duration_ms = (vim.uv.hrtime() - started) / 1e6

      -- vim.system's callback runs in a fast event context, where most of
      -- `vim.fn` is off limits. Everything below -- scripts, `>>` file
      -- writes, the UI -- wants a normal context, so hand off immediately.
      vim.schedule(function()

      -- vim.system gives bytes; the pieces we read are text.
      sysresult.stdout = sysresult.stdout and tostring(sysresult.stdout) or ""
      sysresult.stderr = sysresult.stderr and tostring(sysresult.stderr) or ""

      local resp = response.build(cmd, sysresult, duration_ms)

      if cfg.request.substitute_in_response and resp.body ~= "" then
        resp.body = variables.render(resp.body, variables.context(resolved, raw.source)) or resp.body
      end

      local post = nil
      if not resp.error then
        post = scripts.run_post(resolved, resp)
        if post.error then
          util.warn(("curlite: post-request script: %s"):format(post.error))
        end
      end

      if opts.record ~= false then
        variables.record(raw.name, {
          method = resolved.method,
          url = resolved.url,
          headers = resolved.headers,
          body = cmd.sent_body,
        }, resp)
      end

      -- `>> ./file` writes the body out.
      if resolved.redirect and resp.body ~= "" then
        local path = util.resolve_path(resolved.redirect.path, raw.source)
        if vim.fn.filereadable(path) == 1 and not resolved.redirect.overwrite then
          util.warn(("curlite: %s exists; use `>>!` to overwrite"):format(path))
        else
          local ok, werr = util.write_file(path, resp.body)
          if not ok then
            util.warn(("curlite: %s"):format(werr))
          end
        end
      end

      response.cleanup(cmd)

      finish({
        request = resolved,
        raw = raw,
        command = cmd,
        response = resp,
        script = scripts.merge(pre, post),
        skipped = false,
        aborted = (post and post.abort) or false,
        error = resp.error,
        duration_ms = resp.duration_ms,
      })
      end)
    end)

    M.running[id] = handle
    return id
  end

  if delay > 0 then
    vim.defer_fn(spawn, delay)
    return nil
  end
  return spawn()
end

--- Send several requests in order, stopping on an abort.
---@param requests curlite.Request[]
---@param opts { bufnr: integer|nil, on_each: fun(result: curlite.Result, index: integer)|nil, on_finish: fun(results: curlite.Result[])|nil, stop_on_error: boolean|nil }|nil
function M.send_sequence(requests, opts)
  opts = opts or {}
  local results = {}
  local index = 0

  local function step()
    index = index + 1
    local req = requests[index]
    if not req then
      if opts.on_finish then
        opts.on_finish(results)
      end
      return
    end

    M.send(req, {
      bufnr = opts.bufnr,
      on_done = function(result)
        table.insert(results, result)
        if opts.on_each then
          opts.on_each(result, index)
        end
        if result.aborted then
          util.warn(
            ("curlite: aborted at request %d/%d%s"):format(
              index,
              #requests,
              result.script and result.script.reason and (": " .. result.script.reason) or ""
            )
          )
          if opts.on_finish then
            opts.on_finish(results)
          end
          return
        end
        if opts.stop_on_error and result.error then
          if opts.on_finish then
            opts.on_finish(results)
          end
          return
        end
        step()
      end,
    })
  end

  step()
end

--- Cancel every in-flight request.
---@return integer count
function M.cancel_all()
  local count = 0
  for id, handle in pairs(M.running) do
    pcall(function()
      handle:kill("sigterm")
    end)
    M.running[id] = nil
    count = count + 1
  end
  return count
end

--- Run a request and block until it finishes. For scripting, not the UI.
---@param raw curlite.Request
---@param timeout_ms integer|nil
---@return curlite.Result|nil
function M.send_sync(raw, timeout_ms)
  local done, out = false, nil
  M.send(raw, {
    on_done = function(result)
      out = result
      done = true
    end,
  })
  vim.wait(timeout_ms or (config.get().curl.timeout + 5000), function()
    return done
  end, 20)
  return out
end

--- Clear every piece of cross-request state: recorded responses, prompt
--- answers and script globals.
function M.reset()
  variables.reset()
  env.globals = {}
  M.last = nil
end

return M
