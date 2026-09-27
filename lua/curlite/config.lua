--- curlite.nvim configuration.
---
--- Everything here is overridable through `require("curlite").setup{}`; the
--- table you pass is deep-merged over these defaults, so you only name what you
--- want changed.

local M = {}

---@class curlite.Config
M.defaults = {
  -- Filetypes curlite attaches to. Buffer-local keymaps (see `keymaps` below)
  -- and the `on_attach` hook fire for every buffer with one of these.
  -- Neovim detects `.http` natively; curlite additionally registers `.rest`
  -- and `*.http.*` unless `filetype.register` is false.
  filetypes = { "http" },

  filetype = {
    -- Register the extra extensions/patterns that map onto the `http`
    -- filetype. Turn off if you'd rather own `vim.filetype.add` yourself.
    register = true,
    -- Extra extensions mapped to `http`. `.http` is already native.
    extensions = { "rest" },
    -- Lua patterns (as `vim.filetype.add` expects them) mapped to `http`.
    -- The default catches `api.http.dev`, `foo.http.local`, and friends.
    patterns = { [".*%.http%..*"] = "http" },
  },

  -- Optional per-buffer hook: `on_attach(bufnr)` runs once for every http
  -- buffer, after the built-in keymaps are applied. Use it for your own
  -- buffer-local binds instead of hand-rolled autocmds.
  on_attach = nil,

  curl = {
    -- Path to curl. Left as "curl" it is looked up on PATH.
    path = "curl",
    -- Flags prepended to *every* request. `--no-buffer` keeps streaming
    -- responses arriving promptly; `--location` follows redirects the way
    -- every other REST client does by default.
    args = { "--location", "--no-buffer" },
    -- Hard ceiling on a single request, in milliseconds. 0 disables it.
    -- A per-request `# @timeout 5000` overrides this.
    timeout = 30000,
    -- Verify TLS certificates. `false` adds `--insecure`; you can also set it
    -- per request with `# @insecure`.
    verify_ssl = true,
    -- Send and store cookies in this jar so a login request's session carries
    -- into the next one. `false` disables the jar entirely.
    cookie_jar = vim.fn.stdpath("data") .. "/curlite/cookies.txt",
  },

  request = {
    -- Substitute `{{var}}` inside the *response* body too. Off by default —
    -- a response that happens to contain braces should come back untouched.
    substitute_in_response = false,
    -- Scope for document (`@name = value`) variables:
    --   "document" -- a variable is visible to every request in the file,
    --                 regardless of where it is defined (kulala's default)
    --   "request"  -- a variable is only visible to requests *below* it, and
    --                 re-assignment mid-file is respected
    variables_scope = "request",
    -- Default headers merged into every request unless the request sets its
    -- own. Keys are matched case-insensitively.
    default_headers = {
      ["User-Agent"] = "curlite.nvim",
    },
    -- When a body looks like JSON but no Content-Type was given, send
    -- `application/json`. Set false to leave the header off.
    infer_content_type = true,
  },

  ui = {
    -- Where the response window opens.
    --   "right" | "left" | "below" | "above" | "float" | "tab"
    -- `vertical` and `horizontal` are accepted as aliases for right/below.
    display = "right",
    -- Size of the split. width applies to left/right, height to above/below.
    -- 0 lets Neovim decide.
    width = 88,
    height = 20,
    -- Float geometry, used when `display = "float"`. Fractions of the editor.
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    },
    -- Which pane the response opens on. Cycle at runtime with `H`/`L`.
    --   "body" | "headers" | "all" | "stats" | "verbose" | "script"
    default_pane = "body",
    -- Panes offered in the winbar, in order. Drop any you never look at.
    panes = { "body", "headers", "all", "stats", "verbose", "script" },
    -- Draw the pane list in the window's winbar.
    winbar = true,
    -- Move the cursor into the response window when it opens. False keeps you
    -- in the request buffer so you can fire the next one immediately.
    focus = false,
    -- Keep the response window open between requests and reuse it.
    reuse = true,
    -- Wrap long lines in the response.
    wrap = false,
    -- Show line numbers in the response.
    number = false,
    -- Virtual text on the request line showing status and elapsed time
    -- (` 200 OK · 143ms`) after it runs. Cleared when the buffer changes.
    inline_status = true,
    -- Icons used across the UI. Set any to "" to drop it.
    icons = {
      success = "",
      error = "",
      running = "",
      redirect = "",
      warn = "",
    },
    -- Highlight groups. These are linked, not defined, so they follow your
    -- colorscheme; override with concrete groups if you want fixed colors.
    highlights = {
      success = "DiagnosticOk",
      redirect = "DiagnosticInfo",
      client_error = "DiagnosticWarn",
      server_error = "DiagnosticError",
      running = "Comment",
      inline = "Comment",
    },
  },

  response = {
    -- Pretty-print bodies by content type. `jq` is used for JSON when it is on
    -- PATH (fastest and most faithful); otherwise a pure-Lua formatter runs.
    format = true,
    -- Spaces per indent level for the built-in JSON/XML formatters.
    indent = 2,
    -- Map a response filetype onto the buffer so treesitter highlights it.
    -- Keys are matched against the Content-Type, values are filetypes.
    filetypes = {
      json = "json",
      xml = "xml",
      html = "html",
      javascript = "javascript",
      css = "css",
      yaml = "yaml",
      text = "text",
    },
    -- Bodies larger than this (bytes) skip formatting and highlighting — they
    -- are shown raw so a 40MB payload doesn't lock the editor. 0 = no limit.
    max_format_size = 1024 * 1024,
    -- Show the request that produced a response above it in the `all` pane.
    show_request = true,
  },

  env = {
    -- Files searched (nearest-first, walking up from the http file) for
    -- environment definitions. The `.private.` variant is merged over the
    -- public one and is what you gitignore.
    files = { "http-client.env.json", "http-client.private.env.json" },
    -- Also read a `.env` file from the same directories, exposed as
    -- `{{$dotenv NAME}}`.
    dotenv = ".env",
    -- Environment selected at startup. nil means "remember the last one you
    -- picked" (persisted per project), falling back to the first defined.
    default = nil,
    -- The `$shared` key in http-client.env.json is merged under every
    -- environment. This is the name curlite looks for.
    shared_key = "$shared",
  },

  scripts = {
    -- Pre/post request scripts. curlite runs **Lua**, not JavaScript: a
    -- `< {% ... %}` or `> {% ... %}` block is Lua source with a `client`,
    -- `request` and `response` table in scope. See `:h curlite-scripts`.
    enable = true,
    -- Sandbox script execution. When true, scripts get a restricted _ENV with
    -- no `io`, `os.execute` or `loadstring`. Turn off if you script against
    -- your own helper modules.
    sandbox = true,
    -- Milliseconds a single script may run before it is aborted.
    timeout = 5000,
  },

  history = {
    -- Responses kept in the in-memory ring, browsable with `[` and `]` in the
    -- response window. 0 = unlimited (bounded only by memory).
    size = 50,
  },

  -- Buffer-local keymaps applied to every `filetypes` buffer. Set any to
  -- `false` to drop it, or set `keymaps = false` to bind everything yourself.
  keymaps = {
    send = "<leader>Rs",          -- send the request under the cursor
    send_all = "<leader>Ra",      -- send every request in the file
    replay = "<leader>Rr",        -- replay the last request
    toggle = "<leader>Ro",        -- toggle the response window
    select_env = "<leader>Re",    -- pick the environment
    pick_request = "<leader>Rf",  -- jump to a request in this file
    copy_curl = "<leader>Ry",     -- yank the request as a curl command line
    paste_curl = "<leader>Rp",    -- convert a curl command in the clipboard
    inspect = "<leader>Ri",       -- show the fully-resolved request
    next_request = "]r",
    prev_request = "[r",
    clear = "<leader>Rc",         -- clear inline status + close the window
  },

  -- Keymaps inside the response window. Same rules as above.
  result_keymaps = {
    close = "q",
    next_pane = "L",
    prev_pane = "H",
    next_history = "]",
    prev_history = "[",
    jump_to_request = "gd",  -- jump back to the request that produced this
    yank_body = "Y",
    save_body = "gs",
    filter = "/",            -- live jq filter over a JSON body
    refresh = "R",           -- re-send the request that produced this
  },

  -- Notification level: "all" | "errors" | "none".
  --   all    -- a message when a request starts and when it lands
  --   errors -- only failures
  notify = "errors",

  -- Write a debug log to stdpath("log")/curlite.log. Useful when a request
  -- behaves differently than the same curl line in a shell.
  debug = false,
}

---@type curlite.Config
M.options = vim.deepcopy(M.defaults)

--- Merge user options over the defaults.
---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  -- `keymaps = false` and `result_keymaps = false` survive the deep merge as
  -- `false`, which the consumers treat as "bind nothing". Normalise the split
  -- direction aliases here so nothing downstream has to know about them.
  local aliases = { vertical = "right", horizontal = "below" }
  local d = M.options.ui.display
  M.options.ui.display = aliases[d] or d

  return M.options
end

--- Convenience accessor so modules can `local cfg = require("curlite.config").get()`.
---@return curlite.Config
function M.get()
  return M.options
end

return M
