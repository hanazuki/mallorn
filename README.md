# Mallorn

WebAssembly-based Tree-sitter bindings for Ruby.

Mallorn is under development. Runtime initialization and Wasm grammar linking
are implemented; the public parsing, node, and query APIs remain drafts.
Unfinished methods use `fail 'TODO'`.

The planned API supports incremental parsing, UTF-8/UTF-16LE/UTF-16BE input,
caller-owned chunked storage, tree navigation, and queries. Source storage and
revision management belong to the consumer.

## Requirements

Ruby 4.0 or later.

## Development

```sh
bundle install
npm ci --ignore-scripts
bundle exec rake
```

Run RSpec directly with `bundle exec rspec`.

The npm development dependency pins `tree-sitter-javascript` to 0.25.0 for its
published `node_modules/tree-sitter-javascript/tree-sitter-javascript.wasm`
grammar. Native Node binding installation scripts are unnecessary for Wasm
tests and are skipped by `--ignore-scripts`.

Build the gem into `pkg/`:

```sh
bundle exec rake build
```

This compiles and includes `tree-sitter.wasm` in the gem. Building the gem requires
WASI SDK as described below; installing the built gem does not.

## Building Tree-sitter

Install [WASI SDK](https://github.com/WebAssembly/wasi-sdk/releases) (tested with
34), then initialize the Tree-sitter submodule and build:

```sh
git submodule update --init tree-sitter
export WASI_SDK_PATH=/path/to/wasi-sdk
bundle exec rake tree-sitter
```

This generates `tree-sitter.wasm` at the repository root. Subsequent invocations
rebuild when the C sources, headers, or Rakefile change. Run `bundle exec rake
clean` to remove the output, including when changing SDK versions.

The engine is a wasm32 WASI Preview 1 reactor, with `_initialize`, exported
memory and a growable function table. Mallorn's entrypoints are defined in
`src/main.c` against Tree-sitter's public C API. No Web binding code or
Emscripten JavaScript runtime is used. Initialize WASI and call `_initialize`
once before using the module in Wasmtime.

The initial exports cover allocation, parser lifecycle, contiguous input in
all three encodings, and tree reuse/editing. Chunked input callbacks are not
implemented yet.

## Loading grammars

```ruby
require 'mallorn'

runtime = Mallorn::Runtime.new
begin
  javascript = runtime.load_language(
    'node_modules/tree-sitter-javascript/tree-sitter-javascript.wasm',
    name: 'javascript'
  )
  javascript.abi_version # => 15
  javascript.metadata # => { major_version: 0, minor_version: 25, patch_version: 0 }
ensure
  runtime.close
end
```

`Runtime#load_language_bytes(bytes, name:)` accepts a Wasm binary directly.
The name identifies the module's `tree_sitter_<name>` export.

The linker in `lib/mallorn/wasm_linker.rb` supports self-contained wasm32
`dylink.0` modules. It allocates separate data and function-table regions for
each load, shares the engine's stack pointer, applies data relocations, runs
initializers, and checks the grammar ABI. Loading and engine access are serialized
within each runtime. Loaded modules remain resident until the runtime is closed
or garbage-collected.

Current scanner imports are `env.iswspace`, `env.iswalpha`, `env.malloc`,
`env.calloc`, and `env.free`, implemented by the engine's WASI libc. Other
imports, dependencies on additional shared modules, and legacy `dylink` modules
are rejected with `Mallorn::LinkError`. Incompatible grammar ABIs raise
`Mallorn::IncompatibleLanguageError`. The pinned JavaScript grammar is tested
through the engine, including its external scanner, in all three encodings.

The RSpec suite builds and instantiates the module, so it also requires
`WASI_SDK_PATH`. Grammar linking specs also require the npm dependency.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
