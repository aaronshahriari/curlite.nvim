--- Completion for `.http` buffers.
---
--- One source of items, three ways to reach them:
---
---   * `curlite.blink`  -- a blink.cmp source
---   * `curlite.cmp`    -- an nvim-cmp source, registered for you
---   * `M.omnifunc`     -- Neovim's own `<C-x><C-o>`, set on every http
---                         buffer, and popped open by itself after `{{`
---                         when no completion engine is loaded
---
--- What is offered depends on where the cursor sits:
---
---   * inside an unclosed `{{` -- document variables, the shared variables,
---     the selected environment's variables, script globals, prompt answers,
---     the `{{$...}}` functions, and the named requests you can chain from
---   * the start of a line -- request methods and header names
---   * after `Header:` -- plausible values for the common headers
---   * after `# @` -- metadata keys

local M = {}

--- LSP `CompletionItemKind`, for the engines that want numbers.
M.KIND = {
  Text = 1,
  Method = 2,
  Function = 3,
  Field = 5,
  Variable = 6,
  Keyword = 14,
  EnumMember = 20,
  Constant = 21,
}

M.METHODS = {
  "GET",
  "POST",
  "PUT",
  "PATCH",
  "DELETE",
  "HEAD",
  "OPTIONS",
  "TRACE",
  "CONNECT",
  "QUERY",
  "GRAPHQL",
}

M.HEADERS = {
  "Accept",
  "Accept-Encoding",
  "Accept-Language",
  "Authorization",
  "Cache-Control",
  "Connection",
  "Content-Disposition",
  "Content-Encoding",
  "Content-Length",
  "Content-Type",
  "Cookie",
  "ETag",
  "Expect",
  "Host",
  "If-Match",
  "If-Modified-Since",
  "If-None-Match",
  "Origin",
  "Prefer",
  "Range",
  "Referer",
  "User-Agent",
  "X-API-Key",
  "X-Correlation-ID",
  "X-Request-ID",
  "X-REQUEST-TYPE",
}

M.HEADER_VALUES = {
  ["accept"] = {
    "application/json",
    "application/xml",
    "application/problem+json",
    "text/plain",
    "text/html",
    "*/*",
  },
  ["content-type"] = {
    "application/json",
    "application/x-www-form-urlencoded",
    "multipart/form-data; boundary=CurliteBoundary",
    "application/xml",
    "application/graphql",
    "text/plain",
    "application/octet-stream",
  },
  ["authorization"] = {
    "Bearer {{token}}",
    "Basic {{user}} {{password}}",
    "Digest {{user}} {{password}}",
    "NTLM {{user}} {{password}}",
    "AWS {{key}} {{secret}} us-east-1 execute-api",
  },
  ["accept-encoding"] = { "gzip", "gzip, deflate, br", "identity" },
  ["cache-control"] = { "no-cache", "no-store", "max-age=0" },
  ["connection"] = { "keep-alive", "close" },
  ["x-request-type"] = { "GraphQL" },
  ["prefer"] = { "respond-async", "return=representation", "return=minimal" },
}

-- `# @key` metadata, with what each one does.
M.METADATA = {
  { "name", "name this request, so `{{name.response...}}` can reference it" },
  { "prompt", "ask for a value before sending: `# @prompt token Paste the token`" },
  { "assert", "check the response: `# @assert status == 200`" },
  { "run", "send another named request first: `# @run LOGIN`" },
  { "import", "make another file's named requests available: `# @import ./auth.http`" },
  { "accept", "shorthand for the Accept header" },
  { "timeout", "milliseconds before the request is abandoned" },
  { "delay", "milliseconds to wait before sending" },
  { "insecure", "skip TLS certificate verification" },
  { "no-redirect", "do not follow redirects" },
  { "max-redirs", "maximum redirects to follow" },
  { "compressed", "ask for and decode a compressed response" },
  { "http2", "force HTTP/2" },
  { "http1.1", "force HTTP/1.1" },
  { "http3", "force HTTP/3" },
  { "proxy", "send through this proxy" },
  { "unix-socket", "connect over a unix socket instead of TCP" },
  { "cert", "client certificate path" },
  { "key", "client key path" },
  { "cacert", "CA bundle path" },
  { "resolve", "pin a host to an address: `host:port:addr`" },
  { "interface", "bind to this network interface" },
  { "retry", "retry this many times on a transient failure" },
  { "user", "credentials for curl's --user" },
  { "graphql", "treat the body as a GraphQL query" },
  { "confirm", "show the resolved request and require confirmation" },
  { "skip", "never send this request" },
  { "no-cookie-jar", "don't read or write the shared cookie jar" },
  { "curl", "raw curl flags, appended verbatim" },
}

