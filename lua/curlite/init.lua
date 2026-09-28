--- curlite.nvim -- a REST client for Neovim built on curl.
---
--- Public API. Everything a keymap or your own Lua would want to call lives
--- here; the modules underneath are free to change.

local config = require("curlite.config")
local env = require("curlite.env")
local exec = require("curlite.exec")
local parser = require("curlite.parser")
local ui = require("curlite.ui")
local util = require("curlite.util")
local variables = require("curlite.variables")

local M = {}

M.config = config

local did_setup = false

--- ----------------------------------------------------------------- helpers

-- Buffers already warned about a given duplicate name, so the warning shows
-- once rather than on every send.
---@type table<string, boolean>
local warned_duplicates = {}

---@param bufnr integer|nil
---@return curlite.Document
local function document(bufnr)
  local doc = parser.parse_buffer(bufnr)

  local dupes = parser.duplicate_names(doc)
  if #dupes > 0 then
    local key = ("%s:%s"):format(doc.source or tostring(bufnr), table.concat(dupes, ","))
    if not warned_duplicates[key] then
      warned_duplicates[key] = true
      util.warn(
        ("curlite: duplicate request name%s in this file: %s — `# @run` and `{{name.response...}}` can't tell them apart"):format(
          #dupes == 1 and "" or "s",
          table.concat(dupes, ", ")
        )
      )
    end
  end

  return doc
end

---@return curlite.Request|nil, curlite.Document
local function request_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local doc = document(bufnr)
  if #doc.requests == 0 then
    return nil, doc
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local req = parser.request_at(doc, line)
  return req, doc
end

--- The callbacks that hook a run up to the UI.
---@param bufnr integer
---@param opts table|nil
---@return table
local function ui_handlers(bufnr, opts)
  opts = opts or {}
  return {
    bufnr = bufnr,
    force_prompts = opts.force_prompts,
    dry_run = opts.dry_run,
    on_start = function(req)
      if config.get().notify == "all" then
        util.notify(("curlite: %s %s"):format(req.method, req.url), vim.log.levels.INFO)
      end
      if not opts.quiet then
        ui.show_pending(req)
      end
    end,
    on_done = function(result)
      ui.set_inline(result, bufnr)

      if result.skipped then
        util.notify("curlite: request skipped" .. (result.script and result.script.reason and (": " .. result.script.reason) or ""), vim.log.levels.INFO)
        return
      end

      if not opts.quiet then
        ui.show(result)
      end

      if result.response then
        local level = result.response.status >= 400 and vim.log.levels.WARN or vim.log.levels.INFO
        util.notify(
          ("curlite: %d %s in %s"):format(
            result.response.status,
            result.response.status_text,
            util.human_time(result.response.duration_ms)
          ),
          level
        )
      end

      if opts.on_done then
        opts.on_done(result)
      end
    end,
  }
end

--- -------------------------------------------------------------------- API

