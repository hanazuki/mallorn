require 'rspec/core/rake_task'
require 'rake/clean'
require 'open-uri'

root = Pathname(__dir__)
tree_sitter = root / 'tree-sitter'
include_dir = tree_sitter / 'lib/include'
source_dir = tree_sitter / 'lib/src'
main = root / 'src/main.c'
engine = source_dir / 'lib.c'
output = root / 'tree-sitter.wasm'
temporary = output.sub_ext('.wasm.tmp')
licenses_dir = Pathname('licenses')
license_sources = {
  'LICENSE-wasi-libc-MIT.txt' => 'LICENSE-MIT',
  'LICENSE-musl.txt' => 'libc-top-half/musl/COPYRIGHT',
  'LICENSE-cloudlibc.txt' => 'libc-bottom-half/cloudlibc/LICENSE'
}

desc 'Fetch license notices matching the installed WASI SDK'
task :licenses

if sdk = ENV['WASI_SDK_PATH']
  sdk_version = Pathname(sdk).expand_path / 'VERSION'
  license_sources.each do |name, source|
    target = licenses_dir / name
    file target.to_s => sdk_version.to_s do
      revision = sdk_version.read[/^wasi-libc: ([0-9a-f]{12,40})\r?$/, 1]
      abort 'WASI SDK VERSION does not identify its wasi-libc revision' unless revision
      url = "https://raw.githubusercontent.com/WebAssembly/wasi-libc/#{revision}/#{source}"
      target.binwrite(URI.open(url, &:read))
    end
  end
  task licenses: license_sources.keys.map { |name| (licenses_dir / name).to_s }
end

tree_sitter_sources = source_dir.glob('**/*.{c,h}') +
                      include_dir.glob('**/*.h') + [main, root / 'Rakefile']

desc 'Compile the Tree-sitter engine to tree-sitter.wasm (requires WASI SDK)'
task 'tree-sitter' => [:licenses, output.to_s]

file output.to_s => tree_sitter_sources.map(&:to_s) do
  sdk = ENV['WASI_SDK_PATH'] or abort 'Set WASI_SDK_PATH to an installed WASI SDK directory.'

  compiler = Pathname(sdk).expand_path / 'bin/clang'
  abort "WASI SDK compiler not found: #{compiler}" unless compiler.executable?
  abort 'Initialize Tree-sitter with git submodule update --init tree-sitter' unless
    engine.file?

  # Publish only successful builds; failed compilation preserves the last output.
  begin
    sh compiler.to_s, '--target=wasm32-wasip1', '-mexec-model=reactor',
       '-std=c11', '-O2', '-DNDEBUG', '-D_POSIX_C_SOURCE=200809L',
       '-Wall', '-Wextra', '-I', include_dir.to_s, '-I', source_dir.to_s,
       '-Wl,--export-table', '-Wl,--growable-table', '-Wl,--export=__stack_pointer',
       main.to_s, engine.to_s, '-o', temporary.to_s

    temporary.rename(output)
  ensure
    temporary.unlink if temporary.exist?
  end
end

CLEAN.include(output.to_s, temporary.to_s)
CLOBBER.include(*license_sources.keys.map { |name| (licenses_dir / name).to_s })

RSpec::Core::RakeTask.new(:spec)

task default: :spec
