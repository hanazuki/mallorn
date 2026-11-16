module Mallorn
  # Internal linker for self-contained wasm32 dylink.0 grammar modules. Every
  # grammar uses this engine's memory, stack pointer, and function table.
  # Dependencies on other shared modules and GOT imports are not supported.
  class WasmLinker
    LoadedLanguage = Data.define(
      :instance, :address, :allocation, :abi_version,
      :symbol_count, :field_count, :state_count, :metadata
    )
    Layout = Data.define(:memory_size, :memory_alignment, :table_size, :table_alignment)

    # Reads binary sections without trusting their declared sizes or LEBs.
    class Reader
      def initialize(bytes)
        @bytes = bytes
        @offset = 0
      end

      def empty?
        @offset == @bytes.bytesize
      end

      def read(length)
        if length > @bytes.bytesize - @offset
          raise LinkError, 'Truncated Wasm section'
        end
        result = @bytes.byteslice(@offset, length)
        @offset += length
        result
      end

      def byte
        read(1).getbyte(0)
      end

      def uint32
        value = 0
        5.times do |index|
          part = byte
          raise LinkError, 'Invalid Wasm uint32' if index == 4 && part > 15
          value |= (part & 127) << (index * 7)
          return value if part < 128
        end
        raise LinkError, 'Invalid Wasm uint32'
      end

      def string
        read(uint32)
      end
    end

    def initialize(path)
      @engine = Wasmtime::Engine.new
      @store = Wasmtime::Store.new(@engine, wasi_p1_config: Wasmtime::WasiConfig.new)
      linker = Wasmtime::Linker.new(@engine)
      Wasmtime::WASI::P1.add_to_linker_sync(linker)
      mod = Wasmtime::Module.from_file(@engine, path.to_s)
      @instance = linker.instantiate(@store, mod)
      @instance.invoke('_initialize')
      @memory = @instance.export('memory').to_memory
      @table = @instance.export('__indirect_function_table').to_table
      @stack_pointer = @instance.export('__stack_pointer').to_global
      @languages = []
    rescue Wasmtime::Error, Wasmtime::Trap => error
      @store&.close
      raise LinkError, "Cannot initialize Tree-sitter engine: #{error.message}"
    end

    def close
      @store.close
      @languages.clear
    end

    def closed?
      @store.closed?
    end

    # Internal engine calls use scalar wasm32 values. Ruby memory operations
    # use unsigned offsets, whereas Wasmtime's i32 calls use signed integers.
    def invoke(name, *arguments)
      @instance.invoke(name, *arguments.map { |value| i32(value) })
    end

    attr_reader :memory

    def load(bytes, name:)
      bytes = String.try_convert(bytes) or raise TypeError, 'Expected Wasm bytes as a String'
      bytes = bytes.b
      layout = read_layout(bytes)
      mod = Wasmtime::Module.new(@engine, bytes)

      allocation = nil
      table_start = nil
      table_end = nil
      loaded = nil
      saved_stack = @stack_pointer.get
      begin
        alignment = 1 << layout.memory_alignment
        size = [layout.memory_size, 1].max + alignment - 1
        raise LinkError, 'Grammar allocation exceeds wasm32 address space' if size > 0xffffffff
        allocation = invoke('mallorn_calloc', 1, size) & 0xffffffff
        raise LinkError, 'Cannot allocate grammar data' if allocation.zero?
        memory_base = align(allocation, layout.memory_alignment)

        table_start = @table.size
        table_base = align(table_start, layout.table_alignment)
        table_end = table_base + layout.table_size
        raise LinkError, 'Grammar table exceeds wasm32 address space' if table_end > 0xffffffff
        @table.grow(table_end - table_start, nil) if table_end > table_start

        linker = grammar_linker(mod, memory_base, table_base)
        instance = linker.instantiate(@store, mod)
        entrypoint = instance.export("tree_sitter_#{name}")
        raise LinkError, "Missing grammar export tree_sitter_#{name}" unless entrypoint

        instance.invoke('__wasm_apply_data_relocs') if instance.export('__wasm_apply_data_relocs')
        if instance.export('_initialize')
          instance.invoke('_initialize')
        elsif instance.export('__wasm_call_ctors')
          instance.invoke('__wasm_call_ctors')
        end

        address = entrypoint.to_func.call & 0xffffffff
        unless address >= memory_base && address + 4 <= memory_base + layout.memory_size
          raise LinkError, 'Grammar returned a language pointer outside its data region'
        end
        abi_version = @memory.read_u32(address)
        minimum = invoke('mallorn_min_compatible_language_version')
        maximum = invoke('mallorn_language_version')
        unless (minimum..maximum).cover?(abi_version)
          raise IncompatibleLanguageError,
                "Grammar ABI #{abi_version} is unsupported; engine accepts #{minimum}..#{maximum}"
        end

        metadata_pointer = invoke('mallorn_language_metadata', address) & 0xffffffff
        metadata = unless metadata_pointer.zero?
          major, minor, patch = @memory.read(metadata_pointer, 3).unpack('C3')
          { major_version: major, minor_version: minor, patch_version: patch }.freeze
        end
        loaded = LoadedLanguage.new(
          instance: instance, address: address, allocation: allocation,
          abi_version: abi_version,
          symbol_count: invoke('mallorn_language_symbol_count', address),
          field_count: invoke('mallorn_language_field_count', address),
          state_count: invoke('mallorn_language_state_count', address),
          metadata: metadata
        )
        @languages << loaded
        loaded
      ensure
        unless loaded
          # Wasm tables cannot shrink. Clear failed modules' slots and leave
          # the holes unused; successful modules retain their original indexes.
          if table_start && table_end
            (table_start...[@table.size, table_end].min).each { |index| @table.set(index, nil) }
          end
          @stack_pointer.set(saved_stack)
          invoke('mallorn_free', allocation) if allocation && !allocation.zero?
        end
      end
    rescue Wasmtime::Error, Wasmtime::Trap => error
      raise LinkError, "Cannot link grammar #{name}: #{error.message}"
    end

    private

    def i32(value)
      value >= 0x80000000 ? value - 0x100000000 : value
    end

    def align(value, exponent)
      alignment = 1 << exponent
      (value + alignment - 1) & -alignment
    end

    def grammar_linker(mod, memory_base, table_base)
      imports = {
        'memory' => @memory,
        '__indirect_function_table' => @table,
        '__stack_pointer' => @stack_pointer,
        '__memory_base' => Wasmtime::Global.const(@store, :i32, i32(memory_base)),
        '__table_base' => Wasmtime::Global.const(@store, :i32, i32(table_base)),
        'iswspace' => @instance.export('mallorn_iswspace').to_func,
        'iswalpha' => @instance.export('mallorn_iswalpha').to_func,
        'malloc' => @instance.export('mallorn_alloc').to_func,
        'calloc' => @instance.export('mallorn_calloc').to_func,
        'free' => @instance.export('mallorn_free').to_func
      }
      linker = Wasmtime::Linker.new(@engine)
      mod.imports.each do |import|
        item = import['module'] == 'env' ? imports[import['name']] : nil
        unless item
          raise LinkError, "Unsupported grammar import #{import['module']}.#{import['name']}"
        end
        linker.define(@store, import['module'], import['name'], item)
      end
      linker
    end

    def read_layout(bytes)
      reader = Reader.new(bytes)
      unless reader.read(8) == ['0061736d01000000'].pack('H*')
        raise LinkError, 'Expected a WebAssembly version 1 module'
      end
      layout = nil
      until reader.empty?
        section_id = reader.byte
        section = Reader.new(reader.read(reader.uint32))
        next unless section_id.zero?
        name = section.string
        raise LinkError, 'Legacy dylink sections are not supported' if name == 'dylink'
        next unless name == 'dylink.0'
        raise LinkError, 'Duplicate dylink.0 section' if layout
        layout = read_dylink(section)
      end
      layout or raise LinkError, 'Grammar must contain a dylink.0 memory layout'
    end

    def read_dylink(reader)
      layout = nil
      until reader.empty?
        subsection_id = reader.byte
        subsection = Reader.new(reader.read(reader.uint32))
        case subsection_id
        when 1 # WASM_DYLINK_MEM_INFO
          raise LinkError, 'Duplicate dylink.0 memory layout' if layout
          layout = Layout.new(
            memory_size: subsection.uint32,
            memory_alignment: subsection.uint32,
            table_size: subsection.uint32,
            table_alignment: subsection.uint32
          )
          unless subsection.empty? && layout.memory_alignment <= 31 && layout.table_alignment <= 31
            raise LinkError, 'Invalid dylink.0 memory layout'
          end
        when 2 # WASM_DYLINK_NEEDED
          unless subsection.uint32.zero? && subsection.empty?
            raise LinkError, 'Grammar dependencies on other shared modules are not supported'
          end
        end
      end
      layout or raise LinkError, 'Missing dylink.0 memory layout'
    end
  end
end
