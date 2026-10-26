-- The hover card (`K`). `M.rows` is a pure function of the request and the
-- width it is given, so most of the layout is testable without a window; the
-- rest of these put a real card up and look at the window it made.

local config = require("curlite.config")
local hover = require("curlite.hover")

local M = {}

local function text(rows)
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, row.text)
  end
  return out
end

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
--- something to answer about when a card is opened.
---@return integer buf
local function scratch()
  -- A test that fails mid-way leaves its card standing, and the next `open`
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
  name = "CREATE_THING",
  env = "dev",
}

--- The query string is the whole reason the old popup was unreadable: it put
--- the longest line in the request first and let it run off the edge.
function M.the_query_string_is_broken_out_one_parameter_per_line(t)
  local lines = text(hover.rows(REQUEST, 60))

  t.eq(lines[1], "POST https://api.example.com/v1/things", "the URL loses its query string")
  t.eq(lines[2], "     ?expand = owner", "the first parameter sits under it")
  t.eq(lines[3], "     &fields = id,name", "and the rest follow, aligned")
end

function M.split_query_can_be_turned_off(t)
  with_hover({ split_query = false }, function()
    local lines = text(hover.rows(REQUEST, 80))
    t.eq(lines[1], "POST https://api.example.com/v1/things?expand=owner&fields=id,name")
  end)
end

-- `?debug` is a flag, not an empty value, so it must not render as `debug = `.
function M.a_valueless_parameter_keeps_its_name_alone(t)
  local lines = text(hover.rows({
    method = "GET",
    url = "https://api.example.com/things?debug&page=2",
  }, 60))
  t.eq(lines[2], "    ?debug")
  -- The keys line up with each other, flag or not.
  t.eq(lines[3], "    &page  = 2")
end

function M.headers_are_aligned_into_a_column(t)
  local lines = text(hover.rows(REQUEST, 60))
  local seen = table.concat(lines, "\n")

  t.match(seen, "headers .- 2\n", "a labelled rule, with the count")
  t.match(seen, "\nContent%-Type:  application/json\n", "the longest name sets the column")
  t.match(seen, "\nX%-Request%-Id:  9f1c2d", "and every value lines up in it")
end

