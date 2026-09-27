# demo

A tour of the `.http` format curlite reads. Every request in `api.http` runs
against [httpbin.org](https://httpbin.org), so you can open the file and start
sending.

```
nvim demo/api.http
```

| key | what it does |
| --- | --- |
| `<leader>Rs` | send the request under the cursor |
| `<leader>Ra` | send every request in the file |
| `<leader>Re` | switch environment (`dev` / `local`) |
| `<leader>Ri` | show the resolved request and its curl equivalent |
| `<leader>Rf` | jump to a request by name |
| `]r` / `[r` | next / previous request |

In the response window: `H`/`L` cycle panes, `1`..`6` jump to one, `[`/`]` page
through history, `/` filters a JSON body with jq, `gd` jumps back to the
request, `q` closes it.

`http-client.env.json` defines the environments. Copy
`http-client.private.env.json.example` to `http-client.private.env.json` for
anything secret — that filename is gitignored, and its values are merged over
the public file.
