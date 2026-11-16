require 'rspec/core/rake_task'
require 'rubygems/package'
require 'rake/clean'

root = Pathname(__dir__)
tree_sitter = root / 'tree-sitter'
include_dir = tree_sitter / 'lib/include'
source_dir = tree_sitter / 'lib/src'
main = root / 'src/main.c'
engine = source_dir / 'lib.c'
output = root / 'tree-sitter.wasm'
temporary = output.sub_ext('.wasm.tmp')

tree_sitter_sources = source_dir.glob('**/*.{c,h}') +
                      include_dir.glob('**/*.h') + [main, root / 'Rakefile']

desc 'Compile the Tree-sitter engine to tree-sitter.wasm (requires WASI SDK)'
task 'tree-sitter' => output.to_s

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

RSpec::Core::RakeTask.new(:spec)

gemspec_path = root / 'mallorn.gemspec'
gemspec = Gem::Specification.load(gemspec_path.to_s)
package_dir = root / 'pkg'
package = package_dir / gemspec.file_name

directory package_dir.to_s
file package.to_s => [package_dir, gemspec_path, *gemspec.files.map { |path| root / path }].map(&:to_s) do
  Dir.chdir(root) do
    Gem::Package.build(gemspec, false, false, package.to_s)
  end
end

CLOBBER.include(package_dir.to_s)

desc 'Build the gem into pkg/'
task gem: package.to_s

task package: :gem

desc 'Build the gem into pkg/'
task build: :gem

task default: :spec
