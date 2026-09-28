-- Rendering and highlighting of the response window. These use a fabricated
-- result rather than a real request, so they are fast and deterministic.

local response = require("curlite.response")
local ui = require("curlite.ui")

local NS_NAME = "curlite"

--- A plausible result to render.
---@param overrides table|nil
local function fake(overrides)
  local headers = response.ci_headers({
    ["Content-Type"] = "application/json",
    ["Content-Length"] = "27",
    ["Set-Cookie"] = "session=abc123; Path=/",
    ["X-Request-Id"] = "req-1",
  })
  local result = {
    raw = { name = "SAMPLE", url_line = 2, source = "/tmp/curlite-ui/t.http" },
    request = {
      method = "POST",
      url = "https://api.example.com/things?page=2",
      headers = { ["Content-Type"] = "application/json", ["X-Trace"] = "t-1" },
      header_order = { "Content-Type", "X-Trace" },
    },
    command = { sent_body = '{"name":"aaron"}' },
    response = {
      status = 201,
      status_text = "Created",
      http_version = "HTTP/2",
      headers = headers,
      header_order = { "Content-Type", "Content-Length", "Set-Cookie", "X-Request-Id" },
      raw_headers = "HTTP/2 201 Created\r\nContent-Type: application/json\r\n",
      hops = {
        {
          http_version = "HTTP/2",
          status = 301,
          status_text = "Moved Permanently",
          headers = response.ci_headers({ Location = "/things?page=2" }),
          header_order = { "Location" },
          raw = {},
        },
        {
          http_version = "HTTP/2",
          status = 201,
          status_text = "Created",
          headers = headers,
          header_order = { "Content-Type", "Content-Length", "Set-Cookie", "X-Request-Id" },
          raw = { { name = "Set-Cookie", value = "session=abc123; Path=/" } },
        },
      },
      body = '{\n  "id": 7,\n  "ok": true\n}',
      json = { id = 7, ok = true },
      cookies = { session = "abc123" },
      stats = {
        http_code = 201,
        http_version = "2",
        method = "POST",
        content_type = "application/json",
        url_effective = "https://api.example.com/things?page=2",
        num_redirects = 1,
        num_connects = 1,
        remote_ip = "93.184.216.34",
        remote_port = 443,
        local_port = 51234,
        size_download = 27,
        size_upload = 16,
        size_header = 120,
        size_request = 240,
        speed_download = 4096,
        speed_upload = 512,
        time_namelookup = 0.01,
        time_connect = 0.02,
        time_appconnect = 0.06,
        time_pretransfer = 0.061,
        time_starttransfer = 0.12,
        time_redirect = 0.03,
        time_total = 0.14,
        ssl_verify_result = 0,
      },
      duration_ms = 140,
      verbose = table.concat({
        "*   Trying 93.184.216.34:443...",
        "* ALPN: server accepted h2",
        "> POST /things?page=2 HTTP/2",
        "> content-type: application/json",
        "{ [16 bytes data]",
        "< HTTP/2 201",
        "< content-type: application/json",
        "} [27 bytes data]",
      }, "\n"),
      body_path = "/tmp/nope",
      error = nil,
    },
    script = {
      logs = { "a log line", "another one" },
      tests = {
        { name = "this one passes", ok = true },
        { name = "this one fails", ok = false, message = "evaluated to false" },
      },
      skip = false,
      abort = false,
    },
    skipped = false,
    aborted = false,
    error = nil,
    duration_ms = 140,
  }
  return vim.tbl_deep_extend("force", result, overrides or {})
end

--- Render `pane` and report what is coloured.
---@return { lines: string[], uncoloured: string[], groups: table<string, boolean>, filetype: string }
local function render(pane, result)
  ui.show(result or fake(), { pane = pane, push = false })
  local win = ui.winid
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local ns = vim.api.nvim_get_namespaces()[NS_NAME]
  local marked, groups = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    marked[m[2] + 1] = true
    if m[4] and m[4].hl_group then
      groups[m[4].hl_group] = true
    end
  end

  local uncoloured = {}
  vim.api.nvim_win_call(win, function()
    for i, text in ipairs(lines) do
      if not marked[i] and vim.trim(text) ~= "" then
        local coloured = false
        for col = 1, #text do
          if vim.fn.synIDattr(vim.fn.synID(i, col, 1), "name") ~= "" then
            coloured = true
            break
          end
        end
        if not coloured then
          table.insert(uncoloured, ("line %d: %q"):format(i, text))
        end
      end
    end
  end)

  return { lines = lines, uncoloured = uncoloured, groups = groups, filetype = vim.bo[buf].filetype }
