--- nvim-cmp source for curlite.nvim.
---
--- Registered for you the first time an http buffer attaches, so all you need
--- in your cmp config is the source name:
---
---   require("cmp").setup.filetype("http", {
---     sources = { { name = "curlite" }, { name = "buffer" } },
---   })
---
--- It completes the same things the blink source and `omnifunc` do; see
--- `curlite.complete`.

local complete = require("curlite.complete")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:is_available()
  return vim.tbl_contains(require("curlite.config").get().filetypes, vim.bo.filetype)
end

function source:get_debug_name()
  return "curlite"
end

function source:get_trigger_characters()
  return { "{", "@", ":", "$", "." }
end

function source:get_keyword_pattern()
  -- Names may hold `$`, `.` and `-`, none of which cmp's default pattern
  -- treats as part of a word.
  return [[\%([[:alnum:]_$.\-]\)\+]]
end

function source:complete(params, callback)
  local line = params.context.cursor_line
  local col = params.context.cursor.col - 1
  local items = complete.at(line, col, params.context.bufnr or 0)

  local out = {}
  for _, entry in ipairs(items) do
    table.insert(out, {
      label = entry.label,
      kind = entry.kind,
      detail = entry.detail,
      insertText = entry.insertText,
      sortText = entry.sortText,
      documentation = entry.documentation,
    })
  end
  callback({ items = out, isIncomplete = false })
end

local registered = false

--- Register the source with nvim-cmp, once.
---@return boolean  whether the source is registered
function source.register()
  if registered then
    return true
  end
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    return false
  end
  cmp.register_source("curlite", source.new())
  registered = true
  return true
end

return source
