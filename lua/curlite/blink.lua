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
  local cursor = ctx.cursor or vim.api.nvim_win_get_cursor(0)
  local col = cursor[2]
  local row = cursor[1]
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

  -- blink does its own filtering, so it gets the unfiltered set for the
  -- position: that keeps the list stable as you type rather than re-querying
  -- a narrowing one.
  local cctx = complete.context(line, col)
  local items = complete.items(cctx, bufnr)

  -- Left to itself blink guesses the range to replace from its own keyword
  -- pattern, which stops at `$` and `.`: the keyword for `{{auth.cl` is `cl`,
  -- so accepting `auth.client_id` would write `{{auth.auth.client_id`. Every
  -- item that knows its range says so outright.
  for _, item in ipairs(items) do
    local range = item.curlite
    if range then
      item.textEdit = {
        range = {
          start = { line = row - 1, character = range.start },
          ["end"] = { line = row - 1, character = range.stop },
        },
        newText = item.insertText,
      }
    end
    -- blink stores nothing it does not know about, and the payload has to
    -- survive to `execute`.
    item.data = vim.tbl_extend("force", item.data or {}, { curlite = range })
    item.curlite = nil
  end

  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

--- Apply the item, then put the cursor where the next keystroke belongs.
---
--- `default_implementation` is what actually inserts the text. blink only
--- calls it for a source that has no `execute` of its own, so a source that
--- defines one and forgets to call it accepts completions that insert
--- nothing at all.
function source:execute(_, item, callback, default_implementation)
  if default_implementation then
    default_implementation()
  end

  local back = item and item.data and item.data.curlite and item.data.curlite.back or 0
  if back > 0 then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_win_set_cursor(0, { row, math.max(col - back, 0) })
  end

  callback()
end

return source
