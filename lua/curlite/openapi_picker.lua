--- The OpenAPI operation picker.
---
--- Same two-pane idea as the environment picker: the operations on the left,
--- and on the right the exact `.http` block `<CR>` is about to write into your
--- file -- URL, headers and an example body, with the spec's own values filled
--- in. You pick by reading the request rather than by guessing what
--- `POST /v2/pets` wants.
---
--- Telescope drives it when it is installed, so the list is fuzzy-findable
--- over method, path, summary, operationId and tags, and `<Tab>` marks several
--- operations to insert in one go. Without telescope the built-in window does
--- the same job, because curlite depends on no plugin.

local config = require("curlite.config")
local openapi = require("curlite.openapi")

local M = {}

local ns = vim.api.nvim_create_namespace("curlite_openapi_picker")

-- The highlight groups the `.http` buffer uses for methods, so a GET in the
-- list is the same colour as a GET in the file.
local METHOD_HL = {
  GET = "CurliteHttpMethodGet",
  HEAD = "CurliteHttpMethodHead",
  OPTIONS = "CurliteHttpMethodOptions",
  POST = "CurliteHttpMethodPost",
  PUT = "CurliteHttpMethodPut",
  PATCH = "CurliteHttpMethodPatch",
  DELETE = "CurliteHttpMethodDelete",
  TRACE = "CurliteHttpMethodTrace",
}

--- Picker geometry: `ui.picker` with `openapi.picker` merged over it, so both
--- pickers look like the same plugin while the operation list gets the extra
--- width it needs.
---@return table
local function picker_config()
  local cfg = config.get()
  return vim.tbl_deep_extend("force", cfg.ui.picker or {}, cfg.openapi.picker or {})
end

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

--- The block one operation would insert.
---@param op table
---@param opts table
---@return string[]
function M.preview_lines(op, opts)
  return openapi.block(op, { env_headers = (opts or {}).env_headers })
end

--- The title line of the spec, for the picker's own title.
---@param spec table
---@return string
function M.spec_title(spec)
  local info = type(spec.info) == "table" and spec.info or {}
  local name = info.title and tostring(info.title) or "OpenAPI"
  if info.version then
    return ("%s %s"):format(name, tostring(info.version))
  end
  return name
end

--- Open the picker through whichever front end is configured.
---@class curlite.openapi.PickerOpts
---@field spec table
---@field operations table[]
---@field source string|nil
---@field env_headers table|nil
---@field telescope table|nil
---@field on_choice fun(ops: table[])

---@param opts curlite.openapi.PickerOpts
function M.open(opts)
  local backend = (picker_config().backend) or "auto"

  if backend ~= "builtin" then
    if require("curlite.telescope").available() then
      return M.open_telescope(opts)
    end
    if backend == "telescope" then
      require("curlite.util").emit(
        "warn",
        "curlite: picker.backend is \"telescope\" but telescope is not installed"
          .. " — using the built-in picker"
      )
    end
  end
  return M.open_builtin(opts)
end

--- Narrow a list of operations with a fuzzy query.
---
--- `matchfuzzy` is Neovim's own matcher, so the built-in picker scores and
--- orders the way everything else in the editor does, over the same text
--- telescope matches on: method, path, summary, operationId and tags.
---@param ops table[]
---@param query string
---@return table[]
function M.filter(ops, query)
  query = vim.trim(query or "")
  if query == "" then
    return ops
  end

  local items = {}
  for idx, op in ipairs(ops) do
    table.insert(items, { text = op.ordinal, idx = idx })
  end
  local ok, matched = pcall(vim.fn.matchfuzzy, items, query, { key = "text" })
  if not ok then
    return {}
  end

  local out = {}
  for _, item in ipairs(matched) do
    local op = ops[tonumber(item.idx)]
    if op then
      table.insert(out, op)
    end
  end
  return out
end