-- The dynamic `{{$...}}` functions, with a hint of what each returns.
M.DYNAMIC = {
  { "$uuid", "a random v4 UUID" },
  { "$guid", "a random v4 UUID" },
  { "$timestamp", "seconds since the epoch; `$timestamp -1 d` shifts it" },
  { "$isoTimestamp", "ISO-8601 UTC, e.g. 2026-09-27T12:00:00Z" },
  { "$datetime iso8601", "ISO-8601; also `rfc1123`, `unix`, or a strftime format" },
  { "$localDatetime iso8601", "the same, in local time" },
  { "$date", "today, or `$date %d/%m/%Y`" },
  { "$time", "now, or `$time %H:%M`" },
  { "$randomInt 1 100", "an integer in a range" },
  { "$randomAlphaNumeric 16", "a random alphanumeric string" },
  { "$randomHex 16", "a random hex string" },
  { "$randomEmail", "a random example.com address" },
  { "$randomFullName", "a random name" },
  { "$random.integer(1, 100)", "IntelliJ spelling of a random integer" },
  { "$random.uuid", "IntelliJ spelling of a random UUID" },
  { "$env.NAME", "a process environment variable" },
  { "$processEnv NAME", "a process environment variable" },
  { "$dotenv NAME", "a value from the nearest .env file" },
  { "$exec command", "stdout of a shell command, e.g. `$exec pass show api/token`" },
}

--- ------------------------------------------------------------------ items

---@param label string
---@param kind integer
---@param detail string|nil
---@param insert string|nil
---@param doc string|nil
---@return table
local function item(label, kind, detail, insert, doc)
  return {
    label = label,
    kind = kind,
    detail = detail,
    documentation = doc,
    insertText = insert or label,
    -- Keep our own ordering: methods before headers, variables before
    -- dynamic functions.
    sortText = label,
  }
end
M.item = item

--- A value as it should read in a one-line `detail`.
---@param value any
---@return string
local function preview(value)
  local text
  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    text = ok and encoded or vim.inspect(value)
  else
    text = tostring(value)
  end
  text = text:gsub("%s+", " ")
  if #text > 60 then
    text = text:sub(1, 57) .. "..."
  end
  return text
end
M.preview = preview

--- Walk a nested variable, emitting `auth`, `auth.client_id`, ... so the
--- dotted access `{{auth.client_id}}` supports is completable too.
---@param out table
---@param name string
---@param value any
---@param detail_for fun(value: any): string
---@param kind integer
---@param depth integer
local function flatten(out, name, value, detail_for, kind, depth)
  table.insert(out, item(name, kind, detail_for(value)))
  if type(value) ~= "table" or depth <= 0 or vim.islist(value) then
    return
  end
  for key, nested in pairs(value) do
    if type(key) == "string" then
      flatten(out, ("%s.%s"):format(name, key), nested, detail_for, kind, depth - 1)
    end
  end
end

