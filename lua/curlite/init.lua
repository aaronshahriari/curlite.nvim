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

-- The http file most recently entered. The response window, the confirm
-- dialog and the picker have no path of their own, so anything asked from
-- them is answered for this file's project.
---@type string|nil
local last_source = nil

-- http file buffers this session has already seen, as a set of buffer
-- numbers. Used to tell a genuinely fresh open from the many other things
-- that fire `FileType http`.
local entered = {}

--- Is this buffer the file on disk, rather than one of curlite's own?
---
--- The confirm dialog, the inspect float and the hover preview are scratch
--- buffers given `filetype=http` for the highlighting, so they raise
--- `FileType` exactly like opening a request file does. They are not files,
--- and must never be mistaken for one.
---@param buf integer
---@return boolean
local function is_file_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

--- Is another http file from the same project already open?
---@param buf integer  the buffer to ignore
---@param root string
---@return boolean
local function project_is_open(buf, root)
  for other in pairs(entered) do
    if other ~= buf and vim.api.nvim_buf_is_loaded(other) and is_file_buffer(other) then
      if env.root(vim.api.nvim_buf_get_name(other)) == root then
        return true
      end
    end
  end
  return false
end

--- Remember `buf` as an http file we are working in, if that is what it is.
---@param buf integer
local function note_buffer(buf)
  if is_file_buffer(buf) then
    entered[buf] = true
    last_source = vim.api.nvim_buf_get_name(buf)
  end
end

--- Should loading `buf` drop the environment chosen for its project?
---
--- Entering a project starts with no environment, every time: carrying the
--- last one over is how a request meant for dev ends up at prod. But only a
--- genuine arrival counts. Re-reading a buffer you are working in (`:e`,
--- 'autoread' picking up a change on disk, a formatter, a branch switch) and
--- opening a second `.http` file beside the first are not arrivals, and
--- throwing the choice away there is just an unexplained reset mid-task.
---@param buf integer
---@return boolean
local function arriving(buf)
  if not is_file_buffer(buf) then
    return false
  end
  if entered[buf] then
    return false
  end
  return not project_is_open(buf, env.root(vim.api.nvim_buf_get_name(buf)))
end

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
      util.emit(
        "duplicate_names",
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
      util.emit("request_sent", ("curlite: %s %s"):format(req.method, req.url), {
        data = { method = req.method, url = req.url, name = req.name },
      })
      ui.flash(req, bufnr)
      if not opts.quiet then
        ui.show_pending(req)
      end
    end,
    on_done = function(result)
      -- With `flash_timeout = 0` the flash is held until the response lands,
      -- which is here. A non-zero timeout has its own timer and this is a
      -- no-op by the time it fires.
      if (config.get().ui.flash_timeout or 0) == 0 then
        ui.clear_flash()
      end
      ui.set_inline(result, bufnr)

      if result.skipped then
        util.emit(
          "request_skipped",
          "curlite: request skipped"
            .. (result.script and result.script.reason and (": " .. result.script.reason) or ""),
          { data = { result = result } }
        )
        return
      end

      if not opts.quiet then
        ui.show(result)
      end

      if result.response then
        local level = result.response.status >= 400 and vim.log.levels.WARN or vim.log.levels.INFO
        util.emit(
          "request_done",
          ("curlite: %d %s in %s"):format(
            result.response.status,
            result.response.status_text,
            util.human_time(result.response.duration_ms)
          ),
          { level = level, data = { result = result, status = result.response.status } }
        )
      end

      if opts.on_done then
        opts.on_done(result)
      end
    end,
  }
end

--- Run `fn` once this project's environment has been chosen.
---
--- With `env.require_selection` on (the default) and environments defined,
--- the first send in a buffer opens the picker instead of going out against
--- whichever environment happened to be selected somewhere else. Picking one
--- -- or picking "no environment" deliberately -- then runs `fn`.
---@param source string|nil
---@param fn fun()
local function with_env(source, fn)
  local cfg = config.get().env
  if not cfg.require_selection or env.chosen(source) or #env.names(source) == 0 then
    return fn()
  end
  util.emit("env_required", "curlite: select an environment first")
  -- `source` is passed on rather than left to the picker to work out from the
  -- current buffer: a replay, a `:CurliteRun path` or a send triggered from
  -- the response window is about *that* file's project, and storing the
  -- choice against the wrong one looks exactly like the environment unsetting
  -- itself.
  M.select_env({
    source = source,
    on_choice = function()
      fn()
    end,
  })
