-- Buffer-local settings for .http / .rest files.
-- Neovim ships an ftplugin/http.vim that sets `comments` and `commentstring`;
-- this adds folding and the bits that make editing requests pleasant.

if vim.b.did_ftplugin_curlite then
  return
end
vim.b.did_ftplugin_curlite = true

local bo, wo = vim.bo, vim.wo

bo.commentstring = "# %s"
bo.comments = ":#,://"
-- `@` and `{` are part of a variable reference, so `*` and `w` behave.
bo.iskeyword = bo.iskeyword .. ",@-@,$,-"

-- Fold on `###` separators: one fold per request.
wo.foldmethod = "expr"
wo.foldexpr = "v:lua.require'curlite.fold'.expr()"
wo.foldlevel = 99

vim.b.undo_ftplugin = (vim.b.undo_ftplugin or "") .. " | setl cms< com< isk< fdm< fde< fdl<"
