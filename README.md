# Mallorn

WebAssembly-based Tree-sitter bindings for Ruby, with incremental parsing,
UTF-8/UTF-16LE/UTF-16BE input, chunked source storage, tree navigation, and
queries.

## Quick start

This example uses `tree-sitter-javascript.wasm` from the
`tree-sitter-javascript` 0.25.0 package.

```ruby
require 'mallorn'

runtime = Mallorn::Runtime.new
begin
  javascript = runtime.load_language('tree-sitter-javascript.wasm', name: 'javascript')
  parser = Mallorn::Parser.new(language: javascript)
  tree = parser.parse('const answer = 42;')

  puts tree.root_node.to_sexp
  variable = tree.root_node.first_named_child.first_named_child
  puts variable.child_by_field_name('name').text # => answer

  query = javascript.query('(identifier) @name')
  cursor = query.cursor
  cursor.matches(tree.root_node).each do |match|
    match.captures.each { |capture| puts capture.node.text }
  end
ensure
  runtime.close
end
```

Syntax errors return a tree; inspect `Node#has_error?` to detect them. Source
input can be a String or a caller-owned stable revision exposing `encoding`
and `read_at(byte_offset, point:)`. Every byte offset and point column counts
bytes in the original encoding, including UTF-16.

Grammars must be self-contained wasm32 modules using `dylink.0` and language
ABI 13–15. Unsupported modules/imports raise `Mallorn::LinkError`; incompatible
language ABIs raise `Mallorn::IncompatibleLanguageError`.

Detailed usage, parameters, errors, and examples are documented with YARD in
[lib/mallorn.rb](lib/mallorn.rb), including incremental edits, included ranges,
chunked input, cursors, cancellation, and query predicates.

## License

Mallorn is released under the MIT License. See [LICENSE.txt](LICENSE.txt).

The published gem includes `tree-sitter.wasm`, a binary derived from Tree-sitter,
which is covered by the license in [tree-sitter/LICENSE](tree-sitter/LICENSE).
