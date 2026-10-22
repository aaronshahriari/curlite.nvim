-- The YAML reader, which exists so a spec written in YAML needs no extra
-- tooling. It is a subset reader: these are the shapes it promises.

local yaml = require("curlite.yaml")

local M = {}

---@param text string
---@return any
local function decode(text)
  local value, err = yaml.decode(text)
  if value == nil then
    error("decode failed: " .. tostring(err), 2)
  end
  return value
end

function M.nested_mappings_and_scalars(t)
  local got = decode([[
info:
  title: Petstore
  version: "1.0"
  count: 3
  ratio: 1.5
  public: true
  private: false
  retired: null
]])
  t.eq(got.info.title, "Petstore")
  t.eq(got.info.version, "1.0", "a quoted number stays a string")
  t.eq(got.info.count, 3)
  t.eq(got.info.ratio, 1.5)
  t.eq(got.info.public, true)
  t.eq(got.info.private, false)
  t.eq(got.info.retired, nil)
end

function M.a_version_is_not_a_number(t)
  local got = decode("openapi: 3.0.0\nmajor: 3\n")
  t.eq(got.openapi, "3.0.0")
  t.eq(got.major, 3)
end

function M.sequences_of_mappings(t)
  local got = decode([[
parameters:
  - name: limit
    in: query
    required: false
  - name: id
    in: path
    required: true
]])
  t.eq(#got.parameters, 2)
  t.eq(got.parameters[1].name, "limit")
  t.eq(got.parameters[1]["in"], "query")
  t.eq(got.parameters[1].required, false)
  t.eq(got.parameters[2].required, true)
end

function M.a_sequence_may_sit_at_its_keys_indent(t)
  -- Legal YAML, and how hand-written specs are usually laid out.
  local got = decode([[
tags:
- pets
- store
servers:
- url: https://api.example.com
]])
  t.eq(got.tags, { "pets", "store" })
  t.eq(got.servers[1].url, "https://api.example.com")
end

function M.flow_collections(t)
  local got = decode([[
enum: [available, pending, sold]
empty: []
responses:
  "201": { description: created, headers: {} }
nested: [{ a: 1 }, { a: 2 }]
numbers: [1, 2.5, true]
]])
  t.eq(got.enum, { "available", "pending", "sold" })
  t.eq(got.empty, {})
  t.eq(got.responses["201"].description, "created")
  t.eq(got.responses["201"].headers, {})
  t.eq(got.nested[2].a, 2)
  t.eq(got.numbers, { 1, 2.5, true })
end

function M.quoted_scalars(t)
  local got = decode([[
plain: hello world
dq: "a \"quoted\" value\nwith a newline"
sq: 'it''s here'
hash: "a # not a comment"
url: https://example.com/path?a=1 # but this is
colon: "key: value"
]])
  t.eq(got.plain, "hello world")
  t.eq(got.dq, 'a "quoted" value\nwith a newline')
  t.eq(got.sq, "it's here")
  t.eq(got.hash, "a # not a comment")
  t.eq(got.url, "https://example.com/path?a=1")
  t.eq(got.colon, "key: value")
end

function M.comments_and_blank_lines_are_ignored(t)
  local got = decode([[
# leading comment
a: 1

# another
b: 2   # trailing
]])
  t.eq(got, { a = 1, b = 2 })
end

function M.block_scalars(t)
  local got = decode([[
literal: |
  line one
  line two
stripped: |-
  no trailing newline
folded: >-
  one long
  sentence
after: here
]])
  t.eq(got.literal, "line one\nline two\n")
  t.eq(got.stripped, "no trailing newline")
  t.eq(got.folded, "one long sentence")
  t.eq(got.after, "here", "the block ends where the indentation does")
end

function M.a_plain_scalar_folds_over_lines(t)
  local got = decode([[
description: a long description
  that carries on
  over lines
title: Petstore
]])
  t.eq(got.description, "a long description that carries on over lines")
  t.eq(got.title, "Petstore", "and the next key is still read")
end

function M.anchors_aliases_and_merge_keys(t)
  local got = decode([[
defaults: &defaults
  type: string
  required: true
first:
  <<: *defaults
  name: id
second: *defaults
]])
  t.eq(got.first.type, "string")
  t.eq(got.first.required, true)
  t.eq(got.first.name, "id")
  t.eq(got.second.type, "string")
end

function M.the_first_document_wins(t)
  local got = decode([[
---
a: 1
---
a: 2
]])
  t.eq(got.a, 1)
end

function M.keys_that_are_not_identifiers(t)
  local got = decode([[
paths:
  /pets/{petId}:
    get:
      responses:
        "200":
          description: ok
        404:
          description: gone
  "application/json":
    schema:
      $ref: "#/components/schemas/Pet"
]])
  t.eq(got.paths["/pets/{petId}"].get.responses["200"].description, "ok")
  t.eq(got.paths["/pets/{petId}"].get.responses["404"].description, "gone")
  t.eq(got.paths["application/json"].schema["$ref"], "#/components/schemas/Pet")
end

function M.an_empty_value_is_nil_not_a_truncation(t)
  local got = decode([[
a:
b: 2
c:
d: 4
]])
  t.eq(got.a, nil)
  t.eq(got.b, 2)
  t.eq(got.d, 4, "a key with no value does not swallow what follows")
end

function M.tab_indentation_is_an_error(t)
  local value, err = yaml.decode("a:\n\tb: 1\n")
  t.eq(value, nil)
  t.match(err, "tab")
end

function M.empty_input_is_an_error(t)
  local value, err = yaml.decode("")
  t.eq(value, nil)
  t.truthy(err)
end

return M