end

--- -------------------------------------------------------------------- API

--- Send a specific request.
---@param req curlite.Request
---@param opts table|nil
function M.run(req, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  with_env(req.source or vim.api.nvim_buf_get_name(bufnr), function()
    exec.send(req, ui_handlers(bufnr, opts))
  end)
end

--- Send the request under the cursor.
---@param opts table|nil
function M.run_at_cursor(opts)
  local req = request_at_cursor()
  if not req then
    util.emit("no_request", "curlite: no request found in this buffer")
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
    util.emit("no_request", "curlite: no requests in this buffer")
    return
  end

  ui.clear_inline(bufnr)
  local ok_count, fail_count, skip_count = 0, 0, 0

  with_env(doc.source, function()
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
        util.emit(
          "run_summary",
          ("curlite: ran %d request%s — %d ok, %d failed%s"):format(
            #results - skip_count,
            (#results - skip_count) == 1 and "" or "s",
            ok_count,
            fail_count,
            skip_count > 0 and (", %d skipped"):format(skip_count) or ""
          ),
          {
            level = fail_count > 0 and vim.log.levels.WARN or vim.log.levels.INFO,
            data = { ok = ok_count, failed = fail_count, skipped = skip_count },
          }
        )
        if opts.on_finish then
          opts.on_finish(results)
        end
      end,
    })
  end)
end