--- Send a specific request.
---@param req curlite.Request
---@param opts table|nil
function M.run(req, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  exec.send(req, ui_handlers(bufnr, opts))
end

--- Send the request under the cursor.
---@param opts table|nil
function M.run_at_cursor(opts)
  local req = request_at_cursor()
  if not req then
    util.err("curlite: no request found in this buffer")
    return
  end
  M.run(req, opts)
end

--- Send every request in the buffer, in order.
---@param opts table|nil
function M.run_all(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local doc = document(bufnr)
  if #doc.requests == 0 then
    util.err("curlite: no requests in this buffer")
    return
  end

  ui.clear_inline(bufnr)
  local ok_count, fail_count, skip_count = 0, 0, 0

  exec.send_sequence(doc.requests, {
    bufnr = bufnr,
    stop_on_error = opts.stop_on_error,
    on_each = function(result)
      ui.set_inline(result, bufnr)
      if result.skipped then
        skip_count = skip_count + 1
      elseif result.response and result.response.status < 400 and not result.error then
        ok_count = ok_count + 1
      else
        fail_count = fail_count + 1
      end
      -- A skipped request has no response, so showing it would replace the
      -- last real one with an empty window and push a dead entry into the
      -- history. The inline status above already says it was skipped.
      if not opts.quiet and not result.skipped then
        ui.show(result)
      end
    end,
    on_finish = function(results)
      util.alert(
        ("curlite: ran %d request%s — %d ok, %d failed%s"):format(
          #results - skip_count,
          (#results - skip_count) == 1 and "" or "s",
          ok_count,
          fail_count,
          skip_count > 0 and (", %d skipped"):format(skip_count) or ""
        ),
        fail_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
      if opts.on_finish then
        opts.on_finish(results)
      end
    end,
  })
end

--- Send every request from the cursor's position down.
function M.run_from_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local doc = document(bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local _, idx = parser.request_at(doc, line)
  if not idx then
    util.err("curlite: no request found in this buffer")
    return
  end
  local rest = vim.list_slice(doc.requests, idx)
  exec.send_sequence(rest, {
    bufnr = bufnr,
    on_each = function(result)
      ui.set_inline(result, bufnr)
      if not result.skipped then
        ui.show(result)
      end
    end,
  })
end

--- Re-send the last request that was sent.
function M.replay()
  if not exec.last then
    util.err("curlite: nothing to replay")
    return
  end
  M.run(exec.last.request, { bufnr = exec.last.bufnr })
end

--- Show the fully-resolved request (and the curl line) without sending it.
function M.inspect()
  local req = request_at_cursor()
  if not req then
    util.err("curlite: no request found in this buffer")
    return
  end

  local cmd, err, resolved = exec.prepare(req)
  local lines = {}

  if err then
    lines = { "# could not prepare this request", "# " .. err }
    if resolved then
      table.insert(lines, "")
      table.insert(lines, ("%s %s"):format(resolved.method, resolved.url))
    end
  else
    lines = require("curlite.preview").lines(cmd, true)
  end

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "http"
  vim.bo[buf].modifiable = false

  local win_width = math.min(width + 4, vim.o.columns - 8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = win_width,
    height = math.min(#lines + 1, vim.o.lines - 8),
    row = math.floor(vim.o.lines * 0.15),
    col = math.floor((vim.o.columns - win_width) / 2),
    style = "minimal",
    border = config.get().ui.float.border,
    title = " resolved request ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true, silent = true })
  end
end

--- Pick the active environment.
function M.select_env()
  local source = vim.api.nvim_buf_get_name(0)
  local names = env.names(source)
  if #names == 0 then
    util.err(
      ("curlite: no environments found — create %s next to this file"):format(
        config.get().env.files[1]
      )
    )
    return
  end

  local current = env.current(source)
  vim.ui.select(names, {
    prompt = "Environment",
    format_item = function(name)
      return name == current and ("● " .. name) or ("  " .. name)
    end,
  }, function(choice)
    if choice then
      env.select(choice, source)
      util.alert(("curlite: environment → %s"):format(choice), vim.log.levels.INFO)
    end
  end)
end

--- The active environment's name, for a statusline component.
---@return string|nil
function M.current_env()
  return env.current(vim.api.nvim_buf_get_name(0))
end

--- Jump to a request in this buffer.
function M.pick_request()
  local doc = document()
  if #doc.requests == 0 then
    util.err("curlite: no requests in this buffer")
    return
  end

  local items = {}
  for idx, req in ipairs(doc.requests) do
    table.insert(items, {
      idx = idx,
      req = req,
      label = ("%-7s %s%s"):format(
        req.method,
        req.name and (req.name .. "  ") or "",
        req.url
      ),
    })
  end

  vim.ui.select(items, {
    prompt = "Request",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      pcall(vim.api.nvim_win_set_cursor, 0, { choice.req.url_line or choice.req.start_line, 0 })
      vim.cmd("normal! zz")
    end
  end)
end

--- Move the cursor to the next/previous request.
---@param delta integer
function M.goto_request(delta)
  local doc = document()
  if #doc.requests == 0 then
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local _, idx = parser.request_at(doc, line)
  idx = idx or 1

  -- When the cursor is already below a request's own line, `]r` should land on
  -- the next one, but `[r` should first come back to this one's start.
  local current = doc.requests[idx]
  local anchor = current.url_line or current.start_line
  if delta < 0 and line > anchor then
    idx = idx + 1
  end

  local target = doc.requests[idx + delta]
  if not target then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { target.url_line or target.start_line, 0 })
  vim.cmd("normal! zz")
end

--- Yank the request under the cursor as a curl command line.
---@param register string|nil
function M.copy_curl(register)
  local req = request_at_cursor()
  if not req then
    util.err("curlite: no request found in this buffer")
    return
  end
  local cmd, err = exec.prepare(req)
  if not cmd then
    util.err(("curlite: %s"):format(err or "could not build the request"))
    return
  end
  local line = require("curlite.curl").to_shell(cmd)
  vim.fn.setreg(register or "+", line)
  vim.fn.setreg('"', line)
  util.alert("curlite: curl command yanked", vim.log.levels.INFO)
end

--- Convert a curl command (from a register, or prompted for) into a request
--- and insert it at the cursor.
---@param register string|nil
function M.paste_curl(register)
  local text = vim.fn.getreg(register or "+")
  if not text or vim.trim(text) == "" then
    text = vim.fn.getreg('"')
  end
  if not text or not text:find("curl") then
    vim.ui.input({ prompt = "curl command: " }, function(input)
      if input and input ~= "" then
        M.insert_curl(input)
      end
    end)
    return
  end
  M.insert_curl(text)
end

--- Convert a curl command string and insert the `.http` form at the cursor.
---@param command string
function M.insert_curl(command)
  local lines, err = require("curlite.convert").from_curl(command)
  if not lines then
    util.err(("curlite: %s"):format(err))
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, 0 })
end

--- Open a throwaway `.http` buffer.
function M.scratchpad()
  local path = vim.fn.stdpath("data") .. "/curlite/scratchpad.http"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if vim.api.nvim_buf_line_count(0) == 1 and vim.api.nvim_get_current_line() == "" then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "### scratch",
      "GET https://httpbin.org/get",
      "Accept: application/json",
      "",
    })
  end
end

--- Toggle the response window.
function M.toggle()
  ui.toggle()
end

--- Close the response window, clear inline status and forget session state.
function M.clear()
  ui.clear_inline(vim.api.nvim_get_current_buf())
  ui.reset()
  exec.reset()
  util.notify("curlite: cleared", vim.log.levels.INFO)
end

--- Cancel every in-flight request.
function M.cancel()
  local n = exec.cancel_all()
  util.alert(("curlite: cancelled %d request%s"):format(n, n == 1 and "" or "s"), vim.log.levels.INFO)
end

--- Run a request headlessly and hand the result to a callback. Useful from a
--- keymap, timer or autocommand without opening the UI.
---@param spec string|curlite.Request  raw `.http` text, or a parsed request
---@param cb fun(result: curlite.Result)|nil
function M.inline(spec, cb)
  local req = spec
  if type(spec) == "string" then
    local doc = parser.parse(vim.split(spec, "\n", { plain = true }), vim.fn.getcwd() .. "/inline.http")
    req = doc.requests[1]
    if not req then
      util.err("curlite: inline spec contained no request")
      return
    end
  end
  exec.send(req, { on_done = cb })
end

--- Same, but blocks and returns the result.
---@param spec string|curlite.Request
---@param timeout_ms integer|nil
---@return curlite.Result|nil
function M.inline_sync(spec, timeout_ms)
  local req = spec
  if type(spec) == "string" then
    local doc = parser.parse(vim.split(spec, "\n", { plain = true }), vim.fn.getcwd() .. "/inline.http")
    req = doc.requests[1]
    if not req then
      return nil
    end
  end
  return exec.send_sync(req, timeout_ms)
end

--- Run every request in a file and report the assertions, for CI-ish use.
---@param path string
---@param cb fun(summary: { total: integer, passed: integer, failed: integer, results: curlite.Result[] })|nil
function M.run_file(path, cb)
  local doc, err = parser.parse_file(vim.fn.expand(path))
  if not doc then
    util.err(("curlite: %s"):format(err))
    return
  end
  local scripts = require("curlite.scripts")
  exec.send_sequence(doc.requests, {
    on_finish = function(results)
      local passed, failed = 0, 0
      for _, r in ipairs(results) do
        local p, f = scripts.tally(r.script)
        passed, failed = passed + p, failed + f
        if r.error then
          failed = failed + 1
        end
      end
      local summary = { total = #results, passed = passed, failed = failed, results = results }
      if cb then
        cb(summary)
      else
        util.alert(
          ("curlite: %s — %d request%s, %d passed, %d failed"):format(
            vim.fn.fnamemodify(path, ":t"),
            #results,
            #results == 1 and "" or "s",
            passed,
            failed
          ),
          failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
        )
      end
    end,
  })
end

--- ---------------------------------------------------------------- wiring

local function register_filetypes()
  local cfg = config.get().filetype
  if not cfg.register then
    return
  end
  local spec = {}
  if next(cfg.extensions or {}) then
    spec.extension = {}
    for _, ext in ipairs(cfg.extensions) do
      spec.extension[ext] = "http"
    end
  end
  if next(cfg.patterns or {}) then
    spec.pattern = cfg.patterns
  end
  if next(spec) then
    vim.filetype.add(spec)
  end
end

--- Apply the buffer-local keymaps to an http buffer.
---@param bufnr integer
function M.attach(bufnr)
  local cfg = config.get()
  local maps = cfg.keymaps

  require("curlite.highlight").attach(bufnr)

  if maps ~= false then
    local function map(lhs, fn, desc)
      if lhs and lhs ~= false then
        vim.keymap.set("n", lhs, fn, {
          buffer = bufnr,
          silent = true,
          desc = "curlite: " .. desc,
        })
      end
    end

    map(maps.send, M.run_at_cursor, "send request")
    map(maps.send_all, M.run_all, "send all requests")
    map(maps.replay, M.replay, "replay last request")
    map(maps.toggle, M.toggle, "toggle response window")
    map(maps.select_env, M.select_env, "select environment")
    map(maps.pick_request, M.pick_request, "pick request")
    map(maps.copy_curl, function()
      M.copy_curl()
    end, "yank as curl")
    map(maps.paste_curl, function()
      M.paste_curl()
    end, "paste curl as request")
    map(maps.inspect, M.inspect, "inspect resolved request")
    map(maps.hover, M.inspect, "preview request")
    map(maps.clear, M.clear, "clear")
    map(maps.next_request, function()
      M.goto_request(1)
    end, "next request")
    map(maps.prev_request, function()
      M.goto_request(-1)
    end, "previous request")
  end

  if type(cfg.on_attach) == "function" then
    cfg.on_attach(bufnr)
  end
end

local SUBCOMMANDS = {
  send = M.run_at_cursor,
  all = M.run_all,
  rest = M.run_from_cursor,
  replay = M.replay,
  inspect = M.inspect,
  env = M.select_env,
  pick = M.pick_request,
  toggle = M.toggle,
  open = function()
    ui.toggle()
    ui.focus()
  end,
  close = ui.close,
  clear = M.clear,
  cancel = M.cancel,
  curl = function()
    M.copy_curl()
  end,
  paste = function()
    M.paste_curl()
  end,
  scratch = M.scratchpad,
  log = function()
    vim.cmd("edit " .. vim.fn.fnameescape(util.log_path()))
  end,
  health = function()
    vim.cmd("checkhealth curlite")
  end,
}

local function register_commands()
  local names = vim.tbl_keys(SUBCOMMANDS)
  table.sort(names)

  vim.api.nvim_create_user_command("Curlite", function(opts)
    local sub = opts.fargs[1] or "send"
    local fn = SUBCOMMANDS[sub]
    if not fn then
      util.err(("curlite: unknown subcommand `%s` (try: %s)"):format(sub, table.concat(names, ", ")))
      return
    end
    fn()
  end, {
    nargs = "?",
    desc = "curlite",
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, names)
    end,
  })

  vim.api.nvim_create_user_command("CurliteRun", function(opts)
    if opts.args ~= "" then
      M.run_file(opts.args)
    else
      M.run_at_cursor()
    end
  end, { nargs = "?", complete = "file", desc = "curlite: run a request or a whole file" })
end

local function register_autocmds()
  local group = vim.api.nvim_create_augroup("curlite", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.get().filetypes,
    callback = function(args)
      M.attach(args.buf)
    end,
  })

  -- Stale inline status is worse than none: once the buffer changes, the line
  -- the extmark sits on may not be the request that produced it.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "*.http,*.rest",
    callback = function(args)
      ui.clear_inline(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      parser.invalidate(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      ui.setup_highlights()
      require("curlite.highlight").setup_highlights()
    end,
  })
end

--- Set curlite up. Safe to call more than once.
---@param opts curlite.Config|nil
function M.setup(opts)
  config.setup(opts)
  register_filetypes()
  ui.setup_highlights()
  require("curlite.highlight").setup_highlights()

  if not did_setup then
    register_commands()
    did_setup = true
  end
  register_autocmds()

  -- A buffer opened before setup ran still deserves its keymaps.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.tbl_contains(config.get().filetypes, vim.bo[buf].filetype)
    then
      M.attach(buf)
    end
  end

  return M
end

-- Re-exported so `require("curlite").variables.responses` and friends work.
M.parser = parser
M.exec = exec
M.env = env
M.ui = ui
M.variables = variables

return M
