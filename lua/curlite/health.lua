--- `:checkhealth curlite`

local M = {}

local function check_curl()
  local config = require("curlite.config")
  local path = config.get().curl.path

  if vim.fn.executable(path) == 0 then
    vim.health.error(
      ("curl not found at `%s`"):format(path),
      { "install curl, or set `curl.path` to its location" }
    )
    return
  end

  local result = vim.system({ path, "--version" }, { text = true }):wait()
  local first = vim.split(result.stdout or "", "\n")[1] or ""
  local version = first:match("^curl%s+([%d%.]+)")

  if not version then
    vim.health.warn(("could not read curl's version from `%s --version`"):format(path))
    return
  end

  vim.health.ok(("curl %s (%s)"):format(version, path))

  -- `%{json:field}` is what the stats pane is built on.
  local major, minor = version:match("^(%d+)%.(%d+)")
  major, minor = tonumber(major) or 0, tonumber(minor) or 0
  if major < 7 or (major == 7 and minor < 75) then
    vim.health.warn(
      ("curl %s is older than 7.75"):format(version),
      { "the Stats pane needs `--write-out '%{json:...}'`; everything else works" }
    )
  end

  if not first:find("HTTP2") and not first:find("nghttp2") then
    vim.health.info("curl was built without HTTP/2 — `# @http2` will be ignored")
  end
  if not first:find("brotli") and not first:find("zstd") then
    vim.health.info("curl was built without brotli/zstd — `# @compressed` covers less")
  end
end

local function check_optional()
  if vim.fn.executable("jq") == 1 then
    local v = vim.system({ "jq", "--version" }, { text = true }):wait()
    vim.health.ok(("jq %s — powers the `/` filter in the response window"):format(vim.trim(v.stdout or "")))
  else
    vim.health.info(
      "jq not found — the `/` filter in the response window is unavailable. "
        .. "JSON formatting does not need it."
    )
  end
end

local function check_treesitter()
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  local has_ts_http = false
  if ok and parsers then
    has_ts_http = (parsers.has_parser and parsers.has_parser("http")) or false
  end
  if not has_ts_http then
    has_ts_http = pcall(vim.treesitter.language.inspect, "http")
  end

  if has_ts_http then
    vim.health.ok("a treesitter `http` parser is installed and will be used")
  else
    vim.health.ok("no treesitter `http` parser — curlite's bundled syntax file is used instead")
  end

  if not pcall(vim.treesitter.language.inspect, "json") then
    vim.health.info("no treesitter `json` parser — JSON response bodies fall back to vim syntax")
  end
end

