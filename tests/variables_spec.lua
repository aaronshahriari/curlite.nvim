local vars = require("curlite.variables")
local util = require("curlite.util")

local function ctx(t)
  return vim.tbl_extend("force", {
    vars = {},
    envvars = {},
    globals = {},
    dotenv = {},
    prompts = {},
  }, t or {})
end

local M = {}

function M.document_variable(t)
  t.eq(vars.render("{{host}}/x", ctx({ vars = { host = "https://a.dev" } })), "https://a.dev/x")
end

function M.env_variable(t)
  t.eq(vars.render("{{host}}", ctx({ envvars = { host = "prod.dev" } })), "prod.dev")
end

function M.document_beats_env(t)
  t.eq(
    vars.render("{{host}}", ctx({ vars = { host = "doc" }, envvars = { host = "env" } })),
    "doc"
  )
end

function M.globals_beat_document(t)
  t.eq(
    vars.render("{{t}}", ctx({ globals = { t = "g" }, vars = { t = "d" } })),
    "g"
  )
end

function M.recursive_expansion(t)
  local c = ctx({ vars = { host = "https://a.dev", base = "{{host}}/v1", url = "{{base}}/me" } })
  t.eq(vars.render("{{url}}", c), "https://a.dev/v1/me")
end

function M.unresolved_left_intact(t)
  local missing = {}
  t.eq(vars.render("{{nope}}/x", ctx(), missing), "{{nope}}/x")
  t.eq(missing, { "nope" })
end

function M.whitespace_in_braces(t)
  t.eq(vars.render("{{  host  }}", ctx({ vars = { host = "ok" } })), "ok")
end

function M.nested_env_lookup(t)
  local c = ctx({ envvars = { auth = { client_id = "abc" } } })
  t.eq(vars.render("{{auth.client_id}}", c), "abc")
end

function M.dynamic_uuid(t)
  local out = vars.render("{{$uuid}}", ctx())
  t.match(out, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
end

function M.dynamic_timestamp(t)
  local out = tonumber(vars.render("{{$timestamp}}", ctx()))
  t.truthy(out and math.abs(out - os.time()) < 5)
end

function M.dynamic_timestamp_offset(t)
  local now = tonumber(vars.render("{{$timestamp}}", ctx()))
  local tomorrow = tonumber(vars.render("{{$timestamp 1 d}}", ctx()))
  t.truthy(math.abs((tomorrow - now) - 86400) < 5)
end

function M.dynamic_iso_timestamp(t)
  t.match(vars.render("{{$isoTimestamp}}", ctx()), "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
end

function M.dynamic_random_int_range(t)
  for _ = 1, 20 do
    local n = tonumber(vars.render("{{$randomInt 5 7}}", ctx()))
    t.truthy(n >= 5 and n <= 7, "got " .. tostring(n))
  end
end

function M.dynamic_env(t)
  vim.env.CURLITE_TEST_VAR = "from-env"
  t.eq(vars.render("{{$env.CURLITE_TEST_VAR}}", ctx()), "from-env")
  t.eq(vars.render("{{$env CURLITE_TEST_VAR}}", ctx()), "from-env")
  vim.env.CURLITE_TEST_VAR = nil
end

function M.dynamic_dotenv(t)
  t.eq(vars.render("{{$dotenv TOKEN}}", ctx({ dotenv = { TOKEN = "dt" } })), "dt")
end

function M.dynamic_intellij_random(t)
  for _ = 1, 20 do
    local n = tonumber(vars.render("{{$random.integer(10, 12)}}", ctx()))
    t.truthy(n >= 10 and n <= 12, "got " .. tostring(n))
  end
  t.eq(#vars.render("{{$random.alphanumeric(8)}}", ctx()), 8)
end

function M.dynamic_datetime_rfc1123(t)
  t.match(
    vars.render("{{$datetime rfc1123}}", ctx()),
    "^%a%a%a, %d%d %a%a%a %d%d%d%d %d%d:%d%d:%d%d GMT$"
  )
end

function M.request_variable_from_response(t)
  vars.reset()
  vars.record("LOGIN", { headers = {} }, {
    status = 200,
    headers = { ["X-Trace"] = "t-1" },
    body = '{"data":{"token":"tok-9"},"ids":[10,20]}',
  })
  t.eq(vars.render("{{LOGIN.response.body.$.data.token}}", ctx()), "tok-9")
  t.eq(vars.render("{{LOGIN.response.body.$.ids[1]}}", ctx()), "20")
  t.eq(vars.render("{{LOGIN.response.headers.x-trace}}", ctx()), "t-1")
  t.eq(vars.render("{{LOGIN.response.status}}", ctx()), "200")
  vars.reset()
end

function M.request_variable_unknown_name_stays(t)
  vars.reset()
  local missing = {}
  t.eq(vars.render("{{NOPE.response.body.$.a}}", ctx(), missing), "{{NOPE.response.body.$.a}}")
  t.eq(missing, { "NOPE.response.body.$.a" })
end

function M.render_request_covers_every_field(t)
  local parser = require("curlite.parser")
  local doc = parser.parse(vim.split(
    "@h = https://a.dev\n@tok = xyz\nPOST {{h}}/x\nAuthorization: Bearer {{tok}}\n\n{\"a\":\"{{tok}}\"}\n",
    "\n",
    { plain = true }
  ))
  local resolved, missing = vars.render_request(doc.requests[1], ctx({ vars = doc.variables }))
  t.eq(missing, {})
  t.eq(resolved.url, "https://a.dev/x")
  t.eq(resolved.headers.Authorization, "Bearer xyz")
  t.eq(resolved.body, '{"a":"xyz"}')
end

function M.json_path_variants(t)
  local v = { a = { b = { 1, 2, { c = "deep" } } }, list = { "x", "y" } }
  t.eq(util.json_path(v, "$.a.b[2].c"), "deep")
  t.eq(util.json_path(v, "a.b.2.c"), "deep")
  t.eq(util.json_path(v, "$.list[0]"), "x")
  t.eq(util.json_path(v, "$"), v)
  t.eq(util.json_path(v, "$.nope.deeper"), nil)
end

function M.stringify_keeps_integers(t)
  t.eq(util.stringify(200), "200")
  t.eq(util.stringify(1.5), "1.5")
  t.eq(util.stringify(true), "true")
  t.eq(util.stringify(nil), "")
  t.eq(util.stringify({ a = 1 }), '{"a":1}')
end

return M
