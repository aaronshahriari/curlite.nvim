--- Telescope front end for the environment picker.
---
--- The same idea as the built-in picker -- names on one side, the variables
--- that name resolves to on the other -- but driven by telescope, so the list
--- is fuzzy-findable and obeys whatever layout and theme you have configured
--- for everything else.
---
--- The preview is rebuilt for whichever entry is highlighted, so it is a live
--- view of the environment rather than a snapshot taken when the picker
--- opened: edit `http-client.env.json`, reopen, and the values follow.
---
--- Reached through `curlite.picker`, which picks a front end, or directly as
--- a telescope extension:
---
---   require("telescope").load_extension("curlite")
---   :Telescope curlite env

local config = require("curlite.config")
local env = require("curlite.env")

local M = {}

local ns = vim.api.nvim_create_namespace("curlite_telescope")

--- Is telescope installed and loadable?
---@return boolean
function M.available()
  return pcall(require, "telescope")
end

--- The entries the picker lists: every environment, plus the deliberate
--- "none" that clears the selection and shows the shared block alone.
---
--- Public so it can be tested without telescope on the runtimepath.
---@param source string|nil
---@return table[]
function M.entries(source)
  local current = env.current(source)
  local out = {
    { name = nil, label = "(no environment)", active = env.chosen(source) and current == nil },
  }
  for _, name in ipairs(env.names(source)) do
    table.insert(out, { name = name, label = name, active = name == current })
  end
  for _, entry in ipairs(out) do
    entry.count = vim.tbl_count(env.vars(source, entry.name))
    entry.headers = vim.tbl_count(env.headers(source, entry.name))
  end
  return out
end

--- Open the environment picker.
---@param opts { source: string|nil, on_choice: fun(name: string|nil)|nil }|nil
function M.open(opts)
  opts = opts or {}
  local source = opts.source

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local putils = require("telescope.previewers.utils")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local conf = require("telescope.config").values

  local cfg = config.get().ui.picker or {}
  local list = M.entries(source)

  local widest = 0
  for _, entry in ipairs(list) do
    widest = math.max(widest, vim.fn.strdisplaywidth(entry.label))
  end

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 1 },
      { width = widest },
      { remaining = true },
    },
  })

  local function make_entry(entry)
    return {
      value = entry.name,
      -- `(no environment)` has no name to type, so give the matcher a word.
      ordinal = entry.name or "none shared",
      display = function(e)
        return displayer({
          { e.entry.active and "●" or " ", "CurliteEnvActive" },
          { e.entry.label, e.entry.active and "CurliteEnvActive" or "" },
          {
            ("%d var%s%s"):format(
              e.entry.count,
              e.entry.count == 1 and "" or "s",
              e.entry.headers > 0 and (", %d header%s"):format(
                e.entry.headers,
                e.entry.headers == 1 and "" or "s"
              ) or ""
            ),
            "CurliteEnvCount",
          },
        })
      end,
      entry = entry,
    }
  end

  local previewer
  if cfg.preview ~= false then
    previewer = previewers.new_buffer_previewer({
      title = "Variables",
      dyn_title = function(_, entry)
        return entry.value or "shared variables"
      end,
      define_preview = function(self, entry)
        local bufnr = self.state.bufnr
        -- Rebuilt on every move: the environment files are read through a
        -- stat-keyed cache, so this is a live view of what is on disk.
        local lines, origins = require("curlite.picker").preview_lines(source, entry.value)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

        -- `putils.highlighter` rather than setting 'filetype': a preview
        -- buffer should not be running ftplugins or attracting an LSP.
        pcall(putils.highlighter, bufnr, "json")

        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        for line, origin in pairs(origins) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line - 1, 0, {
            virt_text = { { " " .. origin, "CurliteEnvOrigin" } },
            virt_text_pos = "eol",
          })
        end
      end,
    })
  end

  -- Reuse the built-in picker's proportions, so switching front ends does not
  -- change the shape of the thing.
  local defaults = {
    prompt_title = "Environment",
    results_title = false,
    layout_strategy = "horizontal",
    layout_config = {
      width = cfg.width or 0.8,
      height = cfg.height or 0.7,
      preview_width = 1 - (cfg.list_width or 0.3),
      -- Telescope hides the preview below 120 columns, which is right for a
      -- file preview and wrong here: the variables *are* what you are
      -- choosing by. Override it in `ui.picker.telescope` if you disagree.
      preview_cutoff = 0,
    },
  }
  local picker_opts = vim.tbl_deep_extend("force", defaults, cfg.telescope or {}, opts.telescope or {})

  -- Start on the selected environment, so <CR> is a no-op rather than a
  -- surprise. Telescope counts rows from the bottom.
  local selected_index = 1
  for idx, entry in ipairs(list) do
    if entry.active then
      selected_index = idx
      break
    end
  end
  picker_opts.default_selection_index = selected_index

  pickers
    .new(picker_opts, {
      finder = finders.new_table({ results = list, entry_maker = make_entry }),
      sorter = conf.generic_sorter(picker_opts),
      previewer = previewer,
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if opts.on_choice then
            -- `entry.value` is nil for "(no environment)", which is a
            -- deliberate choice rather than a cancelled one.
            opts.on_choice(entry and entry.value or nil)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