-- A bearer token is longer than any card; it wraps under its own column
-- rather than being cut off, because the end of a signed value is the part
-- you are usually checking.
function M.a_long_header_value_wraps_with_a_hanging_indent(t)
  local rows = text(hover.rows({
    method = "GET",
    url = "https://api.example.com/things",
    headers = { Authorization = "Bearer " .. ("x"):rep(80) },
    header_order = { "Authorization" },
  }, 40))

  local first, second
  for i, line in ipairs(rows) do
    if line:match("^Authorization:") then
      first, second = line, rows[i + 1]
    end
  end
  t.truthy(first, "the header is there")
  t.truthy(#first <= 40, "the first line fits the width")
  local column = #first:match("^(Authorization:%s+)")
  t.match(second, "^ +x+$", "the rest of the value follows")
  t.eq(#second:match("^( +)"), column, "indented to exactly the value's column")
end

function M.the_body_is_labelled_with_its_kind_and_size(t)
  local lines = table.concat(text(hover.rows(REQUEST, 60)), "\n")
  t.match(lines, "body .- json · 17B", "the rule says what the body is")
  t.match(lines, '\n  "name": "widget"\n', "and the JSON is re-indented")
end

function M.a_form_body_is_named_from_its_content_type(t)
  local lines = table.concat(
    text(hover.rows({
      method = "POST",
      url = "https://api.example.com/login",
      headers = { ["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8" },
      header_order = { "Content-Type" },
      body = "user=aaron&pass=hunter2",
    }, 60)),
    "\n"
  )
  t.match(lines, "body .- form · 23B")
end

function M.a_long_body_is_capped_with_a_count_of_what_is_left(t)
  local body = { "[" }
  for i = 1, 30 do
    table.insert(body, ("  %d,"):format(i))
  end
  table.insert(body, "]")

  with_hover({ body_lines = 5 }, function()
    local lines = text(hover.rows({
      method = "POST",
      url = "https://api.example.com/things",
      body = table.concat(body, "\n"),
    }, 60))
    t.eq(lines[#lines], "… 27 more lines", "the rest is counted, not dumped")
  end)
end

-- A request that could not be resolved still hovers: the error comes first,
-- then whatever curlite did manage to work out.
function M.an_unresolved_request_leads_with_the_error(t)
  local lines = text(hover.rows({
    method = "GET",
    url = "{{missing}}/things",
    error = "unresolved variable: missing",
  }, 60))
  t.eq(lines[1], "⚠ unresolved variable: missing")
  t.eq(lines[3], "GET {{missing}}/things")
end

--- ---------------------------------------------------------------- the window

-- The complaint about the old hover was its shape: a float sized by Neovim's
-- preview helper, with the text jammed against the border. The card hugs its
-- content between a floor and a ceiling instead.
function M.the_card_hugs_its_content_between_min_and_max_width(t)
  local buf = scratch()

  with_hover({ min_width = 40, max_width = 70, padding = 2 }, function()
    local _, win = hover.open({ method = "GET", url = "https://x.dev/a" })
    t.eq(vim.api.nvim_win_get_width(win), 40, "a short request still gets a readable card")
    hover.close()

    local _, wide = hover.open({
      method = "GET",
      url = "https://api.example.com/" .. ("segment/"):rep(20),
    })
    t.eq(vim.api.nvim_win_get_width(wide), 70, "and a long one stops at the maximum")
    hover.close()
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.the_border_carries_the_request_name_and_the_environment(t)
  local buf = scratch()
  local _, win = hover.open(REQUEST)
  local cfg = vim.api.nvim_win_get_config(win)

  local title = ""
  for _, chunk in ipairs(cfg.title or {}) do
    title = title .. chunk[1]
  end
  t.match(title, "CREATE_THING", "the request's name")
  t.match(title, "dev", "and the environment it resolved against")

  local footer = ""
  for _, chunk in ipairs(cfg.footer or {}) do
    footer = footer .. chunk[1]
  end
  t.match(footer, "K focus", "the keys are on the bottom edge")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- `border = "none"` is a legitimate choice, and Neovim refuses a title on a
-- borderless window -- the card has to go up bare rather than error.
function M.a_borderless_card_drops_the_title_instead_of_failing(t)
  local buf = scratch()

  with_hover({ border = "none" }, function()
    local _, win = hover.open(REQUEST)
    t.truthy(win and vim.api.nvim_win_is_valid(win), "the card is still drawn")
    t.falsy(vim.api.nvim_win_get_config(win).title, "with no title")
    hover.close()
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.a_body_too_tall_for_the_card_is_counted_in_the_footer(t)
  local buf = scratch()
  local lines = {}
  for i = 1, 200 do
    table.insert(lines, ("line %d"):format(i))
  end

  with_hover({ max_height = 10 }, function()
    local _, win = hover.open({
      method = "POST",
      url = "https://x.dev/a",
      body = table.concat(lines, "\n"),
    })
    t.eq(vim.api.nvim_win_get_height(win), 10, "the card stops at the ceiling")
    local footer = ""
    for _, chunk in ipairs(vim.api.nvim_win_get_config(win).footer or {}) do
      footer = footer .. chunk[1]
    end
    t.match(footer, "%+%d+ lines", "and says how much is below the fold")
    hover.close()
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- The method and the header names are coloured with the same groups the
-- buffer uses, so a hovered request reads like the request you wrote.
function M.the_card_is_highlighted_with_the_buffers_own_groups(t)
  local buf = scratch()
  local float_buf = hover.open(REQUEST)
  local ns = vim.api.nvim_get_namespaces()["curlite_hover"]
  local groups = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(float_buf, ns, 0, -1, { details = true })) do
    groups[mark[4].hl_group] = true
  end

  t.truthy(groups.CurliteHttpMethodPost, "the method keeps its colour")
  t.truthy(groups.CurliteHttpUrl, "so does the URL")
  t.truthy(groups.CurliteHttpHeaderName, "and the header names")
  t.truthy(groups.CurliteHoverQueryKey, "the query keys get their own")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.closing_takes_the_window_and_the_buffer_with_it(t)
  local buf = scratch()
  local float_buf, win = hover.open(REQUEST)
  t.eq(#floats(), 1, "one card")

  hover.close()
  t.falsy(vim.api.nvim_win_is_valid(win), "the window is gone")
  t.falsy(vim.api.nvim_buf_is_valid(float_buf), "and so is its buffer")
  t.falsy(hover.current(), "nothing is tracked as open")

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- Opening twice focuses what is up rather than stacking a second card over
-- the first; that is what makes `K K` step in.
function M.opening_twice_focuses_the_card_that_is_already_up(t)
  local buf = scratch()
  local _, win = hover.open(REQUEST)
  local _, again = hover.open(REQUEST)

  t.eq(again, win, "the same window comes back")
  t.eq(#floats(), 1, "and there is only ever one")
  t.eq(vim.api.nvim_get_current_win(), win, "the second call steps into it")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

function M.moving_the_cursor_closes_the_card(t)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET https://x.dev/a", "GET https://x.dev/b" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  hover.open(REQUEST)
  t.truthy(hover.current(), "the card is up")

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
  t.truthy(float_buf, "a card goes up")
  local seen = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
  t.match(seen, "GET https://api%.example%.com/things", "with the resolved request")

  hover.close()
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- `style = "plain"` is the pre-card popup, kept for anyone who preferred it.
function M.plain_style_falls_back_to_the_lsp_preview_float(t)
  local buf = scratch()

  with_hover({ style = "plain" }, function()
    local float_buf = hover.open(REQUEST)
    local seen = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
    t.match(seen, "POST https://api%.example%.com/v1/things%?expand=owner", "the raw request line")
    t.match(seen, "Content%-Type: application/json", "and headers as written")
    t.falsy(hover.current(), "the card's own bookkeeping is untouched")
  end)

  for _, win in ipairs(floats()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A narrow window is where the arithmetic goes wrong: a max width wider than
-- the editor, padding eating what is left, a rule filled to a negative count.
function M.a_narrow_editor_still_gets_a_card(t)
  local buf = scratch()
  local columns = vim.o.columns
  vim.o.columns = 40

  local ok, err = pcall(function()
    local _, win = hover.open(REQUEST)
    t.truthy(vim.api.nvim_win_get_width(win) <= 40, "the card fits the editor")
    hover.close()
  end)

  vim.o.columns = columns
  vim.api.nvim_buf_delete(buf, { force = true })
  t.truthy(ok, tostring(err))
end

return M
