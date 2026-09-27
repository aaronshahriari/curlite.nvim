local parser = require("curlite.parser")

local function parse(src)
  return parser.parse(vim.split(src, "\n", { plain = true }), "test.http")
end

local M = {}

function M.bare_get(t)
  local doc = parse([[
GET https://example.com/api
]])
  t.eq(#doc.requests, 1)
  t.eq(doc.requests[1].method, "GET")
  t.eq(doc.requests[1].url, "https://example.com/api")
end

function M.method_optional(t)
  local doc = parse("https://example.com/x")
  t.eq(doc.requests[1].method, "GET")
  t.eq(doc.requests[1].url, "https://example.com/x")
end

function M.http_version_stripped(t)
  local doc = parse("POST https://x.dev/y HTTP/1.1")
  t.eq(doc.requests[1].url, "https://x.dev/y")
  t.eq(doc.requests[1].http_version, "HTTP/1.1")
end

function M.separator_names_requests(t)
  local doc = parse([[
### Login
POST https://x.dev/login

### Fetch
GET https://x.dev/me
]])
  t.eq(#doc.requests, 2)
  t.eq(doc.requests[1].name, "Login")
  t.eq(doc.requests[2].name, "Fetch")
end

function M.name_metadata_wins(t)
  local doc = parse([[
###
# @name create_user
POST https://x.dev/users
]])
  t.eq(doc.requests[1].name, "create_user")
end

function M.headers_and_body(t)
  local doc = parse([[
POST https://x.dev/users
Content-Type: application/json
Authorization: Bearer abc

{
  "name": "aaron"
}
]])
  local r = doc.requests[1]
  t.eq(r.headers["Content-Type"], "application/json")
  t.eq(r.headers["Authorization"], "Bearer abc")
  t.eq(r.body, '{\n  "name": "aaron"\n}')
end

function M.header_lookup_is_case_insensitive(t)
  local doc = parse("GET https://x.dev\nCONTENT-type: text/plain\n")
  t.eq(parser.header(doc.requests[1], "content-type"), "text/plain")
end

function M.document_variables(t)
  local doc = parse([[
@host = https://x.dev
@token=abc123

GET {{host}}/me
Authorization: Bearer {{token}}
]])
  t.eq(doc.variables.host, "https://x.dev")
  t.eq(doc.variables.token, "abc123")
  t.eq(doc.requests[1].variables.token, "abc123")
end

function M.request_scoped_variables(t)
  -- With request scope (the default) a variable defined after a request is
  -- not visible to it.
  local doc = parse([[
@a = 1

GET https://x.dev/one

@b = 2

GET https://x.dev/two
]])
  t.eq(doc.requests[1].variables, { a = "1" })
  t.eq(doc.requests[2].variables, { a = "1", b = "2" })
end

function M.url_continuation(t)
  local doc = parse([[
GET https://x.dev/search
  ?q=neovim
  &lang=lua
Accept: application/json
]])
  t.eq(doc.requests[1].url, "https://x.dev/search?q=neovim&lang=lua")
  t.eq(doc.requests[1].headers.Accept, "application/json")
end

function M.form_body_continuation(t)
  -- The user's real-world shape: form-urlencoded with leading `&` lines.
  local doc = parse([[
POST https://api.example.com/betHistory
Content-Type: application/x-www-form-urlencoded

sessionToken={{token}}
&firstResult=0
&maxResults=10
]])
  t.eq(doc.requests[1].body, "sessionToken={{token}}\n&firstResult=0\n&maxResults=10")
end

function M.body_from_file(t)
  local doc = parse([[
POST https://x.dev/upload
Content-Type: application/json

< ./payload.json
]])
  t.eq(doc.requests[1].body_file, "./payload.json")
  t.eq(doc.requests[1].body, nil)
end

function M.inline_post_script(t)
  local doc = parse([[
POST https://x.dev/login

> {%
  client.global.set("token", response.body.json.token)
%}
]])
  t.eq(#doc.requests[1].post_scripts, 1)
  t.eq(doc.requests[1].post_scripts[1].kind, "inline")
  t.match(doc.requests[1].post_scripts[1].body, "client%.global%.set")
end

function M.one_line_inline_script(t)
  local doc = parse('GET https://x.dev\n\n> {% log(response.status) %}\n')
  t.eq(#doc.requests[1].post_scripts, 1)
  t.eq(doc.requests[1].post_scripts[1].body, "log(response.status) ")
end

function M.external_scripts(t)
  local doc = parse([[
< ./sign.lua
POST https://x.dev/secure

> ./check.lua
]])
  local r = doc.requests[1]
  t.eq(r.pre_scripts[1], { kind = "file", body = "./sign.lua" })
  t.eq(r.post_scripts[1], { kind = "file", body = "./check.lua" })
end

function M.response_redirect(t)
  local doc = parse("GET https://x.dev/big.json\n\n>>! ./out.json\n")
  t.eq(doc.requests[1].redirect, { path = "./out.json", overwrite = true })
end

function M.metadata_flags_and_prompts(t)
  local doc = parse([[
# @insecure
# @timeout 5000
# @prompt api_key Paste the API key
GET https://x.dev
]])
  local m = doc.requests[1].metadata
  t.eq(m.insecure, true)
  t.eq(m.timeout, "5000")
  t.eq(m.prompts, { { name = "api_key", description = "Paste the API key" } })
end

function M.curl_metadata_appends_args(t)
  local doc = parse('# @curl --compressed --http2 -H "X-A: 1"\nGET https://x.dev\n')
  t.eq(doc.requests[1].curl_args, { "--compressed", "--http2", "-H", "X-A: 1" })
end

function M.asserts_collected(t)
  local doc = parse([[
# @assert status == 200
# @assert body.json.ok == true
GET https://x.dev
]])
  t.eq(doc.requests[1].metadata.asserts, { "status == 200", "body.json.ok == true" })
end

function M.slash_comments(t)
  local doc = parse("// just a note\n// @name noted\nGET https://x.dev\n")
  t.eq(doc.requests[1].name, "noted")
end

function M.folded_header(t)
  local doc = parse("GET https://x.dev\nX-Long: one\n  two\n\n")
  t.eq(doc.requests[1].headers["X-Long"], "one two")
end

function M.request_at_cursor(t)
  local doc = parse([[
### one
GET https://x.dev/1

### two
GET https://x.dev/2
]])
  local r = parser.request_at(doc, 2)
  t.eq(r.name, "one")
  r = parser.request_at(doc, 5)
  t.eq(r.name, "two")
  -- A blank line after the last request still resolves to it.
  r = parser.request_at(doc, 7)
  t.eq(r.name, "two")
end

function M.split_args_quoting(t)
  t.eq(parser.split_args([[-H "X: a b" --flag 'q r']]), { "-H", "X: a b", "--flag", "q r" })
end

function M.trailing_blank_lines_trimmed_from_body(t)
  local doc = parse("POST https://x.dev\n\nbody here\n\n\n")
  t.eq(doc.requests[1].body, "body here")
end

function M.missing_blank_line_before_body_is_forgiving(t)
  local doc = parse('POST https://x.dev\nContent-Type: application/json\n{"a":1}\n')
  t.eq(doc.requests[1].body, '{"a":1}')
end

return M
