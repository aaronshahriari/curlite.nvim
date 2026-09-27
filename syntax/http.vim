" Vim syntax file for .http / .rest request files (JetBrains format).
"
" curlite ships this so the plugin works with no treesitter parser installed.
" If a treesitter highlighter is already active on the buffer (kulala's
" `kulala_http` parser, or any other), this file gets out of the way.

if exists('b:current_syntax')
  finish
endif

if luaeval('vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil')
  finish
endif

syn case match

" --- separators and comments ------------------------------------------------
syn match httpSeparator  "^###.*$"      contains=httpRequestName
syn match httpRequestName "\%(^###\s*\)\@<=.\+$" contained

syn match httpComment    "^\s*\%(#\|//\).*$" contains=httpMetadata,httpTodo
syn match httpMetadata   "@[[:alnum:]_-]\+" contained nextgroup=httpMetaValue
syn match httpMetaValue  ".*$"           contained
syn keyword httpTodo     TODO FIXME XXX NOTE contained

" --- variables --------------------------------------------------------------
syn match httpVariableDef "^@[[:alnum:]_.-]\+\ze\s*=" 
syn match httpAssign      "=" contained
syn region httpTemplate   start="{{" end="}}" oneline contains=httpDynamic
syn match httpDynamic     "\$[[:alnum:]_.]\+" contained

" --- the request line -------------------------------------------------------
syn match httpMethod  "^\s*\<\%(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\|TRACE\|CONNECT\|QUERY\|GRAPHQL\)\>"
      \ nextgroup=httpURL skipwhite
syn match httpURL     "\S\+" contained contains=httpTemplate nextgroup=httpVersion skipwhite
syn match httpVersion "HTTP/[0-9.]\+" contained
syn match httpURLCont "^\s\+[?&#]\S*$" contains=httpTemplate

" --- headers ----------------------------------------------------------------
syn match httpHeaderName  "^[A-Za-z][A-Za-z0-9._-]*\ze\s*:" nextgroup=httpHeaderSep
syn match httpHeaderSep   ":" contained nextgroup=httpHeaderValue
syn match httpHeaderValue ".*$" contained contains=httpTemplate

" --- scripts and redirection ------------------------------------------------
syn region httpScript matchgroup=httpScriptDelim start="^\s*[<>]\s*{%" end="%}" contains=@httpLua keepend
syn match  httpScriptFile "^\s*[<>]\s\+\%(\./\|/\|\~\)\S*$"
syn match  httpRedirect   "^\s*>>!\?\s\+\S.*$"
syn match  httpBodyFile   "^\s*<\s\+\S.*$"

" Lua inside `{% ... %}` blocks.
syn include @httpLua syntax/lua.vim
unlet! b:current_syntax

" --- bodies -----------------------------------------------------------------
" A JSON-looking body gets the real JSON syntax; anything else stays plain so
" a form body or GraphQL query isn't mis-coloured.
syn region httpJsonBody start="^\s*[{[]" end="^\s*[}\]]\s*$" keepend contains=@httpJson,httpTemplate fold
syn include @httpJson syntax/json.vim
unlet! b:current_syntax

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
