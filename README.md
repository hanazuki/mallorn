# Mallorn

WebAssembly-based Tree-sitter bindings for Ruby, with incremental parsing, chunked source storage, tree navigation, and queries.

## Quick start

This example uses prebuilt `tree-sitter-javascript.wasm` from the `tree-sitter-javascript` npm package.

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

## License

Mallorn is released under the MIT License. See [LICENSE.txt](LICENSE.txt).

The published gem includes `tree-sitter.wasm`, a binary derived from Tree-sitter, which is licensed under MIT License. It also links other third-party libraries covered by OSS licesnse. See [third-party notices](licenses/README.md).
