local config = require("curlite.config")
local parser = require("curlite.parser")
local scripts = require("curlite.scripts")
local env = require("curlite.env")

--- Parse `src` and run its post-request scripts against a fake response.
local function post(src, resp)
  local doc = parser.parse(vim.split(src, "\n", { plain = true }), "/tmp/curlite-scripts/t.http")
  local req = doc.requests[1]
  return scripts.run_post(
    req,
    vim.tbl_extend("keep", resp or {}, {
      status = 200,
      status_text = "OK",
      http_version = "HTTP/1.1",
      body = "",
      json = nil,
      headers = {},
      cookies = {},
      duration_ms = 12,
      stats = {},
    })
  ),
    req
end

local function pre(src)
  local doc = parser.parse(vim.split(src, "\n", { plain = true }), "/tmp/curlite-scripts/t.http")
  local req = doc.requests[1]
  return scripts.run_pre(req), req
end

local M = {}

function M.log_reaches_the_script_pane(t)
  local r = post("GET https://x.dev\n\n> {% client.log('hello', 42) %}\n")
  t.eq(r.logs, { "hello 42" })
end

function M.print_is_an_alias_for_log(t)
  t.eq(post("GET https://x.dev\n\n> {% print('via print') %}\n").logs, { "via print" })
end

function M.global_set_is_visible_as_a_variable(t)
  env.globals = {}
  post('GET https://x.dev\n\n> {% client.global.set("tok", "abc") %}\n')
  t.eq(env.globals.tok, "abc")
  env.globals = {}
end

function M.client_test_records_pass_and_fail(t)
  local r = post([[
GET https://x.dev

> {%
  client.test("passes", function() assert(true) end)
  client.test("fails", function() error("nope") end)
%}
]])
  local passed, failed = scripts.tally(r)
  t.eq(passed, 1)
  t.eq(failed, 1)
  t.eq(r.tests[1].name, "passes")
  t.eq(r.tests[1].message, nil, "a passing test carries no message")
  t.eq(r.tests[2].ok, false)
  t.match(r.tests[2].message, "nope")
end

function M.response_fields_are_in_scope(t)
  local r = post(
    "GET https://x.dev\n\n> {% client.log(response.status, response.header('X-A'), response.duration_ms) %}\n",
    { headers = { ["x-a"] = "one" } }
  )
  t.eq(r.logs, { "200 one 12" })
end

function M.pre_script_rewrites_the_request(t)
  local _, req = pre([[
< {%
  request.method = "put"
  request.url = request.url .. "?x=1"
  request.body = "new body"
  request.headers.set("X-Added", "yes")
  request.headers.remove("X-Gone")
%}
POST https://x.dev
X-Gone: bye
]])
  t.eq(req.method, "PUT", "the method should be upper-cased")
  t.eq(req.url, "https://x.dev?x=1")
  t.eq(req.body, "new body")
  t.eq(req.headers["X-Added"], "yes")
  t.eq(req.headers["X-Gone"], nil)
end

function M.header_accessors_are_case_insensitive(t)
  local r = pre([[
< {%
  client.log(request.headers.get("content-TYPE"))
  request.headers.set("CONTENT-type", "text/plain")
%}
POST https://x.dev
Content-Type: application/json
]])
  t.eq(r.logs, { "application/json" })
end

function M.skip_and_abort_are_reported(t)
  t.truthy(pre("< {% request.skip('nope') %}\nGET https://x.dev\n").skip)
  t.eq(pre("< {% request.skip('nope') %}\nGET https://x.dev\n").reason, "nope")
  t.truthy(pre("< {% request.abort('stop') %}\nGET https://x.dev\n").abort)
end

function M.syntax_error_is_reported_not_raised(t)
  local r = post("GET https://x.dev\n\n> {% this is not lua %}\n")
  t.truthy(r.error)
  t.match(r.error, "syntax error")
end

function M.runtime_error_is_reported(t)
  local r = post("GET https://x.dev\n\n> {% error('boom') %}\n")
  t.match(r.error, "boom")
end

function M.sandbox_blocks_io_and_os_execute(t)
  t.truthy(config.get().scripts.sandbox, "sandbox should be on by default")
  t.match(post("GET https://x.dev\n\n> {% io.open('/tmp/x', 'w') %}\n").error, "nil value")
  t.match(post("GET https://x.dev\n\n> {% os.execute('true') %}\n").error, "nil value")
  -- os.date and os.time are allowed, being pure.
  t.eq(post("GET https://x.dev\n\n> {% client.log(type(os.time())) %}\n").logs, { "number" })
end

function M.timeout_stops_a_runaway_loop(t)
  local saved = config.get().scripts.timeout
  config.get().scripts.timeout = 150

  local started = vim.uv.hrtime()
  local r = post("GET https://x.dev\n\n> {% while true do end %}\n")
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

  t.truthy(r.error, "an endless loop must be aborted, not hang the editor")
  t.match(r.error, "scripts%.timeout")
  t.truthy(elapsed_ms < 5000, ("gave up after %.0fms"):format(elapsed_ms))

  config.get().scripts.timeout = saved
end

function M.timeout_does_not_disturb_a_normal_script(t)
  local saved = config.get().scripts.timeout
  config.get().scripts.timeout = 2000
  local r = post("GET https://x.dev\n\n> {% client.log('fine') %}\n")
  t.eq(r.error, nil)
  t.eq(r.logs, { "fine" })
  config.get().scripts.timeout = saved
end

function M.timeout_of_zero_disables_the_check(t)
  local saved = config.get().scripts.timeout
  config.get().scripts.timeout = 0
  local r = post("GET https://x.dev\n\n> {% for _ = 1, 200000 do end client.log('done') %}\n")
  t.eq(r.error, nil)
  t.eq(r.logs, { "done" })
  config.get().scripts.timeout = saved
end

function M.assert_expressions_see_the_response(t)
  local r = post([[
# @assert status == 200
# @assert duration < 1000
# @assert json.a.b == 2
# @assert headers["content-type"]:find("json") ~= nil
GET https://x.dev
]], {
    json = { a = { b = 2 } },
    headers = { ["Content-Type"] = "application/json" },
  })
  local passed, failed = scripts.tally(r)
  t.eq(failed, 0, vim.inspect(r.tests))
  t.eq(passed, 4)
end

function M.assert_with_a_broken_expression_fails_cleanly(t)
  local r = post("# @assert ??? nonsense\nGET https://x.dev\n")
  local _, failed = scripts.tally(r)
  t.eq(failed, 1)
  t.truthy(r.tests[1].message)
end

function M.external_script_file(t)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  require("curlite.util").write_file(dir .. "/post.lua", 'client.log("from a file")\n')
  local doc = parser.parse(
    vim.split("GET https://x.dev\n\n> ./post.lua\n", "\n", { plain = true }),
    dir .. "/t.http"
  )
  local r = scripts.run_post(doc.requests[1], {
    status = 200,
    body = "",
    headers = {},
    cookies = {},
    duration_ms = 1,
    stats = {},
  })
  t.eq(r.logs, { "from a file" })
end

function M.missing_external_script_is_reported(t)
  local r = post("GET https://x.dev\n\n> ./does-not-exist.lua\n")
  t.match(r.error, "cannot read")
end

function M.scripts_can_be_disabled(t)
  config.get().scripts.enable = false
  local r = post("GET https://x.dev\n\n> {% client.log('should not run') %}\n")
  t.eq(r.logs, {})
  config.get().scripts.enable = true
end

return M
