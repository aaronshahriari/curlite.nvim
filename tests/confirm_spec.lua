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
  -- A minified JSON body is re-indented for display, the same as `:Curlite format`.
  t.truthy(vim.tbl_contains(lines, "{"), "the body is spaced out as JSON")
  t.truthy(vim.tbl_contains(lines, '  "active": false'))
  t.truthy(vim.tbl_contains(lines, "}"))
  t.falsy(vim.tbl_contains(lines, '{"active":false}'), "not the minified original")
end

function M.preview_leaves_a_non_json_body_alone(t)
  local req = parse("POST https://api.test/form\nContent-Type: text/plain\n\na=1&b=2\n")
  local cmd = require("curlite.curl").build(req)
  local lines = require("curlite.preview").lines(cmd)
  t.truthy(vim.tbl_contains(lines, "a=1&b=2"), "only JSON gets re-indented")
end

function M.preview_leaves_broken_json_alone(t)
  local body = '{"active":false,}'
  local req = parse(
    "POST https://api.test/users\nContent-Type: application/json\n\n" .. body .. "\n"
  )
  local cmd = require("curlite.curl").build(req)
  local lines = require("curlite.preview").lines(cmd)
  t.truthy(vim.tbl_contains(lines, body), "a body mid-edit is shown as typed")
end

function M.preview_caps_width_and_wraps_long_url(t)
  local preview = require("curlite.preview")
  local url = "GET https://api.example.com/v1/forecast?" .. string.rep("x", 180)
  local geo = preview.geometry({ url, "Accept: application/json" }, {
    min_width = 44,
    max_width = 56,
    wrap = true,
  })
  t.eq(geo.width, 56)
  t.truthy(geo.height >= 4, "wrapped url should grow the frame instead of stretching it")

  local _, win = preview.open({ url, "Accept: application/json" }, {
    min_width = 44,
    max_width = 56,
    wrap = true,
    title = " confirm request ",
  })
  local cfg = vim.api.nvim_win_get_config(win)
  t.eq(cfg.width, 56)
  t.eq(vim.wo[win].wrap, true)
  t.eq(cfg.relative, "editor")
  vim.api.nvim_win_close(win, true)
end

function M.preview_stays_compact_for_short_request(t)
  local geo = require("curlite.preview").geometry({
    "DELETE https://api.test/users/42",
    "Accept: application/json",
  }, { min_width = 44, max_width = 72 })
  t.eq(geo.width, 44)
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

--- Drive the dialog for real. `ask` fails closed when no UI is attached, which
--- is right in production and useless here, so the check is stubbed out.
---@param body fun(buf: integer, win: integer)
local function with_dialog(body)
  local real_uis = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    return { { width = 120, height = 40 } }
  end

  local req = parse("### [confirm] Danger\nDELETE https://api.test/users/42\n")
  local cmd = require("curlite.curl").build(req)
  local answered = nil
  confirm.ask(cmd, function(ok)
    answered = ok
  end)

  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      win = w
    end
  end
  local ok, err = pcall(body, win and vim.api.nvim_win_get_buf(win), win)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  vim.api.nvim_list_uis = real_uis
  if not ok then
    error(err)
  end
  return answered
end

function M.dialog_hides_the_cursor_and_puts_it_back(t)
  local before = vim.o.guicursor
  local during
  with_dialog(function()
    during = vim.o.guicursor
  end)

  t.truthy(during and during:find("CurliteConfirmCursor", 1, true),
    "the block cursor is hidden so it cannot paint over the selected button")
  t.eq(vim.o.guicursor, before, "and `guicursor` is global, so it must be put back")
end

function M.closing_the_dialog_without_answering_fails_closed(t)
  -- `with_dialog` closes the window directly, never reaching the keymaps.
  local answered = with_dialog(function() end)
  vim.wait(50)
  t.eq(answered, false, "a dialog disposed of without an answer is a no")
  t.truthy(vim.o.guicursor:find("CurliteConfirmCursor", 1, true) == nil,
    "the cursor is restored on that path too")
end

function M.selected_button_is_a_solid_block_of_colour(t)
  with_dialog(function() end)
  -- The white square the user saw was the cursor, not this: both buttons are
  -- an inverted diagnostic colour, dark text on a solid background.
  for _, name in ipairs({ "CurliteConfirmYes", "CurliteConfirmNo" }) do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    t.truthy(hl.bg ~= nil or hl.reverse, name .. " has a solid background")
  end
end

return M
