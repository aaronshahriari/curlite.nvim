-- curlite.nvim -- lazy entry point.
--
-- The plugin does nothing until `require("curlite").setup{}` runs, except
-- register `:Curlite` so the commands exist in a lazy-loading setup. Calling
-- `setup{}` again is safe and is what applies your configuration.

if vim.g.loaded_curlite then
  return
end
vim.g.loaded_curlite = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("curlite.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end
