--- blink.cmp source for curlite.nvim.
---
--- Register it in your blink.cmp config:
---
---   sources = {
---     providers = {
---       curlite = { module = "curlite.blink", name = "curlite" },
---     },
---     per_filetype = { http = { "curlite", "path", "buffer" } },
---   }
---
--- The items themselves live in `curlite.complete`, which the nvim-cmp source
--- and Neovim's `omnifunc` share; this file is only the blink adapter.

local complete = require("curlite.complete")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return vim.tbl_contains(require("curlite.config").get().filetypes, vim.bo.filetype)
end

function source:get_trigger_characters()
  return { "{", "@", ":", "$", "." }
end

function source:get_completions(ctx, callback)
  local line = ctx.line or vim.api.nvim_get_current_line()
  local col = ctx.cursor and ctx.cursor[2] or vim.api.nvim_win_get_cursor(0)[2]
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

  -- blink does its own filtering, so it gets the unfiltered set for the
  -- position: that keeps the list stable as you type rather than re-querying
  -- a narrowing one.
  local items = complete.items(complete.context(line, col), bufnr)

  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

function source:execute(_, _, callback)
  callback()
end

return source
