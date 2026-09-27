local format = require("curlite.format")

local M = {}

function M.json_indents(t)
  t.eq(format.json('{"a":1,"b":[1,2]}', 2), '{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}')
end

function M.json_keeps_key_order(t)
  -- A decode/encode round trip would sort or shuffle these; walking the text
  -- does not.
  local out = format.json('{"zebra":1,"apple":2,"mango":3}', 2)
  t.eq(out:find("zebra") < out:find("apple"), true)
  t.eq(out:find("apple") < out:find("mango"), true)
end

function M.json_empty_containers_stay_inline(t)
  t.eq(format.json('{"a":{},"b":[]}', 2), '{\n  "a": {},\n  "b": []\n}')
end

function M.json_strings_are_untouched(t)
  -- Braces, colons and commas inside a string must not trigger indentation.
  local out = format.json('{"s":"a{b}c: d, e","t":1}', 2)
  t.match(out, '"s": "a{b}c: d, e"')
end

function M.json_escaped_quote_in_string(t)
  local out = format.json('{"s":"he said \\"hi\\"","n":1}', 2)
  t.match(out, '"n": 1')
  t.match(out, 'he said')
end

function M.json_preserves_big_integers(t)
  -- Round-tripping through a Lua double would turn this into 1.2345678901235e+19.
  local out = format.json('{"id":12345678901234567890}', 2)
  t.match(out, "12345678901234567890")
end

function M.xml_indents(t)
  local out = format.xml("<a><b>1</b><b>2</b></a>", 2)
  t.eq(out, "<a>\n  <b>1</b>\n  <b>2</b>\n</a>")
end

function M.xml_self_closing_does_not_indent(t)
  t.eq(format.xml("<a><b/><c/></a>", 2), "<a>\n  <b/>\n  <c/>\n</a>")
end

function M.filetype_from_content_type(t)
  t.eq(format.filetype("application/json; charset=utf-8"), "json")
  t.eq(format.filetype("application/problem+json"), "json")
  t.eq(format.filetype("text/html"), "html")
  t.eq(format.filetype("application/xml"), "xml")
  t.eq(format.filetype("text/plain"), "text")
  t.eq(format.filetype(nil), nil)
end

function M.body_formats_json_without_a_content_type(t)
  local out, ft = format.body('{"a":1}', nil)
  t.eq(ft, "json")
  t.match(out, '"a": 1')
end

function M.body_leaves_plain_text_alone(t)
  local out, ft = format.body("just text", "text/plain")
  t.eq(out, "just text")
  t.eq(ft, "text")
end

function M.body_skips_formatting_over_the_size_limit(t)
  local config = require("curlite.config")
  local saved = config.get().response.max_format_size
  config.get().response.max_format_size = 10
  local out = format.body('{"a":1,"bbbbbbbbbbbbbb":2}', "application/json")
  t.eq(out, '{"a":1,"bbbbbbbbbbbbbb":2}', "a large body must come back raw")
  config.get().response.max_format_size = saved
end

function M.is_binary(t)
  t.truthy(format.is_binary("\0\1\2", "application/octet-stream"))
  t.truthy(format.is_binary("whatever", "image/png"))
  t.truthy(format.is_binary("abc\0def", nil))
  t.falsy(format.is_binary('{"a":1}', "application/json"))
end

function M.jq_filter(t)
  if vim.fn.executable("jq") == 0 then
    return
  end
  t.eq(format.jq('{"a":{"b":42}}', ".a.b"), "42")
  local out, err = format.jq('{"a":1}', "this is not jq")
  t.eq(out, nil)
  t.truthy(err)
end

return M
