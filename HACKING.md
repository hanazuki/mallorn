# Developing Mallorn

## Development setup

Install [WASI SDK](https://github.com/WebAssembly/wasi-sdk/releases) (tested with
version 34), then:

```sh
git submodule update --init tree-sitter
export WASI_SDK_PATH=/path/to/wasi-sdk
bundle install
npm ci --ignore-scripts
bundle exec rake spec
```

## Design decisions

The input protocol serves consumers that own their source storage and revision
history, including editors using ropes or piece tables. Chunked reads allow
direct access to that storage. Coordinates use bytes in the original encoding
so edit positions correspond directly to the consumer's buffer, including UTF-16.

Capture enumeration trades memory and first-result latency for predicate
correctness. This Tree-sitter revision can expose unfinished quantified matches
through next_capture; a later capture can invalidate a predicate that appeared
to pass earlier. Waiting for completed matches avoids returning those premature
results. Match enumeration remains available when streaming matters more than
global capture order.
