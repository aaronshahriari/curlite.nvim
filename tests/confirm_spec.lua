local confirm = require("curlite.confirm")
local exec = require("curlite.exec")
local parser = require("curlite.parser")

local M = {}

local function parse(src)
  return parser.parse(vim.split(src, "\n", { plain = true }), "/tmp/confirm.http").requests[1]
end

function M.title_marker_guards_request_without_changing_name(t)
  local req = parse("### [confirm] Delete production user\nDELETE https://api.test/users/42\n")
  t.eq(req.name, "Delete production user")
  t.eq(req.metadata.confirm, true)
end

function M.title_marker_is_case_insensitive(t)
  local req = parse("### Deploy [CONFIRM]\nPOST https://api.test/deploy\n")
  t.eq(req.name, "Deploy")
  t.eq(req.metadata.confirm, true)
end

function M.metadata_marker_guards_untitled_request(t)
  local req = parse("# @confirm\nDELETE https://api.test/users/42\n")
  t.eq(req.metadata.confirm, true)
end

function M.preview_contains_resolved_request(t)
  local req = parse("POST https://api.test/users\nContent-Type: application/json\n\n{\"active\":false}\n")
  local cmd = require("curlite.curl").build(req)
  local lines = require("curlite.preview").lines(cmd)
  t.eq(lines[1], "POST https://api.test/users")
  t.truthy(vim.tbl_contains(lines, "Content-Type: application/json"))
  t.truthy(vim.tbl_contains(lines, '{"active":false}'))
end

function M.declining_does_not_spawn_request(t)
  exec.reset()
  local original = confirm.ask
  local asked = false
  confirm.ask = function(_, callback)
    asked = true
    callback(false)
  end

  local done, result = false, nil
  exec.send(parse("### [confirm] guarded\nDELETE https://api.test/users/42\n"), {
    on_done = function(value)
      result = value
      done = true
    end,
  })
  vim.wait(500, function()
    return done
  end, 10)
  confirm.ask = original

  t.truthy(asked)
  t.truthy(done)
  t.truthy(result.skipped)
  t.eq(result.response, nil)
  t.eq(exec.last, nil)
  exec.reset()
end

function M.dry_run_does_not_prompt(t)
  local original = confirm.ask
  local asked = false
  confirm.ask = function()
    asked = true
  end

  local done, result = false, nil
  exec.send(parse("### [confirm] guarded\nDELETE https://api.test/users/42\n"), {
    dry_run = true,
    on_done = function(value)
      result = value
      done = true
    end,
  })
  vim.wait(500, function()
    return done
  end, 10)
  confirm.ask = original

  t.falsy(asked)
  t.truthy(done)
  t.falsy(result.skipped)
  t.eq(result.response, nil)
  exec.reset()
end

return M
