require 'tmpdir'

RSpec.describe 'Wasm grammar linking' do
  before(:context) do
    root = Pathname(__dir__).parent
    @grammar = root / 'node_modules/tree-sitter-javascript/tree-sitter-javascript.wasm'
    @bytes = @grammar.binread

    Dir.mktmpdir('mallorn-grammar-fixtures-') do |directory|
      @scanner_libc = build_fixture(root, directory, 'scanner_libc',
                                    exports: ['tree_sitter_scanner_libc'])
      @incompatible = build_fixture(root, directory, 'incompatible_language',
                                    exports: ['tree_sitter_incompatible'])
      @trapping_initializer = build_fixture(root, directory, 'trapping_initializer',
                                            exports: ['__wasm_call_ctors'])
      @multi_language = build_fixture(root, directory, 'multi_language',
                                     exports: ['tree_sitter_first', 'tree_sitter_first_alias',
                                               'tree_sitter_second'])
      @invalid_pointer = build_fixture(root, directory, 'invalid_language_pointer',
                                      exports: ['tree_sitter_invalid_pointer'])
      @trapping_entrypoint = build_fixture(root, directory, 'trapping_language_entrypoint',
                                          exports: ['tree_sitter_trapping'])
    end
  end

  def build_fixture(root, directory, name, exports:)
    output = Pathname(directory) / "#{name}.wasm"
    compiler = Pathname(ENV.fetch('WASI_SDK_PATH')) / 'bin/clang'
    system(compiler.to_s, '--target=wasm32-wasip1', '-fPIC', '-shared', '-nostdlib',
           '-Wl,--allow-undefined', '-Wl,--no-entry',
           *exports.map { |name| "-Wl,--export=#{name}" },
           '-I', (root / 'tree-sitter/lib/src').to_s,
           (root / "spec/fixtures/#{name}.c").to_s, '-o', output.to_s,
           exception: true)
    output.binread
  end

  around do |example|
    @linker = Mallorn::Runtime.new
    @runtime = Mallorn::Runtime.new
    example.run
  ensure
    @runtime&.close
    @linker&.close
  end

  def load_javascript(bytes = @bytes)
    @linker.load_language_bytes(bytes, name: 'javascript')
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
      @linker.invoke('free', sexp) unless sexp.zero?
      @linker.invoke('mallorn_tree_delete', tree) unless tree.zero?
      @linker.invoke('free', input)
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

  it 'loads a grammar from a path and caches languages by name' do
    grammar = @runtime.load_grammar(@grammar)
    expect(grammar).to be_a(Mallorn::Grammar)
    expect(grammar.runtime).to equal(@runtime)
    language = grammar.language('javascript')
    name = +'javascript'
    expect(grammar.language(name)).to equal(language)
    name.replace('missing')
    expect(grammar.language('javascript')).to equal(language)
    expect(language.name).to eq('javascript')
    expect(language.metadata).to eq(major_version: 0, minor_version: 25, patch_version: 0)
  end

  it 'selects multiple language exports from one linked module' do
    grammar = @linker.load_grammar_bytes(@multi_language)
    first = grammar.language('first')
    second = grammar.language('second')
    expect(second).not_to equal(first)
    expect(second.name).to eq('second')
    expect(second.address).not_to eq(first.address)
    expect(first.metadata).to eq(major_version: 1, minor_version: 2, patch_version: 3)
    expect(second.metadata).to eq(major_version: 4, minor_version: 5, patch_version: 6)
    expect(first.symbol_count).to eq(3)
    expect(second.symbol_count).to eq(5)
    expect(first.field_count).to eq(1)
    expect(second.field_count).to eq(2)
    expect(first.state_count).to eq(2)
    expect(second.state_count).to eq(4)
    # The aliases return the same pointer only when they share an instance.
    expect(grammar.language('first_alias').address).to eq(first.address)
    expect(grammar.language('second')).to equal(second)
  end

  it 'keeps a grammar usable after selecting a missing export' do
    grammar = @runtime.load_grammar_bytes(@bytes)
    expect { grammar.language('missing') }
      .to raise_error(Mallorn::LanguageLoadError, /Missing grammar export/)
    expect(grammar.language('javascript').symbol_count).to be_positive
  end

  it 'checks the language ABI on selection rather than when linking a grammar' do
    grammar = @runtime.load_grammar_bytes(@incompatible)
    expect { grammar.language('incompatible') }
      .to raise_error(Mallorn::LanguageLoadError, /ABI 999/)
  end

  it 'links scanner libc functions to the engine allocator and memory' do
    language = @runtime.load_language_bytes(@scanner_libc, name: 'scanner_libc')
    expect(language.abi_version).to eq(15)
  end

  it 'rejects an invalid language pointer without invalidating existing languages' do
    javascript = load_javascript
    grammar = @linker.load_grammar_bytes(@invalid_pointer)
    expect { grammar.language('invalid_pointer') }
      .to raise_error(Mallorn::LanguageLoadError, /outside its data region/)
    expect(parse(javascript, 'let x = 1;')).to include('(lexical_declaration ')
  end

  it 'reports a trapping entry point without invalidating existing languages' do
    javascript = load_javascript
    grammar = @linker.load_grammar_bytes(@trapping_entrypoint)
    expect { grammar.language('trapping') }
      .to raise_error(Mallorn::LanguageLoadError, /Cannot select language trapping/)
    expect(parse(javascript, 'let x = 1;')).to include('(lexical_declaration ')
  end

  it 'rejects invalid language names' do
    grammar = @runtime.load_grammar_bytes(@bytes)
    ['', 'javascript-extra', "javascript\n"].each do |name|
      expect { grammar.language(name) }.to raise_error(ArgumentError, /C identifier/)
      expect { @runtime.load_language_bytes(@bytes, name:) }
        .to raise_error(ArgumentError, /C identifier/)
    end
  end

  it 'rejects cached and new language selections after runtime close' do
    grammar = @runtime.load_grammar_bytes(@multi_language)
    grammar.language('first')
    @runtime.close
    expect { grammar.language('first') }.to raise_error(Mallorn::ClosedError)
    expect { grammar.language('second') }.to raise_error(Mallorn::ClosedError)
    expect { @runtime.load_grammar_bytes(@bytes) }.to raise_error(Mallorn::ClosedError)
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
      @linker.load_language_bytes(@incompatible, name: 'incompatible')
    end.to raise_error(Mallorn::LanguageLoadError, /ABI 999/)
    expect(parse(load_javascript, 'let x = 1;')).to include('(lexical_declaration ')
  end

  it 'rejects a missing grammar export' do
    expect do
      @linker.load_language_bytes(@bytes, name: 'missing')
    end.to raise_error(Mallorn::LanguageLoadError, /Missing grammar export tree_sitter_missing/)
    expect(parse(load_javascript, 'let x = 1;')).to include('(lexical_declaration ')
  end

  it 'recovers from a trapping initializer without invalidating existing languages' do
    first = load_javascript
    expect do
      @linker.load_grammar_bytes(@trapping_initializer)
    end.to raise_error(Mallorn::LinkError, /Cannot link side module/)
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