--- Send every request from the cursor's position down.
function M.run_from_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local doc = document(bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local _, idx = parser.request_at(doc, line)
  if not idx then
    util.emit("no_request", "curlite: no request found in this buffer")
    return
  end
  local rest = vim.list_slice(doc.requests, idx)
  with_env(doc.source, function()
    exec.send_sequence(rest, {
      bufnr = bufnr,
      on_each = function(result)
        ui.set_inline(result, bufnr)
        if not result.skipped then
          ui.show(result)
        end
      end,
    })
  end)
end

--- Re-send the last request that was sent.
function M.replay()
  if not exec.last then
    util.emit("no_request", "curlite: nothing to replay")
    return
  end
  M.run(exec.last.request, { bufnr = exec.last.bufnr })
end

--- Show the fully-resolved request (and the curl line) without sending it.
function M.inspect()
  local req = request_at_cursor()
  if not req then
    util.emit("no_request", "curlite: no request found in this buffer")
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

--- Hover: the resolved request under the cursor, in an LSP-style popup.
---
--- Deliberately not `inspect`: this is the small, cursor-anchored float that
--- closes when you move, exactly like `vim.lsp.buf.hover()`. It shows the
--- request and nothing else -- no curl line. Press `K` again to step into it.
function M.hover()
  local req = request_at_cursor()
  if not req then
    util.emit("no_request", "curlite: no request found in this buffer")
    return
  end

  local cmd, err, resolved = exec.prepare(req)
  local body
  if err then
    body = { ("# %s"):format(err) }
    if resolved then
      table.insert(body, ("%s %s"):format(resolved.method, resolved.url))
    end
  else
    body = require("curlite.preview").lines(cmd, false)
  end

  -- With an `http` treesitter parser the markdown fence gets highlighted by
  -- injection, the way an LSP hover does it. Without one, drop the fence and
  -- let `syntax/http.vim` colour the buffer instead -- a bare ```http block
  -- would otherwise render as plain text.
  local contents, syntax = body, "http"
  local ok, added = pcall(vim.treesitter.language.add, "http")
  if ok and added then
    contents = { "```http" }
    vim.list_extend(contents, body)
    table.insert(contents, "```")
    syntax = "markdown"
  end

  -- `BufLeave` must stay out of `close_events`: pressing `K` again focuses the
  -- float, which leaves the request buffer, and that close autocmd is
  -- unconditional -- it would shut the window the second before you land in
  -- it. `open_floating_preview` registers its own `BufLeave` handler that
  -- ignores the float's own buffer, so leaving for anywhere else still closes.
  local float_buf, float_win = vim.lsp.util.open_floating_preview(contents, syntax, {
    border = config.get().ui.float.border,
    focus_id = "curlite_hover",
    wrap = true,
    max_width = math.max(40, math.min(100, vim.o.columns - 10)),
    max_height = math.max(5, math.floor(vim.o.lines * 0.5)),
    close_events = { "CursorMoved", "CursorMovedI", "InsertCharPre", "WinScrolled" },
  })

  -- `q` comes from `open_floating_preview`; `<Esc>` matches curlite's other
  -- floats. Setting it on every call is harmless -- the second `K` hands back
  -- the same window. The buffer check skips the third path through
  -- `open_floating_preview`, which returns the *source* buffer when it steps
  -- back out of an already-focused float; mapping `<Esc>` there would shadow it
  -- in the request buffer.
  if
    float_win
    and vim.api.nvim_win_is_valid(float_win)
    and vim.api.nvim_win_get_buf(float_win) == float_buf
  then
    vim.keymap.set("n", "<Esc>", function()
      pcall(vim.api.nvim_win_close, float_win, true)
    end, { buffer = float_buf, nowait = true, silent = true })
  end

  return float_buf, float_win
end

--- Pick the active environment.
---
--- Opens the two-pane picker: environments on the left, the variables each one
--- resolves to on the right, so you can see what you are switching to.
---@param opts { source: string|nil, on_choice: fun(name: string|nil), quiet: boolean }|nil
function M.select_env(opts)
  opts = opts or {}
  local source = opts.source
  if not source or source == "" then
    source = M.source_hint()
  end
  local names = env.names(source)
  if #names == 0 then
    util.emit(
      "env_missing",
      ("curlite: no environments found — create %s next to this file"):format(
        config.get().env.files[1]
      )
    )
    return
  end

  require("curlite.picker").open({
    source = source,
    -- Passed straight through to the telescope front end, so a caller can
    -- hand it a theme or a layout without going near the config.
    telescope = opts.telescope,
    on_choice = function(name)
      env.select(name, source)
      if not opts.quiet then
        util.emit(
          "env_selected",
          name and ("curlite: environment → %s"):format(name)
            or "curlite: no environment — only shared variables will resolve",
          { data = { env = name } }
        )
      end
      if opts.on_choice then
        opts.on_choice(name)
      end
    end,
  })
end

--- The `.http` file whose project the current window is about.
---
--- The current buffer when it is a request file, and otherwise the http file
--- most recently worked in -- the response window, the confirm dialog and the
--- inspect float have no path of their own, and resolving them to the working
--- directory points the environment at a project that may not be the one on
--- screen.
---@return string
function M.source_hint()
  local buf = vim.api.nvim_get_current_buf()
  if is_file_buffer(buf) and vim.tbl_contains(config.get().filetypes, vim.bo[buf].filetype) then
    return vim.api.nvim_buf_get_name(buf)
  end
  if last_source and vim.fn.filereadable(last_source) == 1 then
    return last_source
  end
  return vim.api.nvim_buf_get_name(buf)
end

--- The active environment's name, for a statusline component.
---@param source string|nil  the file to report for; the current one by default
---@return string|nil
function M.current_env(source)
  return env.current(source or M.source_hint())
end

--- Jump to a request in this buffer.
function M.pick_request()
  local doc = document()
  if #doc.requests == 0 then
    util.emit("no_request", "curlite: no requests in this buffer")
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

--- Yank the request under the cursor as a curl command line. A named request
--- keeps its `###` header as a shell comment so the shared command has context.
---@param register string|nil
function M.copy_curl(register)
  local req = request_at_cursor()
  if not req then
    util.emit("no_request", "curlite: no request found in this buffer")
    return
  end
  local cmd, err = exec.prepare(req)
  if not cmd then
    util.emit("request_error", ("curlite: %s"):format(err or "could not build the request"))
    return
  end
  local text = require("curlite.curl").to_shell(cmd)
  if req.name and req.name ~= "" then
    text = ("### %s\n%s"):format(req.name, text)
  end
  vim.fn.setreg(register or "+", text)
  vim.fn.setreg('"', text)
  util.emit("yank", "curlite: curl command yanked")
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
    util.emit("parse_error", ("curlite: %s"):format(err))
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, 0 })
end

--- Write `.http` lines into a buffer at the cursor, and leave the cursor on
--- the request itself so it can be sent straight away.
---
--- A block is kept off the back of whatever the cursor was sitting on with a
--- blank line, and an empty buffer is filled rather than pushed down.
---@param lines string[]
---@param bufnr integer|nil
---@param win integer|nil
---@return integer|nil row  the line the request line landed on
function M.insert_lines(lines, bufnr, win)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.bo[bufnr].modifiable then
    util.emit("error", "curlite: that buffer cannot be written to")
    return nil
  end
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr) then
    win = nil
    for _, candidate in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(candidate) == bufnr then
        win = candidate
        break
      end
    end
  end

  local body = vim.deepcopy(lines)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  local at

  if count == 1 and vim.trim(first) == "" then
    at = 0
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, body)
  else
    local row = win and vim.api.nvim_win_get_cursor(win)[1] or count
    local current = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    if vim.trim(current) ~= "" then
      table.insert(body, 1, "")
    end
    at = row
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, body)
  end

  local row = at + require("curlite.openapi").request_line(body)
  if win then
    local last = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(row, last), 0 })
  end
  return row
