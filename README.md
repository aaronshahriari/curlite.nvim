<div align="center">

# curlite.nvim

Write HTTP requests in a `.http` file, send them from the buffer, read the response in a split.

![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10+-4c566a?style=flat-square&logo=neovim&logoColor=white)
![curl](https://img.shields.io/badge/powered%20by-curl-4c566a?style=flat-square&logo=curl&logoColor=white)
![Lua](https://img.shields.io/badge/pure-Lua-4c566a?style=flat-square&logo=lua&logoColor=white)

[Features](#features) · [Install](#install) · [Quick start](#quick-start) · [The format](#the-http-format) · [Configuration](#configuration) · [Coming from kulala](#coming-from-kulala)

</div>

curlite reads the JetBrains `.http` format — the same one JetBrains IDEs, VS Code's REST Client and kulala.nvim use — and runs it through `curl`.

There is no companion binary, no language server and no Node. `curl` is the only requirement, and responses come back **out of band** (headers to one file, body to another, timings as JSON on stdout), so a body containing header-looking lines can't confuse the parser and a 40MB download never passes through a Lua string twice.

<!-- DEMO SCREENSHOT: save the screenshot to the repo root as `curlite_demo.png`,
     then delete this comment wrapper (the two lines marked <<< / >>>) to show it.
<<<
<div align="center">

<img src="curlite_demo.png" alt="curlite.nvim sending a request with the response in a split" width="900" />

<sub>A request in an <code>.http</code> buffer, the response in the split on the right, status and timing in the winbar.</sub>

</div>
>>>
-->

## Features

- **Send from the buffer** — the request under the cursor, all of them, or everything from the cursor down. Inline `  200 OK · 143ms` appears at the end of the request line.
- **Six response panes** — body, headers, both, a timing and size breakdown, curl's verbose trace, and your scripts' output. Cycle with `H`/`L`, jump with `1`–`6`. The body pane holds *only* the body, so treesitter highlights it and `jq` can filter it live with `/`.
- **Environments** from `http-client.env.json` with a `$shared` block, a gitignored `.private.` overlay, and per-project memory of which one you picked.
- **Variables everywhere** — document (`@token = ...`), environment, process env, `.env`, prompts, dynamic (`{{$uuid}}`, `{{$timestamp -1 d}}`, `{{$randomInt 1 100}}`, IntelliJ's `{{$random.integer(1,100)}}`), and shell (`{{$exec pass show api/token}}`). Resolution is recursive, so `@base = {{host}}/v1` works.
- **Request chaining** — `{{LOGIN.response.body.$.data.token}}` reads an earlier response, and `# @run LOGIN` makes curlite send it for you first. Cycles terminate; a failed dependency blocks the request that needed it.
- **Lua scripts**, not JavaScript — `< {% ... %}` before, `> {% ... %}` after, with `request`, `response` and `client` in scope. You're already in a Lua editor.
- **Assertions** — `# @assert status == 200`, `client.test("name", fn)`. Results show as a `3/4` tally in the winbar and on the request line. `:CurliteRun file.http` runs a whole file and reports the totals.
- **Auth** — Bearer, Basic (base64-encoded for you), Digest, NTLM, Negotiate, AWS SigV4 and client certificates, each mapped onto the curl flag that implements it. A shared cookie jar carries a login's session into the next request.
- **GraphQL** and **multipart** bodies, `< ./payload.json` inputs, `>>! ./out.json` outputs.
- **Paste a curl command**, get a request back — including the shape Chrome's "Copy as cURL" produces. And the reverse: yank any request as a pasteable curl line.
- **Completion** for blink.cmp: variables with their values, chain references for every named request, methods, header names, header values and `# @` metadata with descriptions.
- **Form bodies written the way people write them** — one parameter per line, `&`-prefixed. The newlines are formatting, and curlite strips them before sending, the way every other client does.

## Requirements

- Neovim 0.10+
- `curl` (7.75+ for the Stats pane; older still works)
- Optional: [`jq`](https://jqlang.github.io/jq/) (the `/` filter; formatting doesn't need it), [blink.cmp](https://github.com/Saghen/blink.cmp) (completion), a treesitter `http` parser (curlite ships a syntax file and uses it when there isn't one), [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim)

`:checkhealth curlite` reports what's available.

## Install

With [`vim.pack`](https://neovim.io/doc/user/pack.html) (Neovim 0.12+):

```lua
vim.pack.add({ { src = "https://github.com/aaronshahriari/curlite.nvim" } })
require("curlite").setup({})
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "aaronshahriari/curlite.nvim",
  ft = { "http" },
  cmd = { "Curlite", "CurliteRun" },
  opts = {},
}
```

`setup()` has to run — it registers the filetypes, keymaps and commands. Calling it twice is safe.

## Quick start

```http
@host = https://httpbin.org

### GET_IP
GET {{host}}/ip
Accept: application/json
```

Cursor anywhere in it, `<leader>Rs`. That's it.

| key | |
| --- | --- |
| `<leader>Rs` | send the request under the cursor |
| `<leader>Ra` | send every request in the file |
| `<leader>Rr` | replay the last one |
| `<leader>Re` | pick the environment |
| `<leader>Rf` | jump to a request by name |
| `<leader>Ri` | show the resolved request + its curl equivalent |
| `K` | show the same resolved-request preview |
| `<leader>Ry` | yank the request as a curl command |
| `<leader>Rp` | turn a curl command in the clipboard into a request |
| `<leader>h` | hide/show the response at its last split position |
| `]r` `[r` | next / previous request |

In the response window: `H`/`L` cycle panes, `1`–`6` jump, `[`/`]` walk the history, `/` filters JSON with jq, `gd` jumps back to the request, `Y` yanks the body, `gs` saves it, `R` re-sends, `q` closes.

There's a full tour in [`demo/api.http`](demo/api.http) — every request in it runs against httpbin.org, so you can open it and start pressing keys.

## The `.http` format

````http
@host = https://api.example.com
@traceId = {{$uuid}}

### LOGIN
POST {{host}}/auth/login
Content-Type: application/json

{ "user": "aaron", "password": "{{$env.PASSWORD}}" }

> {%
  client.global.set("token", response.json.data.token)
%}

# @assert status == 200


### ORDERS
# @run LOGIN
GET {{host}}/orders
  ?status=open
  &limit=50
Authorization: Bearer {{token}}
X-Trace-Id: {{traceId}}

# @assert #json.items <= 50
````

A run of three or more `#` separates requests, and whatever follows names one. The method is optional. Indented lines starting with `?` or `&` extend the URL. Headers run until the first blank line; everything after it is the body.

A file with no `###` at all still works — a method at column 0 after a blank line begins a new request.

Guard a request that should never run accidentally by adding `[confirm]` to its title. Curlite shows the fully resolved request in a centered popup and requires `y` or `n`, followed by Enter, before continuing:

```http
### [confirm] Delete production user
DELETE {{prod}}/users/42
```

`# @confirm` provides the same protection for an untitled request. Declining skips it without stopping a "send all" run.

<details>
<summary><b>Metadata</b> — <code># @key value</code> above a request</summary>

| | |
| --- | --- |
| `@name NAME` | name this request |
| `@prompt NAME DESC` | ask for a value before sending, once per session |
| `@assert EXPR` | a Lua expression checked against the response |
| `@run NAME` | send another request first |
| `@import PATH` | make another file's named requests available |
| `@accept TYPE` | shorthand for the `Accept` header |
| `@timeout MS` / `@delay MS` | give up after / wait before |
| `@insecure` | skip TLS verification |
| `@no-redirect` / `@max-redirs N` | redirect handling |
| `@compressed` | ask for and decode a compressed response |
| `@http2` `@http3` `@http1.1` | force a protocol version |
| `@proxy URL` / `@unix-socket PATH` | where to connect |
| `@cert` `@key` `@cacert` | client certificates |
| `@resolve H:P:ADDR` / `@interface NAME` | pin a host / bind an interface |
| `@retry N` / `@user USER:PASS` | |
| `@graphql` | treat the body as a GraphQL query |
| `@confirm` | show the resolved request and require confirmation before sending |
| `@skip` | never send this one; a "send all" steps over it |
| `@no-cookie-jar` | don't touch the shared jar |
| `@curl ARGS` | raw curl flags, the escape hatch |

</details>

<details>
<summary><b>Variables</b> — lookup order and the dynamic ones</summary>

First hit wins: dynamic functions → request variables → script globals → prompt answers → document variables → environment.

An unresolvable name means the request is **refused**, not sent with a literal `{{name}}` in it, and the error names what was missing.

```
{{$uuid}} {{$guid}}
{{$timestamp}}  {{$timestamp -1 d}}       units: ms s m h d w M y
{{$isoTimestamp}}  {{$isoTimestamp 7 d}}
{{$datetime iso8601|rfc1123|unix|"%Y/%m/%d"}}
{{$localDatetime iso8601}}
{{$date}}  {{$date %d/%m/%Y}}  {{$time}}
{{$randomInt 1 100}}  {{$randomAlphaNumeric 16}}  {{$randomHex 16}}
{{$randomEmail}}  {{$randomFirstName}}  {{$randomLastName}}  {{$randomFullName}}
{{$env.NAME}}  {{$processEnv NAME}}  {{$dotenv NAME}}
{{$exec pass show api/example/token}}   evaluated once per run, not per request
```

IntelliJ's spellings work too: `{{$random.integer(1, 100)}}`, `{{$random.uuid}}`, `{{$random.alphanumeric(8)}}`, `{{$random.float(0, 1)}}`, `{{$random.hexadecimal(12)}}`, `{{$random.email}}`.

Reading an earlier response:

```
{{LOGIN.response.body.$.data.token}}    a JSONPath ([0]-indexed arrays)
{{LOGIN.response.headers.x-request-id}} case-insensitive
{{LOGIN.response.status}}
{{LOGIN.response.cookies.session}}
{{LOGIN.request.body.$.user}}
{{$last.response.status}}
```

</details>

<details>
<summary><b>Environments</b> — <code>http-client.env.json</code></summary>

```json
{
  "$shared": { "apiVersion": "v1" },
  "dev":  { "host": "http://localhost:3000" },
  "prod": { "host": "https://api.example.com", "auth": { "clientId": "abc" } }
}
```

`$shared` is merged under every environment. Nested values are reachable as `{{auth.clientId}}`. `http-client.private.env.json` is merged over the public file and is the one to gitignore. Files nearer the `.http` file win over ones further up. `//` and `/* */` comments are tolerated (and a `//` inside a string, as in `https://`, is left alone).

Pick with `<leader>Re`. The choice is remembered per project. A `.env` in the same directories is read too, as `{{$dotenv NAME}}`.

</details>

<details>
<summary><b>Scripts</b> — Lua, before and after</summary>

```http
### LOGIN
< {%
  request.headers.set("X-Request-Id", client.global.get("run_id"))
%}
POST {{host}}/login

{ "user": "aaron" }

> {%
  client.global.set("token", response.json.data.token)
  client.log("expires in " .. response.json.data.expires_in)

  client.test("token looks real", function()
    assert(#response.json.data.token > 20)
  end)
%}
```

`< ./pre.lua` and `> ./post.lua` load from disk instead.

**`request`** (mutable): `.method` `.url` `.body`, `.headers.get/set/remove/all`, `.variables.set/get`, `.metadata`, `.skip([reason])`, `.abort([reason])`
**`response`** (post only): `.status` `.status_text` `.http_version` `.body` `.json` `.headers` `.header(name)` `.cookies` `.duration_ms` `.stats`
**`client`**: `.global.set/get/clear/all`, `.log(...)`, `.test(name, fn)`, `.assert(cond, msg)`, `.exit()`

Also in scope: `json`, `env`, `log`, `print`. Sandboxed by default — no `io`, no `os.execute`, no loaders. `scripts.sandbox = false` if you script against your own modules.

</details>

<details>
<summary><b>Auth</b> — and what to do about OAuth2</summary>

```http
Authorization: Bearer {{token}}
Authorization: Basic alice s3cret        # base64-encoded for you
Authorization: Basic alice:s3cret        # same
Authorization: Digest alice s3cret       # --digest, curl does the challenge
Authorization: NTLM alice s3cret
Authorization: Negotiate
Authorization: AWS KEY SECRET eu-west-1 s3
```

A value that is already base64 is passed through untouched. Client certificates use `# @cert` / `# @key` / `# @cacert`.

There's no built-in OAuth2 flow. For client credentials, make the token request a request and chain it:

```http
### TOKEN
POST {{host}}/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id={{clientId}}
&client_secret={{clientSecret}}

> {% client.global.set("access_token", response.json.access_token) %}

### THINGS
# @run TOKEN
GET {{host}}/v1/things
Authorization: Bearer {{access_token}}
```

For a browser-redirect flow, get the token however you normally do and reach it with `{{$exec}}`.

</details>

## Configuration

`setup()` deep-merges over the defaults, so pass only what you want changed.
Every field is documented inline in [`lua/curlite/config.lua`](lua/curlite/config.lua),
and in full in `:h curlite-configuration`.

<details open>
<summary><b>The complete default table</b></summary>

```lua
require("curlite").setup({
  -- Filetypes curlite attaches to; keymaps and on_attach fire for each.
  filetypes = { "http" },
  filetype = {
    register = true,                       -- let curlite call vim.filetype.add
    extensions = { "rest" },               -- .http is already native
    patterns = { [".*%.http%..*"] = "http" }, -- api.http.dev, api.http.local
  },
  on_attach = nil,                         -- function(bufnr), for your own binds

  curl = {
    path = "curl",
    args = { "--location", "--no-buffer" },
    timeout = 30000,                       -- ms; 0 disables. `# @timeout` wins.
    verify_ssl = true,                     -- false adds --insecure to everything
    cookie_jar = vim.fn.stdpath("data") .. "/curlite/cookies.txt", -- false disables
  },

  request = {
    variables_scope = "request",           -- or "document" (kulala's behaviour)
    default_headers = { ["User-Agent"] = "curlite.nvim" },
    infer_content_type = true,             -- JSON-looking body -> application/json
    substitute_in_response = false,        -- expand {{...}} in the response too
  },

  ui = {
    display = "right",                     -- right|left|below|above|float|tab
    width = 88,                            -- columns, for a left/right split
    height = 20,                           -- rows, for an above/below split
    float = { width = 0.8, height = 0.8, border = "rounded" },
    default_pane = "body",
    panes = { "body", "headers", "all", "stats", "verbose", "script" },
    winbar = true,                         -- the pane tabs and status line
    focus = false,                         -- keep the cursor in the request buffer
    wrap = false,
    number = false,
    inline_status = true,                  -- ` 200 OK · 143ms` on the request line
    icons = {
      success  = "",
      error    = "",
      running  = "",
      redirect = "",
    },
    highlights = {                         -- see "Highlights" below
      success      = "DiagnosticOk",
      redirect     = "DiagnosticInfo",
      client_error = "DiagnosticWarn",
      server_error = "DiagnosticError",
      running      = "Comment",
      inline       = "Comment",
    },
  },

  response = {
    format = true,                         -- pretty-print bodies
    indent = 2,
    filetypes = {                          -- Content-Type substring -> filetype
      json = "json", xml = "xml", html = "html",
      javascript = "javascript", css = "css", yaml = "yaml", text = "text",
    },
    max_format_size = 1024 * 1024,         -- above this, show raw. 0 = no limit
    show_request = true,                   -- include the request in the `all` pane
  },

  env = {
    files = { "http-client.env.json", "http-client.private.env.json" },
    dotenv = ".env",                       -- false disables {{$dotenv NAME}}
    default = nil,                         -- nil = remember the last choice
    shared_key = "$shared",
  },

  scripts = {
    enable = true,
    sandbox = true,                        -- no io, os.execute, debug, jit, require
    timeout = 5000,                        -- ms; stops a runaway loop. 0 disables
  },

  history = {
    size = 50,                             -- responses kept for [ and ]. 0 = all
    max_bytes = 16 * 1024 * 1024,          -- ...and a byte ceiling. 0 disables
  },

  -- Buffer-local, in every .http buffer. Set one to false to drop it,
  -- or keymaps = false to bind everything yourself.
  keymaps = {
    send         = "<leader>Rs",
    send_all     = "<leader>Ra",
    replay       = "<leader>Rr",
    toggle       = "<leader>h",
    select_env   = "<leader>Re",
    pick_request = "<leader>Rf",
    copy_curl    = "<leader>Ry",
    paste_curl   = "<leader>Rp",
    inspect      = "<leader>Ri",
    clear        = "<leader>Rc",
    next_request = "]r",
    prev_request = "[r",
  },

  -- Inside the response window. Same rules.
  result_keymaps = {
    close           = "q",
    next_pane       = "L",
    prev_pane       = "H",
    next_history    = "]",
    prev_history    = "[",
    jump_to_request = "gd",
    yank_body       = "Y",
    save_body       = "gs",
    filter          = "/",
    refresh         = "R",
  },

  notify = "errors",                       -- all|errors|none
  debug = false,                           -- log commands to stdpath("log")
})
```

</details>

### Where the response opens

`ui.display` takes `right` (default), `left`, `below`, `above`, `float` or `tab`.
`vertical` and `horizontal` are aliases for `right` and `below`.

`ui.width` sizes a vertical split, `ui.height` a horizontal one; `0` leaves it
to Neovim, and a size you set by hand sticks while the window is open. For
`float`, `ui.float.width`/`height` are fractions of the editor and
`ui.float.border` is anything `nvim_open_win` accepts.

`ui.focus = false` keeps the cursor in the request buffer so you can fire the
next request straight away. The window carries `winfixbuf`, so a stray
`:bnext` or a plugin can't replace your response with something else.

Drop any pane you never open from `ui.panes` — it leaves the winbar and the
`H`/`L` cycle with it.

### Highlights

Every group is a link with `default = true`, so it follows your colorscheme,
anything you set wins, and a `:colorscheme` change is picked up automatically.

Six carry meaning and are configurable through `ui.highlights`:

| group | when | default |
| --- | --- | --- |
| `CurliteSuccess` | 2xx | `DiagnosticOk` |
| `CurliteRedirect` | 3xx | `DiagnosticInfo` |
| `CurliteClientError` | 4xx | `DiagnosticWarn` |
| `CurliteServerError` | 5xx, and a failed request | `DiagnosticError` |
| `CurliteRunning` | in flight | `Comment` |
| `CurliteInline` | the inline virtual text | `Comment` |

The rest describe curlite's own furniture and are fixed links — override them
with `:highlight` if you want:

| group | | group | |
| --- | --- | --- | --- |
| `CurlitePaneActive` | the pane you're on | `CurliteSection` | a Stats/Script heading |
| `CurlitePaneInactive` | the other tabs | `CurliteLabel` | a Stats label |
| `CurliteStatusLine` | the `HTTP/2` prefix | `CurliteValue` | a Stats value |
| `CurliteHeaderName` | a header's name | `CurliteTotal` | the Total timing row |
| `CurliteHeaderValue` | a header's value | `CurliteLogLine` | a `client.log` line |
| `CurliteMethod` | the request's method | `CurliteTestPass` | a passing assertion |
| `CurliteUrl` | the request's URL | `CurliteTestFail` | a failing one |
| `CurliteRule` | the request/response divider | `CurliteTestDetail` | a failure's detail |
| | | `CurliteTestName` | a passing test's name |

`.http` buffers use a treesitter `http` parser when one is installed; otherwise
curlite's own `syntax/http.vim` runs — `:h curlite-highlights-http` lists every
group it defines.

<details>
<summary><b>blink.cmp</b></summary>

```lua
require("blink.cmp").setup({
  sources = {
    providers = { curlite = { module = "curlite.blink", name = "curlite" } },
    per_filetype = { http = { "curlite", "path", "buffer" } },
  },
})
```

</details>

<details>
<summary><b>lualine</b></summary>

```lua
require("lualine").setup({ sections = { lualine_x = { "curlite" } } })
```

Shows the active environment and the last response. `require("curlite").current_env()`
is the building block for any other statusline.

</details>

## From Lua

```lua
-- Run a request without touching the UI: a keymap, a timer, an autocommand.
require("curlite").inline([[
GET https://api.example.com/health
Accept: application/json
]], function(result)
  if result.response.status ~= 200 then
    vim.notify("service is down", vim.log.levels.ERROR)
  end
end)

-- Or block on it.
local result = require("curlite").inline_sync("GET https://api.example.com/ip")

-- Run a whole file's assertions.
require("curlite").run_file("tests/api.http", function(s)
  print(s.total, s.passed, s.failed)
end)
```

## Coming from kulala

The file format is identical, so your `.http` files and `http-client.env.json` work unchanged. What's different:

| | |
| --- | --- |
| **scripts** | Lua, not JavaScript. `client.global.set`, `client.test`, `request.skip` and `request.abort` keep their names; the bodies are Lua. |
| **no backend** | no companion binary, no tree-sitter CLI, no download on install. `curl` is the only requirement. |
| **protocols** | HTTP and GraphQL. No gRPC, WebSocket or streaming. |
| **OAuth2** | no built-in flow — chain a token request instead. |
| **OpenAPI explorer** | not included. |
| **filtering** | a jq expression over the body (`/` in the response window). |

Environments, `$shared`, dynamic variables, request chaining, prompts, assertions, `>>` redirects, `< file` bodies, multipart and the scratchpad all behave the same way.

## Commands

`:Curlite [send|all|rest|replay|inspect|env|pick|toggle|open|close|clear|cancel|curl|paste|scratch|log|health]`

`:CurliteRun [file]` — with a file, run every request in it and report the assertion totals.

## Development

```sh
tests/run.sh              # the whole suite
tests/run.sh parser       # just the ones matching "parser"
```

`tests/run.sh` starts a local echo server (`tests/server.py`) for the end-to-end tests and stops it on exit. Without `python3` those skip and the rest still run.

## License

MIT
