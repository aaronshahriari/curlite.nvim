" curl's --verbose trace.
if exists('b:current_syntax')
  finish
endif

syn match curliteVerbInfo   "^\*.*$"
syn match curliteVerbSent   "^>.*$"
syn match curliteVerbRecv   "^<.*$"
syn match curliteVerbHeader "^[<>]\s\zs[A-Za-z][A-Za-z0-9-]*\ze:"
syn match curliteVerbTLS    "^\*\s\+\%(SSL\|TLS\|ALPN\|subject\|issuer\|certificate\).*$"
" curl marks body chunks it isn't printing, e.g. `{ [12 bytes data]`.
syn match curliteVerbChunk  "^[{}]\s\[\d\+ bytes data\]$"

hi def link curliteVerbInfo   Comment
hi def link curliteVerbSent   Function
hi def link curliteVerbRecv   String
hi def link curliteVerbHeader Identifier
hi def link curliteVerbTLS    Special
hi def link curliteVerbChunk  NonText

let b:current_syntax = 'curlite_verbose'
