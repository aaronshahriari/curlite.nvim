-- The memoisation added for performance has to be invisible: a cached answer
-- must never differ from a fresh one, and an edit must always be picked up.

local parser = require("curlite.parser")
local env = require("curlite.env")
local util = require("curlite.util")
local ui = require("curlite.ui")
local config = require("curlite.config")

local M = {}

function M.buffer_parse_is_reused_while_unchanged(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### A", "GET https://x.dev/a" })
  local first = parser.parse_buffer(buf)
  local second = parser.parse_buffer(buf)
  t.truthy(rawequal(first, second), "an unchanged buffer should not be re-parsed")
end

function M.editing_the_buffer_invalidates_the_parse(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### A", "GET https://x.dev/a" })
  t.eq(#parser.parse_buffer(buf).requests, 1)

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "### B", "GET https://x.dev/b" })
  local after = parser.parse_buffer(buf)
  t.eq(#after.requests, 2, "the edit should have been picked up")
  t.eq(after.requests[2].name, "B")
end

function M.invalidate_forces_a_reparse(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET https://x.dev" })
  local first = parser.parse_buffer(buf)
  parser.invalidate(buf)
  t.falsy(rawequal(first, parser.parse_buffer(buf)))
end

function M.an_invalid_buffer_yields_an_empty_document(t)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  local doc = parser.parse_buffer(buf)
  t.eq(doc.requests, {})
  t.eq(doc.variables, {})
end

function M.file_parse_is_reused_then_invalidated_by_an_edit(t)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/api.http"
  util.write_file(path, "### A\nGET https://x.dev/a\n")

  local first = parser.parse_file(path)
  t.truthy(rawequal(first, parser.parse_file(path)), "unchanged file should be reused")

  -- Rewrite with a different size so the signature changes even if the
  -- filesystem's mtime resolution is coarse.
  util.write_file(path, "### A\nGET https://x.dev/a\n\n### B\nGET https://x.dev/b\n")
  local after = parser.parse_file(path)
  t.eq(#after.requests, 2)
end

function M.a_missing_file_is_still_an_error(t)
  local doc, err = parser.parse_file(vim.fn.tempname() .. "/nope.http")
  t.eq(doc, nil)
  t.match(err, "cannot read")
end

function M.env_files_are_reread_after_an_edit(t)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  local path = dir .. "/http-client.env.json"
  util.write_file(path, [[{ "dev": { "host": "first" } }]])

  env.reset()
  env.select("dev", dir .. "/api.http")
  t.eq(env.active(dir .. "/api.http").host, "first")

  util.write_file(path, [[{ "dev": { "host": "second-and-longer" } }]])
  t.eq(
    env.active(dir .. "/api.http").host,
    "second-and-longer",
    "an edited env file must be picked up without a restart"
  )
  env.reset()
end

function M.dotenv_is_reread_after_an_edit(t)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  util.write_file(dir .. "/.env", "TOKEN=one\n")
  env.reset()
  t.eq(env.dotenv(dir .. "/api.http").TOKEN, "one")
  util.write_file(dir .. "/.env", "TOKEN=two-and-longer\n")
  t.eq(env.dotenv(dir .. "/api.http").TOKEN, "two-and-longer")
  env.reset()
end

function M.a_new_env_file_appearing_is_noticed(t)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  env.reset()
  t.eq(env.names(dir .. "/api.http"), {})
  util.write_file(dir .. "/http-client.env.json", [[{ "dev": {}, "prod": {} }]])
  t.eq(env.names(dir .. "/api.http"), { "dev", "prod" }, "a file created later must be seen")
  env.reset()
end

function M.history_respects_the_byte_budget(t)
  local saved_bytes = config.get().history.max_bytes
  local saved_size = config.get().history.size
  config.get().history.max_bytes = 1000
  config.get().history.size = 0

  ui.reset()
  local response = require("curlite.response")
  local function push(body)
    ui.show({
      raw = {},
      request = { method = "GET", url = "https://x.dev", headers = {}, header_order = {} },
      command = {},
      response = {
        status = 200, status_text = "OK", http_version = "HTTP/2",
        headers = response.ci_headers({}), header_order = {}, raw_headers = "",
        hops = {}, body = body, json = { n = #body }, cookies = {}, stats = {},
        duration_ms = 1, verbose = "", body_path = "",
      },
      script = { logs = {}, tests = {} }, duration_ms = 1,
    }, { push = true })
  end

  for _ = 1, 10 do
    push(("x"):rep(300))
  end
  t.truthy(#ui.history <= 4, ("kept %d entries for a 1000-byte budget"):format(#ui.history))

  -- The newest is kept however large.
  push(("y"):rep(50000))
  t.eq(#ui.history, 1, "an oversized newest response should evict the rest and stay")
  t.eq(#ui.history[1].response.body, 50000)

  config.get().history.max_bytes = saved_bytes
  config.get().history.size = saved_size
  ui.reset()
end

function M.decoded_json_is_dropped_from_older_entries(t)
  local saved = config.get().history.max_bytes
  config.get().history.max_bytes = 0
  ui.reset()
  local response = require("curlite.response")
  for i = 1, 3 do
    ui.show({
      raw = {}, request = { method = "GET", url = "https://x.dev", headers = {}, header_order = {} },
      command = {},
      response = {
        status = 200, status_text = "OK", http_version = "HTTP/2",
        headers = response.ci_headers({}), header_order = {}, raw_headers = "",
        hops = {}, body = ('{"i":%d}'):format(i), json = { i = i }, cookies = {},
        stats = {}, duration_ms = 1, verbose = "", body_path = "",
      },
      script = { logs = {}, tests = {} }, duration_ms = 1,
    }, { push = true })
  end
  t.eq(ui.history[3].response.json, { i = 3 }, "the newest keeps its decoded body")
  t.eq(ui.history[1].response.json, nil, "older entries drop derived data")
  t.eq(ui.history[2].response.json, nil)
  -- ...and it is still reachable, because the body is still there.
  t.eq(vim.json.decode(ui.history[1].response.body), { i = 1 })
  config.get().history.max_bytes = saved
  ui.reset()
end

function M.a_request_variable_still_resolves_after_json_is_dropped(t)
  local variables = require("curlite.variables")
  variables.reset()
  local resp = { status = 200, body = '{"token":"abc"}', json = { token = "abc" }, headers = {} }
  variables.record("LOGIN", { headers = {} }, resp)
  t.eq(variables.render("{{LOGIN.response.body.$.token}}", {
    vars = {}, envvars = {}, globals = {}, dotenv = {}, prompts = {},
  }), "abc")

  -- The history trim nils this out; the lookup must fall back to the body.
  resp.json = nil
  t.eq(variables.render("{{LOGIN.response.body.$.token}}", {
    vars = {}, envvars = {}, globals = {}, dotenv = {}, prompts = {},
  }), "abc", "a chained reference must survive the decoded body being dropped")
  variables.reset()
end

return M
