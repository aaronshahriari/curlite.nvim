" Response headers pane. Most of the colouring is done with extmarks by
" curlite itself; this only covers what extmarks can't reach cheaply.
if exists('b:current_syntax')
  finish
endif

" The `all` pane appends the response body after the headers. Give a JSON or
" XML body real highlighting; the `headers` pane has no such block, so nothing
" here matches there.
syn include @curliteJson syntax/json.vim
unlet! b:current_syntax

syn region curliteBody start="^\s*\ze[{[]" end="\%$" keepend contains=@curliteJson
syn match curliteXmlBody "^\s*<[^>]\+>.*$"

syn match curliteStatusLine "^HTTP/[0-9.]\+\s\+\d\{3\}.*$"
syn match curliteRule       "^─\+$"
syn match curliteMethodLine "^\<\%(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\|TRACE\|CONNECT\|QUERY\|GRAPHQL\)\>.*$"

hi def link curliteStatusLine Title
hi def link curliteRule       Comment
hi def link curliteMethodLine Keyword
hi def link curliteXmlBody    Tag

let b:current_syntax = 'curlite_headers'