end

local M = {}

function M.every_pane_is_fully_coloured(t)
  for _, pane in ipairs({ "body", "headers", "all", "stats", "verbose", "script" }) do
    local out = render(pane)
    t.eq(
      out.uncoloured,
      {},
      ("the %s pane has uncoloured lines:\n  %s"):format(pane, table.concat(out.uncoloured, "\n  "))
    )
  end
  ui.close()
end

function M.marks_that_run_to_end_of_line_are_applied(t)
  -- Regression: these were created with `end_row = line + 1, end_col = nil`,
  -- which is rejected on the final line of a buffer -- and the rejection was
  -- swallowed, so every such mark vanished.
  local out = render("stats")
  t.truthy(out.groups.CurliteValue, "stats values should be highlighted")
  t.truthy(out.groups.CurliteLabel, "stats labels should be highlighted")
  t.truthy(out.groups.CurliteTotal, "the Total row should stand out")
  t.truthy(out.groups.CurliteUrl, "the URL row should be highlighted")
  t.truthy(out.groups.CurliteSection, "section headings should be highlighted")
  ui.close()
end

function M.script_pane_highlights_logs_and_tests(t)
  local out = render("script")
  t.truthy(out.groups.CurliteLogLine, "log lines should be highlighted")
  t.truthy(out.groups.CurliteTestPass)
  t.truthy(out.groups.CurliteTestFail)
  t.truthy(out.groups.CurliteTestDetail, "a failure's detail line should be highlighted")
  ui.close()
end

function M.status_is_graded_by_class(t)
  local out = render("headers")
  -- A 301 hop and a 201 hop, so both gradings appear.
  t.truthy(out.groups.CurliteRedirect, "the 301 hop should be graded as a redirect")
  t.truthy(out.groups.CurliteSuccess, "the 201 should be graded as success")
  t.truthy(out.groups.CurliteStatusLine)
  t.truthy(out.groups.CurliteHeaderName)
  t.truthy(out.groups.CurliteHeaderValue)
  ui.close()
end

function M.error_statuses_are_graded(t)
  local r = fake()
  r.response.status = 503
  r.response.status_text = "Service Unavailable"
  r.response.hops = { {
    http_version = "HTTP/2",
    status = 503,
    status_text = "Service Unavailable",
    headers = require("curlite.response").ci_headers({}),
    header_order = {},
    raw = {},
  } }
  t.truthy(render("headers", r).groups.CurliteServerError)

  r.response.status = 404
  r.response.hops[1].status = 404
  t.truthy(render("headers", r).groups.CurliteClientError)
  ui.close()
end

function M.all_pane_shows_request_then_response(t)
  local out = render("all")
  t.match(out.lines[1], "^POST https://api%.example%.com/things%?page=2$")
  t.truthy(out.groups.CurliteMethod)
  t.truthy(out.groups.CurliteUrl)
  t.truthy(out.groups.CurliteRule, "the request/response divider should be highlighted")
  -- The body that was sent appears before the divider.
  t.truthy(vim.tbl_contains(out.lines, '{"name":"aaron"}'))
  ui.close()
end

function M.body_pane_holds_only_the_body(t)
  local out = render("body")
  t.eq(table.concat(out.lines, "\n"), '{\n  "id": 7,\n  "ok": true\n}')
  t.eq(out.filetype, "json", "so treesitter and jq both work on it")
  ui.close()
end

function M.slash_filters_only_a_json_body(t)
  ui.show(fake(), { pane = "body", push = true })
  t.truthy(ui.jq_filter_available(), "JSON Body enables jq")

  ui.set_pane("headers")
  t.falsy(ui.jq_filter_available(), "Headers keeps normal search")
  local buf = vim.api.nvim_win_get_buf(ui.winid)
  local mapping
  vim.api.nvim_buf_call(buf, function()
    mapping = vim.fn.maparg("/", "n", false, true)
  end)
  t.eq(mapping.expr, 1)
  t.eq(mapping.callback(), "/", "the mapping falls through to native /")

  local text = fake()
  text.response.body = "plain response"
  text.response.json = nil
  text.response.headers = require("curlite.response").ci_headers({ ["Content-Type"] = "text/plain" })
  ui.show(text, { pane = "body", push = true })
  t.falsy(ui.jq_filter_available(), "a plain-text Body keeps normal search")
  ui.reset()
end

