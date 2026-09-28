local highlight = require("curlite.highlight")

local M = {}

local function marks(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  highlight.setup_highlights()
  highlight.refresh(buf)
  local ns = vim.api.nvim_get_namespaces().curlite_http
  local out = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  return vim.tbl_map(function(mark)
    return { row = mark[2], col = mark[3], details = mark[4] }
  end, out)
end

local function groups(all, row)
  local out = {}
  for _, mark in ipairs(all) do
    if mark.row == row then
      local group = mark.details.hl_group or mark.details.line_hl_group
      if group and not vim.tbl_contains(out, group) then
        table.insert(out, group)
      end
    end
  end
  return out
end

function M.request_structure_has_a_visual_hierarchy(t)
  local all = marks({
    "### [confirm] Remove user",
    "# this is a comment",
    "# @timeout 5000",
    "DELETE https://api.example.com/users/{{id}} HTTP/1.1",
    "Authorization: Bearer {{token}}",
    "Accept: application/json",
    "",
    '{"keep":"body: value"}',
  })

  local title = groups(all, 0)
  t.truthy(vim.tbl_contains(title, "CurliteHttpRequestLine"))
  t.truthy(vim.tbl_contains(title, "CurliteHttpRequestName"))
  t.truthy(vim.tbl_contains(title, "CurliteHttpConfirm"))
  t.truthy(vim.tbl_contains(groups(all, 1), "CurliteHttpComment"))
  t.truthy(vim.tbl_contains(groups(all, 2), "CurliteHttpMetadata"))

  local request = groups(all, 3)
  t.truthy(vim.tbl_contains(request, "CurliteHttpMethodDelete"))
  t.truthy(vim.tbl_contains(request, "CurliteHttpUrl"))
  t.truthy(vim.tbl_contains(request, "CurliteHttpVersion"))
  t.truthy(vim.tbl_contains(request, "CurliteHttpTemplate"))

  local secret = groups(all, 4)
  t.truthy(vim.tbl_contains(secret, "CurliteHttpRequestLine"))
  t.truthy(vim.tbl_contains(secret, "CurliteHttpHeaderName"))
  t.truthy(vim.tbl_contains(secret, "CurliteHttpSensitiveValue"))
  t.truthy(vim.tbl_contains(groups(all, 5), "CurliteHttpHeaderValue"))
  t.falsy(vim.tbl_contains(groups(all, 7), "CurliteHttpHeaderName"), "body fields are not headers")
end

function M.method_colours_reflect_risk(t)
  local all = marks({
    "### read",
    "GET https://x.dev",
    "",
    "### write",
    "POST https://x.dev",
    "",
    "### change",
    "PATCH https://x.dev",
  })
  t.truthy(vim.tbl_contains(groups(all, 1), "CurliteHttpMethodRead"))
  t.truthy(vim.tbl_contains(groups(all, 4), "CurliteHttpMethodWrite"))
  t.truthy(vim.tbl_contains(groups(all, 7), "CurliteHttpMethodChange"))
end

return M