--- Everything that could go inside `{{ }}` at this point in `bufnr`.
---
--- Built lowest-precedence-first (functions, shared, environment, document,
--- prompts, globals) and then deduplicated keeping the last entry for a name,
--- so a name defined in two places is described by the one that would actually
--- win at send time.
---@param bufnr integer|nil
---@return table[]
function M.variable_items(bufnr)
  bufnr = bufnr or 0
  local items = {}
  local env = require("curlite.env")
  local variables = require("curlite.variables")

  local source_path = vim.api.nvim_buf_get_name(bufnr)

  for _, spec in ipairs(M.DYNAMIC) do
    table.insert(items, item(spec[1], M.KIND.Function, spec[2]))
  end

  -- Environment variables, labelled with where each one comes from: the
  -- shared block is always in play, the selected environment only once you
  -- have chosen one. With no environment selected you get the shared
  -- variables alone -- which is exactly what a request would resolve.
  local all = env.load(source_path)
  local selected = env.current(source_path)
  local shared_label = env.shared_keys()[1]

  for name, value in pairs(env.shared(source_path, all)) do
    flatten(items, name, value, function(v)
      return ("%s: %s"):format(shared_label, preview(v))
    end, M.KIND.Constant, 2)
  end

  if selected and type(all[selected]) == "table" then
    for name, value in pairs(all[selected]) do
      -- `$default_headers` is a directive, not a variable: it is read as
      -- headers and would resolve to nothing inside `{{ }}`.
      if not env.is_reserved(name) then
        flatten(items, name, value, function(v)
          return ("%s: %s"):format(selected, preview(v))
        end, M.KIND.Constant, 2)
      end
    end
  end

  local ok, doc = pcall(require("curlite.parser").parse_buffer, bufnr)
  if ok then
    for name, value in pairs(doc.variables) do
      table.insert(items, item(name, M.KIND.Variable, ("= %s"):format(preview(value))))
    end
    -- Named requests, offered as a chain reference rather than a bare name,
    -- because the name alone is never what you want inside `{{ }}`.
    for _, req in ipairs(doc.requests) do
      if req.name and req.name ~= "" then
        table.insert(
          items,
          item(
            ("%s.response.body.$."):format(req.name),
            M.KIND.Field,
            ("%s %s"):format(req.method, req.url)
          )
        )
        table.insert(
          items,
          item(("%s.response.status"):format(req.name), M.KIND.Field, "that request's status code")
        )
        table.insert(
          items,
          item(
            ("%s.response.headers."):format(req.name),
            M.KIND.Field,
            "that request's response headers"
          )
        )
      end
    end
  end

  for name in pairs(variables.prompt_answers) do
    table.insert(items, item(name, M.KIND.Variable, "prompt answer"))
  end

  for name, value in pairs(env.globals) do
    table.insert(items, item(name, M.KIND.Variable, ("script global: %s"):format(preview(value))))
  end

  local seen, deduped = {}, {}
  for idx = #items, 1, -1 do
    local entry = items[idx]
    if not seen[entry.label] then
      seen[entry.label] = true
      table.insert(deduped, 1, entry)
    end
  end
  return deduped
end

--- A variable completes to the whole `{{name}}`, braces included.
---
--- Inserting the bare name leaves you with `{{host` and two braces to close by
--- hand, which is what makes completion inside `{{` feel broken. Each item
--- carries the text to insert and the exact range to replace; the blink and
--- cmp adapters turn that into a `textEdit`, and `omnifunc` reads it directly.
---
--- `label` stays the bare name so the menu reads as a list of variables and so
--- an engine's own filtering has something sensible to match against.
---@param items table[]
---@param ctx table
---@return table[]
function M.wrap_variables(items, ctx)
  for _, entry in ipairs(items) do
    local label = entry.label
    -- A path still being written -- `LOGIN.response.body.$.` -- keeps the
    -- cursor between the braces so you can go on typing it. A finished name
    -- puts the cursor after them, ready for whatever comes next.
    local open_ended = label:sub(-1) == "."
    entry.insertText = ("{{%s}}"):format(label)
    entry.filterText = label
    entry.curlite = {
      start = ctx.replace_start,
      stop = ctx.replace_end,
      -- Bytes to step back from the end of the inserted text.
      back = open_ended and 2 or 0,
    }
  end
  return items
end

--- ---------------------------------------------------------------- context

