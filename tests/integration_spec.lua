-- End-to-end tests against tests/server.py. The harness starts it; if it
-- isn't reachable these tests skip rather than fail, so `tests/run.sh` still
-- works on a machine without python3.

local exec = require("curlite.exec")
local parser = require("curlite.parser")
local env = require("curlite.env")
local variables = require("curlite.variables")

local PORT = tonumber(vim.env.CURLITE_TEST_PORT or "") or 18923
local BASE = ("http://127.0.0.1:%d"):format(PORT)

local available = nil
local function server_up()
  if available == nil then
    local probe = vim.system({ "curl", "-s", "-o", "/dev/null", "-m", "2", BASE .. "/json" }):wait()
    available = probe.code == 0
  end
  return available
end

--- Send `src` (one `.http` document) and return the first result.
---@return curlite.Result|nil
local function run(src, index)
  local doc = parser.parse(
    vim.split((src:gsub("%%BASE%%", BASE)), "\n", { plain = true }),
    vim.fn.getcwd() .. "/tests/it.http"
  )
  return exec.send_sync(doc.requests[index or 1], 15000)
end

local M = {}

function M.get_json(t)
  if not server_up() then
    return
  end
  local r = run("GET %BASE%/json\nAccept: application/json\n")
  t.truthy(r, "no result")
  t.eq(r.error, nil)
  t.eq(r.response.status, 200)
  t.eq(r.response.json.count, 2)
  t.eq(r.response.headers["content-type"], "application/json")
  -- case-insensitive access must work in both directions
  t.eq(r.response.headers["Content-Type"], "application/json")
end

function M.post_json_body(t)
  if not server_up() then
    return
  end
  local r = run('POST %BASE%/echo\nContent-Type: application/json\n\n{"name":"aaron","n":7}\n')
  t.eq(r.response.status, 200)
  t.eq(r.response.json.method, "POST")
  t.eq(r.response.json.json, { name = "aaron", n = 7 })
end

function M.form_body_newlines_are_stripped_on_the_wire(t)
  if not server_up() then
    return
  end
  local r = run([[
POST %BASE%/echo
Content-Type: application/x-www-form-urlencoded

sessionToken=abc
&firstResult=0
&maxResults=10
]])
  t.eq(r.response.json.body, "sessionToken=abc&firstResult=0&maxResults=10")
end

function M.query_continuation_lines(t)
  if not server_up() then
    return
  end
  local r = run("GET %BASE%/echo\n  ?q=neovim\n  &lang=lua\n")
  t.eq(r.response.json.query, { q = "neovim", lang = "lua" })
end

function M.headers_reach_the_server(t)
  if not server_up() then
    return
  end
  local r = run("GET %BASE%/echo\nX-Custom: hello\nAccept: application/json\n")
  t.eq(r.response.json.headers["x-custom"], "hello")
end

function M.variables_resolve_end_to_end(t)
  if not server_up() then
    return
  end
  local r = run("@base = %BASE%\n@who = aaron\n\nGET {{base}}/echo?who={{who}}\n")
  t.eq(r.response.json.query.who, "aaron")
end

function M.methods(t)
  if not server_up() then
    return
  end
  for _, method in ipairs({ "PUT", "PATCH", "DELETE", "OPTIONS" }) do
    local r = run(("%s %%BASE%%/echo\n"):format(method))
    t.eq(r.response.json.method, method, "method " .. method)
  end
end

function M.head_request_has_no_body(t)
  if not server_up() then
    return
  end
  local r = run("HEAD %BASE%/json\n")
  t.eq(r.response.status, 200)
  t.eq(r.response.body, "")
end

function M.error_statuses(t)
  if not server_up() then
    return
  end
  t.eq(run("GET %BASE%/status/404\n").response.status, 404)
  t.eq(run("GET %BASE%/status/500\n").response.status, 500)
  t.eq(run("GET %BASE%/status/201\n").response.status_text, "Created")
end

