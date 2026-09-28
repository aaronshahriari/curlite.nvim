--- The environment picker.
---
--- `vim.ui.select` can list the environment names, and that is all it can do:
--- a name tells you nothing about which host you are about to point a DELETE
--- at. This shows the names beside the variables each one resolves to -- the
--- shared block merged with that environment, every value visible, each line
--- marked with where it came from -- so the choice is made by looking at the
--- values rather than by remembering what "dev2" meant.

local config = require("curlite.config")
local env = require("curlite.env")

local M = {}

local ns = vim.api.nvim_create_namespace("curlite_picker")

--- A dimension given as a fraction of the editor, or as an absolute count.
---@param value number
---@param total integer
---@return integer
local function dimension(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.min(math.floor(value), total)
end

--- JSON with sorted keys, as display text.
---@param value any
---@param indent integer
---@param level integer
---@return string
local function encode(value, indent, level)
  local pad = (" "):rep(indent * level)
  local pad_in = (" "):rep(indent * (level + 1))

  if type(value) == "table" then
    if vim.islist(value) then
      if #value == 0 then
        return "[]"
      end
      local parts = {}
      for _, entry in ipairs(value) do
        table.insert(parts, pad_in .. encode(entry, indent, level + 1))
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end

    local keys = {}
    for key in pairs(value) do
      table.insert(keys, tostring(key))
    end
    table.sort(keys)
    if #keys == 0 then
      return "{}"
    end
    local parts = {}
    for _, key in ipairs(keys) do
      table.insert(
        parts,
        ("%s%s: %s"):format(pad_in, vim.json.encode(key), encode(value[key], indent, level + 1))
      )
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
  end

  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or ('"%s"'):format(tostring(value))
end

--- The `$default_headers` block, appended under the variables so the preview
--- answers "what does this environment send?" as well as "what does it set?".
---@param source string|nil
---@param name string|nil
---@param all table
---@param lines string[]
---@param origins table<integer, string>
local function append_headers(source, name, all, lines, origins)
  local headers = env.headers(source, name, all)
  local own = env.own_headers(source, name, all)

  local names = {}
  for header in pairs(headers) do
    if headers[header] ~= false then
      table.insert(names, header)
    end
  end
  if #names == 0 then
    return
  end
  table.sort(names)

  if #lines > 0 then
    table.insert(lines, "")
  end
  table.insert(lines, "-- sent with every request")
  for _, header in ipairs(names) do
    table.insert(lines, ("--   %s: %s"):format(header, tostring(headers[header])))
    origins[#lines] = own[header] ~= nil and name or env.shared_keys()[1]
  end
end

--- The preview for one environment: the variables it resolves to, as JSON,
--- then the headers it adds to every request, plus the line each entry starts
--- on so its origin can be marked.
---@param source string|nil
---@param name string|nil  nil previews the shared variables alone
---@return string[] lines, table<integer, string> origins
function M.preview_lines(source, name)
  local all = env.load(source)
  local shared = env.shared(source, all)
  local own = (name and type(all[name]) == "table") and all[name] or {}
  local vars = env.vars(source, name)

  local keys = {}
  for key in pairs(vars) do
    table.insert(keys, key)
  end
  table.sort(keys)

  if #keys == 0 then
    local empty = {
      "{}",
      "",
      name and ("-- " .. name .. " defines no variables, and neither does " .. env.shared_keys()[1])
        or ("-- " .. env.shared_keys()[1] .. " defines no variables"),
    }
    local empty_origins = {}
    append_headers(source, name, all, empty, empty_origins)
    return empty, empty_origins
  end

  local indent = config.get().response.indent or 2
  local lines, origins = { "{" }, {}

  for idx, key in ipairs(keys) do
    local chunk = ("%s%s: %s"):format(
      (" "):rep(indent),
      vim.json.encode(key),
      encode(vars[key], indent, 1)
    )
    if idx < #keys then
      chunk = chunk .. ","
    end
    local start = #lines + 1
    for _, line in ipairs(vim.split(chunk, "\n", { plain = true })) do
      table.insert(lines, line)
    end
    -- An environment's own value wins over the shared one, so that is the
    -- origin worth naming.
    if own[key] ~= nil then
      origins[start] = name
    elseif shared[key] ~= nil then
      origins[start] = env.shared_keys()[1]
    end
  end

  table.insert(lines, "}")
  append_headers(source, name, all, lines, origins)
  return lines, origins
end

--- Open the picker, through whichever front end is configured.
---
--- `ui.picker.backend` is "auto" by default: telescope when it is installed,
--- the built-in window otherwise. curlite depends on no plugin, so the
--- built-in one is always there to fall back to.
---@param opts { source: string|nil, on_choice: fun(name: string|nil) }
function M.open(opts)
  local backend = (config.get().ui.picker or {}).backend or "auto"

  if backend ~= "builtin" then
    local telescope = require("curlite.telescope")
    if telescope.available() then
      return telescope.open(opts)
    end
    if backend == "telescope" then
      require("curlite.util").emit(
        "warn",
        "curlite: picker.backend is \"telescope\" but telescope is not installed — using the built-in picker"
      )
    end
  end

  return M.open_builtin(opts)
end

--- The built-in two-pane window: names on the left, the variables that name
--- resolves to on the right.
---@param opts { source: string|nil, on_choice: fun(name: string|nil) }
function M.open_builtin(opts)
  opts = opts or {}
  local source = opts.source
  local names = env.names(source)
  local current = env.current(source)
  local cfg = config.get().ui.picker or {}
  local show_preview = cfg.preview ~= false

  -- "(none)" first: it is both how you clear a selection and how you see what
  -- the shared block alone gives you.
  local entries = { { name = nil, label = "(no environment)" } }
  for _, name in ipairs(names) do
    table.insert(entries, { name = name, label = name })
  end

  local total_width = dimension(cfg.width or 0.8, vim.o.columns)
  local total_height = dimension(cfg.height or 0.7, vim.o.lines - 4)
  total_width = math.max(total_width, 40)
  total_height = math.max(math.min(total_height, vim.o.lines - 4), math.min(#entries + 2, 8))

  local list_width = show_preview and math.max(dimension(cfg.list_width or 0.3, total_width), 18)
    or total_width
  local preview_width = total_width - list_width - 4 -- two borders between them
  local border = cfg.border or config.get().ui.float.border or "rounded"
  local row = math.floor((vim.o.lines - total_height) / 2) - 1
  local col = math.floor((vim.o.columns - total_width) / 2)

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].filetype = "curlite-env"

  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, ("%s %s"):format(entry.name == current and "●" or " ", entry.label))
  end
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)

  -- How many variables each environment ends up with, so the list itself says
  -- which ones are actually populated.
  for idx, entry in ipairs(entries) do
    local count = vim.tbl_count(env.vars(source, entry.name))
    vim.api.nvim_buf_set_extmark(list_buf, ns, idx - 1, 0, {
      virt_text = { { ("%d var%s"):format(count, count == 1 and "" or "s"), "CurliteEnvCount" } },
      virt_text_pos = "right_align",
    })
    if entry.name == current then
      vim.api.nvim_buf_set_extmark(list_buf, ns, idx - 1, 0, {
        end_col = #lines[idx],
        hl_group = "CurliteEnvActive",
      })
    end
  end
  vim.bo[list_buf].modifiable = false

  local list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = list_width,
    height = total_height,
    style = "minimal",
    border = border,
    title = " Environment ",
    title_pos = "center",
    footer = " <CR> select   q cancel ",
    footer_pos = "center",
  })
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].winhighlight = "NormalFloat:NormalFloat,CursorLine:PmenuSel"

  local preview_buf, preview_win
  if show_preview and preview_width > 20 then
    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[preview_buf].bufhidden = "wipe"
    preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      row = row,
      col = col + list_width + 2,
      width = preview_width,
      height = total_height,
      style = "minimal",
      border = border,
      title = " Variables ",
      title_pos = "center",
    })
    vim.wo[preview_win].wrap = false
  end

  local function render_preview()
    if not (preview_buf and vim.api.nvim_buf_is_valid(preview_buf)) then
      return
    end
    local idx = vim.api.nvim_win_get_cursor(list_win)[1]
    local entry = entries[idx]
    if not entry then
      return
    end

    local body, origins = M.preview_lines(source, entry.name)
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, body)
    vim.bo[preview_buf].modifiable = false
    vim.bo[preview_buf].filetype = "json"

    vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, -1)
    for line, origin in pairs(origins) do
      vim.api.nvim_buf_set_extmark(preview_buf, ns, line - 1, 0, {
        virt_text = { { " " .. origin, "CurliteEnvOrigin" } },
        virt_text_pos = "eol",
      })
    end

    if vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, {
        title = (" %s "):format(entry.name or "shared variables"),
        title_pos = "center",
      })
      pcall(vim.api.nvim_win_set_cursor, preview_win, { 1, 0 })
    end
  end

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    for _, win in ipairs({ preview_win, list_win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  local function choose()
    local idx = vim.api.nvim_win_get_cursor(list_win)[1]
    local entry = entries[idx]
    close()
    if opts.on_choice then
      opts.on_choice(entry and entry.name or nil)
    end
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = list_buf, nowait = true, silent = true })
  end
  map("<CR>", choose)
  map("<2-LeftMouse>", choose)
  map("q", close)
  map("<Esc>", close)
  map("<C-c>", close)

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    buffer = list_buf,
    callback = render_preview,
  })
  -- Leaving the list (clicking elsewhere, `<C-w>w`) closes the whole thing
  -- rather than stranding a preview window with no list beside it.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = list_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  -- Start on the selected environment, so <CR> is a no-op rather than a
  -- surprise.
  local start = 1
  for idx, entry in ipairs(entries) do
    if entry.name == current then
      start = idx
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, list_win, { start, 0 })
  render_preview()

  return { list_win = list_win, preview_win = preview_win, list_buf = list_buf, close = close }
end

return M
