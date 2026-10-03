<div align="center">

# curlite.nvim

Write HTTP requests in a `.http` file, send them from the buffer, read the response in a split.

![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10+-4c566a?style=flat-square&logo=neovim&logoColor=white)
![curl](https://img.shields.io/badge/powered%20by-curl-4c566a?style=flat-square&logo=curl&logoColor=white)
![Lua](https://img.shields.io/badge/pure-Lua-4c566a?style=flat-square&logo=lua&logoColor=white)

[Features](#features) · [Install](#install) · [Quick start](#quick-start) · [Format](#the-http-format) · [Configuration](#configuration)

</div>

<!-- DEMO SCREENSHOT: save the screenshot to the repo root as `curlite_demo.png`,
     then delete this comment wrapper (the two lines marked <<< / >>>) to show it.
<<<
<div align="center">

<img src="curlite_demo.png" alt="curlite.nvim sending a request with the response in a split" width="900" />

<sub>A request in an <code>.http</code> buffer, the response in the split on the right, status and timing in the winbar.</sub>

</div>
>>>
-->

curlite reads the JetBrains `.http` format — the same one JetBrains IDEs, VS Code's REST Client and kulala.nvim use — and runs it through `curl`. **No companion binary, no language server, no Node.** Responses come back out of band (headers, body and timings in separate streams), so a body full of header-looking lines can't confuse the parser and a 40MB download never passes through a Lua string twice.

## Features

- **Send from the buffer** — the request under the cursor, all of them, or everything from the cursor down. ` 200 OK` appears inline at the end of the request line; timing, size and test totals can be enabled there too.
- **Six response panes** — body, headers, both, timing and size, curl's verbose trace, script output. Open them with `B`/`H`/`A`/`S`/`T`/`O`, or jump with `1`–`6`. The body pane holds *only* the body, so treesitter highlights it and `gq` filters it live through `jq`, while `gi` drops a copy in its own tab to filter by hand. `/` stays plain Vim search.
- **Environments** from `http-client.env.json` — a `$curliteshared` block, a gitignored `.private.` overlay, per-project `$default_headers`, and a picker that shows each environment's variables beside its name. Nothing is selected until you pick: opening a file starts with no environment, and the first send asks which one.
- **Variables everywhere** — document, environment, process env, `.env`, prompts, dynamic (`{{$uuid}}`, `{{$timestamp -1 d}}`, `{{$randomInt 1 100}}`) and shell (`{{$exec pass show api/token}}`). Resolution is recursive, so `@base = {{host}}/v1` works.
- **Request chaining** — `{{LOGIN.response.body.$.data.token}}` reads an earlier response, and `# @run LOGIN` makes curlite send it for you first.
- **Lua scripts**, not JavaScript — `< {% ... %}` before, `> {% ... %}` after, with `request`, `response` and `client` in scope. You're already in a Lua editor.
- **Assertions** — `# @assert status == 200` and `client.test(...)`, tallied in the winbar. `:CurliteRun file.http` runs a whole file and reports the totals.
- **Auth** — Bearer, Basic, Digest, NTLM, Negotiate, AWS SigV4 and client certificates, each mapped onto the curl flag that implements it. A shared cookie jar carries a login's session into the next request.
- **Paste a curl command**, get a request back — including what Chrome's "Copy as cURL" produces. And the reverse: yank any request as a pasteable curl line.
- **Completion**, with or without a plugin — `{{` offers every variable that would actually resolve there, each with its value and the environment it came from, plus chain references, methods, header names and values, and `# @` metadata. blink.cmp and nvim-cmp sources are included; with neither, Neovim's own `omnifunc` is wired up and opens by itself after `{{`.

## Requirements

- Neovim 0.10+
- `curl` (7.75+ for the Stats pane; older still works)
- Optional: [`jq`](https://jqlang.github.io/jq/) (the `gq` filter), [blink.cmp](https://github.com/Saghen/blink.cmp) (completion), a treesitter `http` parser (curlite ships a syntax file for when there isn't one), [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim)

`:checkhealth curlite` reports what's available.

## Install

**vim.pack (Neovim 0.12+)**

```lua
vim.pack.add({ { src = "https://github.com/aaronshahriari/curlite.nvim" } })
require("curlite").setup({})
```

**lazy.nvim**

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

There's a full tour in [`demo/api.http`](demo/api.http) — every request in it runs against httpbin.org, so you can open it and start pressing keys.

## Sending requests

| Key | Action | Key | Action |
|---|---|---|---|
| `<leader>Rs` / `<CR>` | Send the request under the cursor | `K` | Hover: the resolved request, LSP-style — `K` again steps inside |
| `<leader>Ra` | Send every request in the file | `<leader>Ri` | The same, plus the curl equivalent, in a window you can read |
| `<leader>Rr` | Replay the last one | `<leader>Rc` | Yank a shareable cURL command |
| `<leader>Re` | Pick the environment | `<leader>RC` | Turn a curl command in the clipboard into a request |
| `<leader>Rf` | Jump to a request by name | `<leader>Ro` | Hide/show the response (also inside it) |
| `<leader>f` | Format the request file | `<leader>Rn` / `<leader>Rp` | Next / previous request |
| `<leader>Rx` | Clear response state | | |

**In the response window:** `B` body, `H` headers, `A` all, `S` stats, `T` trace (verbose), `O` script; `<C-h>`/`<C-l>` cycle, `1`–`6` jump by position, and `[`/`]` walk history. `gq` filters a JSON body through `jq`, leaving `/` to search the response as usual. `gi` opens a copy of the body in its own tab as a plain modifiable buffer — `:%!jq '.items | map(.id)'`, `:g/.../d`, anything — and `q` throws it away. `gd` jumps back, `Y` yanks the body, `gs` saves it, `R` re-sends, `<leader>Ro` hides the window without leaving it, and `q` closes.

`:Curlite [send|all|rest|replay|inspect|hover|env|pick|toggle|open|close|clear|cancel|curl|paste|format|scratch|body|log|health]` covers the same ground, and `:CurliteRun [file]` runs every request in a file and reports the assertion totals.

## The `.http` format

````http
@host = https://api.example.com

### LOGIN
POST {{host}}/auth/login
Content-Type: application/json

{ "user": "aaron", "password": "{{$env.PASSWORD}}" }

> {% client.global.set("token", response.json.data.token) %}

# @assert status == 200


### ORDERS
# @run LOGIN
GET {{host}}/orders
  ?status=open
  &limit=50
Authorization: Bearer {{token}}
````

A run of three or more `#` separates requests, and whatever follows names one. The method is optional. Indented lines starting with `?` or `&` extend the URL. Headers run until the first blank line; everything after it is the body. A file with no `###` at all still works — a method at column 0 after a blank line begins a new request.

Guard a dangerous request with `[confirm]` in its title (or `# @confirm` on an untitled one) and curlite shows the fully resolved request in a popup, requiring `y` or `n` before it sends:

```http
### [confirm] Delete production user
DELETE {{prod}}/users/42
```

## More

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
| `@confirm` | show the resolved request and require confirmation |
| `@skip` | never send this one; a "send all" steps over it |
| `@no-cookie-jar` | don't touch the shared jar |
| `@curl ARGS` | raw curl flags, the escape hatch |

</details>

<details>
<summary><b>Variables</b> — lookup order, dynamic values, chaining</summary>

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

Cycles terminate, and a failed dependency blocks the request that needed it.

</details>

<details>
<summary><b>Environments</b> — <code>http-client.env.json</code></summary>

```json
{
  "$curliteshared": { "apiVersion": "v1" },
  "dev":  { "host": "http://localhost:3000" },
  "prod": { "host": "https://api.example.com", "auth": { "clientId": "abc" } }
}
```

`$curliteshared` is merged under every environment. JetBrains' `$shared` is read as well, so a file written for another client works unchanged; where both define a key, `$curliteshared` wins. Nested values are reachable as `{{auth.clientId}}`. `http-client.private.env.json` is merged over the public file and is the one to gitignore. Files nearer the `.http` file win over ones further up. `//` and `/* */` comments are tolerated (and a `//` inside a string, as in `https://`, is left alone).

**Nothing is selected until you say so.** Opening a `.http` file starts with no environment — never the one you picked yesterday, never the first one in the file — and the first send stops and opens the picker instead of going out against a host you did not choose. Pick with `<leader>Re` or `:Curlite env`:

```
╭─ Environment ──────────╮ ╭─ dev ──────────────────────────────────╮
│   (no environment)     │ │{                                       │
│ ● dev            6 vars│ │  "apiVersion": "v1",    $curliteshared │
│   prod           5 vars│ │  "clientId": "demo",    $curliteshared │
│                        │ │  "host": "http://localhost:3000",  dev │
│                        │ │  "verbose": true                   dev │
│                        │ │}                                       │
╰─ <CR> select   q cancel ╯ ╰────────────────────────────────────────╯
```

The right-hand pane is what that environment actually resolves to — the shared block merged with its own values, every line marked with where it came from — so you choose by looking at the host rather than by remembering what `dev2` meant. It is rebuilt as you move, so it is a live view of the file rather than a snapshot. `(no environment)` clears the selection and shows the shared block alone; choosing it counts as a choice, so sends stop asking.

With [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) installed that is a telescope picker — fuzzy-findable, and laid out the way the rest of your telescope pickers are — with the same list and the same live JSON preview:

```
╭─ Environment ─────────────────────────────────────────────────────────────╮
│ > ● prod             2 vars, 2 headers │ {                                │
│     dev              3 vars, 1 header  │   "apiVersion": "v1", $curliteshared
│     (no environment) 1 var,  1 header  │   "host": "https://api.example.com"
│                                        │ }                     prod       │
│ > prod                                 │                                  │
│                                        │ -- sent with every request       │
│                                        │ --   Accept: application/json  $curliteshared
│                                        │ --   Authorization: Bearer {{tok}}  prod
╰───────────────────────────────────────────────────────────────────────────╯
```

curlite depends on no plugin, so without telescope it opens the window above instead. `ui.picker.backend` decides — `"auto"` (the default), `"telescope"` or `"builtin"` — and `ui.picker.telescope` passes a layout or theme through. There's an extension too, if you drive everything from `:Telescope`:

```lua
require("telescope").load_extension("curlite")  -- :Telescope curlite
```

Set `env.default` to a name if you want one active without being asked, or `env.require_selection = false` to let requests run with only the shared variables. A `.env` in the same directories is read too, as `{{$dotenv NAME}}`.

**Default headers.** A `$default_headers` object sends headers with every request in the project — in the shared block, in an environment, or both:

```json
{
  "$curliteshared": {
    "$default_headers": { "Accept": "application/json", "X-Client": "curlite" }
  },
  "dev":  { "host": "http://localhost:3000", "token": "dev-token" },
  "prod": {
    "host": "https://api.example.com",
    "token": "{{$dotenv PROD_TOKEN}}",
    "$default_headers": { "Authorization": "Bearer {{token}}", "X-Client": false }
  }
}
```

This is where a header belonging to the *project* goes, as opposed to your editor (`request.default_headers`) or a single request. `{{...}}` in a value resolves against the request going out, so `"Bearer {{token}}"` picks up whichever token the selected environment defines. An environment's headers merge over the shared ones, and `false` drops an inherited one rather than sending it — `prod` above sends no `X-Client`. A request that writes the header itself always wins, in any case, and nothing is sent twice. Later wins:

```
request.default_headers  <  $shared's $default_headers
                         <  the environment's $default_headers
                         <  the header on the request itself
```

The picker lists them under the variables, `:Curlite inspect` and `curl` show them resolved, and `:checkhealth curlite` names the ones in force.

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

<details>
<summary><b>Bodies</b> — forms, files, GraphQL, multipart</summary>

Form bodies are written the way people write them — one parameter per line, `&`-prefixed. The newlines are formatting, and curlite strips them before sending, the way every other client does.

`< ./payload.json` reads a body from disk, `>>! ./out.json` writes the response to one, `# @graphql` treats the body as a GraphQL query, and multipart bodies work as they do in every other `.http` client.

</details>

<details>
<summary><b>Where the response opens</b></summary>

`ui.display` takes `right` (default), `left`, `below`, `above`, `float` or `tab`. `vertical` and `horizontal` are aliases for `right` and `below`.

`ui.width` sizes a vertical split and `ui.height` a horizontal one. Values between 0 and 1 are fractions (`0.5` is 50%); values of 1 or more are cell counts. A size you set by hand is remembered as a fraction. For `float`, `ui.float.width`/`height` are fractions of the editor and `ui.float.border` is anything `nvim_open_win` accepts.

`ui.focus = false` keeps the cursor in the request buffer so you can fire the next request straight away. The window carries `winfixbuf`, so a stray `:bnext` or a plugin can't replace your response with something else.

Drop any pane you never open from `ui.panes` and it leaves the winbar and pane cycle with it.

</details>

<details>
<summary><b>Highlights</b></summary>

Every group is a link with `default = true`, so it follows your colorscheme, anything you set wins, and a `:colorscheme` change is picked up automatically.

Six carry meaning and are configurable through `ui.highlights`:

| group | when | default |
| --- | --- | --- |
| `CurliteSuccess` | 2xx | `DiagnosticOk` |
| `CurliteRedirect` | 3xx | `DiagnosticInfo` |
| `CurliteClientError` | 4xx | `DiagnosticWarn` |
| `CurliteServerError` | 5xx, and a failed request | `DiagnosticError` |
| `CurliteRunning` | in flight | `Comment` |
| `CurliteInline` | the inline virtual text | `Comment` |

The rest describe curlite's own furniture and are fixed links — override them with `:highlight` if you want:

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

`.http` buffers use a treesitter `http` parser when one is installed; otherwise curlite's own `syntax/http.vim` runs — `:h curlite-highlights-http` lists every group it defines.

</details>

<details>
<summary><b>Completion, lualine</b></summary>

Completion works out of the box: every `.http` buffer gets `omnifunc`, and after `{{` the menu opens by itself. With a completion engine, register the matching source instead — it is the same items either way.

blink.cmp:

```lua
require("blink.cmp").setup({
  sources = {
    providers = { curlite = { module = "curlite.blink", name = "curlite" } },
    per_filetype = { http = { "curlite", "path", "buffer" } },
  },
})
```

nvim-cmp — the source registers itself, so it only needs naming:

```lua
require("cmp").setup.filetype("http", {
  sources = { { name = "curlite" }, { name = "buffer" } },
})
```

Inside `{{` you get the document's `@variables`, the shared block, the selected environment's variables (each with its value and where it came from), nested paths like `auth.clientId`, script globals, prompt answers, the `{{$...}}` functions and the named requests you can chain from. Only what would actually resolve is offered: an environment you have not selected does not appear.

Accepting a variable writes the whole `{{name}}` — the menu lists bare names, but the braces come with it, and whatever `{{...}}` the cursor is in is replaced:

```
GET {{ho        ->  GET {{host}}
GET {{auth.cl   ->  GET {{auth.client_id}}
GET {{$uu       ->  GET {{$uuid}}
GET {{}}        ->  GET {{host}}     (an autopaired pair is reused, not doubled)
GET {{host}}    ->  GET {{token}}    (re-completing replaces all of it)
```

```lua
require("lualine").setup({ sections = { lualine_x = { "curlite" } } })
```

The lualine component shows the active environment — or `no env` while none is selected, which is the state worth seeing — and the last response. `require("curlite").current_env()` is the building block for any other statusline.

</details>

<details>
<summary><b>Coming from kulala</b></summary>

The file format is identical, so your `.http` files and `http-client.env.json` work unchanged. What's different:

| | |
| --- | --- |
| **scripts** | Lua, not JavaScript. `client.global.set`, `client.test`, `request.skip` and `request.abort` keep their names; the bodies are Lua. |
| **no backend** | no companion binary, no tree-sitter CLI, no download on install. `curl` is the only requirement. |
| **protocols** | HTTP and GraphQL. No gRPC, WebSocket or streaming. |
| **OAuth2** | no built-in flow — chain a token request instead. |
| **OpenAPI explorer** | not included. |
| **filtering** | a jq expression over the body (`gq` in the response window), or `gi` for the body in a scratch tab to run `:%!jq` over yourself. |
| **environments** | nothing is selected until you pick. Opening a file starts with none, and the first send opens the picker rather than reusing yesterday's choice. |

Environments, the shared block, dynamic variables, request chaining, prompts, assertions, `>>` redirects, `< file` bodies, multipart and the scratchpad all behave the same way.

</details>

## API

Run requests from Lua with no UI at all — handy in a keymap, timer or autocommand:

```lua
-- Async: your callback runs on the main loop.
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

## Configuration

`setup()` deep-merges over the defaults, so pass only what you want changed. Common ones:

```lua
require("curlite").setup({
  ui = {
    display = "right",      -- right | left | below | above | float | tab
    width   = 0.5,          -- half the editor; >= 1 is an absolute column count
    focus   = false,        -- keep the cursor in the request buffer
    cursorline = false,     -- no cursor-line bar in the response window
  },
  format = {
    bodies  = true,         -- re-indent JSON bodies on `:Curlite format`
    on_save = false,        -- format automatically before `:w`
  },
  curl = {
    timeout    = 30000,     -- ms; `# @timeout` wins
    verify_ssl = true,
  },
  response = { format = true },
  notify = {
    level  = "warn",        -- the floor for ordinary messages
    events = { env_selected = false },  -- silence one message by name
  },
})
```

<details>
<summary>All options &amp; defaults</summary>

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
    default_headers = { ["User-Agent"] = "curlite.nvim" },  -- env `$default_headers` wins
    infer_content_type = true,             -- JSON-looking body -> application/json
    substitute_in_response = false,        -- expand {{...}} in the response too
  },

  ui = {
    display = "right",                     -- right|left|below|above|float|tab
    width = 0.5,                           -- fraction or columns, left/right
    height = 0.5,                          -- fraction or rows, above/below
    float = { width = 0.8, height = 0.8, border = "rounded" },
    picker = {                             -- the environment picker
      backend = "auto",                    -- telescope when installed, else built-in
      telescope = {},                      -- passed to telescope's picker
      width = 0.8, height = 0.7,           -- fractions of the editor
      list_width = 0.3,                    -- the rest previews the variables
      border = "rounded",
      preview = true,                      -- false = a plain list of names
    },
    default_pane = "body",
    panes = { "body", "headers", "all", "stats", "verbose", "script" },
    winbar = true,                         -- the pane tabs and status line
    focus = false,                         -- keep the cursor in the request buffer
    wrap = false,
    number = false,
    cursorline = false,
    inline_status = true,                  -- ` 200 OK` on the request line
    inline = {
      icon = true, status = true,
      time = false, size = false, tests = false,
    },
    flash = true,                          -- briefly mark the request being sent
    flash_timeout = 1500,
    flash_scope = "request",              -- request | line
    icons = {
      success  = "",
      error    = "",
      running  = "",
      redirect = "",
    },
    highlights = {                         -- see "Highlights" above
      success      = "DiagnosticOk",
      redirect     = "DiagnosticInfo",
      client_error = "DiagnosticWarn",
      server_error = "DiagnosticError",
      running      = "Comment",
      inline       = "Comment",
    },
  },

  format = {
    bodies = true,                         -- re-indent JSON request bodies
    indent = 2,
    on_save = false,
  },

  highlight = {
    enable = true,
    line_bar = "none",                    -- none | separator | all
    line_bar_group = "CursorLine",
    methods = {
      dark = {
        GET = "#a6e3a1", POST = "#89b4fa", PUT = "#fab387",
        PATCH = "#f9e2af", DELETE = "#f38ba8", HEAD = "#94e2d5",
        OPTIONS = "#94e2d5", QUERY = "#cba6f7", GRAPHQL = "#cba6f7",
        TRACE = "#bac2de", CONNECT = "#bac2de", default = "#cdd6f4",
      },
      light = {
        GET = "#40a02b", POST = "#1e66f5", PUT = "#fe640b",
        PATCH = "#df8e1d", DELETE = "#d20f39", HEAD = "#179299",
        OPTIONS = "#179299", QUERY = "#8839ef", GRAPHQL = "#8839ef",
        TRACE = "#6c6f85", CONNECT = "#6c6f85", default = "#4c4f69",
      },
    },
    method_style = { bold = true, italic = false },
    url = { dark = "#89dceb", light = "#04a5e5", underline = true },
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
    default = nil,                         -- nil = none, until you pick one
    require_selection = true,              -- a send with none selected opens the picker
    shared_key = { "$curliteshared", "$shared" },
    headers_key = { "$default_headers", "$defaultHeaders" },  -- per-project default headers
  },

  completion = {
    enable = true,                         -- set `omnifunc` on http buffers
    auto_trigger = true,                   -- open the menu after `{{` (no engine loaded)
    cmp = true,                            -- register the nvim-cmp source when cmp is there
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
    send_enter   = "<CR>",
    send_all     = "<leader>Ra",
    replay       = "<leader>Rr",
    toggle       = "<leader>Ro",
    select_env   = "<leader>Re",
    pick_request = "<leader>Rf",
    copy_curl    = "<leader>Rc",
    paste_curl   = "<leader>RC",
    inspect      = "<leader>Ri",
    hover        = "K",
    clear        = "<leader>Rx",
    next_request = "<leader>Rn",
    prev_request = "<leader>Rp",
    format       = "<leader>f",
  },

  -- Inside the response window. Same rules.
  result_keymaps = {
    close           = "q",
    next_pane       = "<C-l>",
    prev_pane       = "<C-h>",
    show_body       = "B",
    show_headers    = "H",
    show_all        = "A",
    show_stats      = "S",
    show_verbose    = "T",   -- `V` is left to linewise Visual mode
    show_script     = "O",
    next_history    = "]",
    prev_history    = "[",
    jump_to_request = "gd",
    yank_body       = "Y",
    save_body       = "gs",
    filter          = "gq",  -- `/` is left to Vim's own search
    refresh         = "R",
    scratch         = "gi",  -- the body in its own tab, to filter by hand
    toggle          = "<leader>Ro",
  },

  -- Which vim.notify messages get through. Every message curlite shows is
  -- tagged with an event name, so you silence one by name rather than
  -- turning the plugin quiet. `:Curlite events` lists them.
  notify = {
    enabled = true,                        -- master switch; false hides errors too
    level = "warn",                        -- floor for ordinary events
    events = {                             -- false | true | a per-event level
      -- request_sent = true,              -- "GET https://..." as it goes out
      -- request_done = "warn",            -- 4xx/5xx only; 200s stay quiet
      -- env_selected = false,             -- stop announcing the environment
    },
    filter = nil,                          -- function(ev) -> boolean|nil, last word
    backend = nil,                         -- function(msg, level, opts) -> fidget, ...
    title = "curlite",
  },
  debug = false,                           -- log commands to stdpath("log")
})
```

</details>

Every field is documented inline in [`lua/curlite/config.lua`](lua/curlite/config.lua), and in full at `:help curlite-configuration`.

## Development

```sh
tests/run.sh              # the whole suite
tests/run.sh parser       # just the ones matching "parser"
```

`tests/run.sh` starts a local echo server (`tests/server.py`) for the end-to-end tests and stops it on exit. Without `python3` those skip and the rest still run.

## License

[MIT](LICENSE) © 2026 Aaron Shahriari
