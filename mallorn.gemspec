require_relative 'lib/mallorn'

Gem::Specification.new do |spec|
  spec.name = 'mallorn'
  spec.version = Mallorn::VERSION
  spec.authors = ['Kasumi Hanazuki']
  spec.email = ['kasumi@rollingapple.net']

  spec.summary = 'WebAssembly-based Tree-sitter bindings for Ruby'
  spec.description = 'Ruby bindings for a WebAssembly Tree-sitter engine and ' \
                     'grammars, with incremental parsing and chunked input.'
  spec.homepage = 'https://github.com/hanazuki/mallorn'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0'

  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*.rb', 'README.md', 'LICENSE.txt'].sort
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'wasmtime', '~> 50.0'

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }
end
