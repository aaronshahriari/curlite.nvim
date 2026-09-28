--- Telescope extension for curlite.nvim.
---
---   require("telescope").load_extension("curlite")
---   :Telescope curlite
---
--- Loading it is optional: with `ui.picker.backend` left at "auto",
--- `<leader>Re` and `:Curlite env` already open the telescope picker whenever
--- telescope is installed. This is for the people who drive everything
--- through `:Telescope`, and for passing a theme in:
---
---   :Telescope curlite theme=dropdown

local ok, telescope = pcall(require, "telescope")
if not ok then
  error("telescope.nvim is not installed")
end

local function env(opts)
  require("curlite").select_env({ telescope = opts })
end

return telescope.register_extension({
  exports = {
    -- `:Telescope curlite` with no subcommand picks the environment, which is
    -- the one you reach for.
    curlite = env,
    env = env,
  },
})
