-- The blink.cmp and nvim-cmp adapters.
--
-- These drive the adapters the way the engines do, because the bugs that
-- matter live in the handoff rather than in the item list: blink applies a
-- completion itself *only* for a source with no `execute` of its own, so a
-- source that defines one and forgets to call `default_implementation`
-- accepts completions that insert nothing at all.

local complete = require("curlite.complete")
local util = require("curlite.util")

local function project(files, buffer_name)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  require("curlite.env").reset()
  local buf = vim.fn.bufadd(dir .. "/" .. buffer_name)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "http"
  return buf
end

--- A stand-in for blink's context.
local function blink_context(buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  return { line = line, cursor = { row, col }, bufnr = buf }
end

local function find(items, label)
  for _, entry in ipairs(items) do
    if entry.label == label then
      return entry
    end
  end
end

--- Apply an item's textEdit to `line` the way an engine would.
local function apply(line, item)
  local r = item.textEdit.range
  return line:sub(1, r.start.character) .. item.textEdit.newText .. line:sub(r["end"].character + 1)
end

local M = {}

function M.blink_items_carry_an_explicit_text_edit(t)
  local buf = project({
    ["http-client.env.json"] = [[{ "$curliteshared": { "auth": { "client_id": "abc" } } }]],
    ["api.http"] = "GET {{auth.cl\n",
  }, "api.http")

  local src = require("curlite.blink").new()
  local got
  src:get_completions(blink_context(buf, 1, 13), function(res)
    got = res
  end)

  local item = find(got.items, "auth.client_id")
  t.truthy(item, "the nested variable is offered")
  t.truthy(item.textEdit, "with a range of its own")
  t.eq(item.textEdit.newText, "{{auth.client_id}}")
  t.eq(item.textEdit.range.start.character, 4, "replacing from the braces")
  t.eq(item.textEdit.range["end"].character, 13)
  -- Left to guess, blink's keyword for `{{auth.cl` is `cl`, and accepting
  -- would have written `{{auth.auth.client_id`.
  t.eq(apply("GET {{auth.cl", item), "GET {{auth.client_id}}")
end

function M.blink_execute_applies_the_edit(t)
  local buf = project({ ["api.http"] = "GET {{\n" }, "api.http")
  local src = require("curlite.blink").new()
  local got
  src:get_completions(blink_context(buf, 1, 6), function(res)
    got = res
  end)

  local applied, finished = false, false
  src:execute({}, got.items[1], function()
    finished = true
  end, function()
    applied = true
  end)

  t.truthy(applied, "the default implementation must be called, or nothing is inserted")
  t.truthy(finished, "and the callback still resolves")
end

function M.blink_execute_survives_a_missing_default(t)
  -- Older blink passed no default implementation; `execute` must not raise.
  local src = require("curlite.blink").new()
  local finished = false
  src:execute({}, { data = {} }, function()
    finished = true
  end)
  t.truthy(finished)
end

function M.blink_offers_nothing_where_nothing_applies(t)
  local buf = project({ ["api.http"] = "GET https://example.com/a\n" }, "api.http")
  local src = require("curlite.blink").new()
  local got
  src:get_completions(blink_context(buf, 1, 25), function(res)
    got = res
  end)
  t.eq(#got.items, 0, "mid-URL is not a completion site")
end

function M.blink_leaves_non_variables_alone(t)
  local buf = project({ ["api.http"] = "GE\n" }, "api.http")
  local src = require("curlite.blink").new()
  local got
  src:get_completions(blink_context(buf, 1, 2), function(res)
    got = res
  end)
  local get = find(got.items, "GET")
  t.truthy(get)
  t.falsy(get.textEdit, "a method has no range of its own to name")
  t.eq(get.insertText, "GET ")
end

function M.cmp_items_carry_the_same_edit(t)
  local buf = project({
    ["http-client.env.json"] = [[{ "$curliteshared": { "host": "https://x.dev" } }]],
    ["api.http"] = "GET {{ho\n",
  }, "api.http")
  vim.api.nvim_win_set_buf(0, buf)

  local src = require("curlite.cmp").new()
  local got
  src:complete({
    context = { cursor_line = "GET {{ho", cursor = { row = 1, col = 9 }, bufnr = buf },
  }, function(res)
    got = res
  end)

  local item = find(got.items, "host")
  t.truthy(item)
  t.eq(item.insertText, "{{host}}")
  t.eq(item.textEdit.newText, "{{host}}")
  t.eq(item.textEdit.range.start.character, 4)
  t.eq(item.textEdit.range["end"].character, 8)
  t.eq(apply("GET {{ho", item), "GET {{host}}")
end

function M.the_omnifunc_cleans_up_the_trailing_braces(t)
  -- Vim replaces only up to the cursor, so the `}}` an autopair left behind
  -- has to go on CompleteDone -- otherwise you get `{{host}}}}`.
  local buf = project({ ["api.http"] = "GET {{}}\n" }, "api.http")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, 6 })

  t.eq(complete.omnifunc(1, ""), 4)

  -- Stand where Vim would after inserting `{{host}}` over `{{`.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET {{host}}}}" })
  vim.api.nvim_win_set_cursor(0, { 1, 12 })
  local completed = vim.v.completed_item
  pcall(function()
    vim.v.completed_item = { word = "{{host}}", user_data = vim.json.encode({ back = 0 }) }
  end)
  complete.complete_done()
  t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "GET {{host}}")
  pcall(function()
    vim.v.completed_item = completed
  end)
end

return M
