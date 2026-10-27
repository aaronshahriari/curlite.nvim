-- The hover (`K`). `M.lines` is a pure function of the request, so what it
-- shows is testable without a window; the rest of these put a real hover up
-- and look at the window it made.

local config = require("curlite.config")
local hover = require("curlite.hover")

local M = {}

---@param overrides table
---@param fn fun()
local function with_hover(overrides, fn)
  local cfg = config.get()
  cfg.ui.hover = cfg.ui.hover or {}
  local previous = vim.deepcopy(cfg.ui.hover)
  cfg.ui.hover = vim.tbl_extend("force", previous, overrides)
  local ok, err = pcall(fn)
  cfg.ui.hover = previous
  if not ok then
    error(err, 0)
  end
end

local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

--- A real buffer with the cursor in it, so `screencol`/`winline` have
--- something to answer about when a hover is opened.
---@return integer buf
local function scratch()
  -- A test that fails mid-way leaves its hover standing, and the next `open`
  -- would focus that one instead of drawing its own. Start from nothing.
  hover.close()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET https://api.example.com/things" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf
end

local REQUEST = {
  method = "POST",
  url = "https://api.example.com/v1/things?expand=owner&fields=id,name",
  headers = {
    ["Content-Type"] = "application/json",
    ["X-Request-Id"] = "9f1c2d",
  },
  header_order = { "Content-Type", "X-Request-Id" },
  body = '{"name":"widget"}',
}

-- The whole point: what comes up is the request, the way it reads in a file.
-- No labels, no dividers, no counts, nothing to read past.
function M.the_hover_is_the_request_and_nothing_else(t)
  t.eq(hover.lines(REQUEST), {
    "POST https://api.example.com/v1/things?expand=owner&fields=id,name",
    "Content-Type: application/json",
    "X-Request-Id: 9f1c2d",
    "",
    "{",
    '  "name": "widget"',
    "}",
  })
end

function M.headers_keep_the_order_they_were_written_in(t)
  local lines = hover.lines({
    method = "GET",
    url = "https://x.dev/a",
    headers = { Accept = "application/json", Authorization = "Bearer x" },
    header_order = { "Authorization", "Accept" },
  })
  t.eq(lines[2], "Authorization: Bearer x")
  t.eq(lines[3], "Accept: application/json")
end

function M.an_http_version_stays_on_the_request_line(t)
  local lines = hover.lines({ method = "GET", url = "https://x.dev/a", http_version = "HTTP/1.1" })
  t.eq(lines[1], "GET https://x.dev/a HTTP/1.1")
end

-- A request that could not be resolved still hovers: the error comes first,
-- as a comment, then whatever curlite did manage to work out.
function M.an_unresolved_request_leads_with_the_error(t)
  local lines = hover.lines({
    method = "GET",
    url = "{{missing}}/things",
    error = "unresolved variable: missing",
  })
  t.eq(lines[1], "# unresolved variable: missing")
  t.eq(lines[2], "GET {{missing}}/things")
end

--- ---------------------------------------------------------------- the window

