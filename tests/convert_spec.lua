local convert = require("curlite.convert")
local parser = require("curlite.parser")

--- Convert, then parse the result back, so the assertions are about the
--- request that comes out rather than about exact formatting.
local function roundtrip(command)
  local lines, err = convert.from_curl(command)
  if not lines then
    return nil, err
  end
  local doc = parser.parse(lines, "/tmp/curlite-convert/t.http")
  return doc.requests[1], nil, lines
end

local M = {}

function M.simple_get(t)
  local req = roundtrip("curl https://api.example.com/users")
  t.eq(req.method, "GET")
  t.eq(req.url, "https://api.example.com/users")
end

function M.method_and_headers(t)
  local req = roundtrip(
    [[curl -X POST 'https://api.example.com/users' -H 'Content-Type: application/json' -H 'Authorization: Bearer abc' -d '{"name":"aaron"}']]
  )
  t.eq(req.method, "POST")
  t.eq(req.headers["Content-Type"], "application/json")
  t.eq(req.headers["Authorization"], "Bearer abc")
  t.eq(vim.json.decode(req.body), { name = "aaron" })
end

function M.method_is_inferred_from_data(t)
  t.eq(roundtrip("curl https://x.dev -d 'a=1'").method, "POST")
end

function M.line_continuations_are_joined(t)
  local req = roundtrip([[
curl 'https://x.dev/a' \
  -H 'Accept: application/json' \
  -H 'X-Trace: 1'
]])
  t.eq(req.url, "https://x.dev/a")
  t.eq(req.headers["X-Trace"], "1")
end

function M.leading_shell_prompt_is_stripped(t)
  t.eq(roundtrip("$ curl https://x.dev/a").url, "https://x.dev/a")
end

function M.long_flag_with_equals(t)
  local req = roundtrip("curl --request=PUT --url=https://x.dev/a")
  t.eq(req.method, "PUT")
  t.eq(req.url, "https://x.dev/a")
end

function M.user_becomes_basic_auth(t)
  t.eq(roundtrip("curl -u alice:s3cret https://x.dev").headers["Authorization"], "Basic alice s3cret")
end

function M.user_agent_and_cookie_flags(t)
  local req = roundtrip("curl -A 'mybot/1' -b 'session=abc' https://x.dev")
  t.eq(req.headers["User-Agent"], "mybot/1")
  t.eq(req.headers["Cookie"], "session=abc")
end

function M.insecure_becomes_metadata(t)
  local req = roundtrip("curl -k https://x.dev")
  t.eq(req.metadata.insecure, true)
end

function M.max_time_becomes_a_timeout_in_ms(t)
  t.eq(roundtrip("curl --max-time 5 https://x.dev").metadata.timeout, "5000")
end

function M.head_flag(t)
  t.eq(roundtrip("curl -I https://x.dev").method, "HEAD")
end

function M.get_flag_moves_data_into_the_query(t)
  local req = roundtrip("curl -G -d 'a=1&b=2' https://x.dev/search")
  t.eq(req.method, "GET")
  t.eq(req.url, "https://x.dev/search?a=1&b=2")
  t.eq(req.body, nil)
end

function M.form_body_is_split_onto_lines(t)
  local req, _, lines = roundtrip("curl -d 'a=1&b=2&c=3' https://x.dev")
  -- Readable in the file...
  t.truthy(vim.tbl_contains(lines, "&b=2"))
  -- ...and collapsed back on the way out.
  t.eq(require("curlite.curl").collapse_form_body(req.body), "a=1&b=2&c=3")
end

function M.multipart_form_flags(t)
  local req = roundtrip([[curl -F 'title=hello' -F 'doc=@/tmp/a.txt' https://x.dev/upload]])
  t.eq(req.method, "POST")
  t.match(req.headers["Content-Type"], "^multipart/form%-data; boundary=")
  t.match(req.body, 'name="title"')
  t.match(req.body, "hello")
  t.match(req.body, 'filename="a%.txt"')
  t.match(req.body, "< /tmp/a%.txt")
end

function M.unknown_flags_are_preserved(t)
  local req = roundtrip("curl --tlsv1.3 https://x.dev")
  t.eq(req.curl_args, { "--tlsv1.3" })
end

function M.data_urlencode(t)
  local req = roundtrip("curl --data-urlencode 'q=two words' https://x.dev/s")
  t.eq(req.headers["Content-Type"], "application/x-www-form-urlencoded")
  t.match(req.body, "q=two words")
end

function M.no_url_is_an_error(t)
  local req, err = roundtrip("curl -X POST -H 'A: b'")
  t.eq(req, nil)
  t.match(err, "no URL")
end

function M.not_a_curl_command(t)
  local _, err = convert.from_curl("wget https://x.dev")
  t.match(err, "no `curl` command found")
end

function M.browser_copy_as_curl(t)
  -- The shape Chrome's devtools produces.
  local req = roundtrip([[
curl 'https://api.example.com/v1/items?page=2' \
  -H 'accept: application/json, text/plain, */*' \
  -H 'accept-language: en-US,en;q=0.9' \
  -H 'authorization: Bearer eyJhbGciOi' \
  -H 'content-type: application/json' \
  --data-raw '{"filter":{"status":"open"},"limit":50}' \
  --compressed
]])
  t.eq(req.method, "POST")
  t.eq(req.url, "https://api.example.com/v1/items?page=2")
  t.eq(req.headers["authorization"], "Bearer eyJhbGciOi")
  t.eq(req.metadata.compressed, true)
  t.eq(vim.json.decode(req.body), { filter = { status = "open" }, limit = 50 })
end

function M.round_trip_through_to_curl(t)
  -- http -> curl -> http must land on the same request.
  local doc = parser.parse(
    vim.split(
      'POST https://x.dev/a\nContent-Type: application/json\nX-Trace: 1\n\n{"a":1}\n',
      "\n",
      { plain = true }
    ),
    "/tmp/rt.http"
  )
  local line, err = convert.to_curl(doc.requests[1])
  t.truthy(line, err)
  local back = roundtrip(line)
  t.eq(back.method, "POST")
  t.eq(back.url, "https://x.dev/a")
  t.eq(back.headers["Content-Type"], "application/json")
  t.eq(back.headers["X-Trace"], "1")
  t.eq(vim.json.decode(back.body), { a = 1 })
end

function M.unknown_value_flag_does_not_swallow_the_url(t)
  -- `--cookie-jar` takes a path; without knowing that, the path would be read
  -- as the URL and the real URL would be dropped.
  local req = roundtrip("curl --cookie-jar /tmp/jar.txt --retry 3 https://x.dev/a")
  t.eq(req.url, "https://x.dev/a")
end

function M.url_is_picked_out_of_several_positionals(t)
  local req = roundtrip("curl --oauth2-bearer tok https://x.dev/a")
  t.eq(req.url, "https://x.dev/a")
end

function M.cookie_file_is_not_turned_into_a_header(t)
  local req = roundtrip("curl -b /tmp/jar.txt https://x.dev/a")
  t.eq(req.headers["Cookie"], nil)
  t.eq(req.url, "https://x.dev/a")
end

function M.bare_domain_without_scheme(t)
  t.eq(roundtrip("curl example.com/api").url, "example.com/api")
end

return M
