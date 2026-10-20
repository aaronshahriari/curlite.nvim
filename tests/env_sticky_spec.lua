-- The environment you chose has to stay chosen.
--
-- Selection is dropped deliberately -- when you arrive in a project, so a
-- request can never go out against whichever environment happened to be
-- active last time. Everything else must leave it alone. curlite's own
-- scratch buffers (the confirm dialog, the inspect float, the hover preview)
-- carry `filetype=http` for the highlighting, so they raise `FileType` just
-- like opening a request file does; before this was pinned down, confirming a
-- request unset the environment for the next one.

local curlite = require("curlite")
local env = require("curlite.env")
local exec = require("curlite.exec")
local parser = require("curlite.parser")
local util = require("curlite.util")

local M = {}

local HTTP = "GET http://127.0.0.1:1/never\n"
local GUARDED = "### [confirm] Danger\nDELETE http://127.0.0.1:1/users/42\n"
local ENV_FILE = [[{ "$curliteshared": { "a": "1" }, "dev": {}, "prod": {} }]]

---@param files table<string, string>
---@return string dir
local function project(files)
  local dir = vim.fn.tempname()
  for name, content in pairs(files) do
    util.write_file(dir .. "/" .. name, content)
  end
  vim.fn.mkdir(dir .. "/.git", "p")
  env.reset()
  require("curlite.config").setup({})
  curlite.setup({})
  return dir
end

--- Run `fn` with the working directory inside `dir`, the way you would have
--- opened the editor on the project. It matters: curlite's own scratch
--- buffers have no path, so anything that resolves them falls back to the
--- working directory -- and in real use that is the project you are in.
---@param dir string
---@param fn fun()
local function in_dir(dir, fn)
  local before = vim.fn.getcwd()
  vim.cmd("lcd " .. vim.fn.fnameescape(dir))
  local ok, err = pcall(fn)
  vim.cmd("lcd " .. vim.fn.fnameescape(before))
  if not ok then
    error(err, 0)
  end
end

---@param path string
local function open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Run `fn` with `exec.send` recorded rather than performed.
---@param fn fun()
---@return table[] sent
local function capture(fn)
  local sent = {}
  local real = exec.send
  exec.send = function(req)
    table.insert(sent, req)
  end
  local ok, err = pcall(fn)
  exec.send = real
  if not ok then
    error(err, 0)
  end
  return sent
end

--- The open environment picker, if there is one.
---@return integer|nil win
local function picker_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative ~= "" and type(cfg.title) == "table" then
      for _, chunk in ipairs(cfg.title) do
        if type(chunk[1]) == "string" and chunk[1]:find("Environment") then
          return win
        end
      end
    end
  end
end

--- Open the confirm dialog for real and answer it. `ask` fails closed with no
--- UI attached, which is right in production and useless here.
---@param answer string  the keys to answer with
---@return boolean|nil approved
local function confirm_with(answer)
  local real_uis = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    return { { width = 120, height = 40 } }
  end

  local doc = parser.parse(vim.split(GUARDED, "\n", { plain = true }), "/tmp/guarded.http")
  local req = doc.requests[1]
  local cmd = require("curlite.curl").build(req)
  local approved = nil
  local ok, err = pcall(function()
    require("curlite.confirm").ask(cmd, function(value)
      approved = value
    end)
    local win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        win = w
      end
    end
    if win then
      vim.api.nvim_win_call(win, function()
        vim.api.nvim_feedkeys(vim.keycode(answer), "x", false)
      end)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
  end)

  vim.api.nvim_list_uis = real_uis
  if not ok then
    error(err, 0)
  end
  return approved
end

function M.confirming_a_request_keeps_the_environment(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = GUARDED })
  in_dir(dir, function()
    open(dir .. "/api.http")
    env.select("prod", dir .. "/api.http")

    t.eq(confirm_with("y<CR>"), true, "the dialog was answered yes")
    t.eq(
      env.current(dir .. "/api.http"),
      "prod",
      "the dialog is not a file: answering it must not unset the environment"
    )
    t.truthy(env.chosen(dir .. "/api.http"), "and the next send must not stop to ask again")
  end)
end

function M.declining_a_request_keeps_the_environment(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = GUARDED })
  in_dir(dir, function()
    open(dir .. "/api.http")
    env.select("dev", dir .. "/api.http")

    t.eq(confirm_with("n<CR>"), false)
    t.eq(env.current(dir .. "/api.http"), "dev")
  end)
end

