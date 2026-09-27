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
  if current then
    if vim.tbl_contains(names, current) then
      vim.health.ok(("active environment: %s"):format(current))
    else
      vim.health.warn(
        ("active environment `%s` is not defined"):format(current),
        { "pick another with `:Curlite env`" }
      )
    end
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
