" Vim syntax file for .http / .rest request files (JetBrains format).
"
" curlite ships this so the plugin works with no treesitter parser installed.
" If a treesitter highlighter is already active on the buffer (kulala's
" `kulala_http` parser, or any other), this file gets out of the way.

if exists('b:current_syntax')
  finish
endif

" `highlighter.active` is internal, so reach for it defensively: if the field
" ever moves, fall through and highlight with this file rather than error out.
if luaeval('(function() local ok, r = pcall(function() return vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil end) return ok and r end)()')
  finish
endif

syn case match

" Embedded languages first: a `contains=@cluster` is only resolved once the
" cluster exists, and `syn include` clears b:current_syntax as a side effect.
syn include @httpLua syntax/lua.vim
unlet! b:current_syntax
syn include @httpJson syntax/json.vim
unlet! b:current_syntax

" --- variables --------------------------------------------------------------
" `containedin=ALL` so a `{{var}}` lights up wherever it appears: in a URL, a
" header value, or inside a JSON string in the body.
syn match httpVariableDef "^@[[:alnum:]_.-]\+\ze\s*="
syn region httpTemplate start="{{" end="}}" oneline containedin=ALL contains=httpDynamic
syn match httpDynamic "\$[[:alnum:]_.]\+" contained

" --- separators and comments ------------------------------------------------
syn match httpSeparator "^###.*$" contains=httpRequestName
syn match httpRequestName "\%(^###\s*\)\@<=.\+$" contained

" `###` is a separator, not a comment, and a `syn match` defined later wins at
" the same position -- hence the negative lookahead rather than relying on the
" order these two are defined in.
syn match httpComment "^\s*\%(###\)\@!\%(#\|//\).*$"
      \ contains=httpMetadata,httpTodo,httpTemplate
syn match httpMetadata "@[[:alnum:]_-]\+" contained nextgroup=httpMetaValue
syn match httpMetaValue ".*$" contained contains=httpTemplate
syn keyword httpTodo TODO FIXME XXX NOTE contained

" --- the request line -------------------------------------------------------
syn match httpMethod "^\s*\<\%(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\|TRACE\|CONNECT\|QUERY\|GRAPHQL\)\>"
      \ nextgroup=httpURL skipwhite
syn match httpURL "\S\+" contained contains=httpTemplate nextgroup=httpVersion skipwhite
syn match httpVersion "HTTP/[0-9.]\+" contained
syn match httpURLCont "^\s\+[?&#]\S*$" contains=httpTemplate

" --- headers ----------------------------------------------------------------
syn match httpHeaderName "^[A-Za-z][A-Za-z0-9._-]*\ze\s*:" nextgroup=httpHeaderSep
syn match httpHeaderSep ":" contained nextgroup=httpHeaderValue
syn match httpHeaderValue ".*$" contained contains=httpTemplate

" --- scripts and redirection ------------------------------------------------
syn region httpScript matchgroup=httpScriptDelim
      \ start="^\s*[<>]\s*{%" end="%}" keepend contains=@httpLua
syn match httpScriptFile "^\s*[<>]\s\+\%(\./\|\.\./\|/\|\~\)\S*$"
syn match httpRedirect "^\s*>>!\?\s\+\S.*$" contains=httpTemplate
syn match httpBodyFile "^\s*<\s\+\S.*$" contains=httpTemplate

" --- bodies -----------------------------------------------------------------
" A body that starts with `{` or `[` on its own line gets real JSON
" highlighting. The region runs to whatever ends the request -- the next
" separator, a metadata comment, a script block, or the end of the file --
" rather than to a closing brace, because a nested `}` at the start of a line
" would end it far too early.
syn region httpJsonBody
      \ start="^\s*\ze[{[]"
      \ end="^###"me=s-1
      \ end="^\s*\%(#\|//\)\s*@"me=s-1
      \ end="^\s*[<>]\s*\%({%\|\./\|/\)"me=s-1
      \ end="\%$"
      \ keepend contains=@httpJson,httpTemplate

syn match httpBoundary "^--[A-Za-z0-9._-]\+-\?-\?$"

" --- links ------------------------------------------------------------------
hi def link httpSeparator    PreProc
hi def link httpRequestName  Title
hi def link httpComment      Comment
hi def link httpTodo         Todo
hi def link httpMetadata     Special
hi def link httpMetaValue    Comment
hi def link httpVariableDef  Identifier
hi def link httpTemplate     Macro
hi def link httpDynamic      Function
hi def link httpMethod       Keyword
hi def link httpURL          Underlined
hi def link httpURLCont      Underlined
hi def link httpVersion      Constant
hi def link httpHeaderName   Identifier
hi def link httpHeaderSep    Delimiter
hi def link httpHeaderValue  String
hi def link httpScriptDelim  PreProc
hi def link httpScriptFile   Include
hi def link httpRedirect     Statement
hi def link httpBodyFile     Include
hi def link httpBoundary     Delimiter

let b:current_syntax = 'http'
