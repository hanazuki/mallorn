require 're2'
require 'wasmtime'
require_relative 'mallorn/version'
require_relative '../generated/lib/mallorn/wasm_stdlib'

# Tree-sitter bindings backed by a Wasm engine and separately loaded grammars.
# @see Runtime
# @see Parser
module Mallorn
  # Supported source encodings.
  #
  # @note This array must be in sync with TSInputEncoding.
  SUPPORTED_ENCODINGS = [Encoding::UTF_8, Encoding::UTF_16LE, Encoding::UTF_16BE].freeze

  # Base class for Mallorn failures.
  class Error < StandardError; end
  # An unsupported input encoding or an encoding mismatch during tree reuse.
  class UnsupportedEncodingError < Error; end
  # A language incompatible with the requested operation.
  class IncompatibleLanguageError < Error; end
  # A mismatch between the Wasm runtimes of two objects.
  class IncompatibleRuntimeError < Error; end
  # An operation on a closed object or runtime.
  class ClosedError < Error; end
  # A cancelled parse or query operation.
  class CancelledError < Error; end
  # A Wasm module loading or import error.
  class LinkError < Error; end
  # A language loading error in a linked grammar.
  class LanguageLoadError < Error; end

  # A query compilation, predicate, or directive error.
  # @see Query
  class QueryError < Error
    # @return [Integer, nil] UTF-8 byte offset for a compilation error
    attr_reader :byte_offset

    # @return [Symbol, nil] compilation category: :syntax, :node_type, :field,
    #   :capture, :structure, or :language
    attr_reader :error_type

    # @api private
    def initialize(message, byte_offset: nil, error_type: nil)
      super(message)
      @byte_offset = byte_offset
      @error_type = error_type
    end
  end

  # Location in the source code.
  #
  # @!attribute [r] row
  #   @return [Integer] zero-based row
  # @!attribute [r] column
  #   @return [Integer] byte column since the last LF
  Point = Data.define(:row, :column) do
    include Comparable

    # @param other [Point]
    # @return [Integer, nil] row/column comparison, or nil for a non-Point
    def <=>(other)
      other.is_a?(Point) ? [row, column] <=> [other.row, other.column] : nil
    end
  end

  # Half-open source interval in bytes and points.
  #
  # @!attribute [r] start_byte
  #   @return [Integer] inclusive byte offset
  # @!attribute [r] end_byte
  #   @return [Integer] exclusive byte offset
  # @!attribute [r] start_point
  #   @return [Point] inclusive start position
  # @!attribute [r] end_point
  #   @return [Point] exclusive end position
  Span = Data.define(:start_byte, :end_byte, :start_point, :end_point)

  # Mapping from an old revision's interval to a new interval.
  #
  # The start and old end use the old revision; the new end uses the updated revision.
  #
  # @!attribute [r] start_byte
  #   @return [Integer] start offset in both revisions
  # @!attribute [r] old_end_byte
  #   @return [Integer] exclusive old end
  # @!attribute [r] new_end_byte
  #   @return [Integer] exclusive new end
  # @!attribute [r] start_point
  #   @return [Point] start position in both revisions
  # @!attribute [r] old_end_point
  #   @return [Point] exclusive old end position
  # @!attribute [r] new_end_point
  #   @return [Point] exclusive new end position
  InputEdit = Data.define(
    :start_byte, :old_end_byte, :new_end_byte,
    :start_point, :old_end_point, :new_end_point
  )

  # A query capture.
  #
  # Repeated captures retain the same name on each occurrence.
  #
  # @!attribute [r] name
  #   @return [String] capture name without the @ prefix
  # @!attribute [r] node
  #   @return [Node] captured node, retaining its tree
  Capture = Data.define(:name, :node)

  # A complete, predicate-checked query match.
  #
  # @!attribute [r] pattern_index
  #   @return [Integer] zero-based query pattern index
  # @!attribute [r] captures
  #   @return [Array<Capture>] frozen captures, including repeated names
  # @!attribute [r] properties
  #   @return [Hash] frozen properties from set! directives and custom handlers
  Match = Data.define(:pattern_index, :captures, :properties)

  # A predicate argument referring to a capture rather than a literal string.
  #
  # @!attribute [r] name
  #   @return [String] capture name without the @ prefix
  CaptureReference = Data.define(:name)

  # An introspected predicate or directive, including unknown operations.
  #
  # @!attribute [r] name
  #   @return [String] operation name without #, for example 'eq?' or 'set!'
  # @!attribute [r] arguments
  #   @return [Array<String, CaptureReference>] frozen, ordered arguments
  Predicate = Data.define(:name, :arguments)

  # @api private
  module Internal
    UINT_MAX = 0xffffffff

    def self.pack_uint32(*values)
      values.map! do |value|
        value = value.to_int
        raise RangeError, "Integer must be in 0..#{UINT_MAX}" unless value.between?(0, UINT_MAX)
        value
      end.pack('L<*')
    end

    def self.ordered(first, last)
      raise ArgumentError, 'Range ends before its start' if first > last
    end

    def self.pack_span(value)
      first = value.start_byte
      last = value.end_byte
      start_point = value.start_point
      end_point = value.end_point
      ordered(first, last)
      ordered(start_point, end_point)
      pack_uint32(start_point.row, start_point.column, end_point.row, end_point.column, first, last)
    end

    def self.pack_edit(value)
      first = value.start_byte
      old_end = value.old_end_byte
      new_end = value.new_end_byte
      start_point = value.start_point
      old_point = value.old_end_point
      new_point = value.new_end_point
      ordered(first, old_end)
      ordered(first, new_end)
      ordered(start_point, old_point)
      ordered(start_point, new_point)
      pack_uint32(first, old_end, new_end, start_point.row, start_point.column,
                  old_point.row, old_point.column, new_point.row, new_point.column)
    end

    def self.pack_ranges(values)
      return nil if values.nil?
      raise ArgumentError, 'Included ranges cannot be empty' if values.empty?
      previous = nil
      bytes = values.map do |value|
        packed = pack_span(value)
        if previous
          ordered(previous.end_byte, value.start_byte)
          ordered(previous.end_point, value.start_point)
        end
        previous = value
        packed
      end
      bytes.join
    end

    def self.cancel!(value)
      raise CancelledError, 'Operation cancelled' if value&.call
    end

    def self.input(source)
      encoding = source.encoding
      unless SUPPORTED_ENCODINGS.include?(encoding)
        raise UnsupportedEncodingError, "Unsupported source encoding: #{encoding}"
      end
      [source.is_a?(String) ? source.dup.freeze : source, encoding]
    end

    # Advances a source point by raw bytes, including partial characters.
    def self.advance(point, bytes, encoding, offset, previous_byte: nil)
      if encoding != Encoding::UTF_8 && offset.odd? && previous_byte
        bytes = previous_byte + bytes
        offset -= 1
        point = Point.new(point.row, point.column - 1)
      end
      width = encoding == Encoding::UTF_8 ? 1 : 2
      newline = "\n".encode(encoding).b
      position = 0
      rows = 0
      last = nil
      while (found = bytes.index(newline, position))
        if ((offset + found) % width).zero?
          rows += 1
          last = found + width
        end
        position = found + 1
      end
      Point.new(point.row + rows, last ? bytes.bytesize - last : point.column + bytes.bytesize)
    end

    # Reads a fragment with enough contiguous bytes for the decoder.
    #
    # The decoder needs up to four contiguous bytes. Coalesce only that small
    # prefix when a caller's fragment splits UTF-8 or a UTF-16 surrogate pair.
    def self.read(source, encoding, offset, point, capacity, previous_byte: nil)
      return (source.byteslice(offset, capacity) || '').b if source.is_a?(String)
      bytes = ''.b
      loop do
        hint = advance(point, bytes, encoding, offset, previous_byte: previous_byte)
        chunk = source.read_at(offset + bytes.bytesize, point: hint)
        break if chunk.nil?
        unless chunk.encoding == encoding
          raise UnsupportedEncodingError, 'read_at returned a different source encoding'
        end
        break if chunk.empty?
        bytes << chunk.byteslice(0, capacity - bytes.bytesize).b
        break if bytes.bytesize >= [4, capacity].min
      end
      bytes
    end

    # A native handle with deferred release during garbage collection.
    #
    # Finalizers enqueue releases. The next serialized runtime operation frees
    # them; no Wasmtime calls or mutex acquisition occur inside a GC finalizer.
    class Handle
      def self.finalizer(queue, function, address)
        proc { queue << [function, address] }
      end

      def initialize(runtime, function, address)
        raise Error, 'Cannot allocate Tree-sitter resource' if address.zero?
        @runtime = runtime
        @function = function
        @address = address
        ObjectSpace.define_finalizer(self, self.class.finalizer(runtime.release_queue, function, address))
      end

      def address
        raise ClosedError, 'Object is closed' if @address.zero?
        @address
      end

      def close
        return if @address.zero?
        if @runtime.closed?
          @address = 0
        else
          @runtime.with_backend do |backend|
            backend.invoke(@function, @address) unless @address.zero?
            @address = 0
          end
        end
        ObjectSpace.undefine_finalizer(self)
        nil
      end

      def closed?
        @address.zero? || @runtime.closed?
      end
    end
  end
  private_constant :Internal

  # A runtime with serialized access to Wasm.
  #
  # Input/cancellation callbacks must not reenter the runtime. All handles
  # become invalid when the runtime is closed.
  class Runtime
    # @api private
    attr_reader :release_queue

    attr_reader :language_abi_versions

    # Creates an independent Wasm runtime.
    #
    # Grammars and trees from different runtimes cannot exchange backend handles.
    # @raise [LinkError] the packaged engine cannot be instantiated
    # @example
    #   runtime = Runtime.new
    #   begin
    #     language = runtime.load_language('tree-sitter-javascript.wasm', name: 'javascript')
    #     parser = Parser.new(language: language)
    #     parser.parse('let x = 1;').root_node.to_sexp
    #   ensure
    #     runtime.close
    #   end
    def initialize
      @mutex = Mutex.new
      @release_queue = Queue.new
      @linker = WasmLinker.new(
        Pathname(__dir__).parent / 'tree-sitter.wasm',
        exports: WasmStdlib::LIBC_SYMBOLS,
        calloc_export: 'calloc',
        free_export: 'free',
        imports: { 'mallorn' => {
          'read' => [[:i32, :i32, :i32, :i32, :i32], [:i32], method(:read_input)],
          'cancel' => [[], [:i32], method(:cancel_operation)]
        } }
      )
      @language_abi_versions = invoke('mallorn_min_compatible_language_version')..invoke('mallorn_language_version')
    end

    # @api private
    def support_abi_version?(version)
      @language_abi_versions.cover?(version)
    end

    # Links and initializes a precompiled Wasm grammar module from a file.
    #
    # Select its languages with Grammar#language. Modules must be self-contained
    # wasm32 dylink.0 with supported imports. These include the env functions
    # in Tree-sitter's lib/src/wasm-stdlib/imports.txt, plus shared memory/table,
    # stack, and relocation base imports. Additional shared-module dependencies
    # and legacy dylink modules are rejected.
    # @param path [String, Pathname] Wasm grammar path
    # @return [Grammar] a newly linked module owned by this runtime
    # @raise [LinkError] linking fails or the module format/imports are unsupported
    # @raise [ClosedError] this runtime is closed
    # @see #load_grammar_bytes
    def load_grammar(path)
      load_grammar_bytes(Pathname(path).binread)
    end

    # Links and initializes a grammar module from bytes.
    #
    # Loaded modules remain resident until this runtime is closed or collected.
    # Each call creates a separate module instance. Retain the Grammar to share
    # it across languages.
    # Language exports and ABIs are validated when selecting a language.
    # @param bytes [String] Wasm binary, without text transcoding
    # @return [Grammar]
    # @raise [LinkError] the grammar module cannot be linked
    # @raise [ClosedError] this runtime is closed
    # @see #load_grammar
    def load_grammar_bytes(bytes)
      with_backend do
        Grammar.new(runtime: self, linked: @linker.load(bytes))
      end
    end

    # Loads a module from a file and selects one language.
    #
    # Use #load_grammar to share a module between multiple languages.
    # @param path [String, Pathname] Wasm grammar path
    # @param name [String] C identifier naming its tree_sitter_<name> export
    # @return [Language] a new language object owned by this runtime
    # @raise [ArgumentError] name is not a C identifier
    # @raise [LinkError] the grammar module cannot be linked
    # @raise [LanguageLoadError] the language export is missing, fails, or returns
    #   an invalid or ABI-incompatible language
    # @raise [ClosedError] this runtime is closed
    # @see #load_language_bytes
    def load_language(path, name:)
      load_language_bytes(Pathname(path).binread, name:)
    end

    # Loads a module from bytes and selects one language.
    # @param bytes [String] Wasm binary, without text transcoding
    # @param name [String] C identifier naming its tree_sitter_<name> export
    # @return [Language]
    # @raise [ArgumentError] name is not a C identifier
    # @raise [LinkError] the grammar module cannot be linked
    # @raise [LanguageLoadError] the language export is missing, fails, or returns
    #   an invalid or ABI-incompatible language
    # @raise [ClosedError] this runtime is closed
    # @see #load_grammar_bytes
    def load_language_bytes(bytes, name:)
      load_grammar_bytes(bytes).language(name)
    end

    # Closes the Wasm store and invalidates every associated object.
    #
    # This method is idempotent.
    # @return [nil]
    # @raise [Error] called from one of this runtime's callbacks
    def close
      raise Error, 'Cannot close a runtime from its callback' if @mutex.owned?
      @mutex.synchronize { @linker.close }
      nil
    end

    # @return [Boolean] whether this object or its owning runtime is closed
    def closed?
      @mutex.owned? ? @linker.closed? : @mutex.synchronize { @linker.closed? }
    end

    # @api private
    def check_open!
      raise ClosedError, 'Runtime is closed' if closed?
    end

    # @api private
    def with_backend
      raise Error, 'Cannot reenter a runtime from its callback' if @mutex.owned?
      @mutex.synchronize do
        raise ClosedError, 'Runtime is closed' if @linker.closed?
        until @release_queue.empty?
          function, address = @release_queue.pop
          @linker.invoke(function, address)
        end
        yield self
      end
    end

    # Calls an internal ABI function within with_backend's serialized section.
    # @api private
    def invoke(name, *arguments)
      @linker.invoke(name, *arguments)
    end

    # @api private
    def memory
      @linker.memory
    end

    # @api private
    def pointer(name, *arguments)
      invoke(name, *arguments) & 0xffffffff
    end

    # @api private
    def buffer(bytes_or_size)
      size = bytes_or_size.is_a?(String) ? bytes_or_size.bytesize : bytes_or_size
      address = pointer('calloc', 1, [size, 1].max)
      raise Error, 'Cannot allocate Wasm memory' if address.zero?
      begin
        memory.write(address, bytes_or_size) if bytes_or_size.is_a?(String)
        yield address
      ensure
        invoke('free', address)
      end
    end

    # @api private
    def cstring(address)
      memory.read_cstring(address).force_encoding(Encoding::UTF_8)
    end

    # @api private
    def string(address, length)
      memory.read(address, length).force_encoding(Encoding::UTF_8)
    end

    # @api private
    def node_result
      buffer(24) do |output|
        yield output
        bytes = memory.read(output, 24)
        bytes.unpack1('L<', offset: 16).zero? ? nil : bytes.freeze
      end
    end

    # @api private
    def ranges(name, *arguments)
      buffer(4) do |count|
        address = pointer(name, *arguments, count)
        begin
          memory.read(address, memory.read_u32(count) * 24).unpack('L<*').each_slice(6).map do |sr, sc, er, ec, first, last|
            Span.new(first, last, Point.new(sr, sc), Point.new(er, ec))
          end.freeze
        ensure
          invoke('free', address)
        end
      end
    end

    # @api private
    def with_callbacks(read: nil, cancellation: nil)
      @read_callback = read
      @cancellation = cancellation
      @callback_error = nil
      @cancelled = false
      result = yield
      raise @callback_error if @callback_error
      raise CancelledError, 'Operation cancelled' if @cancelled
      result
    ensure
      @read_callback = nil
      @cancellation = nil
      @callback_error = nil
      @cancelled = false
    end

    private

    def read_input(_caller, offset, row, column, buffer, capacity)
      begin
        # Wasmtime exposes i32 arguments as signed integers; recover the
        # unsigned offsets, coordinates, and buffer pointer used by Tree-sitter.
        bytes = @read_callback.call(offset & 0xffffffff, Point.new(row & 0xffffffff, column & 0xffffffff), capacity)
        memory.write(buffer & 0xffffffff, bytes)
        bytes.bytesize
      rescue Exception => error # Transport Ruby exceptions without unwinding through C.
        @callback_error ||= error
        0
      end
    end

    def cancel_operation(_caller)
      begin
        cancelled = @callback_error || @cancellation&.call
        @cancelled ||= !!cancelled
        cancelled ? 1 : 0
      rescue Exception => error
        @callback_error ||= error
        1
      end
    end
  end

  # A linked Wasm module that can export multiple Tree-sitter languages.
  #
  # Obtain one from Runtime#load_grammar or Runtime#load_grammar_bytes.
  # Its languages share one module instance until the runtime is closed.
  class Grammar
    # @return [Runtime] owning runtime
    attr_reader :runtime

    # @api private
    def initialize(runtime:, linked:)
      @runtime = runtime
      @module = linked
      @languages = {}
    end

    # Selects a tree_sitter_<name> export and validates its language ABI.
    #
    # Repeated selections of the same name return the identical Language.
    # A failed selection leaves the module available for other selections.
    # The engine supports language ABI 13 through 15.
    # @param name [String] C identifier naming the language export
    # @return [Language]
    # @raise [ArgumentError] name is not a C identifier
    # @raise [LanguageLoadError] the language export is missing, fails, or returns
    #   an invalid or ABI-incompatible language
    # @raise [ClosedError] the runtime is closed
    def language(name)
      unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        raise ArgumentError, 'Language name must be a C identifier'
      end
      name = name.dedup
      @runtime.with_backend do |backend|
        next @languages[name] if @languages.key?(name)
        entrypoint = @module.instance.export("tree_sitter_#{name}")
        raise LanguageLoadError, "Missing grammar export tree_sitter_#{name}" unless entrypoint
        address = entrypoint.to_func.call & 0xffffffff
        unless address >= @module.memory_base && address + 4 <= @module.memory_base + @module.memory_size
          raise LanguageLoadError, 'Grammar returned a language pointer outside its data region'
        end
        abi_version = backend.memory.read_u32(address)
        unless backend.support_abi_version?(abi_version)
          raise LanguageLoadError, "Grammar ABI #{abi_version} is unsupported"
        end
        @languages[name] = Language.new(
          runtime: @runtime,
          name:,
          address:,
          abi_version:,
          metadata: language_metadata(address),
          symbol_count: backend.invoke('mallorn_language_symbol_count', address),
          field_count: backend.invoke('mallorn_language_field_count', address),
          state_count: backend.invoke('mallorn_language_state_count', address)
        )
      end
    rescue Wasmtime::Error => error
      raise LanguageLoadError, "Cannot select language #{name}: #{error.message}"
    end

    private

    def language_metadata(address)
      metadata_pointer = @runtime.pointer('mallorn_language_metadata', address)
      return nil if metadata_pointer.zero?

      version = @runtime.memory.read(metadata_pointer, 3).unpack('C3')
      { major_version: version[0], minor_version: version[1], patch_version: version[2] }.freeze
    end
  end

  # A loaded language shared by parsers, trees, and queries.
  #
  # Obtain one from {Grammar#language}, {Runtime#load_language},
  # or {Runtime#load_language_bytes}.
  class Language
    # Tree-sitter TSSymbolType values.
    SYMBOL_TYPE_REGULAR = 0
    SYMBOL_TYPE_ANONYMOUS = 1
    SYMBOL_TYPE_SUPERTYPE = 2
    SYMBOL_TYPE_AUXILIARY = 3

    # @return [Runtime] owning runtime
    attr_reader :runtime

    # @return [String] name supplied when loading the grammar
    attr_reader :name

    # @return [Integer] Tree-sitter language ABI version
    attr_reader :abi_version

    # @return [Hash{Symbol => Integer}, nil] generated :major_version,
    #   :minor_version, and :patch_version, or nil for older grammars
    attr_reader :metadata

    # @return [Integer] number of grammar symbols
    attr_reader :symbol_count

    # @return [Integer] number of field names (field ID zero means no field)
    attr_reader :field_count

    # @return [Integer] number of parser states
    attr_reader :state_count

    # @api private
    attr_reader :address

    # @api private
    def initialize(runtime:, name:, address:, abi_version:, metadata:, symbol_count:, field_count:, state_count:)
      @runtime = runtime
      @name = name
      @address = address
      @abi_version = abi_version
      @metadata = metadata
      @symbol_count = symbol_count
      @field_count = field_count
      @state_count = state_count
    end

    # @param symbol_id [Integer] ID below symbol_count, or 65535 for ERROR
    # @return [String] grammar name of this symbol
    # @raise [ArgumentError] the symbol ID is invalid
    def symbol_name(symbol_id)
      validate_symbol(symbol_id)
      @runtime.with_backend { |backend| backend.cstring(backend.pointer('mallorn_language_symbol_name', @address, symbol_id)) }
    end

    # @param symbol_id [Integer] ID below symbol_count, or 65535 for ERROR
    # @return [Boolean] whether the symbol denotes a named node or supertype
    # @raise [ArgumentError] the symbol ID is invalid
    def symbol_named?(symbol_id)
      type = symbol_type(symbol_id)
      type == SYMBOL_TYPE_REGULAR || type == SYMBOL_TYPE_SUPERTYPE
    end

    # @param symbol_id [Integer] ID below symbol_count, or 65535 for ERROR
    # @return [Boolean] whether nodes of this symbol are exposed in trees
    # @raise [ArgumentError] the symbol ID is invalid
    def symbol_visible?(symbol_id)
      type = symbol_type(symbol_id)
      type == SYMBOL_TYPE_REGULAR || type == SYMBOL_TYPE_ANONYMOUS
    end

    # @param field_id [Integer] ID in 0..field_count
    # @return [String, nil] field name; nil for ID zero
    # @raise [ArgumentError] the field ID is invalid
    def field_name(field_id)
      @runtime.with_backend do |backend|
        pointer = backend.pointer('mallorn_language_field_name', @address, field_id)
        backend.cstring(pointer) unless pointer.zero?
      end
    end

    # @param name [String] field name
    # @return [Integer, nil] field ID, or nil if the field is absent
    def field_id(name)
      name = name.encode(Encoding::UTF_8)
      @runtime.with_backend do |backend|
        backend.buffer(name) do |buffer|
          id = backend.invoke('mallorn_language_field_id', @address, buffer, name.bytesize)
          id.zero? ? nil : id
        end
      end
    end

    # @param state [Integer] parse state below state_count
    # @param symbol_id [Integer] grammar symbol ID, usually Node#grammar_symbol_id
    # @return [Integer] state reached by consuming the symbol, or zero if none
    # @raise [ArgumentError] an ID is invalid
    # @see #lookahead
    def next_state(state, symbol_id)
      validate_symbol(symbol_id)
      @runtime.with_backend { |backend| backend.invoke('mallorn_language_next_state', @address, state, symbol_id) }
    end

    # @param state [Integer] parse state below state_count
    # @return [Enumerator<Integer>] valid next grammar symbol IDs
    # @raise [ArgumentError] state is invalid
    # @example
    #   language.lookahead(node.parse_state).map { |id| language.symbol_name(id) }
    def lookahead(state)
      symbols = @runtime.with_backend do |backend|
        backend.buffer(4) do |count|
          pointer = backend.pointer('mallorn_language_lookahead', @address, state, count)
          begin
            backend.memory.read(pointer, backend.memory.read_u32(count) * 4).unpack('L<*')
          ensure
            backend.invoke('free', pointer)
          end
        end
      end
      symbols.each
    end

    # @param pattern [String] query source; transcoded to UTF-8
    # @return [Query] compiled query
    # @raise [QueryError] invalid query syntax, node type, field, capture, or structure
    # @see Query#cursor
    def query(pattern)
      Query.new(language: self, pattern: pattern)
    end

    private

    def validate_symbol(value)
      raise ArgumentError, 'Unknown symbol ID' unless value < @symbol_count || value == 0xffff
    end

    def symbol_type(value)
      validate_symbol(value)
      @runtime.with_backend { |backend| backend.invoke('mallorn_language_symbol_type', @address, value) }
    end
  end

  # Parses one language, reusing edited syntax trees when supplied.
  #
  # Parsers cannot execute concurrently or reentrantly; use independent parsers for
  # independent parse operations.
  class Parser
    # @return [Language] language used for every parse
    attr_reader :language

    # @param language [Language] loaded grammar
    # @raise [ClosedError] its runtime is closed
    # @see #parse
    def initialize(language:)
      @language = language
      @operation = Mutex.new
      @handle = language.runtime.with_backend do |backend|
        address = backend.pointer('mallorn_parser_new')
        if backend.invoke('mallorn_parser_set_language', address, language.address).zero?
          backend.invoke('mallorn_parser_delete', address)
          raise IncompatibleLanguageError, 'Parser rejected language'
        end
        Internal::Handle.new(language.runtime, 'mallorn_parser_delete', address)
      end
    end

    # Parses source text into a syntax tree.
    #
    # Input is a String (snapshotted) or caller-owned stable revision responding
    # to encoding and read_at(byte_offset, point:). nil/empty means EOF. Reads
    # can repeat, seek backwards, and split characters. All coordinates are bytes.
    # old_tree must be edited to the new revision before reuse. [] ranges are
    # rejected; nil parses the entire source. Cancellation resets the parser.
    # @param source [String, #read_at] String or stable revision exposing encoding
    #   and read_at(byte_offset, point:). Returned fragments must carry the same
    #   supported Encoding. nil/empty means EOF. Reads can seek or repeat; chunks
    #   can split UTF-8 characters, UTF-16 code units, or surrogate pairs.
    # @param old_tree [Tree, nil] reuse tree, edited to describe every source change;
    #   must use the identical language object, runtime, and Encoding
    # @param included_ranges [Array<Span>, nil] sorted nonoverlapping full-source
    #   ranges, or nil to parse the whole source; [] is rejected
    # @param cancellation [#call, nil] zero-argument callable; truthy cancels parsing
    # @return [Tree] syntax snapshot, including when source contains syntax errors
    # @raise [UnsupportedEncodingError] source or returned fragments have an
    #   unsupported/different encoding, or old_tree uses another encoding
    # @raise [IncompatibleRuntimeError] old_tree belongs to another runtime
    # @raise [IncompatibleLanguageError] old_tree uses another language object
    # @raise [ArgumentError] included ranges are empty, reversed, or overlapping
    # @raise [CancelledError] cancelled; parser state is reset before raising
    # @raise [ClosedError] parser or runtime is closed
    # @raise [Error] the parser is already in use or a callback reenters the runtime
    # @note Callback exceptions propagate unchanged after the native operation
    #   returns. Caller-owned revisions must remain stable for their trees' lifetimes.
    # @example Contiguous UTF-16 input
    #   tree = parser.parse('const café = 1;'.encode(Encoding::UTF_16LE))
    #   tree.root_node.end_byte # counts UTF-16 bytes
    # @example Consumer-owned piece storage
    #   input_class = Data.define(:pieces, :encoding) do
    #     def read_at(offset, point:)
    #       pieces.each do |piece|
    #         return piece.byteslice(offset..) if offset < piece.bytesize
    #         offset -= piece.bytesize
    #       end
    #       nil
    #     end
    #   end
    #   input = input_class.new(['let ', 'name', ' = 1;'], Encoding::UTF_8)
    #   tree = parser.parse(input)
    #   tree.root_node.text # => 'let name = 1;'
    # @see Tree#edited
    # @see Tree#changed_ranges
    # @see Node#has_error?
    def parse(source, old_tree: nil, included_ranges: nil, cancellation: nil)
      operate do
        source, encoding = Internal.input(source)
        ranges = Internal.pack_ranges(included_ranges)
        old_tree&.compatible!(@language, encoding)
        @language.runtime.with_backend do |backend|
          parser = @handle.address
          address = 0
          begin
            backend.buffer(ranges || '') do |buffer|
              count = ranges ? ranges.bytesize / 24 : 0
              if backend.invoke('mallorn_parser_ranges', parser, buffer, count).zero?
                raise ArgumentError, 'Invalid included ranges'
              end
            end
            Internal.cancel!(cancellation)
            read = lambda do |offset, point, capacity|
              Internal.cancel!(cancellation)
              Internal.read(source, encoding, offset, point, capacity)
            end
            backend.with_callbacks(read: read, cancellation: cancellation) do
              address = backend.pointer('mallorn_parser_parse', parser, old_tree ? old_tree.address : 0,
                                        SUPPORTED_ENCODINGS.index(encoding))
            end
            raise Error, 'Tree-sitter failed to allocate a syntax tree' if address.zero?
            actual_ranges = ranges ? backend.ranges('mallorn_tree_ranges', address) : nil
            Tree.new(runtime: @language.runtime, language: @language, encoding: encoding,
                     source: source, address: address, included_ranges: actual_ranges)
          rescue Exception
            backend.invoke('mallorn_tree_delete', address) unless address.zero?
            backend.invoke('mallorn_parser_reset', parser)
            raise
          end
        end
      end
    end

    # Resets any retained parse state.
    #
    # @return [self]
    # @raise [ClosedError] parser or runtime is closed
    # @raise [Error] this parser is already in use
    def reset
      operate { @language.runtime.with_backend { |backend| backend.invoke('mallorn_parser_reset', @handle.address) } }
      self
    end

    # Closes this object and releases its native resources.
    #
    # This method is idempotent.
    #
    # @return [nil]
    # @raise [Error] this parser is currently parsing or resetting
    def close
      operate { @handle.close }
      nil
    end

    # @return [Boolean] whether this object or its owning runtime is closed
    def closed?
      @handle.closed?
    end

    private

    def operate
      raise Error, 'Parser is already in use' unless @operation.try_lock
      begin
        yield
      ensure
        @operation.unlock
      end
    end
  end

  # An immutable syntax snapshot.
  #
  # Nodes retain their tree and its source.
  # A tree remains usable after its parser is closed. It is released by GC
  # or by closing its owning runtime.
  class Tree
    # @return [Runtime] owning runtime
    attr_reader :runtime

    # @return [Language] grammar used to parse this snapshot
    attr_reader :language

    # @return [Encoding] original source encoding
    attr_reader :encoding

    # @return [String, #read_at, nil] frozen input String, retained caller-owned
    #   revision, or nil for an edited intermediate tree
    attr_reader :source

    # @return [Array<Span>, nil] frozen included ranges, or nil for whole-source parsing
    attr_reader :included_ranges

    # @api private
    def initialize(runtime:, language:, encoding:, source:, address:, included_ranges: nil)
      @runtime, @language, @encoding, @source = runtime, language, encoding, source
      @included_ranges = included_ranges
      @handle = Internal::Handle.new(runtime, 'mallorn_tree_delete', address)
    end

    # @api private
    def address
      @handle.address
    end

    # @api private
    def compatible!(language, encoding = @encoding)
      raise IncompatibleRuntimeError, 'Objects belong to different runtimes' unless @runtime.equal?(language.runtime)
      raise IncompatibleLanguageError, 'Objects use different languages' unless @language.equal?(language)
      raise UnsupportedEncodingError, 'Old tree uses a different encoding' unless @encoding == encoding
      @runtime.check_open!
    end

    # @return [Node] root of this snapshot
    # @raise [ClosedError] runtime is closed
    def root_node
      @runtime.with_backend do |backend|
        bytes = backend.node_result { |output| backend.invoke('mallorn_tree_root', address, output) }
        Node.new(tree: self, bytes: bytes)
      end
    end

    # Returns a cheap independent snapshot sharing immutable syntax storage.
    # @return [Tree] a copy retaining the same source revision and encoding
    def copy
      @runtime.with_backend do |backend|
        Tree.new(runtime: @runtime, language: @language, encoding: @encoding, source: @source,
                 address: backend.pointer('mallorn_tree_copy', address), included_ranges: @included_ranges)
      end
    end

    # Copies a tree and adjusts its coordinates for reuse.
    #
    # Existing nodes and snapshots keep their coordinates. Each edit uses the
    # previous edit's output coordinates. The intermediate tree has no source.
    # Node#text becomes available after reparsing.
    # @param edits [Array<InputEdit>] sequential edits, each expressed relative
    #   to the preceding edit's output revision
    # @return [Tree] independent edited reuse tree, with source == nil
    # @raise [ArgumentError] an edit has negative, reversed, or overflowing coordinates
    # @example Replace a number with an array
    #   old = parser.parse('let x = 1;')
    #   edit = InputEdit.new(
    #     start_byte: 8, old_end_byte: 9, new_end_byte: 14,
    #     start_point: Point.new(0, 8),
    #     old_end_point: Point.new(0, 9), new_end_point: Point.new(0, 14)
    #   )
    #   reuse = old.edited(edit)
    #   updated = parser.parse('let x = [1, 2];', old_tree: reuse)
    #   reuse.changed_ranges(updated)
    # @see Parser#parse
    def edited(*edits)
      packed = edits.map { |edit| Internal.pack_edit(edit) }
      @runtime.with_backend do |backend|
        pointer = backend.pointer('mallorn_tree_copy', address)
        begin
          packed.each do |edit|
            backend.buffer(edit) { |buffer| backend.invoke('mallorn_tree_edit', pointer, buffer) }
          end
          ranges = @included_ranges ? backend.ranges('mallorn_tree_ranges', pointer) : nil
          Tree.new(runtime: @runtime, language: @language, encoding: @encoding, source: nil,
                   address: pointer, included_ranges: ranges)
        rescue Exception
          backend.invoke('mallorn_tree_delete', pointer)
          raise
        end
      end
    end

    # Returns syntactic changes in new-tree coordinates.
    # @param new_tree [Tree] freshly parsed tree using this edited reuse tree
    # @return [Array<Span>] frozen syntactic change ranges in the new revision
    # @raise [IncompatibleRuntimeError] runtimes differ
    # @raise [IncompatibleLanguageError] language objects differ
    # @raise [UnsupportedEncodingError] source encodings differ
    # @note These are syntactic differences, not a log of all textual edits.
    def changed_ranges(new_tree)
      new_tree.compatible!(@language, @encoding)
      @runtime.with_backend { |backend| backend.ranges('mallorn_tree_changed_ranges', address, new_tree.address) }
    end
  end

  # An immutable view into a tree snapshot.
  #
  # Text access retains the original source encoding. Coordinates are source
  # bytes. Closing the runtime invalidates node operations even when immutable
  # property values were previously cached.
  class Node
    # @return [Tree] retained owning snapshot
    attr_reader :tree

    # @api private
    attr_reader :bytes

    # @api private
    def initialize(tree:, bytes:)
      @tree, @bytes = tree, bytes
    end

    # Checks whether both objects identify the same node in the same snapshot.
    # @param other [Object]
    # @return [Boolean] whether both nodes identify the same node in the same snapshot
    # @note Copies and edited trees have independent node identities.
    def ==(other)
      other.is_a?(Node) && @tree.equal?(other.tree) && @bytes.byteslice(16, 4) == other.bytes.byteslice(16, 4)
    end
    alias eql? ==

    # @return [Integer] hash consistent with #== and #eql?
    def hash
      [@tree.object_id, @bytes.byteslice(16, 4)].hash
    end

    # @return [String] public node type, including aliases
    def type
      info[0]
    end

    # @return [String] underlying grammar node type before aliases
    def grammar_type
      info[1]
    end

    # @return [Integer] public symbol ID, including aliases
    def symbol_id
      info[2]
    end

    # @return [Integer] underlying grammar symbol ID for language transitions
    def grammar_symbol_id
      info[3]
    end

    # @return [Integer] inclusive byte offset in the full source
    def start_byte
      info[4]
    end

    # @return [Integer] exclusive byte offset in the full source
    def end_byte
      info[5]
    end

    # @return [Point] inclusive full-source position
    def start_point
      values = info
      Point.new(values[6], values[7])
    end

    # @return [Point] exclusive full-source position
    def end_point
      values = info
      Point.new(values[8], values[9])
    end

    # @return [Span] half-open source interval
    def span
      Span.new(start_byte, end_byte, start_point, end_point)
    end

    # @return [Boolean] whether this is a named grammar node
    def named?
      (info[10] & 1) != 0
    end

    # @return [Boolean] whether this is an extra, such as a comment
    def extra?
      (info[10] & 2) != 0
    end

    # @return [Boolean] whether this node itself is an ERROR node
    def error?
      (info[10] & 4) != 0
    end

    # @return [Boolean] whether the parser inserted this node during error recovery
    def missing?
      (info[10] & 8) != 0
    end

    # @return [Boolean] whether this node or any descendant contains an error
    def has_error?
      (info[10] & 16) != 0
    end

    # @return [Boolean] whether an edit marked this node or its descendants as changed
    def has_changes?
      (info[10] & 32) != 0
    end

    # @return [Integer] parser state before this node
    def parse_state
      info[11]
    end

    # @return [Integer] parser state after this node
    def next_parse_state
      info[12]
    end

    # @return [Node, nil] parent, or nil at the root
    def parent
      related('mallorn_node_parent')
    end

    # @return [Integer] number of children, including anonymous punctuation
    def child_count
      info[13]
    end

    # @return [Integer] number of named children
    def named_child_count
      info[14]
    end

    # @return [Node, nil] first child, including anonymous nodes
    def first_child
      child(0)
    end

    # @return [Node, nil] last child, including anonymous nodes
    def last_child
      count = child_count
      count.zero? ? nil : child(count - 1)
    end

    # @return [Node, nil] first named child
    def first_named_child
      named_child(0)
    end

    # @return [Node, nil] last named child
    def last_named_child
      count = named_child_count
      count.zero? ? nil : named_child(count - 1)
    end

    # @return [Node, nil] next sibling, including anonymous nodes
    def next_sibling
      related('mallorn_node_next_sibling')
    end

    # @return [Node, nil] previous sibling, including anonymous nodes
    def previous_sibling
      related('mallorn_node_previous_sibling')
    end

    # @return [Node, nil] next named sibling
    def next_named_sibling
      related('mallorn_node_next_named_sibling')
    end

    # @return [Node, nil] previous named sibling
    def previous_named_sibling
      related('mallorn_node_previous_named_sibling')
    end

    # @param index [Integer] nonnegative zero-based child index
    # @return [Node, nil] child, or nil if absent
    # @raise [ArgumentError] index is negative or exceeds wasm32
    def child(index)
      related('mallorn_node_child', index)
    end

    # @param index [Integer] nonnegative zero-based child index
    # @return [Node, nil] child, or nil if absent
    # @raise [ArgumentError] index is negative or exceeds wasm32
    def named_child(index)
      related('mallorn_node_named_child', index)
    end

    # @param name [String] grammar field name
    # @return [Node, nil] first child assigned this field, or nil if absent
    def child_by_field_name(name)
      id = @tree.language.field_id(name)
      id ? related('mallorn_node_child_by_field_id', id) : nil
    end

    # @param name [String] grammar field name
    # @return [Array<Node>] every child assigned this field, in source order
    def children_by_field_name(name)
      id = @tree.language.field_id(name)
      return [] unless id
      cursor = walk
      result = []
      begin
        if cursor.goto_first_child
          loop do
            result << cursor.node if cursor.field_id == id
            break unless cursor.goto_next_sibling
          end
        end
      ensure
        cursor.close
      end
      result
    end

    # @param index [Integer] nonnegative index among all children
    # @return [String, nil] field name, or nil if the field/child is absent
    def field_name_for_child(index)
      @tree.runtime.with_backend do |backend|
        backend.buffer(@bytes) do |input|
          pointer = backend.pointer('mallorn_node_field', input, index)
          backend.cstring(pointer) unless pointer.zero?
        end
      end
    end

    # Yields child nodes in source order.
    #
    # Fetches all child values in one backend call and releases the runtime lock
    # before yielding. No consumer block runs while Wasm is borrowed.
    # @param named [Boolean] include only named children if true
    # @yield [child] each child in source order
    # @yieldparam child [Node]
    # @return [self, Enumerator<Node>] self with a block, otherwise an Enumerator
    # @example
    #   node.each_child(named: true).map(&:type)
    def each_child(named: false, &block)
      return enum_for(__method__, named: named) unless block
      children = @tree.runtime.with_backend do |backend|
        backend.buffer(@bytes) do |input|
          backend.buffer(4) do |count|
            pointer = backend.pointer('mallorn_node_children', input, named ? 1 : 0, count)
            begin
              data = backend.memory.read(pointer, backend.memory.read_u32(count) * 24)
              Array.new(data.bytesize / 24) { |index| Node.new(tree: @tree, bytes: data.byteslice(index * 24, 24).freeze) }
            ensure
              backend.invoke('free', pointer)
            end
          end
        end
      end
      children.each(&block)
      self
    end

    # @param first [Integer] inclusive full-source byte offset
    # @param last [Integer] exclusive full-source byte offset
    # @param named [Boolean] restrict the result to named nodes
    # @return [Node, nil] smallest descendant spanning the range
    # @raise [ArgumentError] coordinates are reversed, negative, or exceed wasm32
    def descendant_for_byte_range(first, last, named: false)
      Internal.ordered(first, last)
      related(named ? 'mallorn_node_named_descendant_for_byte_range' : 'mallorn_node_descendant_for_byte_range', first, last)
    end

    # @param first [Point] inclusive full-source position
    # @param last [Point] exclusive full-source position
    # @param named [Boolean] restrict the result to named nodes
    # @return [Node, nil] smallest descendant spanning the range
    # @raise [ArgumentError] coordinates are reversed, negative, or exceed wasm32
    def descendant_for_point_range(first, last, named: false)
      Internal.ordered(first, last)
      related(named ? 'mallorn_node_named_descendant_for_point_range' : 'mallorn_node_descendant_for_point_range',
              first.row, first.column, last.row, last.column)
    end

    # @return [TreeCursor] cursor initially positioned on this node
    # @see TreeCursor#close
    def walk
      TreeCursor.new(self)
    end

    # @return [String] this node's bytes, assembled in the original source encoding
    # @raise [Error] tree is an edited intermediate snapshot or source ends early
    # @see #each_text_chunk
    def text
      result = String.new(encoding: @tree.encoding)
      each_text_chunk { |chunk| result << chunk }
      result
    end

    # Yields the source bytes for this node in chunks.
    #
    # A caller-owned source must remain stable throughout the tree's lifetime.
    # Fragments may split characters.
    # @yield [chunk] encoded fragment covering part of this node
    # @yieldparam chunk [String] original source encoding; may split characters
    # @return [self, Enumerator<String>] self with a block, otherwise an Enumerator
    # @raise [Error] tree has no source revision or source ends before the node range
    # @see #text
    def each_text_chunk(&block)
      return enum_for(__method__) unless block
      @tree.runtime.check_open!
      source = @tree.source or raise Error, 'Edited reuse tree has no source text'
      offset, last, point = start_byte, end_byte, start_point
      previous_byte = nil
      while offset < last
        bytes = Internal.read(source, @tree.encoding, offset, point, [16384, last - offset].min, previous_byte: previous_byte)
        raise Error, 'Source ended before the node range' if bytes.empty?
        yield bytes.dup.force_encoding(@tree.encoding)
        point = Internal.advance(point, bytes, @tree.encoding, offset, previous_byte: previous_byte)
        previous_byte = bytes.byteslice(-1, 1)
        offset += bytes.bytesize
      end
      self
    end

    # @return [String] UTF-8 S-expression describing this node and its descendants
    def to_sexp
      @tree.runtime.with_backend do |backend|
        backend.buffer(@bytes) do |input|
          pointer = backend.pointer('mallorn_node_string', input)
          begin
            backend.cstring(pointer)
          ensure
            backend.invoke('free', pointer)
          end
        end
      end
    end

    private

    def info
      @tree.runtime.check_open!
      @info ||= @tree.runtime.with_backend do |backend|
        backend.buffer(@bytes) do |input|
          backend.buffer(60) do |output|
            backend.invoke('mallorn_node_info', input, output)
            values = backend.memory.read(output, 60).unpack('L<*')
            values[0] = backend.cstring(values[0])
            values[1] = backend.cstring(values[1])
            values.freeze
          end
        end
      end
    end

    def related(function, *arguments)
      @tree.runtime.with_backend do |backend|
        backend.buffer(@bytes) do |input|
          result = backend.node_result { |output| backend.invoke(function, input, *arguments, output) }
          result ? Node.new(tree: @tree, bytes: result) : nil
        end
      end
    end
  end

  # A cursor for stateful tree traversal.
  #
  # Movement returns true on success and false otherwise.
  class TreeCursor
    # @return [Tree] snapshot currently retained by this cursor
    attr_reader :tree

    # @api private
    # @see Node#walk
    def initialize(node, handle: nil)
      @tree = node.tree
      if handle
        @handle = handle
        return
      end
      @handle = @tree.runtime.with_backend do |backend|
        pointer = backend.buffer(node.bytes) { |input| backend.pointer('mallorn_cursor_new', input) }
        Internal::Handle.new(@tree.runtime, 'mallorn_cursor_delete', pointer)
      end
    end

    # @return [Node] current node
    def node
      @tree.runtime.with_backend do |backend|
        bytes = backend.node_result { |output| backend.invoke('mallorn_cursor_node', @handle.address, output) }
        Node.new(tree: @tree, bytes: bytes)
      end
    end

    # @return [String, nil] field assigned to the current node, or nil
    def field_name
      @tree.language.field_name(field_id)
    end

    # @return [Integer] field ID for the current node; zero if unassigned
    def field_id
      @tree.runtime.with_backend { |backend| backend.invoke('mallorn_cursor_field', @handle.address) }
    end

    # @return [Integer] depth relative to the cursor's initial/reset root
    def depth
      @tree.runtime.with_backend { |backend| backend.invoke('mallorn_cursor_depth', @handle.address) }
    end

    # Moves to the parent, stopping at this cursor's root.
    # @return [Boolean] true if moved; false leaves the position unchanged
    def goto_parent
      move('mallorn_cursor_goto_parent')
    end

    # Moves to the first child.
    # @return [Boolean] true if moved; false leaves the position unchanged
    def goto_first_child
      move('mallorn_cursor_goto_first_child')
    end

    # Moves to the last child.
    # @return [Boolean] true if moved; false leaves the position unchanged
    def goto_last_child
      move('mallorn_cursor_goto_last_child')
    end

    # Moves to the next sibling.
    # @return [Boolean] true if moved; false leaves the position unchanged
    def goto_next_sibling
      move('mallorn_cursor_goto_next_sibling')
    end

    # Moves to the previous sibling.
    # @return [Boolean] true if moved; false leaves the position unchanged
    def goto_previous_sibling
      move('mallorn_cursor_goto_previous_sibling')
    end

    # @param node [Node] new root; may be from another tree in the same runtime
    # @return [self]
    # @raise [IncompatibleRuntimeError] node belongs to another runtime
    def reset(node)
      unless node.tree.runtime.equal?(@tree.runtime)
        raise IncompatibleRuntimeError, 'Objects belong to different runtimes'
      end
      @tree.runtime.with_backend do |backend|
        backend.buffer(node.bytes) { |input| backend.invoke('mallorn_cursor_reset', @handle.address, input) }
        @tree = node.tree
      end
      self
    end

    # @return [TreeCursor] independent cursor with the same position, depth, and root
    def copy
      @tree.runtime.with_backend do |backend|
        bytes = backend.node_result { |output| backend.invoke('mallorn_cursor_node', @handle.address, output) }
        pointer = backend.pointer('mallorn_cursor_copy', @handle.address)
        handle = Internal::Handle.new(@tree.runtime, 'mallorn_cursor_delete', pointer)
        TreeCursor.new(Node.new(tree: @tree, bytes: bytes), handle: handle)
      end
    end

    # Closes this object and releases its native resources.
    #
    # This method is idempotent.
    # @return [nil]
    def close
      @handle.close
    end

    # @return [Boolean] whether this object or its owning runtime is closed
    def closed?
      @handle.closed?
    end

    private

    def move(function)
      @tree.runtime.with_backend { |backend| backend.invoke(function, @handle.address) != 0 }
    end
  end

  # A compiled Tree-sitter query.
  #
  # Independent query cursors can share the query. Query source is UTF-8.
  # Matched source text can use any supported encoding.
  class Query
    # @return [Language] grammar used to compile this query
    attr_reader :language

    # @return [Integer] number of query patterns
    attr_reader :pattern_count

    # @return [Array<String>] frozen capture names, ordered by capture ID
    attr_reader :capture_names

    # @param language [Language] grammar whose symbols the query references
    # @param pattern [String] query source, transcoded to UTF-8
    # @raise [QueryError] compilation fails; byte_offset and error_type describe it
    # @see Language#query
    def initialize(language:, pattern:)
      pattern = pattern.encode(Encoding::UTF_8)
      @language = language
      @predicates = []
      language.runtime.with_backend do |backend|
        address = 0
        begin
          backend.buffer(pattern) do |source|
            backend.buffer(8) do |error|
              address = backend.pointer('mallorn_query_new', language.address, source, pattern.bytesize, error)
              if address.zero?
                offset, kind = backend.memory.read(error, 8).unpack('L<2')
                type = [:none, :syntax, :node_type, :field, :capture, :structure, :language].fetch(kind)
                raise QueryError.new("Invalid query #{type} at byte #{offset}", byte_offset: offset, error_type: type)
              end
            end
          end
          @pattern_count = backend.invoke('mallorn_query_pattern_count', address)
          count = backend.invoke('mallorn_query_capture_count', address)
          @capture_names = Array.new(count) { |index| query_string(backend, 'mallorn_query_capture_name', address, index) }.freeze
          @predicates = Array.new(@pattern_count) do |index|
            backend.buffer(4) do |length|
              pointer = backend.pointer('mallorn_query_predicates', address, index, length)
              steps = backend.memory.read(pointer, backend.memory.read_u32(length) * 8).unpack('L<*')
              predicates = []
              current = []
              steps.each_slice(2) do |kind, id|
                case kind
                when 0
                  name, *arguments = current
                  raise QueryError, 'Predicate must start with a name' unless name.is_a?(String)
                  predicates << Predicate.new(name, arguments.freeze)
                  current = []
                when 1
                  current << CaptureReference.new(@capture_names.fetch(id))
                when 2
                  current << query_string(backend, 'mallorn_query_string', address, id)
                end
              end
              predicates.freeze
            end
          end.freeze
          @handle = Internal::Handle.new(language.runtime, 'mallorn_query_delete', address)
        rescue Exception
          backend.invoke('mallorn_query_delete', address) unless address.zero?
          raise
        end
      end
    end

    # @api private
    def address
      @handle.address
    end

    # Returns the predicates and directives for a pattern.
    #
    # Unknown operations retain their typed capture references.
    # @param pattern_index [Integer] zero-based index below pattern_count
    # @return [Array<Predicate>] frozen operations with literal or CaptureReference arguments
    # @raise [ArgumentError] pattern index is invalid
    # @see #cursor
    def predicates(pattern_index)
      @language.runtime.check_open!
      @handle.address
      @predicates.fetch(pattern_index)
    end

    # Creates an independent execution cursor.
    #
    # Custom handlers receive (Predicate, Match). Predicates return a truthy
    # value to accept; directives ending in ! return a property Hash or nil.
    # Standard text predicates are eq?,
    # not-eq?, match?, not-match?, their any- variants, and any-of?/not-any-of?.
    # Without any-, every captured node must satisfy the comparison. Regex predicates
    # use RE2 syntax; node text is transcoded to UTF-8 for evaluation.
    # set! assigns a literal property key and optional value to each match.
    #
    # Unknown operations, including property predicates such as is?, require
    # handlers; they are never silently ignored. Handlers may override builtins.
    # @param handlers [Hash{String => #call}] operation names without #,
    #   mapped to callables receiving (Predicate, Match). Predicate handlers return
    #   truthy to accept. Directive handlers ending in ! return a property Hash or nil.
    #   The supplied Hash is retained by reference.
    # @return [QueryCursor]
    # @raise [QueryError] unhandled operation, malformed predicate, or invalid regexp
    # @example Standard predicates and match properties
    #   query = language.query(<<~'QUERY')
    #     ((identifier) @name
    #       (#match? @name "^answer$")
    #       (#set! role "local"))
    #   QUERY
    #   cursor = query.cursor
    #   cursor.matches(tree.root_node).each do |match|
    #     match.properties # => { 'role' => 'local' }
    #     match.captures.map { |capture| [capture.name, capture.node.text] }
    #   end
    #   cursor.close
    #   query.close
    # @example Custom predicate
    #   query = language.query('((identifier) @id (#keep? @id))')
    #   cursor = query.cursor(handlers: {
    #     'keep?' => ->(predicate, match) { match.captures.first.node.text == 'wanted' }
    #   })
    def cursor(handlers: {})
      QueryCursor.new(query: self, handlers: handlers)
    end

    # Closes this object and releases its native resources.
    #
    # This method is idempotent.
    # @return [nil]
    # @note Associated cursors cannot execute after the query is closed.
    def close
      @handle.close
    end

    # @return [Boolean] whether this object or its owning runtime is closed
    def closed?
      @handle.closed?
    end

    private

    def query_string(backend, function, address, index)
      backend.buffer(4) do |length|
        pointer = backend.pointer(function, address, index, length)
        backend.string(pointer, backend.memory.read_u32(length))
      end
    end
  end

  # Executes a query against one node's source snapshot at a time.
  #
  # Execution begins when a returned enumerator is consumed. A cursor cannot
  # execute concurrently or reentrantly, including while an enumerator is paused.
  class QueryCursor
    TEXT_PREDICATES = [
      'eq?', 'not-eq?', 'any-eq?', 'any-not-eq?',
      'match?', 'not-match?', 'any-match?', 'any-not-match?',
      'any-of?', 'not-any-of?'
    ].freeze
    private_constant :TEXT_PREDICATES

    # @param query [Query] compiled query retained by this cursor
    # @param handlers [Hash] custom predicate/directive handlers
    # @see Query#cursor
    def initialize(query:, handlers: {})
      @query = query
      @handlers = handlers
      @operation = Mutex.new
      @regexps = {}
      @exceeded = false
      query.pattern_count.times do |index|
        query.predicates(index).each { |predicate| validate_predicate(predicate) }
      end
      @handle = query.language.runtime.with_backend do |backend|
        query.address
        Internal::Handle.new(query.language.runtime, 'mallorn_query_cursor_delete', backend.pointer('mallorn_query_cursor_new'))
      end
    end

    # Returns a lazy enumerator of query matches.
    #
    # Half-open ranges filter overlapping matches. Individual captures may lie
    # outside those ranges. The cursor cannot execute concurrently or
    # reentrantly. Consumer blocks run unlocked.
    # @param node [Node] search subtree; must use the query's identical language object
    # @param byte_range [Range<Integer>, nil] finite half-open byte range; matches
    #   can extend beyond it if they overlap
    # @param point_range [Range<Point>, nil] finite half-open point range, intersected
    #   with byte_range when both are supplied
    # @param match_limit [Integer, nil] positive maximum in-progress matches; nil
    #   allows the native maximum. Excess matches may be dropped.
    # @param max_start_depth [Integer, nil] maximum pattern-root search depth;
    #   zero searches only at node; nil imposes no depth limit
    # @param cancellation [#call, nil] zero-argument callable; truthy cancels execution
    # @return [Enumerator<Match>] complete, predicate-checked matches in native match order
    # @raise [ArgumentError] ranges are inclusive/unbounded/reversed or limits invalid
    # @raise [IncompatibleRuntimeError] node belongs to another runtime
    # @raise [IncompatibleLanguageError] node uses another language object
    # @raise [CancelledError] execution was cancelled; cursor remains reusable
    # @raise [ClosedError] cursor, query, or runtime is closed
    # @raise [Error] another execution is active, or text predicates need an absent source
    # @note Predicates inspect each complete match's source revision. Callback and
    #   handler exceptions propagate unchanged. Early termination releases execution.
    # @example Filter a point interval
    #   interval = Point.new(1, 0)...Point.new(2, 0)
    #   cursor.matches(tree.root_node, point_range: interval).each do |match|
    #     match.captures.each { |capture| puts capture.node.text }
    #   end
    # @see #exceeded_match_limit?
    def matches(node, byte_range: nil, point_range: nil, match_limit: nil,
                max_start_depth: nil, cancellation: nil)
      Enumerator.new do |output|
        execute(node, false, byte_range, point_range, match_limit, max_start_depth, cancellation) { |match| output << match }
      end
    end

    # Returns query captures in source order.
    #
    # Buffers completed, predicate-checked matches before sorting their captures
    # by source position and pattern index. Use matches for streaming results.
    # Captures outside the filtering ranges are excluded, even when their match
    # spans the range. Repeated captures and captures from distinct matches remain.
    # @param node [Node] subtree with the query's identical language object
    # @param byte_range [Range<Integer>, nil] finite half-open source byte range
    # @param point_range [Range<Point>, nil] finite half-open source point range
    # @param match_limit [Integer, nil] maximum in-progress matches
    # @param max_start_depth [Integer, nil] maximum search start depth
    # @param cancellation [#call, nil] zero-argument cancellation callable
    # @return [Enumerator<Capture>] source order, with pattern order breaking ties
    # @note Buffers completed accepted matches before emitting captures, so predicates
    #   see all quantified arguments. Use matches for streaming large result sets.
    # @see #matches
    def captures(node, byte_range: nil, point_range: nil, match_limit: nil,
                 max_start_depth: nil, cancellation: nil)
      Enumerator.new do |output|
        execute(node, true, byte_range, point_range, match_limit, max_start_depth, cancellation) { |capture| output << capture }
      end
    end

    # @return [Boolean] whether the most recent execution dropped in-progress matches
    # @note Inspect after enumeration; every new execution resets the flag.
    # @see #matches
    def exceeded_match_limit?
      @query.language.runtime.check_open!
      @handle.address
      @exceeded
    end

    # Closes this object and releases its native resources.
    #
    # This method is idempotent.
    # @return [nil]
    # @raise [Error] an enumeration is still active
    def close
      raise Error, 'Query cursor is already in use' unless @operation.try_lock
      begin
        @handle.close
      ensure
        @operation.unlock
      end
    end

    # @return [Boolean] whether this object or its owning runtime is closed
    def closed?
      @handle.closed?
    end

    private

    def validate_predicate(predicate)
      name, args = predicate.name, predicate.arguments
      return if @handlers.key?(name)
      if TEXT_PREDICATES.include?(name)
        unless args.first.is_a?(CaptureReference)
          raise QueryError, "##{name} requires a capture as its first argument"
        end
        if ['any-of?', 'not-any-of?'].include?(name)
          unless args.length >= 2 && args.drop(1).all? { |value| value.is_a?(String) }
            raise QueryError, "##{name} requires literal alternatives"
          end
        elsif args.length != 2 || (name.include?('match?') && !args[1].is_a?(String))
          raise QueryError, "Invalid arguments for ##{name}"
        end
        if name.include?('match?')
          expression = @regexps[args[1]] ||= RE2::Regexp.new(args[1], log_errors: false)
          unless expression.ok?
            raise QueryError, "Invalid query regular expression: #{expression.error}"
          end
        end
      elsif name == 'set!'
        unless (1..2).cover?(args.length) && args.all? { |value| value.is_a?(String) }
          raise QueryError, '#set! requires a property name and optional literal value'
        end
      else
        raise QueryError, "Unhandled query operation ##{name}"
      end
    end

    def byte_range_limits(value)
      return [0, Internal::UINT_MAX] unless value
      unless value.exclude_end? && value.begin && value.end
        raise ArgumentError, 'Expected a finite half-open Range'
      end
      first = value.begin
      last = value.end
      Internal.ordered(first, last)
      [first, last]
    end

    def point_range_limits(value)
      return [0, 0, Internal::UINT_MAX, Internal::UINT_MAX] unless value
      unless value.exclude_end? && value.begin && value.end
        raise ArgumentError, 'Expected a finite half-open Range'
      end
      first = value.begin
      last = value.end
      Internal.ordered(first, last)
      [first.row, first.column, last.row, last.column]
    end

    def execute(node, capture_order, byte_range, point_range, match_limit, max_start_depth, cancellation)
      raise Error, 'Query cursor is already in use' unless @operation.try_lock
      begin
        node.tree.compatible!(@query.language)
        bytes = byte_range_limits(byte_range)
        points = point_range_limits(point_range)
        limit = match_limit.nil? ? Internal::UINT_MAX : match_limit
        raise ArgumentError, 'Match limit must be positive' if limit.zero?
        depth = max_start_depth.nil? ? Internal::UINT_MAX : max_start_depth
        @exceeded = false
        @handle.address
        @query.address
        Internal.cancel!(cancellation)
        return if (byte_range && byte_range.begin == byte_range.end) || (point_range && point_range.begin == point_range.end)
        runtime = @query.language.runtime
        runtime.with_backend do |backend|
          backend.buffer(node.bytes) do |input|
            backend.buffer(Internal.pack_uint32(*bytes, *points, limit, depth)) do |limits|
              backend.invoke('mallorn_query_cursor_exec', @handle.address, @query.address, input, limits)
              @tree = node.tree
            end
          end
        end
        # Tree-sitter may emit captures from unfinished quantified matches.
        # Complete matches are required before evaluating text predicates.
        # matches streams; captures buffers accepted results for source order.
        pending = []
        sequence = 0
        loop do
          Internal.cancel!(cancellation)
          raw = runtime.with_backend do |backend|
            @query.address
            backend.with_callbacks(cancellation: cancellation) do
              backend.buffer(12) do |info|
                found = backend.invoke('mallorn_query_cursor_next_match', @handle.address, info)
                @exceeded = backend.invoke('mallorn_query_cursor_exceeded', @handle.address) != 0
                unless found.zero?
                  pattern, count, pointer = backend.memory.read(info, 12).unpack('L<3')
                  data = backend.memory.read(pointer, count * 28)
                  captures = Array.new(count) do |i|
                    offset = i * 28
                    capture_id = data.unpack1('L<', offset: offset + 24)
                    Capture.new(@query.capture_names.fetch(capture_id), Node.new(tree: node.tree, bytes: data.byteslice(offset, 24).freeze))
                  end.freeze
                  Match.new(pattern, captures, {}.freeze)
                end
              end
            end
          end
          break unless raw
          accepted = evaluate(raw)
          next unless accepted
          if capture_order
            accepted.captures.each_with_index do |capture, index|
              n = capture.node
              next if n.end_byte <= bytes[0] || n.start_byte >= bytes[1]
              next if n.end_point <= Point.new(points[0], points[1]) || n.start_point >= Point.new(points[2], points[3])
              pending << [[n.start_byte, accepted.pattern_index, sequence, index], capture]
            end
            sequence += 1
          else
            yield accepted
          end
        end
        if capture_order
          pending.sort_by!(&:first)
          pending.each do |_key, capture|
            Internal.cancel!(cancellation)
            yield capture
          end
        end
      ensure
        @operation.unlock
      end
    end

    def evaluate(match)
      properties = {}
      @query.predicates(match.pattern_index).each do |predicate|
        name, args = predicate.name, predicate.arguments
        if (handler = @handlers[name])
          value = handler.call(predicate, Match.new(match.pattern_index, match.captures, properties.dup.freeze))
          if name.end_with?('!')
            properties.merge!(value) if value
          else
            return nil unless value
          end
        elsif name == 'set!'
          properties[args[0]] = args[1]
        else
          return nil unless text_predicate(predicate, match.captures)
        end
      end
      Match.new(match.pattern_index, match.captures, properties.freeze)
    end

    def texts(reference, captures)
      captures.select { |capture| capture.name == reference.name }.map { |capture| capture.node.text.encode(Encoding::UTF_8) }
    end

    def text_predicate(predicate, captures)
      name, args = predicate.name, predicate.arguments
      left = texts(args[0], captures)
      if ['any-of?', 'not-any-of?'].include?(name)
        values = args.drop(1)
        return left.all? { |text| name == 'any-of?' ? values.include?(text) : !values.include?(text) }
      end
      negate = name.include?('not-')
      results = if name.include?('match?')
        expression = @regexps.fetch(args[1])
        left.map { |text| expression.partial_match?(text) != negate }
      elsif args[1].is_a?(CaptureReference)
        right = texts(args[1], captures)
        return false unless left.length == right.length
        left.zip(right).map { |a, b| (a == b) != negate }
      else
        left.map { |text| (text == args[1]) != negate }
      end
      name.start_with?('any-') ? results.any? : results.all?
    end
  end
end

require_relative 'mallorn/wasm_linker'
