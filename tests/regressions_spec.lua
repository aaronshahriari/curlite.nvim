local config = require("curlite.config")
local curl = require("curlite.curl")
local parser = require("curlite.parser")
local vars = require("curlite.variables")

local M = {}

local function ctx()
  return { vars = {}, envvars = {}, globals = {}, dotenv = {}, prompts = {} }
end

function M.curl_write_out_uses_supported_json_variable(t)
  t.eq(curl.write_out, "%{json}")
end

function M.last_response_can_be_referenced(t)
  vars.reset()
  vars.record(nil, {}, { status = 201, body = '{"id":42}', headers = {} })
  t.eq(vars.render("{{$last.response.status}}", ctx()), "201")
  t.eq(vars.render("{{$last.response.body.$.id}}", ctx()), "42")
  vars.reset()
end

function M.document_scope_uses_final_assignment(t)
  config.setup({ request = { variables_scope = "document" } })
  local doc = parser.parse({
    "@host = https://first.test",
    "### one",
    "GET {{host}}/one",
    "",
    "@host = https://final.test",
    "### two",
    "GET {{host}}/two",
  })

  t.eq(doc.requests[1].variables.host, "https://final.test")
  t.eq(doc.requests[2].variables.host, "https://final.test")
  config.setup()
end

return M
