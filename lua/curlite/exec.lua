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

--- Every request reachable from a document, including the ones its
--- `# @import`ed files define. Imports are followed depth-first, at most
--- `MAX_IMPORT_DEPTH` levels, and a file already seen is skipped so two files
--- importing each other can't loop.
---@param doc curlite.Document
---@param seen table<string, boolean>|nil
---@param depth integer|nil
---@return table<string, curlite.Request>  name -> request
function M.resolve_imports(doc, seen, depth)
  seen = seen or {}
  depth = depth or 0
  local out = {}

  for _, req in ipairs(doc.requests) do
    if req.name and req.name ~= "" then
      out[req.name] = req
    end
  end

  if depth >= 5 then
    return out
  end

  for _, rel in ipairs(doc.imports or {}) do
    local path = util.resolve_path(rel, doc.source)
    if not seen[path] then
      seen[path] = true
      local imported, ierr = require("curlite.parser").parse_file(path)
      if not imported then
        util.warn(("curlite: @import %s: %s"):format(rel, ierr))
      else
        -- The importing file wins on a name clash, so a local override of an
        -- imported request behaves the way you would expect.
        for name, req in pairs(M.resolve_imports(imported, seen, depth + 1)) do
          if out[name] == nil then
            out[name] = req
          end
        end
      end
    end
  end

  return out
end

--- Resolve a request into something sendable, without sending it.
---@param raw curlite.Request
---@param opts curlite.SendOpts|nil
---@return curlite.Command|nil, string|nil err, curlite.Request|nil resolved, curlite.ScriptResult|nil
function M.prepare(raw, opts)
  opts = opts or {}


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

--- Every named request a `# @run` on this request could refer to: the ones in
--- its own file plus everything its imports pull in.
---
--- The live buffer is preferred over the file on disk, so a `# @run` against a
--- request you just typed and haven't saved still resolves.
---@param raw curlite.Request
---@return table<string, curlite.Request>
function M.lookup_requests(raw)
  if not raw.source or raw.source == "" then
    return {}
  end

  local parser = require("curlite.parser")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == raw.source then
      return M.resolve_imports(parser.parse_buffer(buf))
    end
  end

  local doc = parser.parse_file(raw.source)
  return doc and M.resolve_imports(doc) or {}
end

--- Send one request.
---@param raw curlite.Request
---@param opts curlite.SendOpts|nil
---@return integer|nil job_id  nil when nothing was spawned
function M.send(raw, opts)
  opts = opts or {}

  -- A run is one send, or one "send all", or one `# @run` chain. Marking it
  -- here is what lets `{{$exec}}` shell out once for the whole thing.
  if not opts._in_run then
    opts = vim.tbl_extend("force", opts, { _in_run = true })
    variables.begin_run()
  end

  local cfg = config.get()

  local function finish(result)
    if opts.on_done then
      vim.schedule(function()
        opts.on_done(result)
      end)
    end
  end

  -- `# @skip` is a skip, not a failure: a "send all" run should step over it
  -- quietly rather than report an error for every one.
  if raw.metadata and (raw.metadata.skip or raw.metadata.disabled) then
    finish({
      request = raw,
      raw = raw,
      command = nil,
      response = nil,
      script = nil,
      skipped = true,
      aborted = false,
      error = nil,
      duration_ms = 0,
    })
    return nil
  end

  -- `# @run LOGIN` sends LOGIN first, so a request that needs a fresh token
  -- can declare that instead of you remembering to fire two requests.
  local chain = opts._chain or {}
  local deps = raw.metadata and raw.metadata.run
  if deps and #deps > 0 then
    local next_chain = vim.deepcopy(chain)
    if raw.name then
      next_chain[raw.name] = true
    end

    local pending, available = {}, nil
    for _, name in ipairs(deps) do
      if not chain[name] and not next_chain[name] then
        available = available or M.lookup_requests(raw)
        local dep = available[name]
        if dep then
          next_chain[name] = true
          table.insert(pending, dep)
        else
          util.warn(("curlite: @run %s -- no request by that name"):format(name))
        end
      end
    end

    if #pending > 0 then
      local self_opts = vim.tbl_extend("force", opts, { _chain = next_chain })
      M.send_sequence(pending, {
        bufnr = opts.bufnr,
        _chain = next_chain,
        _in_run = true,
        on_each = opts.on_dependency,
        on_finish = function(results)
          -- An aborted or failed dependency means this request should not run.
          for _, r in ipairs(results) do
            if r.aborted or r.error then
              finish({
                request = raw,
                raw = raw,
                command = nil,
                response = nil,
                script = nil,
                skipped = true,
                aborted = r.aborted or false,
                error = r.error and ("dependency failed: %s"):format(r.error) or nil,
                duration_ms = 0,
              })
              return
            end
          end
          M.send(raw, self_opts)
        end,
      })
      return nil
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

  local function dispatch()
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

    -- `# @delay 500` waits before firing; useful for rate-limited APIs in a
    -- "send all" run.
    local delay = tonumber(resolved.metadata and resolved.metadata.delay) or 0
    if delay > 0 then
      vim.defer_fn(spawn, delay)
      return nil
    end
    return spawn()
  end

  if raw.metadata and raw.metadata.confirm and not opts.dry_run then
    require("curlite.confirm").ask(cmd, function(approved)
      if approved then
        dispatch()
      else
        finish({
          request = resolved,
          raw = raw,
          command = cmd,
          response = nil,
          script = pre,
          skipped = true,
          aborted = false,
          error = nil,
          duration_ms = 0,
        })
      end
    end)
    return nil
  end

  return dispatch()
end

--- Send several requests in order, stopping on an abort.
---@param requests curlite.Request[]
---@param opts { bufnr: integer|nil, on_each: fun(result: curlite.Result, index: integer)|nil, on_finish: fun(results: curlite.Result[])|nil, stop_on_error: boolean|nil }|nil
function M.send_sequence(requests, opts)
  opts = opts or {}
  if not opts._in_run then
    opts = vim.tbl_extend("force", opts, { _in_run = true })
    variables.begin_run()
  end

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
      _chain = opts._chain,
      _in_run = true,
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