function M.stats_pane_reports_the_timing_breakdown(t)
  local text = table.concat(render("stats").lines, "\n")
  for _, label in ipairs({
    "DNS lookup",
    "TCP connect",
    "TLS handshake",
    "Waiting (TTFB)",
    "Download",
    "Total",
    "Remote",
    "Cookies set",
  }) do
    t.match(text, vim.pesc(label))
  end
  t.match(text, "Redirects")
  t.match(text, "93%.184%.216%.34:443")
  ui.close()
end

function M.winbar_shows_status_timing_and_tally(t)
  ui.show(fake(), { pane = "body", push = true })
  local winbar = vim.wo[ui.winid].winbar
  t.match(winbar, "201 Created")
  t.match(winbar, "140ms")
  t.match(winbar, "1/2", "the assertion tally belongs in the winbar")
  t.match(winbar, "CurliteTestFail", "a failing tally should be red")
  -- Pane tabs, with the active one marked.
  t.match(winbar, "CurlitePaneActive")
  t.match(winbar, "CurlitePaneInactive")
  ui.reset()
end

function M.pane_cycling_wraps(t)
  local config = require("curlite.config")
  local panes = config.get().ui.panes
  ui.show(fake(), { pane = panes[1], push = true })
  for i = 2, #panes do
    ui.cycle_pane(1)
    t.eq(ui.pane, panes[i])
  end
  ui.cycle_pane(1)
  t.eq(ui.pane, panes[1], "the last pane should wrap to the first")
  ui.cycle_pane(-1)
  t.eq(ui.pane, panes[#panes])
  ui.reset()
end

function M.direct_pane_keymaps_select_the_kulala_views(t)
  ui.show(fake(), { pane = "stats", push = true })
  local buf = vim.api.nvim_win_get_buf(ui.winid)

  -- `T` for the verbose pane, not kulala's `V`: this buffer is one you select
  -- out of, so `V` is left to linewise Visual mode.
  for key, pane in pairs({ B = "body", H = "headers", A = "all", S = "stats", T = "verbose", O = "script" }) do
    local mapping
    vim.api.nvim_buf_call(buf, function()
      mapping = vim.fn.maparg(key, "n", false, true)
    end)
    t.eq(type(mapping.callback), "function", key .. " should have a buffer-local callback")
    mapping.callback()
    t.eq(ui.pane, pane, key .. " should open the " .. pane .. " pane")
    buf = vim.api.nvim_win_get_buf(ui.winid)
  end

  ui.reset()
end

function M.a_pane_removed_from_the_config_is_unreachable(t)
  local config = require("curlite.config")
  local saved = config.get().ui.panes
  config.get().ui.panes = { "body", "stats" }
  ui.show(fake(), { pane = "verbose", push = true })
  t.eq(ui.pane, "body", "an unlisted pane should fall back to the first listed one")
  config.get().ui.panes = saved
  ui.reset()
end

function M.history_ring_is_bounded(t)
  local config = require("curlite.config")
  local saved = config.get().history.size
  config.get().history.size = 3
  ui.reset()
  for i = 1, 6 do
    local r = fake()
    r.response.status = 200 + i
    ui.show(r, { push = true })
  end
  t.eq(#ui.history, 3)
  t.eq(ui.history[1].response.status, 204, "the oldest entries should be dropped")
  t.eq(ui.history_index, 3)
  config.get().history.size = saved
  ui.reset()
end

function M.history_navigation_clamps(t)
  ui.reset()
  for i = 1, 3 do
    local r = fake()
    r.response.status = 200 + i
    ui.show(r, { push = true })
  end
  ui.cycle_history(-1)
  t.eq(ui.history_index, 2)
  ui.cycle_history(-5)
  t.eq(ui.history_index, 1, "should stop at the oldest, not go negative")
  ui.cycle_history(99)
  t.eq(ui.history_index, 3, "should stop at the newest")
  ui.reset()
end

function M.toggle_restores_a_rearranged_split(t)
  local config = require("curlite.config")
  local cfg = config.get().ui
  local saved = { display = cfg.display, width = cfg.width, focus = cfg.focus }
  cfg.display, cfg.width, cfg.focus = "right", 24, false

  ui.reset()
  local request_win = vim.api.nvim_get_current_win()
  ui.show(fake(), { pane = "body", push = true })
  local response_win = ui.winid
  vim.api.nvim_set_current_win(response_win)
  vim.cmd("wincmd H")
  vim.api.nvim_win_set_width(response_win, 31)
  vim.api.nvim_set_current_win(request_win)

  ui.toggle()
  t.falsy(ui.winid, "the first toggle should hide the response")
  ui.toggle()

  t.truthy(ui.winid and vim.api.nvim_win_is_valid(ui.winid))
  t.eq(vim.api.nvim_win_get_position(ui.winid)[2], 0, "the response should return on the left")
  t.eq(vim.api.nvim_win_get_width(ui.winid), 31, "the rearranged width should be restored")

  ui.reset()
  cfg.display, cfg.width, cfg.focus = saved.display, saved.width, saved.focus
end

function M.keymaps_follow_kulala(t)
  local defaults = require("curlite.config").defaults
  t.eq(defaults.keymaps.toggle, "<leader>Ro")
  t.eq(defaults.keymaps.send_enter, "<CR>")
  t.eq(defaults.result_keymaps.show_body, "B")
  t.eq(defaults.result_keymaps.show_headers, "H")
end

function M.split_defaults_to_half_the_editor(t)
  local cfg = require("curlite.config").defaults.ui
  t.eq(cfg.width, 0.5)
  t.eq(cfg.height, 0.5)
end

function M.vertical_split_opens_at_half_the_editor(t)
  local config = require("curlite.config")
  local size = require("curlite.size")
  local cfg = config.get().ui
  local saved = { display = cfg.display, width = cfg.width, focus = cfg.focus }
  cfg.display, cfg.width, cfg.focus = "right", 0.5, false

  ui.reset()
  local expected = size.resolve("width", 0.5)
  ui.show(fake(), { pane = "body", push = true })
  t.eq(vim.api.nvim_win_get_width(ui.winid), expected)

  ui.reset()
  cfg.display, cfg.width, cfg.focus = saved.display, saved.width, saved.focus
end

function M.binary_body_is_described_not_dumped(t)
  local r = fake()
  r.response.body = "\137PNG\r\n\26\n\0\0\0"
  r.response.json = nil
  r.response.headers = require("curlite.response").ci_headers({ ["Content-Type"] = "image/png" })
  local out = render("body", r)
  t.match(table.concat(out.lines, "\n"), "binary response")
  t.match(table.concat(out.lines, "\n"), "image/png")
  ui.close()
end

function M.empty_body_says_so(t)
  local r = fake()
  r.response.body = ""
  r.response.json = nil
  r.response.status = 204
  r.response.status_text = "No Content"
  t.match(render("body", r).lines[1], "empty body")
  ui.close()
end

function M.an_error_with_no_response_still_renders(t)
  local r = fake()
  r.response = nil
  r.script = nil
  r.error = "curl (7): failed to connect"
  for _, pane in ipairs({ "body", "headers", "all", "stats", "verbose", "script" }) do
    local out = render(pane, r)
    t.truthy(#out.lines > 0, pane .. " rendered nothing")
  end
  ui.close()
end

function M.inline_status_marks_the_request_line(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### SAMPLE", "POST https://api.example.com" })
  ui.set_inline(fake(), buf)

  local ns = vim.api.nvim_get_namespaces()["curlite_inline"]
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  t.eq(#marks, 1)
  t.eq(marks[1][2], 1, "the mark belongs on the request line")
  t.match(marks[1][4].virt_text[1][1], "201 Created")
  t.falsy(marks[1][4].virt_text[1][1]:find("140ms", 1, true), "timing stays in the winbar by default")
  t.falsy(marks[1][4].virt_text[1][1]:find("1/2", 1, true), "test tally stays in the winbar by default")
  -- A failing assertion should colour it as a failure.
  t.eq(marks[1][4].virt_text[1][2], "CurliteTestFail")

  ui.clear_inline(buf)
  t.eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
end

function M.inline_status_is_replaced_not_stacked(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "POST https://x.dev" })
  local ns = vim.api.nvim_get_namespaces()["curlite_inline"]
  for _ = 1, 4 do
    ui.set_inline(fake(), buf)
  end
  t.eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 1)
end

function M.highlight_groups_are_links_so_a_colorscheme_wins(t)
  ui.setup_highlights()
  for _, name in ipairs({
    "CurliteSuccess",
    "CurliteClientError",
    "CurliteServerError",
    "CurliteRedirect",
    "CurliteLabel",
    "CurliteValue",
    "CurlitePaneActive",
  }) do
    local hl = vim.api.nvim_get_hl(0, { name = name })
    t.truthy(next(hl) ~= nil, name .. " is not defined")
  end
end

function M.a_mutated_result_is_redrawn(t)
  -- Panes cache what they last drew. Identity is not enough to key that on:
  -- `show()` is public, and a caller that changes a result and shows it again
  -- must see the change.
  local r = fake()
  local first = render("body", r)
  t.match(table.concat(first.lines, "\n"), '"id": 7')

  r.response.body = '{\n  "id": 99\n}'
  r.response.json = { id = 99 }
  local second = render("body", r)
  t.match(table.concat(second.lines, "\n"), '"id": 99')

  r.response.status = 500
  r.response.status_text = "Internal Server Error"
  t.truthy(render("stats", r).groups.CurliteServerError)
  ui.close()
end

function M.redrawing_the_same_result_reuses_the_buffer(t)
  -- ...and when nothing has changed, the pane must not rewrite its lines.
  local r = fake()
  render("body", r)
  local buf = vim.api.nvim_win_get_buf(ui.winid)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  for _ = 1, 5 do
    render("body", r)
  end
  t.eq(
    vim.api.nvim_buf_get_changedtick(buf),
    tick,
    "an unchanged pane should not be rewritten"
  )
  ui.close()
end

function M.response_window_has_no_cursorline_by_default(t)
  local ui = require("curlite.ui")
  ui.show(fake())
  t.falsy(vim.wo[ui.winid].cursorline, "no cursor-line bar unless asked for")
  ui.close()
end

function M.cursorline_can_be_turned_on(t)
  local config = require("curlite.config")
  local ui = require("curlite.ui")
  local previous = config.get().ui.cursorline
  config.get().ui.cursorline = true

  ui.close()
  ui.show(fake())
  local on = vim.wo[ui.winid].cursorline
  config.get().ui.cursorline = previous
  ui.close()

  t.truthy(on, "ui.cursorline = true restores the bar")
end

-- curlite deliberately diverges from kulala here. kulala binds `V` to the
-- verbose pane; this window is a buffer you select lines out of, so `V` stays
-- with linewise Visual mode and the pane moves to `T`, for trace.
function M.linewise_visual_is_not_shadowed_in_the_response_window(t)
  local config = require("curlite.config")
  local ui = require("curlite.ui")
  ui.show(fake())
  local buf = vim.api.nvim_win_get_buf(ui.winid)

  local bound = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    bound[map.lhs] = true
  end
  ui.close()

  t.eq(config.get().result_keymaps.show_verbose, "T")
  t.falsy(bound["V"], "V is left to linewise Visual mode")
  t.truthy(bound["T"], "T opens the verbose/trace pane")
end

-- `K` is a hover, not the `<leader>Ri` window: small, anchored to the cursor,
-- unfocused, and gone the moment you move.
local function hover_float()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

function M.hover_opens_an_unfocused_cursor_anchored_float(t)
  local curlite = require("curlite")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "@host = https://api.example.com",
    "",
    "GET {{host}}/things",
    "Accept: application/json",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })

  curlite.hover()
  local win = hover_float()
  t.truthy(win, "K opens a float")
  t.eq(vim.api.nvim_win_get_config(win).relative, "win", "anchored to the cursor, not the editor")
  t.falsy(win == vim.api.nvim_get_current_win(), "the cursor stays in the request buffer")

  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  local text = table.concat(lines, "\n")
  t.match(text, "GET https://api%.example%.com/things", "variables are resolved")
  t.match(text, "Accept: application/json", "headers come along")
  t.falsy(text:find("curl", 1, true), "no curl equivalent -- that is `inspect`")

  pcall(vim.api.nvim_win_close, win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A second `K` steps into the float and leaves it open, exactly like
-- `vim.lsp.buf.hover()`. This regressed once because `BufLeave` was in
-- `close_events`: focusing the float leaves the request buffer, so the close
-- autocmd fired. It only shows up after the scheduled close runs, hence the
-- `vim.wait` -- without it the window is still standing either way.
function M.hover_twice_focuses_the_float(t)
  local curlite = require("curlite")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "POST https://api.example.com/things",
    "Content-Type: application/json",
    "",
    '{"active":false}',
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  curlite.hover()
  t.truthy(hover_float(), "the first K opens the float")

  curlite.hover()
  vim.wait(200)
  local win = hover_float()
  t.truthy(win, "the second K does not close it")
  t.eq(vim.api.nvim_get_current_win(), win, "the second K puts the cursor inside it")

  -- `<Esc>` hands the cursor back, the same as curlite's other floats.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  vim.wait(200)
  t.falsy(hover_float(), "<Esc> closes the float")
  t.eq(vim.api.nvim_get_current_buf(), buf, "and leaves you back in the request")

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- The body in a hover is the resolved one, spaced out as JSON.
function M.hover_pretty_prints_a_json_body(t)
  local curlite = require("curlite")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "@flag = false",
    "",
    "POST https://api.example.com/things",
    "Content-Type: application/json",
    "",
    '{"active":{{flag}},"tags":["a"]}',
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })

  curlite.hover()
  local win = hover_float()
  t.truthy(win, "K opens a float")
  local text = table.concat(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false),
    "\n"
  )
  t.match(text, '\n  "active": false', "the resolved body is indented as JSON")
  t.match(text, '\n    "a"', "and nested arrays are spaced too")

  pcall(vim.api.nvim_win_close, win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--- The inline text for `fake()`, with `ui.inline` overridden for one call.
---@param overrides table
local function inline_text(overrides)
  local config = require("curlite.config")
  local previous = vim.deepcopy(config.get().ui.inline)
  config.get().ui.inline = vim.tbl_extend("force", previous, overrides)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### S", "POST https://x.dev" })
  ui.set_inline(fake(), buf)
  local ns = vim.api.nvim_get_namespaces()["curlite_inline"]
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

  config.get().ui.inline = previous
  return marks[1] and marks[1][4].virt_text[1][1] or nil
end

function M.inline_details_are_opt_in(t)
  t.match(inline_text({ time = true }), "140ms", "time can be turned back on")
  t.match(inline_text({ tests = true }), "1/2", "so can the assertion tally")
  t.match(inline_text({ size = true }), "B", "and the body size")
end

function M.inline_status_can_be_dropped_without_losing_the_rest(t)
  local text = inline_text({ status = false, time = true })
  t.falsy(text:find("201", 1, true), "the status itself is optional too")
  t.match(text, "140ms")
end

function M.inline_with_everything_off_draws_nothing(t)
  t.eq(
    inline_text({ icon = false, status = false, time = false, size = false, tests = false }),
    nil,
    "no empty virtual text when every part is off"
  )
end

--- A buffer holding one request, and that request as the parser sees it.
local function flash_buffer()
  local lines = {
    "### SAMPLE",
    "POST https://x.dev",
    "Content-Type: application/json",
    "",
    '{"a":1}',
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local doc = require("curlite.parser").parse(lines)
  return buf, doc.requests[1]
end

local function flash_rows(buf)
  local ns = vim.api.nvim_get_namespaces()["curlite_flash"]
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    rows[#rows + 1] = mark[2]
  end
  table.sort(rows)
  return rows
end

function M.flash_covers_the_request_that_was_sent(t)
  local buf, req = flash_buffer()
  ui.flash(req, buf)

  local rows = flash_rows(buf)
  t.eq(rows, { 0, 1, 2, 3, 4 }, "the flash covers the complete section, including its blank body separator")

  ui.clear_flash()
  t.eq(#flash_rows(buf), 0, "clear_flash removes it")
end

function M.flash_scope_line_covers_only_the_request_line(t)
  local config = require("curlite.config")
  local previous = config.get().ui.flash_scope
  config.get().ui.flash_scope = "line"

  local buf, req = flash_buffer()
  ui.flash(req, buf)
  local rows = flash_rows(buf)
  config.get().ui.flash_scope = previous
  ui.clear_flash()

  t.eq(rows, { 1 }, "only the request line")
end

function M.flash_can_be_turned_off(t)
  local config = require("curlite.config")
  local previous = config.get().ui.flash
  config.get().ui.flash = false

  local buf, req = flash_buffer()
  ui.flash(req, buf)
  local rows = flash_rows(buf)
  config.get().ui.flash = previous

  t.eq(#rows, 0, "nothing is drawn when flash = false")
end

function M.a_second_flash_replaces_the_first(t)
  local buf, req = flash_buffer()
  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "GET https://y.dev" })

  ui.flash(req, buf)
  ui.flash({ url_line = 1, end_line = 1 }, other)

  t.eq(#flash_rows(buf), 0, "the earlier flash is cleared, not left behind")
  t.truthy(#flash_rows(other) > 0)
  ui.clear_flash()
end

function M.flash_survives_a_request_running_past_the_end_of_the_buffer(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET https://x.dev" })
  -- The buffer was edited down after the request was parsed.
  ui.flash({ url_line = 1, end_line = 99 }, buf)
  t.eq(flash_rows(buf), { 0 }, "the range is clamped rather than throwing")
  ui.clear_flash()
end

return M
