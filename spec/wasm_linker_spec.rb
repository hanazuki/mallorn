require 'tmpdir'

RSpec.describe 'Wasm grammar linking' do
  before(:context) do
    root = Pathname(__dir__).parent
    system('bundle', 'exec', 'rake', 'tree-sitter', chdir: root, exception: true)
    @grammar = root / 'node_modules/tree-sitter-javascript/tree-sitter-javascript.wasm'
    @bytes = @grammar.binread

    Dir.mktmpdir('mallorn-incompatible-') do |directory|
      output = Pathname(directory) / 'incompatible.wasm'
      compiler = Pathname(ENV.fetch('WASI_SDK_PATH')) / 'bin/clang'
      command = [compiler.to_s, '--target=wasm32-wasip1', '-fPIC', '-shared', '-nostdlib',
                 '-Wl,--allow-undefined', '-Wl,--no-entry', '-Wl,--export=tree_sitter_incompatible',
                 '-Wl,--export=__wasm_call_ctors',
                 (root / 'spec/fixtures/incompatible_language.c').to_s, '-o', output.to_s]
      system(*command, exception: true)
      @incompatible = output.binread
      system(*command, '-DTRAP_INITIALIZER', exception: true)
      @trapping = output.binread
    end
  end

  around do |example|
    @linker = Mallorn::WasmLinker.new(Pathname(__dir__).parent / 'tree-sitter.wasm')
    @runtime = Mallorn::Runtime.new
    example.run
  ensure
    @runtime&.close
    @linker&.close
  end

  def load_javascript(bytes = @bytes)
    @linker.load(bytes, name: 'javascript')
  end

  # Exercise the linker's ABI directly while the public Parser/Node API is
  # still a draft.
  def parse(language, source)
    parser = @linker.invoke('mallorn_parser_new')
    input = @linker.invoke('mallorn_alloc', source.bytesize) & 0xffffffff
    tree = 0
    sexp = 0
    begin
      @linker.memory.write(input, source.b)
      expect(@linker.invoke('mallorn_parser_set_language', parser, language.address)).to eq(1)
      encoding = Mallorn::SUPPORTED_ENCODINGS.index(source.encoding)
      tree = @linker.invoke('mallorn_parser_parse_string', parser, 0, input, source.bytesize, encoding)
      expect(tree).not_to eq(0)
      expect(@linker.invoke('mallorn_tree_has_error', tree)).to eq(0)
      sexp = @linker.invoke('mallorn_tree_string', tree)
      @linker.memory.read_cstring(sexp & 0xffffffff)
    ensure
      @linker.invoke('mallorn_free', sexp) unless sexp.zero?
      @linker.invoke('mallorn_tree_delete', tree) unless tree.zero?
      @linker.invoke('mallorn_free', input)
      @linker.invoke('mallorn_parser_delete', parser)
    end
  end

  it 'loads the published language from a path and reads its metadata' do
    language = @runtime.load_language(@grammar, name: 'javascript')
    expect(language).to be_a(Mallorn::Language)
    expect(language.runtime).to equal(@runtime)
    expect(language.name).to eq('javascript')
    expect(language.abi_version).to eq(15)
    expect(language.metadata).to eq(major_version: 0, minor_version: 25, patch_version: 0)
    expect(language.symbol_count).to be_positive
    expect(language.field_count).to be_positive
    expect(language.state_count).to be_positive
  end

  Mallorn::SUPPORTED_ENCODINGS.each do |encoding|
    it "parses scanner-dependent JavaScript in #{encoding.name}" do
      source = <<~'JS'
        const café = `hello ${name}`
        const pattern = /ab+c/u
        if (café)
          inspect(café)
      JS
      sexp = parse(load_javascript, source.encode(encoding))
      expect(sexp).to start_with('(program ')
      expect(sexp).to include('(template_string ', '(regex ', '(if_statement ')
    end
  end

  it 'keeps earlier languages parseable after loading another copy' do
    first = load_javascript
    second = load_javascript
    expect(parse(first, 'const x = `first`;')).to include('(template_string ')
    expect(parse(second, 'const y = `second`;')).to include('(template_string ')
  end

  it 'rejects an unsupported import and can subsequently load a valid module' do
    unsupported = @bytes.sub('iswalpha', 'notvalid')
    expect { load_javascript(unsupported) }.to raise_error(Mallorn::LinkError, /env.notvalid/)
    expect(parse(load_javascript, 'let x = 1;')).to include('(lexical_declaration ')
  end

  it 'rejects imports outside the env namespace' do
    original = 'env' + [8].pack('C') + 'iswalpha'
    replacement = 'bad' + [8].pack('C') + 'iswalpha'
    expect { load_javascript(@bytes.sub(original, replacement)) }
      .to raise_error(Mallorn::LinkError, /bad.iswalpha/)
  end

  it 'rejects an incompatible ABI and can subsequently load a valid module' do
    expect do
      @linker.load(@incompatible, name: 'incompatible')
    end.to raise_error(Mallorn::IncompatibleLanguageError, /ABI 999/)
    expect(parse(load_javascript, 'let x = 1;')).to include('(lexical_declaration ')
  end

  it 'rejects a missing grammar export' do
    expect do
      @linker.load(@bytes, name: 'missing')
    end.to raise_error(Mallorn::LinkError, /Missing grammar export tree_sitter_missing/)
    expect(parse(load_javascript, 'let x = 1;')).to include('(lexical_declaration ')
  end

  it 'recovers from a trapping initializer without invalidating existing languages' do
    first = load_javascript
    expect do
      @linker.load(@trapping, name: 'incompatible')
    end.to raise_error(Mallorn::LinkError, /Cannot link grammar incompatible/)
    expect(parse(first, 'let before = 1;')).to include('(lexical_declaration ')
    expect(parse(load_javascript, 'let after = 2;')).to include('(lexical_declaration ')
  end

  it 'rejects modules without dylink.0 metadata' do
    expect { load_javascript(@bytes.sub('dylink.0', 'ignored0')) }
      .to raise_error(Mallorn::LinkError, /must contain a dylink.0/)
  end

  it 'rejects truncated sections and invalid LEB integers' do
    expect { load_javascript(@bytes.byteslice(0, 20)) }
      .to raise_error(Mallorn::LinkError, /Truncated/)
    malformed = @bytes.byteslice(0, 8) + [0, 255, 255, 255, 255, 16].pack('C*')
    expect { load_javascript(malformed) }.to raise_error(Mallorn::LinkError, /Invalid Wasm uint32/)
  end

  it 'closes idempotently and rejects use after close' do
    @runtime.load_language_bytes(@bytes, name: 'javascript')
    @runtime.close
    @runtime.close
    expect(@runtime).to be_closed
    expect { @runtime.load_language_bytes(@bytes, name: 'javascript') }
      .to raise_error(Mallorn::ClosedError)
  end
end
