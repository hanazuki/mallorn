require 'fileutils'
require 'tmpdir'
require 'rubygems/package'

RSpec.describe 'Gem package' do
  it 'ships the generated Wasm engine and its upstream license' do
    root = Pathname(__dir__).parent
    system('bundle', 'exec', 'rake', 'build', chdir: root, exception: true)
    package = Gem::Package.new((root / "pkg/mallorn-#{Mallorn::VERSION}.gem").to_s)

    Dir.mktmpdir('mallorn-package-') do |directory|
      destination = Pathname(directory)
      package.extract_files(destination.to_s)
      expect((destination / 'tree-sitter.wasm').binread).to eq((root / 'tree-sitter.wasm').binread)
      expect((destination / 'tree-sitter/LICENSE').read).to eq((root / 'tree-sitter/LICENSE').read)
    end
  end
end