function M.redirects_are_followed_and_recorded(t)
  if not server_up() then
    return
  end
  local r = run("GET %BASE%/redirect/2\n")
  t.eq(r.response.status, 200)
  -- three hops: two 302s and the final 200
  t.eq(#r.response.hops, 3)
  t.eq(r.response.hops[1].status, 302)
  t.eq(r.response.stats.num_redirects, 2)
end

function M.no_redirect_metadata(t)
  if not server_up() then
    return
  end
  local r = run("# @no-redirect\nGET %BASE%/redirect/1\n")
  t.eq(r.response.status, 302)
  t.eq(#r.response.hops, 1)
end

function M.timeout_metadata_fires(t)
  if not server_up() then
    return
  end
  local r = run("# @timeout 200\nGET %BASE%/slow?ms=2000\n")
  t.truthy(r.error, "expected a timeout error")
  t.match(r.error, "curl %(28%)")
end

function M.basic_auth(t)
  if not server_up() then
    return
  end
  t.eq(run("GET %BASE%/basic-auth\n").response.status, 401)
  local r = run("GET %BASE%/basic-auth\nAuthorization: Basic user pass\n")
  t.eq(r.response.status, 200)
  t.eq(r.response.json.authenticated, true)
end

function M.cookies_are_parsed(t)
  if not server_up() then
    return
  end
  local r = run("GET %BASE%/cookie/set\n")
  t.eq(r.response.cookies.session, "abc123")
  t.eq(r.response.cookies.flavour, "choc")
end

function M.cookie_jar_carries_the_session(t)
  if not server_up() then
    return
  end
  run("GET %BASE%/cookie/set\n")
  local r = run("GET %BASE%/cookie/read\n")
  t.match(r.response.json.cookie, "session=abc123")
end

function M.graphql_round_trip(t)
  if not server_up() then
    return
  end
  local r = run([[
GRAPHQL %BASE%/graphql

query ($id: ID!) { user(id: $id) { name } }

{ "id": "42" }
]])
  t.eq(r.response.status, 200)
  t.eq(r.response.json.data.received.variables, { id = "42" })
  t.match(r.response.json.data.received.query, "user%(id: %$id%)")
end

function M.post_script_sets_a_global(t)
  if not server_up() then
    return
  end
  env.globals = {}
  run([[
### SET
GET %BASE%/json

> {%
  client.global.set("title", response.json.slideshow.title)
  client.log("saw " .. response.status)
%}
]])
  t.eq(env.globals.title, "Sample Slide Show")
  env.globals = {}
end

function M.request_variables_chain(t)
  if not server_up() then
    return
  end
  variables.reset()
  local src = [[
### FIRST
GET %BASE%/json

### SECOND
GET %BASE%/echo?title={{FIRST.response.body.$.slideshow.title}}
]]
  local doc = parser.parse(vim.split((src:gsub("%%BASE%%", BASE)), "\n", { plain = true }), "/tmp/c.http")
  exec.send_sync(doc.requests[1], 15000)
  local second = exec.send_sync(doc.requests[2], 15000)
  t.eq(second.response.json.query.title, "Sample Slide Show")
  variables.reset()
end

function M.pre_script_can_rewrite_the_request(t)
  if not server_up() then
    return
  end
  local r = run([[
### REWRITE
< {%
  request.headers.set("X-Injected", "yes")
  request.url = request.url .. "?injected=1"
%}
GET %BASE%/echo
]])
  t.eq(r.response.json.headers["x-injected"], "yes")
  t.eq(r.response.json.query.injected, "1")
end

function M.pre_script_can_skip(t)
  if not server_up() then
    return
  end
  local r = run("< {% request.skip('not today') %}\nGET %BASE%/json\n")
  t.truthy(r.skipped)
  t.eq(r.response, nil)
end

function M.asserts_pass_and_fail(t)
  if not server_up() then
    return
  end
  local r = run([[
# @assert status == 200
# @assert json.count == 2
# @assert duration < 10000
# @assert json.count == 99
GET %BASE%/json
]])
  local scripts = require("curlite.scripts")
  local passed, failed = scripts.tally(r.script)
  t.eq(passed, 3)
  t.eq(failed, 1)
  -- a passing assertion carries no message
  t.eq(r.script.tests[1].message, nil)
  t.match(r.script.tests[4].message, "evaluated to false")
end

function M.send_sequence_runs_in_order(t)
  if not server_up() then
    return
  end
  local doc = parser.parse(
    vim.split(
      ("### A\nGET %s/echo?n=1\n\n### B\nGET %s/echo?n=2\n\n### C\nGET %s/echo?n=3\n"):format(BASE, BASE, BASE),
      "\n",
      { plain = true }
    ),
    "/tmp/seq.http"
  )
  local done, got = false, {}
  exec.send_sequence(doc.requests, {
    on_each = function(result)
      table.insert(got, result.response.json.query.n)
    end,
    on_finish = function()
      done = true
    end,
  })
  vim.wait(20000, function()
    return done
  end, 20)
  t.eq(got, { "1", "2", "3" })
end

function M.abort_stops_the_sequence(t)
  if not server_up() then
    return
  end
  local doc = parser.parse(
    vim.split(
      ("### A\nGET %s/echo?n=1\n\n> {%% request.abort('stop') %%}\n\n### B\nGET %s/echo?n=2\n"):format(BASE, BASE),
      "\n",
      { plain = true }
    ),
    "/tmp/abort.http"
  )
  local done, count = false, 0
  exec.send_sequence(doc.requests, {
    on_each = function()
      count = count + 1
    end,
    on_finish = function()
      done = true
    end,
  })
  vim.wait(20000, function()
    return done
  end, 20)
  t.eq(count, 1)
end

function M.body_from_file(t)
  if not server_up() then
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local payload = dir .. "/payload.json"
  require("curlite.util").write_file(payload, '{"from":"file"}')

  local doc = parser.parse(
    vim.split(("POST %s/echo\nContent-Type: application/json\n\n< ./payload.json\n"):format(BASE), "\n", { plain = true }),
    dir .. "/req.http"
  )
  local r = exec.send_sync(doc.requests[1], 15000)
  t.eq(r.response.json.json, { from = "file" })
end

function M.response_redirect_writes_a_file(t)
  if not server_up() then
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local doc = parser.parse(
    vim.split(("GET %s/json\n\n>>! ./out.json\n"):format(BASE), "\n", { plain = true }),
    dir .. "/req.http"
  )
  exec.send_sync(doc.requests[1], 15000)
  local content = require("curlite.util").read_file(dir .. "/out.json")
  t.truthy(content, "file was not written")
  t.eq(vim.json.decode(content).count, 2)
end

function M.multipart_upload(t)
  if not server_up() then
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  require("curlite.util").write_file(dir .. "/a.txt", "file contents")

  local doc = parser.parse(vim.split(([[
POST %s/echo
Content-Type: multipart/form-data; boundary=Bnd

--Bnd
Content-Disposition: form-data; name="title"

hello
--Bnd
Content-Disposition: form-data; name="doc"; filename="a.txt"
Content-Type: text/plain

< ./a.txt
--Bnd--
]]):format(BASE), "\n", { plain = true }), dir .. "/req.http")

  local r = exec.send_sync(doc.requests[1], 15000)
  t.eq(r.response.status, 200)
  t.match(r.response.json.headers["content-type"], "multipart/form%-data")
  t.match(r.response.json.body, 'name="title"')
  t.match(r.response.json.body, "hello")
  t.match(r.response.json.body, "file contents")
  t.match(r.response.json.body, 'filename="a%.txt"')
end

function M.binary_response_is_detected(t)
  if not server_up() then
    return
  end
  local r = run("GET %BASE%/binary\n")
  t.truthy(require("curlite.format").is_binary(r.response.body, r.response.headers["Content-Type"]))
  t.eq(#r.response.body, 6)
end

function M.xml_is_formatted(t)
  if not server_up() then
    return
  end
  local r = run("GET %BASE%/xml\n")
  local formatted, ft = require("curlite.format").body(r.response.body, r.response.headers["Content-Type"])
  t.eq(ft, "xml")
  t.truthy(#vim.split(formatted, "\n") > 1, "xml was not indented")
end

function M.connection_refused_is_reported(t)
  local r = run("GET http://127.0.0.1:1/nope\n")
  t.truthy(r.error)
  t.match(r.error, "curl %(7%)")
  t.eq(r.response.status, 0)
end

function M.unresolved_variable_is_refused(t)
  local r = run("GET %BASE%/echo?x={{missing_var}}\n")
  t.eq(r.response, nil)
  t.match(r.error, "unresolved variable: missing_var")
end

function M.stats_are_populated(t)
  if not server_up() then
    return
  end
  local s = run("GET %BASE%/json\n").response.stats
  t.truthy(s.time_total and s.time_total > 0)
  t.truthy(s.size_download and s.size_download > 0)
  t.eq(s.method, "GET")
  t.truthy(s.remote_ip == "127.0.0.1")
end

function M.skip_metadata_skips_without_error(t)
  local r = run("# @skip\nGET %BASE%/json\n")
  t.truthy(r.skipped)
  t.eq(r.error, nil)
  t.eq(r.response, nil)
end

function M.run_metadata_sends_the_dependency_first(t)
  if not server_up() then
    return
  end
  variables.reset()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  require("curlite.util").write_file(
    dir .. "/api.http",
    ([[
### LOGIN
GET %s/json

> {%% client.global.set("tok", response.json.slideshow.title) %%}

### ME
# @run LOGIN
GET %s/echo?tok={{tok}}
]]):format(BASE, BASE)
  )

  local doc = parser.parse_file(dir .. "/api.http")
  local order = {}
  local done = false
  exec.send(doc.requests[2], {
    on_dependency = function(result)
      table.insert(order, result.raw.name)
    end,
    on_done = function(result)
      table.insert(order, result.raw.name)
      M._chain_result = result
      done = true
    end,
  })
  vim.wait(20000, function()
    return done
  end, 20)

  t.eq(order, { "LOGIN", "ME" })
  t.eq(M._chain_result.response.json.query.tok, "Sample Slide Show")
  variables.reset()
  env.globals = {}
end

function M.run_metadata_cycle_terminates(t)
  if not server_up() then
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  require("curlite.util").write_file(
    dir .. "/cycle.http",
    ([[
### A
# @run B
GET %s/echo?r=a

### B
# @run A
GET %s/echo?r=b
]]):format(BASE, BASE)
  )
  local doc = parser.parse_file(dir .. "/cycle.http")
  local done, count = false, 0
  exec.send(doc.requests[1], {
    on_dependency = function()
      count = count + 1
    end,
    on_done = function()
      count = count + 1
      done = true
    end,
  })
  t.truthy(vim.wait(20000, function()
    return done
  end, 20), "a @run cycle must terminate")
  -- B runs once, then A; A's own `@run B` is already in the chain.
  t.eq(count, 2)
end

function M.run_metadata_failure_blocks_the_request(t)
  if not server_up() then
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  require("curlite.util").write_file(
    dir .. "/dep.http",
    ([[
### BROKEN
GET http://127.0.0.1:1/nope

### NEEDS_IT
# @run BROKEN
GET %s/json
]]):format(BASE)
  )
  local doc = parser.parse_file(dir .. "/dep.http")
  local done, got = false, nil
  exec.send(doc.requests[2], {
    on_done = function(result)
      got = result
      done = true
    end,
  })
  vim.wait(20000, function()
    return done
  end, 20)
  t.truthy(got.skipped)
  t.match(got.error, "dependency failed")
  t.eq(got.response, nil)
end

function M.import_makes_another_files_requests_runnable(t)
  if not server_up() then
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  require("curlite.util").write_file(
    dir .. "/shared.http",
    ([[
### AUTH
GET %s/json

> {%% client.global.set("shared_tok", "from-import") %%}
]]):format(BASE)
  )
  require("curlite.util").write_file(
    dir .. "/main.http",
    ([[
# @import ./shared.http

### USE
# @run AUTH
GET %s/echo?tok={{shared_tok}}
]]):format(BASE)
  )

  local doc = parser.parse_file(dir .. "/main.http")
  t.eq(doc.imports, { "./shared.http" })

  local done, got = false, nil
  exec.send(doc.requests[1], {
    on_done = function(result)
      got = result
      done = true
    end,
  })
  vim.wait(20000, function()
    return done
  end, 20)
  t.eq(got.response.json.query.tok, "from-import")
  env.globals = {}
end

return M
