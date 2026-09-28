--- A lualine component showing the active environment and the last response.
---
---   require("lualine").setup({
---     sections = { lualine_x = { "curlite" } },
---   })
---
--- Options:
---   show_env      include the environment name (default true)
---   no_env_text   what to show while none is selected (default "no env")
---   show_status   include the last response's status and time (default true)
---   only_http     render nothing outside `.http` buffers (default true)

local Component = require("lualine.component"):extend()

local default_options = {
  show_env = true,
  show_status = true,
  only_http = true,
  -- What to show while no environment has been picked. "" hides it.
  no_env_text = "no env",
  icon = "󱂛",
}

function Component:init(options)
  Component.super.init(self, vim.tbl_deep_extend("keep", options or {}, default_options))
end

function Component:update_status()
  local opts = self.options

  if opts.only_http and vim.bo.filetype ~= "http" then
    return ""
  end

  local ok, curlite = pcall(require, "curlite")
  if not ok then
    return ""
  end

  local parts = {}

  if opts.show_env then
    -- "no env" is the state worth seeing: it says a send will stop and ask,
    -- and it is what you are looking at before every first request.
    local name = curlite.current_env() or opts.no_env_text
    if name and name ~= "" then
      table.insert(parts, name)
    end
  end

  if opts.show_status then
    local ui = require("curlite.ui")
    local result = ui.history[ui.history_index]
    if result and result.response and result.response.status > 0 then
      table.insert(
        parts,
        ("%d %s"):format(
          result.response.status,
          require("curlite.util").human_time(result.response.duration_ms)
        )
      )
    end
  end

  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "  ")
end

return Component
