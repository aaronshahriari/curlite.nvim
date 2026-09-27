local curl = require("curlite.curl")
local parser = require("curlite.parser")
local vars = require("curlite.variables")

local function build(src)
  local doc = parser.parse(vim.split(src, "\n", { plain = true }), "/tmp/curlite-test/t.http")
  local ctx = { vars = doc.variables, envvars = {}, globals = {}, dotenv = {}, prompts = {} }
  local resolved = vars.render_request(doc.requests[1], ctx)
  return curl.build(resolved)
end

--- index of `flag` in argv, or nil
local function idx(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return i
    end
  end
end

local function has(argv, flag)
  return idx(argv, flag) ~= nil
end

local function value_of(argv, flag)
  local i = idx(argv, flag)
  return i and argv[i + 1] or nil
end

--- every `--header` value
local function headers(argv)
  local out = {}
  for i, a in ipairs(argv) do
    if a == "--header" then
      table.insert(out, argv[i + 1])
    end
  end
  return out
end

local M = {}

function M.url_is_last_arg(t)
  local cmd = build("GET https://x.dev/a")
  t.eq(cmd.argv[#cmd.argv], "https://x.dev/a")
end

function M.get_has_no_request_flag(t)
  t.falsy(has(build("GET https://x.dev").argv, "--request"))
end

function M.post_sets_request_flag(t)
  t.eq(value_of(build("POST https://x.dev").argv, "--request"), "POST")
end

function M.head_uses_head_flag(t)
  local cmd = build("HEAD https://x.dev")
  t.truthy(has(cmd.argv, "--head"))
  t.falsy(has(cmd.argv, "--request"))
end

function M.headers_are_passed(t)
  local cmd = build("GET https://x.dev\nAccept: application/json\nX-Trace: 1\n")
  local h = headers(cmd.argv)
  t.truthy(vim.tbl_contains(h, "Accept: application/json"))
  t.truthy(vim.tbl_contains(h, "X-Trace: 1"))
end

function M.default_headers_fill_gaps_only(t)
  local cmd = build("GET https://x.dev\nUser-Agent: mine/1\n")
  local h = headers(cmd.argv)
  t.truthy(vim.tbl_contains(h, "User-Agent: mine/1"))
  t.falsy(vim.tbl_contains(h, "User-Agent: curlite.nvim"))
end

function M.default_header_added_when_absent(t)
  t.truthy(vim.tbl_contains(headers(build("GET https://x.dev").argv), "User-Agent: curlite.nvim"))
end

function M.body_goes_to_stdin(t)
  local cmd = build('POST https://x.dev\nContent-Type: application/json\n\n{"a":1}\n')
  t.eq(cmd.stdin, '{"a":1}')
  t.eq(value_of(cmd.argv, "--data-binary"), "@-")
end

function M.json_content_type_inferred(t)
  local cmd = build('POST https://x.dev\n\n{"a":1}\n')
  t.truthy(vim.tbl_contains(headers(cmd.argv), "Content-Type: application/json"))
end

function M.non_json_body_gets_no_content_type(t)
  local cmd = build("POST https://x.dev\n\nplain text\n")
  for _, h in ipairs(headers(cmd.argv)) do
    t.falsy(h:match("^Content%-Type"), "unexpected " .. h)
  end
end

function M.form_body_newlines_collapsed(t)
  local cmd = build([[
POST https://x.dev
Content-Type: application/x-www-form-urlencoded

sessionToken=abc
&firstResult=0
&maxResults=10
]])
  t.eq(cmd.stdin, "sessionToken=abc&firstResult=0&maxResults=10")
end

function M.collapse_form_body_direct(t)
  t.eq(curl.collapse_form_body("a=1\n  &b=2\r\n&c=3"), "a=1&b=2&c=3")
end

function M.basic_auth_becomes_user_flag(t)
  local cmd = build("GET https://x.dev\nAuthorization: Basic alice s3cret\n")
  t.eq(value_of(cmd.argv, "--user"), "alice:s3cret")
  t.truthy(has(cmd.argv, "--basic"))
  for _, h in ipairs(headers(cmd.argv)) do
    t.falsy(h:match("^Authorization"), "Authorization should have been consumed")
  end
end

function M.basic_auth_colon_form(t)
  t.eq(value_of(build("GET https://x.dev\nAuthorization: Basic alice:s3cret\n").argv, "--user"), "alice:s3cret")
end

function M.prencoded_basic_auth_is_left_alone(t)
  local cmd = build("GET https://x.dev\nAuthorization: Basic YWxpY2U6czNjcmV0\n")
  t.falsy(has(cmd.argv, "--user"))
  t.truthy(vim.tbl_contains(headers(cmd.argv), "Authorization: Basic YWxpY2U6czNjcmV0"))
end

function M.bearer_auth_stays_a_header(t)
  local cmd = build("GET https://x.dev\nAuthorization: Bearer tok\n")
  t.falsy(has(cmd.argv, "--user"))
  t.truthy(vim.tbl_contains(headers(cmd.argv), "Authorization: Bearer tok"))
end

function M.digest_auth(t)
  local cmd = build("GET https://x.dev\nAuthorization: Digest bob pw\n")
  t.truthy(has(cmd.argv, "--digest"))
  t.eq(value_of(cmd.argv, "--user"), "bob:pw")
end

function M.aws_sigv4(t)
  local cmd = build("GET https://x.dev\nAuthorization: AWS KEY SECRET eu-west-1 s3\n")
  t.eq(value_of(cmd.argv, "--aws-sigv4"), "aws:amz:eu-west-1:s3")
  t.eq(value_of(cmd.argv, "--user"), "KEY:SECRET")
end

function M.insecure_metadata(t)
  t.truthy(has(build("# @insecure\nGET https://x.dev\n").argv, "--insecure"))
end

function M.no_redirect_removes_location(t)
  t.falsy(has(build("# @no-redirect\nGET https://x.dev\n").argv, "--location"))
  t.truthy(has(build("GET https://x.dev\n").argv, "--location"))
end

function M.timeout_metadata_in_seconds(t)
  t.eq(value_of(build("# @timeout 2500\nGET https://x.dev\n").argv, "--max-time"), "2.500")
end

function M.accept_metadata(t)
  t.truthy(vim.tbl_contains(headers(build("# @accept application/xml\nGET https://x.dev\n").argv), "Accept: application/xml"))
end

function M.raw_curl_args_appended(t)
  local cmd = build("# @curl --compressed\nGET https://x.dev\n")
  t.truthy(has(cmd.argv, "--compressed"))
  -- still before the URL
  t.eq(cmd.argv[#cmd.argv], "https://x.dev")
end

function M.graphql_payload_query_only(t)
  local payload = curl.graphql_payload("query { me { id } }")
  t.eq(vim.json.decode(payload), { query = "query { me { id } }" })
end

function M.graphql_payload_with_variables(t)
  local payload = curl.graphql_payload('query ($id: ID!) { user(id: $id) { name } }\n\n{ "id": "42" }')
  t.eq(vim.json.decode(payload), {
    query = 'query ($id: ID!) { user(id: $id) { name } }',
    variables = { id = "42" },
  })
end

function M.graphql_request_becomes_json_post(t)
  local cmd = build("GRAPHQL https://x.dev/graphql\n\nquery { me { id } }\n")
  t.eq(value_of(cmd.argv, "--request"), "POST")
  t.eq(vim.json.decode(cmd.stdin), { query = "query { me { id } }" })
  t.truthy(vim.tbl_contains(headers(cmd.argv), "Content-Type: application/json"))
end

function M.graphql_via_request_type_header(t)
  local cmd = build("POST https://x.dev/graphql\nX-REQUEST-TYPE: GraphQL\n\nquery { me { id } }\n")
  t.eq(vim.json.decode(cmd.stdin).query, "query { me { id } }")
  for _, h in ipairs(headers(cmd.argv)) do
    t.falsy(h:match("^X%-REQUEST%-TYPE"))
  end
end

function M.multipart_becomes_form_args(t)
  local cmd = build([[
POST https://x.dev/upload
Content-Type: multipart/form-data; boundary=WebKitBoundary

--WebKitBoundary
Content-Disposition: form-data; name="title"

My title
--WebKitBoundary
Content-Disposition: form-data; name="avatar"; filename="a.png"
Content-Type: image/png

< ./a.png
--WebKitBoundary--
]])
  local forms = {}
  for i, a in ipairs(cmd.argv) do
    if a == "--form" then
      table.insert(forms, cmd.argv[i + 1])
    end
  end
  t.eq(forms[1], "title=My title")
  t.match(forms[2], "^avatar=@/tmp/curlite%-test/a%.png;filename=a%.png;type=image/png$")
  -- curl builds its own boundary, so ours must not be sent
  for _, h in ipairs(headers(cmd.argv)) do
    t.falsy(h:match("^Content%-Type: multipart"))
  end
end

function M.empty_header_uses_semicolon_form(t)
  local cmd = build("GET https://x.dev\nX-Empty:\n")
  t.truthy(vim.tbl_contains(headers(cmd.argv), "X-Empty;"))
end

function M.to_shell_is_pasteable(t)
  local cmd = build('POST https://x.dev\nContent-Type: application/json\n\n{"a":1}\n')
  local line = curl.to_shell(cmd)
  t.falsy(line:find("--dump-header"))
  t.falsy(line:find("--write-out"))
  t.falsy(line:find("--verbose"))
  t.match(line, "%-%-request POST")
  t.match(line, "%-%-data%-binary")
  t.match(line, "https://x%.dev")
end

function M.http_version_flag(t)
  t.truthy(has(build("GET https://x.dev HTTP/1.1").argv, "--http1.1"))
end

function M.cookie_jar_flags_present(t)
  t.truthy(has(build("GET https://x.dev").argv, "--cookie-jar"))
  t.falsy(has(build("# @no-cookie-jar\nGET https://x.dev\n").argv, "--cookie-jar"))
end

function M.sanitize_url_encodes_unsafe_characters(t)
  t.eq(curl.sanitize_url("http://x.dev/a?q=two words"), "http://x.dev/a?q=two%20words")
  -- an existing escape survives; a bare % becomes %25
  t.eq(curl.sanitize_url("http://x.dev/a%20b?c=100%"), "http://x.dev/a%20b?c=100%25")
  t.eq(curl.sanitize_url("http://x.dev/?a=<b>"), "http://x.dev/?a=%3Cb%3E")
  -- reserved characters that are legal must not be touched
  t.eq(
    curl.sanitize_url("https://x.dev/p;q/r?a=1&b[]=2#frag"),
    "https://x.dev/p;q/r?a=1&b[]=2#frag"
  )
end

function M.spaces_from_variables_are_encoded(t)
  local doc = parser.parse(
    vim.split("@name = two words\nGET https://x.dev/?q={{name}}\n", "\n", { plain = true })
  )
  local cmd = curl.build(
    vars.render_request(doc.requests[1], { vars = doc.variables, envvars = {}, globals = {}, dotenv = {}, prompts = {} })
  )
  t.eq(cmd.argv[#cmd.argv], "https://x.dev/?q=two%20words")
end

return M
