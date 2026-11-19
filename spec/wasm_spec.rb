require 'wasmtime'

RSpec.describe 'Tree-sitter Wasm build' do
  before(:context) do
    root = File.expand_path('..', __dir__)
    engine = Wasmtime::Engine.new
    @store = Wasmtime::Store.new(engine, wasi_p1_config: Wasmtime::WasiConfig.new)
    linker = Wasmtime::Linker.new(engine)
    Wasmtime::WASI::P1.add_to_linker_sync(linker)
    read = Wasmtime::Func.new(@store, [:i32, :i32, :i32, :i32, :i32], [:i32]) { |_caller, *_args| 0 }
    cancel = Wasmtime::Func.new(@store, [], [:i32]) { |_caller| 0 }
    linker.define(@store, 'mallorn', 'read', read)
    linker.define(@store, 'mallorn', 'cancel', cancel)
    mod = Wasmtime::Module.from_file(engine, File.join(root, 'tree-sitter.wasm'))
    @instance = linker.instantiate(@store, mod)
    @instance.invoke('_initialize')
  end

  after(:context) { @store.close }

  it 'reports the supported grammar ABI range' do
    minimum = @instance.invoke('mallorn_min_compatible_language_version')
    maximum = @instance.invoke('mallorn_language_version')
    expect(minimum).to be_positive
    expect(maximum).to be >= minimum
  end

  it 'allocates writable linear memory' do
    pointer = @instance.invoke('mallorn_alloc', 4)
    expect(pointer).to be_positive
    begin
      memory = @instance.export('memory').to_memory
      memory.write(pointer, 'test')
      expect(memory.read(pointer, 4)).to eq('test')
    ensure
      @instance.invoke('mallorn_free', pointer)
    end
  end

  it 'creates and resets a parser without a language' do
    parser = @instance.invoke('mallorn_parser_new')
    expect(parser).to be_positive
    begin
      @instance.invoke('mallorn_parser_reset', parser)
      # Parsing without an assigned language must return a null tree.
      expect(@instance.invoke('mallorn_parser_parse_string', parser, 0, 0, 0, 0)).to eq(0)
    ensure
      @instance.invoke('mallorn_parser_delete', parser)
    end
  end
end
