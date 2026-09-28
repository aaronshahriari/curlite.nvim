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
    --
    -- This is the bottom of the stack. A header may also come from the
    -- environment file, which is where a per-project or per-environment one
    -- belongs; see `env.headers_key`. In full, later wins:
    --
    --   request.default_headers  <  $shared's $default_headers
    --                            <  the environment's $default_headers
    --                            <  the header on the request itself
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
    -- Split size as a fraction of the editor, or an absolute cell count.
    -- 0 lets Neovim decide.
    width = 0.5,
    height = 0.5,
    -- Float geometry, used when `display = "float"`. Fractions of the editor.
    float = {
      width = 0.8,
      height = 0.8,
      border = "rounded",
    },
    -- The environment picker (`keymaps.select_env`). It is deliberately large:
    -- it shows every environment beside the variables that environment
    -- resolves to, so you pick by looking at the values rather than by
    -- remembering which name means which host.
    picker = {
      -- Which front end opens it.
      --   "auto"      -- telescope when it is installed, the built-in window
      --                  otherwise. curlite depends on no plugin, so there is
      --                  always something to fall back to.
      --   "telescope" -- telescope, warning if it is missing
      --   "builtin"   -- always the built-in window
      backend = "auto",
      -- Fractions of the editor, or absolute cell counts above 1. Both front
      -- ends use these, so switching between them keeps the same shape.
      width = 0.8,
      height = 0.7,
      -- How much of that width the list of names takes; the rest previews the
      -- variables.
      list_width = 0.3,
      border = "rounded",
      -- Show the variable preview at all. False leaves a plain, narrow list.
      preview = true,
      -- Passed to telescope's picker, merged over curlite's defaults: a
      -- `layout_strategy`, a `layout_config`, a theme's fields, anything
      -- `telescope.pickers.new` accepts.
      telescope = {},
    },
    -- Which pane the response opens on. Select with `B`/`H`/`A`/`S`/`V`/`O`.
    --   "body" | "headers" | "all" | "stats" | "verbose" | "script"
    default_pane = "body",
    -- Panes offered in the winbar, in order. Drop any you never look at.
    panes = { "body", "headers", "all", "stats", "verbose", "script" },
    -- Draw the pane list in the window's winbar.
    winbar = true,
    -- Move the cursor into the response window when it opens. False keeps you
    -- in the request buffer so you can fire the next one immediately.
    focus = false,
    -- Wrap long lines in the response.
    wrap = false,
    -- Show line numbers in the response.
    number = false,
    -- Highlight the line the cursor is on in the response window. Off: the
    -- response is something you read and copy out of, and a bar tracking the
    -- cursor across it reads as noise rather than as position.
    cursorline = false,
    -- Virtual text on the request line after it runs (` 200 OK`). Cleared
    -- when the buffer changes. Set false to drop it entirely.
    inline_status = true,
    -- What that virtual text shows. The response window carries all of this
    -- a split away, so only the status is on by default -- the inline text is
    -- there to answer "did it work?" at the cursor, not to repeat the winbar.
    inline = {
      icon = true,    -- the status icon
      status = true,  -- `200 OK`
      time = false,   -- `· 143ms`
      size = false,   -- `· 2.7KB`
      tests = false,  -- `· 2/2` assertion tally
    },

    -- Briefly highlight the whole request section in the buffer as it is sent,
    -- from its `###` header through its final body/script line.
    flash = true,
    -- How long to hold it, in milliseconds. 0 holds it until the response
    -- lands, however long that takes.
    flash_timeout = 1500,
    -- How much to highlight.
    --   "request" -- the request line, its headers and its body
    --   "line"    -- the request line alone
    flash_scope = "request",
    -- Icons used across the UI. Set any to "" to drop it.
    icons = {
      success = "",
      error = "",
      running = "",
      redirect = "",
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

  -- Formatting the `.http` buffer you edit, via `:Curlite format` or the
  -- `keymaps.format` binding. curlite formats in pure Lua -- there is no
  -- binary to install and nothing to configure a language server for.
  format = {
    -- Re-indent JSON request bodies. `{{template}}` placeholders survive it.
    -- Off leaves every body exactly as typed and only the structural lines
    -- (separators, variables, request lines, headers) are normalised.
    bodies = true,
    -- Spaces per indent level when re-indenting a JSON body.
    indent = 2,
    -- Format the buffer automatically just before it is written.
    on_save = false,
  },

  -- Highlighting of the `.http` buffer you edit, as opposed to the response
  -- window above.
  highlight = {
    -- Extmark highlighting on top of syntax/treesitter. Off means curlite
    -- colours nothing and whatever else is attached to the buffer is left to
    -- do the job alone.
    enable = true,

    -- A full-width background bar behind structural lines. This is the
    -- `CursorLine`-style banding; `"none"` leaves the buffer flat.
    --   "none"      -- no bar anywhere (default)
    --   "separator" -- behind `###` section lines only
    --   "all"       -- behind `###` lines and header lines
    line_bar = "none",
    -- The group the bar is drawn with, when `line_bar` is not "none".
    line_bar_group = "CursorLine",

    -- Method colours, defined outright rather than linked.
    --
    -- Linking these to colorscheme groups is exactly what made GET and POST
    -- indistinguishable: `DiagnosticInfo` and `Function` are two near-identical
    -- blues in most themes. A method is the single most important token on a
    -- request line, so it gets a fixed hue and real weight.
    --
    -- A value may be:
    --   "#rrggbb"     -- a literal colour
    --   "GroupName"   -- link to that highlight group instead
    --   false         -- leave the method uncoloured
    -- Keys are matched upper-case. Unlisted methods fall back to `default`.
    methods = {
      dark = {
        GET = "#a6e3a1",      -- green
        POST = "#89b4fa",     -- blue
        PUT = "#fab387",      -- orange
        PATCH = "#f9e2af",    -- yellow
        DELETE = "#f38ba8",   -- red
        HEAD = "#94e2d5",     -- teal
        OPTIONS = "#94e2d5",  -- teal
        QUERY = "#cba6f7",    -- mauve
        GRAPHQL = "#cba6f7",  -- mauve
        TRACE = "#bac2de",
        CONNECT = "#bac2de",
        default = "#cdd6f4",
      },
      light = {
        GET = "#40a02b",
        POST = "#1e66f5",
        PUT = "#fe640b",
        PATCH = "#df8e1d",
        DELETE = "#d20f39",
        HEAD = "#179299",
        OPTIONS = "#179299",
        QUERY = "#8839ef",
        GRAPHQL = "#8839ef",
        TRACE = "#6c6f85",
        CONNECT = "#6c6f85",
        default = "#4c4f69",
      },
    },
    -- Attributes applied to every method group alongside its colour. Methods
    -- read as labels, so they are bold and never italic.
    method_style = { bold = true, italic = false },

    -- The URL on a request line. `Underlined` -- the old default -- carries no
    -- foreground at all in most themes, which is why URLs rendered as plain
    -- white text with an underline under them.
    url = { dark = "#89dceb", light = "#04a5e5", underline = true },
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
    -- Environment selected when a file is opened. nil -- the default -- means
    -- *none*: curlite never guesses an environment and never carries the last
    -- one over into a new buffer, so a request cannot go out against the wrong
    -- host because of what you were doing an hour ago. Name one here only if
    -- you genuinely want it active without being asked.
    default = nil,
    -- Refuse to send while no environment is selected (and the project defines
    -- some): the picker opens instead, and the request goes out once you have
    -- chosen. Set false to let requests run with only the shared variables.
    require_selection = true,
    -- The key in http-client.env.json whose variables every environment
    -- inherits. A list is allowed, earlier names winning; JetBrains' `$shared`
    -- is always read as well, so files written for other clients still work.
    shared_key = { "$curliteshared", "$shared" },
    -- The key inside an environment object (or inside a shared one) that holds
    -- headers sent with every request, rather than variables:
    --
    --   {
    --     "$shared": { "$default_headers": { "Accept": "application/json" } },
    --     "prod":    { "$default_headers": { "Authorization": "Bearer {{tok}}" } }
    --   }
    --
    -- The environment's headers are merged over the shared ones, and a header
    -- the request sets itself always wins. `false` as a value drops an
    -- inherited header instead of sending it. A list is allowed, earlier names
    -- winning. These keys are not exposed as variables.
    headers_key = { "$default_headers", "$defaultHeaders" },
  },

  -- Completion inside `.http` buffers: `{{` offers the variables that would
  -- actually resolve there (document, shared, the selected environment,
  -- script globals, prompts, chainable requests and the `$` functions), and
  -- the start of a line offers methods, headers and `# @` metadata.
  --
  -- curlite provides this three ways so it works whatever you use:
  -- blink.cmp and nvim-cmp sources, and -- with neither -- Neovim's own
  -- `omnifunc`, popped open for you as you type.
  completion = {
    -- Set the buffer's `omnifunc`, so `<C-x><C-o>` completes.
    enable = true,
    -- Open the completion menu by itself after `{{`, and keep it filtering as
    -- you type. Only ever used when no completion engine is loaded -- blink
    -- and cmp do their own triggering.
    auto_trigger = true,
    -- Register the nvim-cmp source automatically when nvim-cmp is loaded.
    -- blink.cmp is configured declaratively, so it is registered in your own
    -- blink config; see `:h curlite-completion`.
    cmp = true,
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
    -- Wall-clock budget for a single script block or `# @assert` expression,
    -- in milliseconds. Scripts run on the main loop, so this is what stops a
    -- runaway loop from hanging the editor. 0 disables the check.
    timeout = 5000,
  },

  history = {
    -- Responses kept in the in-memory ring, browsable with `[` and `]` in the
    -- response window. 0 = unlimited.
    size = 50,
    -- A second, byte-based ceiling on the ring, because a count alone is not a
    -- bound: fifty 250KB responses is a lot of memory to hold for a feature
    -- you use occasionally. Oldest entries are dropped until the total of
    -- every retained body, header dump and verbose trace fits. The newest
    -- response is always kept, however large. 0 disables the check.
    max_bytes = 16 * 1024 * 1024,
  },

  -- Buffer-local keymaps applied to every `filetypes` buffer. Set any to
  -- `false` to drop it, or set `keymaps = false` to bind everything yourself.
  keymaps = {
    send = "<leader>Rs",          -- send the request under the cursor
    send_enter = "<CR>",          -- Kulala-compatible send shortcut
    send_all = "<leader>Ra",      -- send every request in the file
    replay = "<leader>Rr",        -- replay the last request
    toggle = "<leader>Ro",        -- hide/show the response at its last split position
    select_env = "<leader>Re",    -- pick the environment
    pick_request = "<leader>Rf",  -- jump to a request in this file
    copy_curl = "<leader>Rc",     -- yank a shareable curl command
    paste_curl = "<leader>RC",    -- convert a curl command in the clipboard
    inspect = "<leader>Ri",       -- show the fully-resolved request
    hover = "K",                  -- LSP-style hover with the resolved request
    next_request = "<leader>Rn",
    prev_request = "<leader>Rp",
    format = "<leader>f",         -- format this .http buffer
    clear = "<leader>Rx",         -- clear inline status + close the window
  },

  -- Keymaps inside the response window. Same rules as above.
  result_keymaps = {
    close = "q",
    next_pane = "<C-l>",
    prev_pane = "<C-h>",
    show_body = "B",
    show_headers = "H",
    show_all = "A",
    show_stats = "S",
    -- `T` for trace, not `V`: the response window is a buffer you select out
    -- of, and `V` belongs to linewise Visual mode there.
    show_verbose = "T",
    show_script = "O",
    next_history = "]",
    prev_history = "[",
    jump_to_request = "gd",  -- jump back to the request that produced this
    yank_body = "Y",
    save_body = "gs",
    filter = "/",            -- jq in JSON Body; normal search everywhere else
    refresh = "R",           -- re-send the request that produced this
  },

  -- Which `vim.notify` messages get through, and where they go.
  --
  -- Every message curlite shows is tagged with an *event* name, so you can
  -- silence one by name instead of turning the whole plugin quiet. See
  -- `:h curlite-notifications` for the list, or `:Curlite events` to print it
  -- with each event's default.
  --
  -- The older `notify = "all" | "errors" | "none"` is still accepted and means
  -- what it always did.
  notify = {
    -- The master switch. False and nothing is ever notified -- errors
    -- included, so prefer silencing events by name.
    enabled = true,

    -- The severity floor for ordinary events: "error" | "warn" | "info" |
    -- "debug" | "trace" | "off", or a `vim.log.levels.*` number.
    --
    -- Events marked *important* in the registry ignore this. Those are the
    -- ones that answer a question you just asked ("did the yank land?") or
    -- report that something you asked for did not happen; hiding those behind
    -- a severity threshold makes the plugin look broken rather than quiet, so
    -- they are only turned off by naming them in `events` below.
    level = "warn",

    -- Per-event overrides, keyed by event name. Each value may be:
    --   false           -- never notify for this event
    --   true            -- always notify, ignoring `level`
    --   "warn" | 3 | .. -- a threshold just for this event
    --
    -- The common ones:
    --   request_sent    -- "GET https://..." as it goes out       (off by default)
    --   request_done    -- "200 OK in 143ms" when it lands        (4xx/5xx only)
    --   request_skipped -- a pre-request script skipped it        (off by default)
    --   run_summary     -- the tally after `send_all`
    --   env_selected    -- "environment -> staging"
    --   yank / save     -- a body or curl line left the editor
    events = {
      -- request_done = "warn",
      -- env_selected = false,
    },

    -- The last word, after `enabled`, `events` and `level` have decided.
    -- `function(ev) -> boolean|nil`, where `ev` is
    -- `{ event, level, shown, msg, data }` and `data` carries whatever the
    -- call site knew (the result, the status, the env name...). Return a
    -- boolean to override the decision, or nil to keep it.
    --
    --   filter = function(ev)
    --     -- every 2xx is silent, everything else behaves normally
    --     if ev.event == "request_done" and ev.data.status < 300 then
    --       return false
    --     end
    --   end,
    filter = nil,

    -- Route messages somewhere other than `vim.notify` -- fidget, snacks,
    -- a statusline, a log file. `function(msg, level, opts)`, where `opts` is
    -- `{ title, event, data }`. nil uses `vim.notify`.
    backend = nil,

    -- The `title` passed to `vim.notify`, which most notifier plugins show.
    title = "curlite",
  },

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
