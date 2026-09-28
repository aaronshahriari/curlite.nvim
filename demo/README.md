# demo

Open [`api.http`](api.http) and start pressing keys.

```
nvim demo/api.http
```

The file is in two halves.

**Part 1 — real public APIs.** Absolute URLs, no keys, no environment to pick.
Park the cursor on any request and hit `<leader>Rs`. Every one of these was
reachable when the file was written, and they're arranged to show off a
different thing as you work down:

| request | what it shows |
| --- | --- |
| `ZEN` | a `text/plain` body, left raw |
| `MY_IP` | the Stats pane — DNS, TLS, TTFB and download broken out |
| `NEOVIM_REPO` | a big nested document; press `/` and try `.stargazers_count` |
| `WEATHER` | a query string split one parameter per line |
| `CREATE_POST` | a JSON `POST` returning `201` |
| `ECHO_FORM` | a `&`-per-line form body, echoed back as one line |
| `LOGIN` → `WHOAMI` | a real JWT captured by a script, then reused |
| `CHAINED_NO_SCRIPT` | the same chain with no script — `{{LOGIN.response.body.$.id}}` |
| `WHOAMI_NO_CREDENTIALS` | `401`, and why `# @no-cookie-jar` is needed to get it |
| `GRAPHQL_RICK` | a GraphQL query with variables |
| `XML_RESPONSE` `HTML_RESPONSE` `PLAIN_TEXT` | non-JSON bodies |
| `BINARY_RESPONSE` | a PNG — detected, not dumped into the buffer |
| `REDIRECTS` | three hops, each listed in the Headers pane |
| `BASIC_AUTH` | `Basic user pass` becoming `--user` |
| `NOT_FOUND` | a deliberate `404` and a deliberately failing assertion |
| `TIMEOUT` | a deliberate `# @timeout` |

**Part 2 — the format, feature by feature.** These run against whatever the
environment points at, so press `<leader>Re` and pick `dev` (httpbin.org)
first. Prompts, multipart, `>>` redirects, `# @skip`, and a reference card of
every dynamic variable.

## Keys

| key | |
| --- | --- |
| `<leader>Rs` | send the request under the cursor |
| `<leader>Ra` | send every request in the file |
| `<leader>Rr` | replay the last one |
| `<leader>Re` | switch environment |
| `<leader>Ri` | show the resolved request + its curl equivalent |
| `<leader>Rc` | yank a shareable cURL command (`### NAME` included) |
| `<leader>Rf` | jump to a request by name |
| `<leader>Rn` `<leader>Rp` | next / previous request |

In the response window: `B`/`H`/`A`/`S`/`V`/`O` select panes, `[`/`]` walk the
history, `/` filters a JSON body with jq, `gd` jumps back to the request, `Y`
yanks the body, `gs` saves it, `R` re-sends, `q` closes.

## Environment files

`http-client.env.json` defines `dev` and `local`. Copy
`http-client.private.env.json.example` to `http-client.private.env.json` for
anything secret — that filename is gitignored, and its values are merged over
the public file.