--- What is being completed at `col` (a 0-based byte offset) on `line`.
---
--- For a variable, `replace_start`/`replace_end` span the whole `{{...}}` and
--- not just the name: a completion engine left to guess the range on its own
--- stops at `$` and `.` (blink's keyword for `{{auth.cl` is `cl`), so
--- accepting `auth.client_id` would write `{{auth.auth.client_id`. Naming the
--- range outright is what lets the item be inserted with its braces.
---
---@param line string
---@param col integer  bytes before the cursor
---@return { kind: string, prefix: string, start: integer, replace_start: integer, replace_end: integer }|nil
---        columns are 0-based byte offsets; `replace_end` is exclusive.
function M.context(line, col)
  local before = line:sub(1, col)

  -- Inside an unclosed `{{`. The prefix may hold dots (`auth.client_id`),
  -- `$` (`$uuid`) and `-`, all of which are part of a name here.
  local open = before:match(".*()%{%{")
  if open then
    local inner = before:sub(open + 2)
    if not inner:find("}}", 1, true) then
      local prefix = inner:match("[%w_%.%$%-]*$") or ""
      -- Absorb a closing brace pair sitting right after the cursor, so
      -- re-completing inside a finished `{{host}}` -- or completing into the
      -- `{{}}` an autopair plugin just made -- replaces it instead of
      -- leaving `{{token}}}}` behind.
      local after = line:sub(col + 1)
      local trailing = #(after:match("^}}") or after:match("^}") or "")
      return {
        kind = "variable",
        prefix = prefix,
        start = col - #prefix,
        replace_start = open - 1,
        replace_end = col + trailing,
      }
    end
  end

  -- `# @` metadata.
  local meta = before:match("^%s*[#/][#/]?%s*@([%w%-%.]*)$")
  if meta then
    return { kind = "metadata", prefix = meta, start = col - #meta }
  end

  -- After `Header: `, the values worth offering for that header.
  local header, value = before:match("^([%w%-]+)%s*:%s*([^;]*)$")
  if header and M.HEADER_VALUES[header:lower()] then
    return { kind = "header_value", prefix = value, start = col - #value, header = header }
  end

  -- At the start of a line: methods and header names.
  local word = before:match("^%s*(%a*)$")
  if word then
    return { kind = "line_start", prefix = word, start = col - #word }
  end

  return nil
end

--- The items for a context, unfiltered.
---@param ctx table
---@param bufnr integer|nil
---@return table[]
function M.items(ctx, bufnr)
  local items = {}
  if not ctx then
    return items
  end

  if ctx.kind == "variable" then
    return M.wrap_variables(M.variable_items(bufnr), ctx)
  elseif ctx.kind == "metadata" then
    for _, spec in ipairs(M.METADATA) do
      table.insert(items, item(spec[1], M.KIND.Keyword, spec[2]))
    end
  elseif ctx.kind == "header_value" then
    for _, value in ipairs(M.HEADER_VALUES[ctx.header:lower()] or {}) do
      table.insert(items, item(value, M.KIND.EnumMember, ctx.header))
    end
  elseif ctx.kind == "line_start" then
    for _, method in ipairs(M.METHODS) do
      table.insert(items, item(method, M.KIND.Method, "request method", method .. " "))
    end
    for _, name in ipairs(M.HEADERS) do
      table.insert(items, item(name, M.KIND.Field, "header", name .. ": "))
    end
  end

  return items
end

--- The items for the cursor's position in `bufnr`, filtered by what has been
--- typed so far. Used by `omnifunc`; the engines filter for themselves.
---@param line string
---@param col integer
---@param bufnr integer|nil
---@return table[], table|nil
function M.at(line, col, bufnr)
  local ctx = M.context(line, col)
  local items = M.items(ctx, bufnr)
  if not ctx or ctx.prefix == "" then
    return items, ctx
  end

  local prefix = ctx.prefix:lower()
  local out = {}
  for _, entry in ipairs(items) do
    if entry.label:lower():sub(1, #prefix) == prefix then
      table.insert(out, entry)
    end
  end
  return out, ctx
end

--- --------------------------------------------------------------- omnifunc

-- Bytes of `}}` sitting after the cursor that the pending omni completion is
-- meant to replace. Vim only ever replaces up to the cursor, so the rest is
-- cleaned up on `CompleteDone`.
local pending_trailing = 0

--- `omnifunc` implementation: `setlocal omnifunc=v:lua.require'curlite.complete'.omnifunc`
---@param findstart integer
---@param base string
---@return any
function M.omnifunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  if findstart == 1 then
    local ctx = M.context(line, col)
    if not ctx then
      -- -3 keeps the menu from opening at all where nothing applies.
      pending_trailing = 0
      return -3
    end
    -- A variable is replaced from its `{{`, because that is what the item
    -- rewrites. Everything else starts where the word does.
    if ctx.kind == "variable" then
      pending_trailing = ctx.replace_end - col
      return ctx.replace_start
    end
    pending_trailing = 0
    return ctx.start
  end

  -- Where the cursor sits for the second call is not something to rely on:
  -- Vim leaves it after the typed text, and a caller driving this by hand may
  -- have it at the start column instead. Both readings are tried, and `base`
  -- does the filtering either way.
  local ctx = M.context(line, col) or M.context(line, col + #base)
  -- For a variable, `base` starts at the `{{` because that is where
  -- `findstart` pointed; the names to match it against do not.
  local needle = (base:gsub("^{{", "")):lower()

  local out = {}
  for _, entry in ipairs(M.items(ctx, 0)) do
    if needle == "" or entry.label:lower():sub(1, #needle) == needle then
      table.insert(out, {
        word = entry.insertText or entry.label,
        abbr = entry.label,
        menu = entry.detail or "",
        icase = 1,
        -- Everything here is a single completion; re-scanning the buffer for
        -- the same word would only duplicate it.
        dup = 0,
        user_data = entry.curlite and vim.json.encode(entry.curlite) or nil,
      })
    end
  end
  return out
end

--- Tidy up after an omni completion Vim could only half-apply: drop the `}}`
--- the inserted item already carries, and step back inside the braces for a
--- path that is still being written.
function M.complete_done()
  local completed = vim.v.completed_item
  if type(completed) ~= "table" or not completed.word then
    return
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()

  if pending_trailing > 0 and line:sub(col + 1, col + pending_trailing):match("^}+$") then
    vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col + pending_trailing, { "" })
  end
  pending_trailing = 0

  local ok, data = pcall(vim.json.decode, completed.user_data or "")
  if ok and type(data) == "table" and (data.back or 0) > 0 then
    vim.api.nvim_win_set_cursor(0, { row, math.max(col - data.back, 0) })
  end
end

--- ----------------------------------------------------------------- attach

--- Is a completion engine going to drive this buffer itself?
---@return boolean
local function engine_loaded()
  return package.loaded["blink.cmp"] ~= nil or package.loaded["cmp"] ~= nil
end

-- Buffers whose `completeopt` we could not make non-intrusive; the auto
-- trigger stays out of the way there rather than inserting text under you.
local auto_ok = {}

--- Make `completeopt` safe to pop a menu open with mid-typing: the menu shows
--- but nothing is selected or inserted until you ask for it. Buffer-local
--- where Neovim allows it, so nothing outside `.http` changes.
---@param bufnr integer
---@return boolean
local function prepare_completeopt(bufnr)
  local wanted = { "menu", "menuone", "noselect", "noinsert" }
  local ok = pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      vim.opt_local.completeopt = wanted
    end)
  end)
  if ok then
    return true
  end
  -- Older Neovim: `completeopt` is global, and quietly rewriting it for the
  -- whole editor is not ours to do. Fall back to whatever the user has.
  local current = vim.o.completeopt
  return current:find("noselect") ~= nil or current:find("noinsert") ~= nil
end

--- Pop the omni menu open after `{{`, and keep it open as the name is typed.
---@param bufnr integer
local function auto_trigger(bufnr)
  if engine_loaded() or vim.fn.pumvisible() == 1 or vim.fn.mode() ~= "i" then
    return
  end
  if not auto_ok[bufnr] then
    return
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local ctx = M.context(line, col)
  -- Only the `{{` case fires by itself. Methods and headers would mean a menu
  -- opening on the first letter of every line, which is not help, it is noise.
  if not ctx or ctx.kind ~= "variable" then
    return
  end
  vim.api.nvim_feedkeys(vim.keycode("<C-x><C-o>"), "n", false)
end

--- Wire completion up for an http buffer. Called from `curlite.attach`.
---@param bufnr integer
function M.attach(bufnr)
  local cfg = require("curlite.config").get().completion or {}
  if cfg.enable == false then
    return
  end

  vim.bo[bufnr].omnifunc = "v:lua.require'curlite.complete'.omnifunc"

  if cfg.cmp ~= false and package.loaded["cmp"] then
    pcall(function()
      require("curlite.cmp").register()
    end)
  end

  local group = vim.api.nvim_create_augroup("curlite_complete_" .. bufnr, { clear = true })

  -- Registered whether or not the menu opens by itself: `<C-x><C-o>` by hand
  -- needs the same tidying up.
  vim.api.nvim_create_autocmd("CompleteDone", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.complete_done()
    end,
  })

  if cfg.auto_trigger == false or engine_loaded() then
    return
  end

  auto_ok[bufnr] = prepare_completeopt(bufnr)
  if not auto_ok[bufnr] then
    return
  end

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = bufnr,
    callback = function()
      auto_trigger(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      auto_ok[bufnr] = nil
    end,
  })
end

return M
