-- The bundled syntax file is what runs when there is no treesitter `http`
-- parser, which is the default on a fresh install -- so it is worth testing.

local M = {}

local function highlighted(lines)
  vim.cmd("syntax enable")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "http"
  vim.cmd("syntax sync fromstart")

  --- The distinct syntax group names on a 1-indexed line.
  return function(lnum)
    local line = vim.fn.getline(lnum)
    local names = {}
    for col = 1, math.max(#line, 1) do
      local name = vim.fn.synIDattr(vim.fn.synID(lnum, col, 1), "name")
      if name ~= "" and not vim.tbl_contains(names, name) then
        table.insert(names, name)
      end
    end
    return names
  end
end

local function has(names, want)
  return vim.tbl_contains(names, want)
end

function M.separator_is_not_a_comment(t)
  local groups = highlighted({ "### LOGIN", "# just a note", "GET https://x.dev" })
  -- A `syn match` defined later wins at the same position, so without an
  -- explicit lookahead httpComment swallows every `###` line.
  t.truthy(has(groups(1), "httpSeparator"), "### should be a separator")
  t.truthy(has(groups(1), "httpRequestName"), "the name after ### should stand out")
  t.falsy(has(groups(1), "httpComment"), "### must not be a comment")
  t.truthy(has(groups(2), "httpComment"))
end

function M.metadata_inside_a_comment(t)
  local groups = highlighted({ "# @assert status == 200", "GET https://x.dev" })
  t.truthy(has(groups(1), "httpComment"))
  t.truthy(has(groups(1), "httpMetadata"))
end

function M.request_line(t)
  local groups = highlighted({ "POST https://x.dev/a HTTP/1.1" })
  t.truthy(has(groups(1), "httpMethod"))
  t.truthy(has(groups(1), "httpURL"))
  t.truthy(has(groups(1), "httpVersion"))
end

function M.headers_and_templates(t)
  local groups = highlighted({
    "@token = abc",
    "GET https://x.dev",
    "Authorization: Bearer {{token}}",
    "  ?q=1",
  })
  t.truthy(has(groups(1), "httpVariableDef"))
  t.truthy(has(groups(3), "httpHeaderName"))
  t.truthy(has(groups(3), "httpHeaderValue"))
  t.truthy(has(groups(3), "httpTemplate"), "{{...}} should light up in a header value")
  t.truthy(has(groups(4), "httpURLCont"))
end

function M.json_body_gets_json_highlighting(t)
  local groups = highlighted({
    "POST https://x.dev",
    "Content-Type: application/json",
    "",
    "{",
    '  "name": "aaron",',
    '  "nested": { "a": 1 }',
    "}",
    "",
    "### NEXT",
    "GET https://x.dev/next",
  })
  t.truthy(has(groups(5), "httpJsonBody"), "the body should be a JSON region")
  t.truthy(
    #vim.tbl_filter(function(n)
      return n:match("^json")
    end, groups(5)) > 0,
    "json.vim groups should apply inside the body"
  )
  -- The region must stop at the next separator rather than run to EOF.
  t.truthy(has(groups(9), "httpSeparator"), "the JSON region leaked past ###")
  t.falsy(has(groups(9), "httpJsonBody"))
end

function M.json_region_survives_a_nested_closing_brace(t)
  -- An indented `}` closing a nested object must not end the body region.
  local groups = highlighted({
    "POST https://x.dev",
    "",
    "{",
    '  "outer": {',
    '    "inner": 1',
    "  },",
    '  "after": true',
    "}",
  })
  t.truthy(has(groups(7), "httpJsonBody"), "the region ended at the nested }")
end

function M.script_block_is_lua(t)
  local groups = highlighted({
    "GET https://x.dev",
    "",
    "> {%",
    '  local x = "hi"',
    "%}",
  })
  t.truthy(
    #vim.tbl_filter(function(n)
      return n:match("^lua")
    end, groups(4)) > 0,
    "lua syntax should apply inside a script block"
  )
end

function M.file_body_and_redirect(t)
  local groups = highlighted({
    "POST https://x.dev",
    "",
    "< ./payload.json",
  })
  t.truthy(has(groups(3), "httpBodyFile"))

  groups = highlighted({ "GET https://x.dev", "", ">>! ./out.json" })
  t.truthy(has(groups(3), "httpRedirect"))
end

return M
