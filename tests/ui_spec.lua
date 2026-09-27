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
  t.match(marks[1][4].virt_text[1][1], "140ms")
  t.match(marks[1][4].virt_text[1][1], "1/2")
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

return M