--- The built-in picker: a filter prompt, the operations it matches, and the
--- block the highlighted one inserts.
---
--- A spec has hundreds of operations, so this is a real picker rather than a
--- list: it opens on the prompt, every keystroke re-filters, and `<CR>` takes
--- what is highlighted. Returned handle: `{ close, choose, set_query }`, which
--- is also how it is driven in tests.
---@param opts curlite.openapi.PickerOpts
function M.open_builtin(opts)
  local all = opts.operations
  local cfg = picker_config()
  local show_preview = cfg.preview ~= false

  local total_width = math.max(dimension(cfg.width or 0.8, vim.o.columns), 40)
  local total_height = dimension(cfg.height or 0.7, vim.o.lines - 6)
  total_height = math.max(math.min(total_height, vim.o.lines - 6), 6)

  local list_width = show_preview and math.max(dimension(cfg.list_width or 0.45, total_width), 20)
    or total_width
  local preview_width = total_width - list_width - 4
  local border = cfg.border or config.get().ui.float.border or "rounded"
  -- The prompt sits above the list, in its own frame, so the two borders are
  -- the separator between what you type and what it matched.
  local list_height = math.max(total_height - 3, 3)
  local row = math.max(math.floor((vim.o.lines - (list_height + 5)) / 2), 0)
  local col = math.floor((vim.o.columns - total_width) / 2)

  local prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[prompt_buf].bufhidden = "wipe"
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].filetype = "curlite-openapi"

  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = list_width,
    height = 1,
    style = "minimal",
    border = border,
    title = (" %s "):format(M.spec_title(opts.spec)),
    title_pos = "center",
  })
  vim.wo[prompt_win].winhighlight = "NormalFloat:NormalFloat"

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = "editor",
    row = row + 3,
    col = col,
    width = list_width,
    height = list_height,
    style = "minimal",
    border = border,
    footer = " <CR> insert   <C-n>/<C-p> move   <Esc> cancel ",
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
      height = list_height + 4,
      style = "minimal",
      border = border,
      title = " Request ",
      title_pos = "center",
    })
    vim.wo[preview_win].wrap = false
  end

  local shown = all
  local selected = 1

  local function render_preview()
    if not (preview_buf and vim.api.nvim_buf_is_valid(preview_buf)) then
      return
    end
    local op = shown[selected]
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      preview_buf,
      0,
      -1,
      false,
      op and M.preview_lines(op, opts) or { "", "  no operation matches" }
    )
    vim.bo[preview_buf].modifiable = false
    -- A real http buffer, so the preview is highlighted exactly as the block
    -- will be once it is in the file.
    local want = op and "http" or ""
    if vim.bo[preview_buf].filetype ~= want then
      vim.bo[preview_buf].filetype = want
    end
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, {
        title = (" %s "):format(op and openapi.title(op) or "no match"),
        title_pos = "center",
      })
      pcall(vim.api.nvim_win_set_cursor, preview_win, { 1, 0 })
    end
  end

  local function render_list()
    if not vim.api.nvim_buf_is_valid(list_buf) then
      return
    end
    local lines = {}
    for _, op in ipairs(shown) do
      table.insert(lines, ("%-7s%s"):format(op.method, op.path))
    end
    if #lines == 0 then
      lines = { "  no operation matches" }
    end

    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    for idx, op in ipairs(shown) do
      vim.api.nvim_buf_set_extmark(list_buf, ns, idx - 1, 0, {
        end_col = #op.method,
        hl_group = METHOD_HL[op.method] or "CurliteHttpMethodGet",
      })
      local note = op.summary and vim.split(op.summary, "\n", { plain = true })[1] or op.id
      if note and note ~= "" then
        vim.api.nvim_buf_set_extmark(list_buf, ns, idx - 1, 0, {
          virt_text = { { note .. " ", op.deprecated and "DiagnosticWarn" or "Comment" } },
          virt_text_pos = "right_align",
        })
      end
    end

    if vim.api.nvim_win_is_valid(list_win) then
      pcall(vim.api.nvim_win_set_cursor, list_win, { math.max(math.min(selected, #shown), 1), 0 })
      vim.api.nvim_win_set_config(list_win, {
        footer = (" %d/%d   <CR> insert   <Esc> cancel "):format(
          #shown > 0 and selected or 0,
          #shown
        ),
        footer_pos = "center",
      })
    end
    render_preview()
  end

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_get_mode().mode:find("i") then
      vim.cmd("stopinsert")
    end
    for _, win in ipairs({ preview_win, list_win, prompt_win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  local function move(delta)
    if #shown == 0 then
      return
    end
    selected = selected + delta
    if selected < 1 then
      selected = #shown
    elseif selected > #shown then
      selected = 1
    end
    render_list()
  end

  local function set_query(query)
    shown = M.filter(all, query)
    selected = 1
    render_list()
  end

  local function choose()
    local op = shown[selected]
    close()
    if op and opts.on_choice then
      opts.on_choice({ op })
    end
  end

  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = prompt_buf, nowait = true, silent = true })
  end
  map({ "i", "n" }, "<CR>", choose)
  map({ "i", "n" }, "<C-n>", function()
    move(1)
  end)
  map({ "i", "n" }, "<C-p>", function()
    move(-1)
  end)
  map({ "i", "n" }, "<Down>", function()
    move(1)
  end)
  map({ "i", "n" }, "<Up>", function()
    move(-1)
  end)
  map({ "i", "n" }, "<C-c>", close)
  map({ "i", "n" }, "<Esc>", close)
  map("n", "q", close)

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "TextChangedP" }, {
    buffer = prompt_buf,
    callback = function()
      set_query(vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or "")
    end,
  })
  -- Anything that disposes of the prompt -- `:q`, a window manager, the mouse
  -- -- takes the other two frames with it rather than stranding them.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(prompt_win),
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = prompt_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  render_list()
  -- Opening on the prompt, in insert mode, is what makes it a fuzzy picker
  -- rather than a list you scroll.
  if #vim.api.nvim_list_uis() > 0 then
    vim.cmd("startinsert")
  end

  return {
    prompt_win = prompt_win,
    list_win = list_win,
    preview_win = preview_win,
    list_buf = list_buf,
    prompt_buf = prompt_buf,
    close = close,
    choose = choose,
    move = move,
    set_query = set_query,
    shown = function()
      return shown
    end,
    selected = function()
      return selected
    end,
  }
end

--- The telescope front end: fuzzy over the whole spec, `<Tab>` to mark more
--- than one, `<CR>` to insert.
---@param opts table
function M.open_telescope(opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local putils = require("telescope.previewers.utils")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local conf = require("telescope.config").values

  local cfg = picker_config()
  local ops = opts.operations

  local widest = 0
  for _, op in ipairs(ops) do
    widest = math.max(widest, vim.fn.strdisplaywidth(op.path))
  end

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 6 },
      { width = math.min(widest, 60) },
      { remaining = true },
    },
  })

  local function make_entry(op)
    return {
      value = op,
      ordinal = op.ordinal,
      display = function(entry)
        local op_entry = entry.value
        local note = op_entry.summary and vim.split(op_entry.summary, "\n", { plain = true })[1]
          or op_entry.id
          or ""
        return displayer({
          { op_entry.method, METHOD_HL[op_entry.method] or "CurliteHttpMethodGet" },
          { op_entry.path, op_entry.deprecated and "Comment" or "" },
          { note, "Comment" },
        })
      end,
    }
  end

  local previewer
  if cfg.preview ~= false then
    previewer = previewers.new_buffer_previewer({
      title = "Request",
      dyn_title = function(_, entry)
        return openapi.title(entry.value)
      end,
      define_preview = function(self, entry)
        local bufnr = self.state.bufnr
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.preview_lines(entry.value, opts))
        -- `putils.highlighter` rather than 'filetype': a preview buffer should
        -- not be running ftplugins or attracting an LSP.
        pcall(putils.highlighter, bufnr, "http")
      end,
    })
  end

  local defaults = {
    prompt_title = M.spec_title(opts.spec),
    results_title = false,
    layout_strategy = "horizontal",
    layout_config = {
      width = cfg.width or 0.8,
      height = cfg.height or 0.7,
      preview_width = 1 - (cfg.list_width or 0.45),
      -- The request *is* what you are choosing by, so the preview stays on in
      -- a narrow window. Override it in `openapi.telescope` if you disagree.
      preview_cutoff = 0,
    },
  }
  local picker_opts = vim.tbl_deep_extend(
    "force",
    defaults,
    cfg.telescope or {},
    config.get().openapi.telescope or {},
    opts.telescope or {}
  )

  pickers
    .new(picker_opts, {
      finder = finders.new_table({ results = ops, entry_maker = make_entry }),
      sorter = conf.generic_sorter(picker_opts),
      previewer = previewer,
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          -- `<Tab>`-marked entries, in the order the list shows them, so
          -- inserting several keeps the spec's order rather than the order you
          -- happened to mark them in.
          local marked = picker and picker:get_multi_selection() or {}
          local chosen = {}
          if #marked > 0 then
            for _, entry in ipairs(marked) do
              table.insert(chosen, entry.value)
            end
            table.sort(chosen, function(a, b)
              return (a.index or 0) < (b.index or 0)
            end)
          else
            local entry = action_state.get_selected_entry()
            if entry then
              chosen = { entry.value }
            end
          end
          actions.close(prompt_bufnr)
          if #chosen > 0 and opts.on_choice then
            opts.on_choice(chosen)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