-- Nothing is folded away: the window is as tall as the request has lines, so
-- a body is on screen rather than behind a "+12 lines" note.
function M.the_whole_request_is_on_screen(t)
  local buf = scratch()
  local body = { "[" }
  for i = 1, 8 do
    table.insert(body, ("  %d,"):format(i))
  end
  table.insert(body, "]")

  local float_buf, win = hover.open({
    method = "POST",
    url = "https://x.dev/a",
    body = table.concat(body, "\n"),
  })
  -- The request line, a blank, and the ten body lines.
  local shown = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
  t.eq(#shown, 12, "every line of the request is in the buffer")
  t.eq(vim.api.nvim_win_get_height(win), 12, "and the window is tall enough for all of them")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.it_is_as_wide_as_its_longest_line(t)
  local buf = scratch()

  with_hover({ padding = 1 }, function()
    local _, win = hover.open({ method = "GET", url = "https://x.dev/a" })
    -- "GET https://x.dev/a" is 19 columns, plus a column of padding a side.
    t.eq(vim.api.nvim_win_get_width(win), 21, "no wider than the request needs")
    hover.close()
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.max_width_and_max_height_are_the_ceiling(t)
  local buf = scratch()
  local body = {}
  for i = 1, 200 do
    table.insert(body, ("line %d"):format(i))
  end

  with_hover({ max_width = 30, max_height = 12 }, function()
    local _, win = hover.open({
      method = "GET",
      url = "https://api.example.com/" .. ("segment/"):rep(20),
      body = table.concat(body, "\n"),
    })
    t.eq(vim.api.nvim_win_get_width(win), 30, "width stops there")
    t.eq(vim.api.nvim_win_get_height(win), 12, "and so does height")
    t.truthy(vim.wo[win].wrap, "a line too long for it wraps rather than running off")
    hover.close()
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A fraction is a fraction of the editor; a number above 1 is a cell count.
function M.the_ceiling_can_be_a_fraction_of_the_editor(t)
  local buf = scratch()
  local columns = vim.o.columns
  vim.o.columns = 100

  local ok, err = pcall(function()
    with_hover({ max_width = 0.5 }, function()
      local _, win = hover.open({ method = "GET", url = "https://x.dev/" .. ("a"):rep(200) })
      t.eq(vim.api.nvim_win_get_width(win), 50, "half the editor")
      hover.close()
    end)
  end)

  vim.o.columns = columns
  vim.api.nvim_buf_delete(buf, { force = true })
  t.truthy(ok, tostring(err))
end

-- It is furniture-free on purpose: a title and a footer are what the border
-- had to say, and the request itself says it better.
function M.there_is_no_title_or_footer(t)
  local buf = scratch()
  local _, win = hover.open(REQUEST)
  local cfg = vim.api.nvim_win_get_config(win)

  t.falsy(cfg.title, "no title")
  t.falsy(cfg.footer, "no footer")
  t.eq(cfg.relative, "win", "anchored to the cursor, not the editor")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- The method, the URL and a JSON body come from `syntax/http.vim`; headers
-- are extmarked, because that file anchors a header name at column 0 and
-- these are indented by the padding.
function M.headers_are_highlighted_through_the_padding(t)
  local buf = scratch()
  local float_buf = hover.open(REQUEST)
  t.eq(vim.bo[float_buf].syntax, "http", "the syntax file colours the rest")

  local ns = vim.api.nvim_get_namespaces()["curlite_hover"]
  local groups = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(float_buf, ns, 0, -1, { details = true })) do
    groups[mark[4].hl_group] = true
  end
  t.truthy(groups.CurliteHttpHeaderName, "the header names")
  t.truthy(groups.CurliteHttpHeaderValue, "and their values")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A JSON body line can start with a word and a colon too (`"name": ...`), and
-- it must not be mistaken for a header and recoloured as one.
function M.a_quoted_json_key_is_not_taken_for_a_header(t)
  local buf = scratch()
  local float_buf = hover.open(REQUEST)
  local ns = vim.api.nvim_get_namespaces()["curlite_hover"]

  local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
  local body_row
  for i, line in ipairs(lines) do
    if line:find('"name"', 1, true) then
      body_row = i - 1
    end
  end
  t.truthy(body_row, "the body is there")
  local marks = vim.api.nvim_buf_get_extmarks(float_buf, ns, { body_row, 0 }, { body_row, -1 }, {})
  t.eq(#marks, 0, "no header marks on a body line")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.closing_takes_the_window_and_the_buffer_with_it(t)
  local buf = scratch()
  local float_buf, win = hover.open(REQUEST)
  t.eq(#floats(), 1, "one hover")

  hover.close()
  t.falsy(vim.api.nvim_win_is_valid(win), "the window is gone")
  t.falsy(vim.api.nvim_buf_is_valid(float_buf), "and so is its buffer")
  t.falsy(hover.current(), "nothing is tracked as open")

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Opening twice focuses what is up rather than stacking a second window over
-- the first; that is what makes `K K` step in.
function M.opening_twice_focuses_the_hover_that_is_already_up(t)
  local buf = scratch()
  local _, win = hover.open(REQUEST)
  local _, again = hover.open(REQUEST)

  t.eq(again, win, "the same window comes back")
  t.eq(#floats(), 1, "and there is only ever one")
  t.eq(vim.api.nvim_get_current_win(), win, "the second call steps into it")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.moving_the_cursor_closes_the_hover(t)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET https://x.dev/a", "GET https://x.dev/b" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  hover.open(REQUEST)
  t.truthy(hover.current(), "the hover is up")

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  vim.wait(200, function()
    return hover.current() == nil
  end)
  t.falsy(hover.current(), "moving off the request takes it down")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A pre-request script that skips leaves `exec.prepare` with no command to
-- hand back, only the resolved request. Hovering has to show that rather than
-- fall over on the missing command.
function M.hovering_a_skipped_request_shows_what_was_resolved(t)
  local curlite = require("curlite")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "@host = https://api.example.com",
    "",
    "< {% request.skip('not today') %}",
    "GET {{host}}/things",
    "Accept: application/json",
  })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })

  local float_buf = curlite.hover()
  t.truthy(float_buf, "a hover goes up")
  local seen = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
  t.match(seen, "GET https://api%.example%.com/things", "with the resolved request")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A narrow editor is where the arithmetic goes wrong: a ceiling wider than
-- the screen, padding eating what is left.
function M.a_narrow_editor_still_gets_a_hover(t)
  local buf = scratch()
  local columns = vim.o.columns
  vim.o.columns = 24

  local ok, err = pcall(function()
    local _, win = hover.open(REQUEST)
    t.truthy(vim.api.nvim_win_get_width(win) <= 24, "it fits the editor")
    hover.close()
  end)

  vim.o.columns = columns
  vim.api.nvim_buf_delete(buf, { force = true })
  t.truthy(ok, tostring(err))
end

return M
