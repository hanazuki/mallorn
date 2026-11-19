require 'fileutils'
require 'tmpdir'
require 'rubygems/package'

RSpec.describe 'Gem package' do
  it 'ships the generated engine and required third-party notices' do
    root = Pathname(__dir__).parent

    Dir.mktmpdir('mallorn-package-') do |directory|
      gemspec = Gem::Specification.load((root / 'mallorn.gemspec').to_s)
      filename = Pathname(directory) / gemspec.file_name
      Dir.chdir(root) { Gem::Package.build(gemspec, false, false, filename.to_s) }
      package = Gem::Package.new(filename.to_s)
      destination = Pathname(directory) / 'unpacked'
      package.extract_files(destination.to_s)
      expect((destination / 'tree-sitter.wasm').binread).to eq((root / 'tree-sitter.wasm').binread)
      stdlib = 'generated/lib/mallorn/wasm_stdlib.rb'
      expect((destination / stdlib).binread).to eq((root / stdlib).binread)
      expect(package.contents).not_to include('tree-sitter/lib/src/wasm-stdlib/imports.txt')
      expect((destination / 'tree-sitter/LICENSE').read).to eq((root / 'tree-sitter/LICENSE').read)
      unicode = 'tree-sitter/lib/src/unicode/LICENSE'
      expect((destination / unicode).binread).to eq((root / unicode).binread)
      expect((destination / unicode).read).to include('Unicode, Inc.')

      notices = {
        'LICENSE-wasi-libc-MIT.txt' => 'Permission is hereby granted',
        'LICENSE-musl.txt' => 'Rich Felker',
        'LICENSE-cloudlibc.txt' => 'Nuxi'
      }
      notices.each do |name, attribution|
        path = Pathname('licenses') / name
        text = (destination / path).read
        expect(text).to eq((root / path).read)
        expect(text).to include(attribution)
      end
      expected_files = notices.keys.map { |name| "licenses/#{name}" }
      expect(package.contents.grep(%r{\Alicenses/}).reject { |path| path == 'licenses/README.md' }.sort).to eq(expected_files.sort)
      expect(package.contents).to include('licenses/README.md')
    end
  end
end