local function check_environments()
  local config = require("curlite.config")
  local env = require("curlite.env")
  local source = vim.api.nvim_buf_get_name(0)
  local names = env.names(source)

  if #names == 0 then
    vim.health.info(
      ("no environments found near %s"):format(
        source ~= "" and vim.fn.fnamemodify(source, ":~:.") or vim.fn.getcwd()
      )
    )
    vim.health.info(("create `%s` to define some"):format(config.get().env.files[1]))
    return
  end

  vim.health.ok(("%d environment%s: %s"):format(#names, #names == 1 and "" or "s", table.concat(names, ", ")))
  local current = env.current(source)
  if not current then
    vim.health.info(
      "no environment selected — only the shared variables resolve until you pick one"
    )
    vim.health.info("pick one with `:Curlite env`")
  elseif vim.tbl_contains(names, current) then
    vim.health.ok(("active environment: %s"):format(current))
  else
    vim.health.warn(
      ("active environment `%s` is not defined"):format(current),
      { "pick another with `:Curlite env`" }
    )
  end

  -- `$default_headers` goes out with every request, including the ones you
  -- are not looking at, so it is worth stating outright rather than leaving
  -- to be discovered in a verbose trace.
  local headers = env.headers(source, current)
  local listed, dropped = {}, {}
  for name, value in pairs(headers) do
    table.insert(value == false and dropped or listed, name)
  end
  table.sort(listed)
  table.sort(dropped)
  if #listed > 0 then
    vim.health.ok(("default headers from the environment file: %s"):format(table.concat(listed, ", ")))
  end
  if #dropped > 0 then
    vim.health.info(("dropped by this environment: %s"):format(table.concat(dropped, ", ")))
  end
end

--- `notify.events` is keyed by name, and a typo there fails silently: the
--- event you meant keeps notifying and the key you wrote does nothing. Name
--- the unknown keys here rather than let them look like they took effect.
---@param cfg table
local function check_notify(cfg)
  local notify = require("curlite.notify")
  local raw = cfg.notify

  if type(raw) == "string" then
    vim.health.info(
      ("notify = %q — the string form still works; `:h curlite-notifications` has the table"):format(raw)
    )
    return
  end
  if type(raw) ~= "table" then
    vim.health.warn(("notify should be a table or a string, got %s"):format(type(raw)))
    return
  end

  if raw.enabled == false then
    vim.health.warn("notifications disabled — errors are silent too", {
      "prefer `notify.events = { <name> = false }` to silence one message",
    })
  end

  if raw.level ~= nil and notify.level(raw.level) == nil then
    vim.health.error(("notify.level = %s is not a level"):format(vim.inspect(raw.level)), {
      '"error" | "warn" | "info" | "debug" | "trace" | "off", or a vim.log.levels.* number',
    })
  end

  local unknown = {}
  for name, rule in pairs(raw.events or {}) do
    if notify.events[name] == nil then
      table.insert(unknown, name)
    elseif type(rule) ~= "boolean" and notify.level(rule) == nil then
      vim.health.error(("notify.events.%s = %s is neither a boolean nor a level"):format(name, vim.inspect(rule)))
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    vim.health.error(("unknown notify.events: %s"):format(table.concat(unknown, ", ")), {
      "`:Curlite events` lists every event name",
    })
  end

  for _, key in ipairs({ "filter", "backend" }) do
    if raw[key] ~= nil and type(raw[key]) ~= "function" then
      vim.health.error(("notify.%s must be a function, got %s"):format(key, type(raw[key])))
    end
  end

  local hidden = {}
  for name, spec in pairs(notify.events) do
    if not notify.enabled(name, spec.level, { msg = "" }) then
      table.insert(hidden, name)
    end
  end
  table.sort(hidden)
  if #hidden == 0 then
    vim.health.ok("notifications: every event is getting through")
  else
    vim.health.ok(("notifications: %d of %d events silenced (%s)"):format(
      #hidden,
      vim.tbl_count(notify.events),
      table.concat(hidden, ", ")
    ))
  end
end

local function check_config()
  local config = require("curlite.config")
  local cfg = config.get()

  local valid_display = { "right", "left", "below", "above", "float", "tab" }
  if not vim.tbl_contains(valid_display, cfg.ui.display) then
    vim.health.error(
      ("`ui.display = %q` is not valid"):format(tostring(cfg.ui.display)),
      { "use one of: " .. table.concat(valid_display, ", ") }
    )
  end

  local known_panes = { "body", "headers", "all", "stats", "verbose", "script" }
  for _, pane in ipairs(cfg.ui.panes) do
    if not vim.tbl_contains(known_panes, pane) then
      vim.health.error(("unknown pane %q in `ui.panes`"):format(tostring(pane)))
    end
  end
  if not vim.tbl_contains(cfg.ui.panes, cfg.ui.default_pane) then
    vim.health.warn(
      ("`ui.default_pane = %q` is not in `ui.panes`"):format(tostring(cfg.ui.default_pane)),
      { "the first listed pane is used instead" }
    )
  end

  if cfg.curl.cookie_jar then
    local dir = vim.fn.fnamemodify(cfg.curl.cookie_jar, ":h")
    if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
      vim.health.error(("cannot create the cookie jar directory %s"):format(dir))
    else
      vim.health.ok(("cookie jar: %s"):format(cfg.curl.cookie_jar))
    end
  else
    vim.health.info("cookie jar disabled — sessions won't carry between requests")
  end

  if cfg.scripts.enable then
    vim.health.ok(("scripts enabled (sandbox: %s)"):format(cfg.scripts.sandbox and "on" or "off"))
  else
    vim.health.info("scripts disabled — `< {% %}` blocks and `# @assert` are ignored")
  end

  if cfg.debug then
    vim.health.info(("debug log: %s"):format(require("curlite.util").log_path()))
  end

  check_notify(cfg)
end

function M.check()
  vim.health.start("curlite.nvim")

  if vim.fn.has("nvim-0.10") == 0 then
    vim.health.error("curlite needs Neovim 0.10 or newer")
    return
  end
  vim.health.ok(("Neovim %s"):format(vim.version()))

  check_curl()
  check_optional()

  vim.health.start("curlite.nvim: configuration")
  check_config()

  vim.health.start("curlite.nvim: highlighting")
  check_treesitter()

  vim.health.start("curlite.nvim: environments")
  check_environments()
end

return M
