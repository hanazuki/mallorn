# Mallorn

WebAssembly-based Tree-sitter bindings for Ruby.

Mallorn is currently an API draft. Parsing and Wasm loading are not implemented;
unfinished methods use `fail 'TODO'`.

The planned API supports incremental parsing, UTF-8/UTF-16LE/UTF-16BE input,
caller-owned chunked storage, tree navigation, and queries. Source storage and
revision management belong to the consumer.

## Requirements

Ruby 4.0 or later.

## Development

```sh
bundle install
bundle exec rake
```

Run RSpec directly with `bundle exec rspec`.

Build the gem into `pkg/`:

```sh
bundle exec rake build
```

The Tree-sitter source is tracked as a submodule. For future backend development,
initialize it with `git submodule update --init --recursive`. The current Ruby
API draft and test suite do not require a Wasm toolchain.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