function M.inspecting_a_request_keeps_the_environment(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  in_dir(dir, function()
    open(dir .. "/api.http")
    env.select("prod", dir .. "/api.http")

    curlite.inspect()
    -- The float took focus; close it the way `q` does.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        vim.api.nvim_win_close(win, true)
      end
    end

    t.eq(env.current(dir .. "/api.http"), "prod", "a preview float is not a file open")
  end)
end

function M.hovering_a_request_keeps_the_environment(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  in_dir(dir, function()
    open(dir .. "/api.http")
    env.select("prod", dir .. "/api.http")

    local preview = require("curlite.preview")
    local req = parser.parse_buffer(0).requests[1]
    preview.open(preview.lines(require("curlite.curl").build(req)))
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        vim.api.nvim_win_close(win, true)
      end
    end

    t.eq(env.current(dir .. "/api.http"), "prod")
  end)
end

function M.opening_a_second_file_in_the_project_keeps_the_environment(t)
  local dir = project({
    ["http-client.env.json"] = ENV_FILE,
    ["api.http"] = HTTP,
    ["users.http"] = HTTP,
  })
  open(dir .. "/api.http")
  env.select("prod", dir .. "/api.http")

  open(dir .. "/users.http")

  t.eq(
    env.current(dir .. "/users.http"),
    "prod",
    "you chose for the project, and you are still in it"
  )
  t.eq(env.current(dir .. "/api.http"), "prod", "the file you came from keeps it too")

  local sent = capture(function()
    curlite.run_at_cursor()
  end)
  t.eq(#sent, 1, "and sending does not stop to ask")
  t.falsy(picker_win())
end

function M.re_reading_the_file_keeps_the_environment(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  open(dir .. "/api.http")
  env.select("prod", dir .. "/api.http")

  -- `:e` is what 'autoread', a formatter or a branch switch amounts to: the
  -- same buffer, read again. It is not arriving in the project.
  vim.cmd("edit!")

  t.eq(env.current(dir .. "/api.http"), "prod")
end

function M.leaving_the_project_and_coming_back_asks_again(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  open(dir .. "/api.http")
  env.select("prod", dir .. "/api.http")

  -- Nothing from this project is open any more, so the next arrival is a
  -- fresh one. This is the safety property the whole design exists for.
  vim.cmd("bwipeout!")
  open(dir .. "/api.http")

  t.falsy(env.chosen(dir .. "/api.http"), "re-entering the project starts with no environment")
end

function M.a_guarded_request_does_not_change_the_rest_of_the_run(t)
  local dir = project({
    ["http-client.env.json"] = [[{
      "dev": { "host": "http://127.0.0.1:1" },
      "prod": { "host": "http://127.0.0.1:2" }
    }]],
    ["api.http"] = "### [confirm] Danger\nDELETE {{host}}/users/42\n\n"
      .. "### Next\nGET {{host}}/ping\n",
  })
  in_dir(dir, function()
    open(dir .. "/api.http")
    env.select("prod", dir .. "/api.http")

    -- The real dialog, answered yes while the run is in flight.
    local real_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return { { width = 120, height = 40 } }
    end

    local urls, done, answered = {}, false, false
    local ok, err = pcall(function()
      exec.send_sequence(parser.parse_buffer(0).requests, {
        on_each = function(result)
          table.insert(urls, result.request and result.request.url)
        end,
        on_finish = function()
          done = true
        end,
      })
      vim.wait(5000, function()
        if not answered then
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(win).relative ~= "" then
              answered = true
              vim.api.nvim_win_call(win, function()
                vim.api.nvim_feedkeys(vim.keycode("y<CR>"), "x", false)
              end)
              break
            end
          end
        end
        return done
      end, 10)
    end)
    vim.api.nvim_list_uis = real_uis
    if not ok then
      error(err, 0)
    end
    t.truthy(answered, "the dialog went up and was answered")

    -- Both against prod. This is the sharp end of it: the environment used to
    -- be dropped while the dialog was up, so everything after a guarded
    -- request in a "send all" resolved against nothing at all.
    t.eq(urls, { "http://127.0.0.1:2/users/42", "http://127.0.0.1:2/ping" })
  end)
end

function M.a_send_from_elsewhere_stores_the_choice_for_the_requests_project(t)
  local dir = project({ ["http-client.env.json"] = ENV_FILE, ["api.http"] = HTTP })
  open(dir .. "/api.http")
  local bufnr = vim.api.nvim_get_current_buf()
  local req = parser.parse_buffer(bufnr).requests[1]

  -- A replay from the response window, or `# @run` from a split: the request
  -- belongs to `api.http`, but the current buffer is not it.
  vim.cmd("enew")

  local sent = capture(function()
    curlite.run(req, { bufnr = bufnr })
    local win = picker_win()
    t.truthy(win, "no environment chosen yet, so the picker opens")
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    end)
  end)

  t.eq(#sent, 1, "the request goes out once the choice is made")
  t.eq(
    env.current(dir .. "/api.http"),
    "dev",
    "the choice belongs to the request's project, not the working directory"
  )
  vim.cmd("bwipeout!")
end

return M
