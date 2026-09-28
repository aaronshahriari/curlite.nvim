local request_format = require("curlite.request_format")

local M = {}

function M.normalises_request_structure(t)
  local out = request_format.lines({
    "####    CREATE   ",
    "@token=abc",
    "post    https://example.com HTTP/1.1",
    "Content-Type :    application/json ",
    "    ?page=1",
  })
  t.eq(out, {
    "### CREATE",
    "@token = abc",
    "POST https://example.com HTTP/1.1",
    "Content-Type: application/json",
    "  ?page=1",
  })
end

function M.formats_json_and_preserves_templates(t)
  local out = request_format.lines({
    "POST https://example.com",
    "Content-Type: application/json",
    "",
    '{"name":"{{name}}","nonce":{{$randomInt 1 9}}}',
  })
  t.eq(table.concat(out, "\n"), table.concat({
    "POST https://example.com",
    "Content-Type: application/json",
    "",
    "{",
    '  "name": "{{name}}",',
    '  "nonce": {{$randomInt 1 9}}',
    "}",
  }, "\n"))
end

function M.leaves_non_json_bodies_untouched(t)
  local out = request_format.lines({ "POST https://example.com", "", "hello   world" })
  t.eq(out[3], "hello   world")
end

function M.does_not_treat_a_graphql_query_as_an_http_method(t)
  local out = request_format.lines({
    "GRAPHQL https://example.com/graphql",
    "",
    "query User($id: ID!) {",
    "  user(id: $id) { name }",
    "}",
  })
  t.eq(out[3], "query User($id: ID!) {")
end

function M.respects_the_bodies_toggle(t)
  local config = require("curlite.config")
  local previous = config.get().format.bodies
  config.get().format.bodies = false

  local out = request_format.lines({
    "POST https://example.com",
    "",
    '{"a":1}',
  })
  config.get().format.bodies = previous

  t.eq(out[3], '{"a":1}', "body is left alone when bodies = false")
end

function M.is_idempotent(t)
  local source = {
    "####  CREATE ",
    "post   https://example.com",
    "Content-Type :  application/json",
    "",
    '{"name":"{{who}}"}',
  }
  local once = request_format.lines(source)
  local twice = request_format.lines(once)
  t.eq(twice, once, "formatting an already-formatted document changes nothing")
end

return M