end

--- Import requests from an OpenAPI / Swagger description.
---
--- `target` is a path, an `http(s)` URL (a Swagger UI page is followed to the
--- spec it serves), or nil to use `openapi.spec`, or failing that the nearest
--- `openapi.json`/`openapi.yaml` above the file being edited. The picker then
--- lists every operation with a preview of the block it writes, and `<CR>`
--- drops that block in at the cursor.
---@param target string|nil
---@param opts { telescope: table|nil, on_insert: fun(ops: table[])|nil }|nil
function M.openapi(target, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if not vim.bo[bufnr].modifiable then
    util.emit(
      "openapi_error",
      "curlite: this buffer cannot be written to — open the .http file you want the request in"
    )
    return
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local source = name ~= "" and name or M.source_hint()
  local openapi = require("curlite.openapi")

  openapi.load(target, source, function(spec, err)
    if not spec then
      util.emit("openapi_error", ("curlite: %s"):format(err))
      return
    end

    local ops = openapi.operations(spec, { source = source })
    if #ops == 0 then
      util.emit(
        "openapi_error",
        ("curlite: %s describes no operations"):format(spec.__source or "that spec")
      )
      return
    end

    -- Headers the environment already sends are left out of the generated
    -- block, so an imported request does not override a real `Authorization`
    -- with the spec's placeholder.
    local env_headers = env.active_headers(source)

    require("curlite.openapi_picker").open({
      spec = spec,
      operations = ops,
      source = source,
      env_headers = env_headers,
      telescope = opts.telescope,
      on_choice = function(chosen)
        local lines = {}
        for _, op in ipairs(chosen) do
          vim.list_extend(lines, openapi.block(op, { env_headers = env_headers }))
        end
        if M.insert_lines(lines, bufnr, win) then
          util.emit(
            "openapi_inserted",
            ("curlite: inserted %d request%s"):format(#chosen, #chosen == 1 and "" or "s"),
            { data = { operations = chosen } }
          )
        end
        if opts.on_insert then
          opts.on_insert(chosen)
        end
      end,
    })
  end)
end

--- Format the current .http request buffer.
function M.format()
  require("curlite.request_format").buffer(0)
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

--- Open the last response body in its own tab, as a scratch buffer to run
--- `:%!jq ...` and friends over.
function M.scratch_body()
  ui.scratch_body()
end

--- Close the response window, clear inline status and forget session state.
function M.clear()
  ui.clear_inline(vim.api.nvim_get_current_buf())
  ui.reset()
  exec.reset()
  util.emit("cleared", "curlite: cleared")
end

--- Cancel every in-flight request.
function M.cancel()
  local n = exec.cancel_all()
  util.emit("cancelled", ("curlite: cancelled %d request%s"):format(n, n == 1 and "" or "s"), {
    data = { count = n },
  })
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
      util.emit("no_request", "curlite: inline spec contained no request")
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
    util.emit("parse_error", ("curlite: %s"):format(err))
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
        util.emit(
          "run_summary",
          ("curlite: %s — %d request%s, %d passed, %d failed"):format(
            vim.fn.fnamemodify(path, ":t"),
            #results,
            #results == 1 and "" or "s",
            passed,
            failed
          ),
          { level = failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO, data = summary }
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
  require("curlite.complete").attach(bufnr)

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
    map(maps.send_enter, M.run_at_cursor, "send request")
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
    map(maps.openapi, function()
      M.openapi()
    end, "insert a request from an OpenAPI spec")
    map(maps.inspect, M.inspect, "inspect resolved request")
    map(maps.hover, M.hover, "hover request preview")
    map(maps.clear, M.clear, "clear")
    map(maps.format, M.format, "format request file")
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

--- Print every notification event, its default level and whether it is
--- currently getting through. This is the list `notify.events` is keyed by.
function M.events()
  local notify = require("curlite.notify")
  local names = vim.tbl_keys(notify.events)
  table.sort(names)

  local lines = { { "curlite notification events\n", "Title" } }
  for _, name in ipairs(names) do
    local spec = notify.events[name]
    local label = ({ [0] = "trace", "debug", "info", "warn", "error" })[spec.level] or "?"
    local on = notify.enabled(name, spec.level, { msg = "" })
    table.insert(lines, { ("  %-16s "):format(name), on and "DiagnosticOk" or "Comment" })
    table.insert(lines, { ("%-6s "):format(label), "Comment" })
    table.insert(lines, { on and "shown  " or "hidden ", on and "DiagnosticOk" or "Comment" })
    table.insert(lines, { spec.desc .. (spec.important and "  (important)" or "") .. "\n", "Comment" })
  end
  vim.api.nvim_echo(lines, true, {})
end

local SUBCOMMANDS = {
  -- The four that take an options *table* are wrapped, so the argument the
  -- command line hands a subcommand cannot arrive where a table is expected.
  send = function()
    M.run_at_cursor()
  end,
  all = function()
    M.run_all()
  end,
  rest = M.run_from_cursor,
  replay = M.replay,
  inspect = M.inspect,
  hover = M.hover,
  env = function()
    M.select_env()
  end,
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
  format = M.format,
  openapi = function(args)
    M.openapi(args)
  end,
  scratch = M.scratchpad,
  body = M.scratch_body,
  log = function()
    vim.cmd("edit " .. vim.fn.fnameescape(util.log_path()))
  end,
  health = function()
    vim.cmd("checkhealth curlite")
  end,
  events = M.events,
}

local function register_commands()
  local names = vim.tbl_keys(SUBCOMMANDS)
  table.sort(names)

  vim.api.nvim_create_user_command("Curlite", function(opts)
    local sub = opts.fargs[1] or "send"
    local fn = SUBCOMMANDS[sub]
    if not fn then
      util.emit(
        "error",
        ("curlite: unknown subcommand `%s` (try: %s)"):format(sub, table.concat(names, ", "))
      )
      return
    end
    -- Anything after the subcommand is the subcommand's argument, which is
    -- how `:Curlite openapi ./api/openapi.yaml` reaches it. The ones that
    -- take no argument are wrapped in `SUBCOMMANDS` so this cannot reach a
    -- function expecting an options table.
    local rest = table.concat(vim.list_slice(opts.fargs, 2), " ")
    fn(rest ~= "" and rest or nil)
  end, {
    nargs = "*",
    desc = "curlite",
    complete = function(lead, line)
      -- Past the subcommand, complete what that subcommand takes: a spec for
      -- `openapi`, nothing for the rest.
      local sub = line:match("^%s*%u%a*%s+(%S+)%s")
      if sub then
        if sub == "openapi" then
          return vim.fn.getcompletion(lead, "file")
        end
        return {}
      end
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

  vim.api.nvim_create_user_command("CurliteOpenapi", function(opts)
    M.openapi(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    complete = "file",
    desc = "curlite: insert a request from an OpenAPI spec",
  })
end

local function register_autocmds()
  local group = vim.api.nvim_create_augroup("curlite", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.get().filetypes,
    callback = function(args)
      if arriving(args.buf) then
        env.forget(vim.api.nvim_buf_get_name(args.buf))
      end
      note_buffer(args.buf)
      M.attach(args.buf)
    end,
  })

  -- Which http file you are in is what answers "which environment?" from the
  -- response window, the picker and the statusline.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if
        is_file_buffer(args.buf)
        and vim.tbl_contains(config.get().filetypes, vim.bo[args.buf].filetype)
      then
        last_source = vim.api.nvim_buf_get_name(args.buf)
      end
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
      -- A buffer number is reused once the buffer is gone, so forgetting it
      -- here is what keeps "have I seen this one?" honest.
      entered[args.buf] = nil
    end,
  })

  -- `format.on_save` is read inside the callback rather than guarding the
  -- autocmd, so toggling it at runtime takes effect without a re-setup.
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    callback = function(args)
      if not (config.get().format or {}).on_save then
        return
      end
      if not vim.tbl_contains(config.get().filetypes, vim.bo[args.buf].filetype) then
        return
      end
      require("curlite.request_format").buffer(args.buf)
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
      -- The `FileType` autocmd above was registered too late to see this
      -- buffer -- with lazy loading, setup *is* the FileType handler -- so
      -- record it here, or the next file opened looks like a fresh arrival
      -- and drops the environment chosen in this one.
      note_buffer(buf)
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
