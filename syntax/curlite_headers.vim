" Response headers pane. Most of the colouring is done with extmarks by
" curlite itself; this only covers what extmarks can't reach cheaply.
if exists('b:current_syntax')
  finish
endif

syn match curliteStatusLine "^HTTP/[0-9.]\+\s\+\d\{3\}.*$"
syn match curliteRule       "^─\+$"
syn match curliteMethodLine "^\<\%(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\|TRACE\|CONNECT\|QUERY\|GRAPHQL\)\>.*$"

hi def link curliteStatusLine Title
hi def link curliteRule       Comment
hi def link curliteMethodLine Keyword

let b:current_syntax = 'curlite_headers'
