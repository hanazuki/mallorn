module Mallorn
  # Internal linker for self-contained wasm32 dylink.0 side modules.
  #
  # Each side module shares the main module's memory, stack pointer, and
  # function table.
  # Dependencies on other shared modules and GOT imports are not supported.
  # @api private
  class WasmLinker
    WASM_CUSTOM_SECTION = 0
    WASM_DYLINK_MEM_INFO = 1
    WASM_DYLINK_NEEDED = 2
    private_constant :WASM_CUSTOM_SECTION, :WASM_DYLINK_MEM_INFO, :WASM_DYLINK_NEEDED

    LinkedModule = Data.define(:instance, :memory_base, :memory_size)
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

    # Instantiates the main Wasm module.
    #
    # The exports list names the main module functions that side modules can
    # import from env.
    def initialize(path, calloc_export:, free_export:, imports: {}, exports: [])
      @calloc_export = calloc_export
      @free_export = free_export
      @exports = exports
      @engine = Wasmtime::Engine.new
      @store = Wasmtime::Store.new(@engine, wasi_p1_config: Wasmtime::WasiConfig.new)
      linker = Wasmtime::Linker.new(@engine)
      Wasmtime::WASI::P1.add_to_linker_sync(linker)
      imports.each do |namespace, functions|
        functions.each do |name, (parameters, results, callback)|
          function = Wasmtime::Func.new(@store, parameters, results, &callback)
          linker.define(@store, namespace, name, function)
        end
      end
      mod = Wasmtime::Module.from_file(@engine, path.to_s)
      @instance = linker.instantiate(@store, mod)
      @instance.invoke('_initialize')
      @memory = @instance.export('memory').to_memory
      @table = @instance.export('__indirect_function_table').to_table
      @stack_pointer = @instance.export('__stack_pointer').to_global
      @modules = []
    rescue Wasmtime::Error, Wasmtime::Trap => error
      @store&.close
      raise LinkError, "Cannot initialize main Wasm module: #{error.message}"
    end

    def close
      @store.close
      @modules.clear
    end

    def closed?
      @store.closed?
    end

    # Calls a main module function with scalar wasm32 arguments.
    #
    # Ruby memory operations use unsigned offsets. Wasmtime's i32 calls use
    # signed integers.
    def invoke(name, *arguments)
      @instance.invoke(name, *arguments.map { |value| i32(value) })
    end

    attr_reader :memory

    def load(bytes)
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
        raise LinkError, 'Side module allocation exceeds wasm32 address space' if size > 0xffffffff
        allocation = invoke(@calloc_export, 1, size) & 0xffffffff
        raise LinkError, 'Cannot allocate side module data' if allocation.zero?
        memory_base = align(allocation, layout.memory_alignment)

        table_start = @table.size
        table_base = align(table_start, layout.table_alignment)
        table_end = table_base + layout.table_size
        raise LinkError, 'Side module table exceeds wasm32 address space' if table_end > 0xffffffff
        @table.grow(table_end - table_start, nil) if table_end > table_start

        linker = side_module_linker(mod, memory_base, table_base)
        instance = linker.instantiate(@store, mod)
        instance.invoke('__wasm_apply_data_relocs') if instance.export('__wasm_apply_data_relocs')
        if instance.export('_initialize')
          instance.invoke('_initialize')
        elsif instance.export('__wasm_call_ctors')
          instance.invoke('__wasm_call_ctors')
        end

        linked = LinkedModule.new(instance: instance, memory_base: memory_base, memory_size: layout.memory_size)
        @modules << linked
        loaded = true
        linked
      ensure
        unless loaded
          # Wasm tables cannot shrink. Clear failed modules' slots and leave
          # the holes unused; successful modules retain their original indexes.
          if table_start && table_end
            (table_start...[@table.size, table_end].min).each { |index| @table.set(index, nil) }
          end
          @stack_pointer.set(saved_stack)
          invoke(@free_export, allocation) if allocation && !allocation.zero?
        end
      end
    rescue Wasmtime::Error, Wasmtime::Trap => error
      raise LinkError, "Cannot link side module: #{error.message}"
    end

    private

    def i32(value)
      value = value.to_int
      raise RangeError, 'Integer must be in 0..4294967295' unless value.between?(0, 0xffffffff)
      value >= 0x80000000 ? value - 0x100000000 : value
    end

    def align(value, exponent)
      alignment = 1 << exponent
      (value + alignment - 1) & -alignment
    end

    def side_module_linker(mod, memory_base, table_base)
      imports = {
        'memory' => @memory,
        '__indirect_function_table' => @table,
        '__stack_pointer' => @stack_pointer,
        '__memory_base' => Wasmtime::Global.const(@store, :i32, i32(memory_base)),
        '__table_base' => Wasmtime::Global.const(@store, :i32, i32(table_base))
      }
      linker = Wasmtime::Linker.new(@engine)
      mod.imports.each do |import|
        namespace, name = import.values_at('module', 'name')
        if namespace == 'env'
          item = imports.fetch(name) do
            @instance.export(name)&.to_func if @exports.include?(name)
          end
        end
        raise LinkError, "Unsupported side module import #{namespace}.#{name}" unless item
        linker.define(@store, namespace, name, item)
      end
      linker
    end

    def read_layout(bytes)
      reader = Reader.new(bytes)
      unless reader.read(8) == "\x00asm\x01\x00\x00\x00"
        raise LinkError, 'Expected a WebAssembly version 1 module'
      end
      layout = nil
      until reader.empty?
        section_id = reader.byte
        section = Reader.new(reader.read(reader.uint32))
        next unless section_id == WASM_CUSTOM_SECTION
        name = section.string
        raise LinkError, 'Legacy dylink sections are not supported' if name == 'dylink'
        next unless name == 'dylink.0'
        raise LinkError, 'Duplicate dylink.0 section' if layout
        layout = read_dylink(section)
      end
      layout or raise LinkError, 'Side module must contain a dylink.0 memory layout'
    end

    def read_dylink(reader)
      layout = nil
      until reader.empty?
        subsection_id = reader.byte
        subsection = Reader.new(reader.read(reader.uint32))
        case subsection_id
        when WASM_DYLINK_MEM_INFO
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
        when WASM_DYLINK_NEEDED
          unless subsection.uint32.zero? && subsection.empty?
            raise LinkError, 'Dependencies on other shared modules are not supported'
          end
        end
      end
      layout or raise LinkError, 'Missing dylink.0 memory layout'
    end
  end
end
