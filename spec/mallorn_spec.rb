RSpec.describe Mallorn do
  it 'exposes a valid gem version' do
    expect(Gem::Version.new(described_class::VERSION).to_s).to eq(described_class::VERSION)
  end
end

RSpec.describe 'Mallorn public API' do
  # Caller-owned piece storage: reads can begin anywhere inside a fragment.
  class Fragments
    attr_reader :encoding, :reads

    def initialize(text, width: 1)
      @encoding = text.encoding
      @parts = text.bytes.each_slice(width).map { |bytes| bytes.pack('C*').force_encoding(@encoding) }
      @width = width
      @reads = []
    end

    def read_at(offset, point:)
      @reads << [offset, point]
      part = @parts[offset / @width]
      part&.byteslice(offset % @width, @width)
    end
  end

  before(:context) do
    root = Pathname(__dir__).parent
    @grammar = root / 'node_modules/tree-sitter-javascript/tree-sitter-javascript.wasm'
  end

  around do |example|
    @runtime = Mallorn::Runtime.new
    @language = @runtime.load_language(@grammar, name: 'javascript')
    @parser = Mallorn::Parser.new(language: @language)
    example.run
  ensure
    @parser&.close
    @runtime&.close
  end

  def query_captures(pattern, source, **options)
    tree = @parser.parse(source)
    query = @language.query(pattern)
    cursor = query.cursor
    begin
      cursor.captures(tree.root_node, **options).map { |capture| capture.node.text.encode(Encoding::UTF_8) }
    ensure
      cursor.close
      query.close
    end
  end

  Mallorn::SUPPORTED_ENCODINGS.each do |encoding|
    it "parses one-byte fragments in #{encoding.name}, including split characters and surrogates" do
      text = "// 😀\nconst café = `hello ${name}`\nconst pattern = /ab+c/u\n".encode(encoding)
      input = Fragments.new(text)
      tree = @parser.parse(input)
      root = tree.root_node
      expect(root.type).to eq('program')
      expect(root.has_error?).to be(false)
      expect(root.text).to eq(text)
      expect(root.each_text_chunk.map(&:b).join.force_encoding(encoding)).to eq(text)
      expect(root.end_byte).to eq(text.bytesize)
      expect(root.end_point).to eq(Mallorn::Point.new(3, 0))
      expect(tree.source).to equal(input)
      expect(input.reads.length).to be > 10
      expect(query_captures('((identifier) @id (#eq? @id "café"))', input)).to eq(['café'])
    end

    it "incrementally reparses #{encoding.name} and leaves existing snapshots unchanged" do
      source = 'let x = 1;'.encode(encoding)
      original = @parser.parse(source)
      number = original.root_node.first_named_child.first_named_child.child_by_field_name('value')
      replacement = '[1, 2]'.encode(encoding)
      edit = Mallorn::InputEdit.new(
        number.start_byte, number.end_byte, number.start_byte + replacement.bytesize,
        number.start_point, number.end_point, Mallorn::Point.new(0, number.start_byte + replacement.bytesize)
      )
      reuse = original.edited(edit)
      updated_source = 'let x = [1, 2];'.encode(encoding)
      updated = @parser.parse(Fragments.new(updated_source, width: 3), old_tree: reuse)
      fresh = @parser.parse(updated_source)
      expect(updated.root_node.to_sexp).to eq(fresh.root_node.to_sexp)
      expect(updated.root_node.text).to eq(updated_source)
      expect(original.root_node.text).to eq(source)
      expect(number.text).to eq('1'.encode(encoding))
      expect(reuse.source).to be_nil
      expect(reuse.root_node.has_changes?).to be(true)
      expect { reuse.root_node.text }.to raise_error(Mallorn::Error, /no source/)
      expect(reuse.changed_ranges(updated)).not_to be_empty
      expect(original.copy.root_node.text).to eq(source)
    end
  end

  it 'snapshots mutable String inputs and preserves syntax errors as trees' do
    source = 'let x = 1;'
    tree = @parser.parse(source)
    source.replace('different')
    expect(tree.root_node.text).to eq('let x = 1;')
    expect(tree.source).to be_frozen
    expect(@parser.parse('let = {').root_node.has_error?).to be(true)
  end

  it 'supplies byte-based point hints when UTF-16 fragments split a newline' do
    [Encoding::UTF_16LE, Encoding::UTF_16BE].each do |encoding|
      text = "a;\nb;\nc;\n".encode(encoding)
      input = Fragments.new(text, width: 5)
      tree = @parser.parse(input)
      input.reads.clear
      expect(tree.root_node.text).to eq(text)
      input.reads.each do |offset, point|
        prefix = text.b.byteslice(0, offset - offset % 2).force_encoding(encoding).encode(Encoding::UTF_8)
        row = prefix.count("\n")
        line_start = prefix.rindex("\n")
        column = line_start ? prefix[(line_start + 1)..].encode(encoding).bytesize : prefix.encode(encoding).bytesize
        expect(point).to eq(Mallorn::Point.new(row, column + offset % 2))
      end
    end
  end

  it 'retains trees through nodes and cursors while collecting other resources' do
    node = @parser.parse('retained').root_node.first_named_child.first_named_child
    cursor = node.walk
    20.times do
      temporary = Mallorn::Parser.new(language: @language)
      temporary.parse('temporary').root_node.walk
    end
    GC.start
    expect(@parser.parse('after_gc').root_node.text).to eq('after_gc')
    @parser.close
    expect(node.text).to eq('retained')
    expect(cursor.node).to eq(node)
    cursor.close
  end

  it 'supports empty and BOM-prefixed input' do
    Mallorn::SUPPORTED_ENCODINGS.each do |encoding|
      expect(@parser.parse(''.encode(encoding)).root_node.text).to eq(''.encode(encoding))
      tree = @parser.parse("\uFEFFlet x = 1;\n".encode(encoding))
      expect(tree.root_node.has_error?).to be(false)
      expect(tree.root_node.end_point).to eq(Mallorn::Point.new(1, 0))
    end
  end

  it 'parses included ranges in full-source coordinates and resets ranges on the next parse' do
    source = "<tag>\nlet x = 1;\n</tag>"
    range = Mallorn::Span.new(6, 17, Mallorn::Point.new(1, 0), Mallorn::Point.new(2, 0))
    tree = @parser.parse(Fragments.new(source), included_ranges: [range])
    expect(tree.root_node.has_error?).to be(false)
    expect(tree.root_node.start_byte).to eq(6)
    expect(tree.root_node.text).to eq("let x = 1;\n")
    expect(tree.included_ranges).to eq([range])
    expect(tree.copy.included_ranges).to eq([range])
    expect(@parser.parse('let full = 2;').root_node.start_byte).to eq(0)
    expect { @parser.parse(source, included_ranges: []) }.to raise_error(ArgumentError)
    expect { @parser.parse(source, included_ranges: [range, range]) }.to raise_error(ArgumentError)
  end

  it 'applies multiple edits sequentially' do
    tree = @parser.parse('let x = 1;')
    first = Mallorn::InputEdit.new(8, 9, 10, Mallorn::Point.new(0, 8), Mallorn::Point.new(0, 9), Mallorn::Point.new(0, 10))
    second = Mallorn::InputEdit.new(4, 5, 8, Mallorn::Point.new(0, 4), Mallorn::Point.new(0, 5), Mallorn::Point.new(0, 8))
    reused = tree.edited(first, second)
    parsed = @parser.parse('let name = 22;', old_tree: reused)
    expect(parsed.root_node.text).to eq('let name = 22;')
    expect(parsed.root_node.has_error?).to be(false)
    expect(tree.root_node.end_byte).to eq(10)
  end

  it 'recovers after cancellation both before and during parsing' do
    expect { @parser.parse('let x = 1;', cancellation: -> { true }) }.to raise_error(Mallorn::CancelledError)
    calls = 0
    expect do
      @parser.parse('let x = 1;' * 10000, cancellation: -> { calls += 1; calls > 5 })
    end.to raise_error(Mallorn::CancelledError)
    expect(calls).to be > 5
    expect(@parser.parse('let recovered = 1;').root_node.has_error?).to be(false)
    expect(@parser.reset).to equal(@parser)
  end

  it 'transports callback exceptions and leaves the parser reusable' do
    input = Fragments.new('let x = 1;')
    allow(input).to receive(:read_at).and_raise(ArgumentError, 'reader failed')
    expect { @parser.parse(input) }.to raise_error(ArgumentError, 'reader failed')
    expect do
      @parser.parse('let x = 1;', cancellation: -> { raise ArgumentError, 'canceller failed' })
    end.to raise_error(ArgumentError, 'canceller failed')
    expect(@parser.parse('let x = 2;').root_node.has_error?).to be(false)
  end

  it 'rejects input and cancellation callbacks that reenter the same runtime' do
    input = Fragments.new('let x = 1;')
    allow(input).to receive(:read_at) { @parser.parse('nested') }
    expect { @parser.parse(input) }.to raise_error(Mallorn::Error, /already in use/)
    expect do
      @parser.parse('let x;', cancellation: -> { @language.symbol_name(0) })
    end.to raise_error(Mallorn::Error, /reenter/)
    expect(@parser.parse('let x;').root_node.has_error?).to be(false)
  end

  it 'rejects unsupported encodings and incompatible reuse' do
    expect { @parser.parse('abc'.b) }.to raise_error(Mallorn::UnsupportedEncodingError)
    input = Fragments.new('let x;')
    allow(input).to receive(:read_at).and_return('abc'.b)
    expect { @parser.parse(input) }.to raise_error(Mallorn::UnsupportedEncodingError)
    tree = @parser.parse('let x;')
    expect { @parser.parse('let x;'.encode(Encoding::UTF_16LE), old_tree: tree) }.to raise_error(Mallorn::UnsupportedEncodingError)
    other_language = @runtime.load_language(@grammar, name: 'javascript')
    other_parser = Mallorn::Parser.new(language: other_language)
    begin
      expect { other_parser.parse('let x;', old_tree: tree) }.to raise_error(Mallorn::IncompatibleLanguageError)
    ensure
      other_parser.close
    end
    other_runtime = Mallorn::Runtime.new
    begin
      foreign = other_runtime.load_language(@grammar, name: 'javascript')
      parser = Mallorn::Parser.new(language: foreign)
      expect { parser.parse('let x;', old_tree: tree) }.to raise_error(Mallorn::IncompatibleRuntimeError)
    ensure
      other_runtime.close
    end
  end

  it 'navigates named and anonymous children, fields, siblings, and descendants' do
    root = @parser.parse('const x = 1, y = 2;').root_node
    declaration = root.first_named_child
    expect(root.parent).to be_nil
    expect(root.last_child).to eq(declaration)
    expect(root.last_named_child).to eq(declaration)
    expect(declaration.parent).to eq(root)
    expect(declaration.first_child.type).to eq('const')
    expect(declaration.first_child.named?).to be(false)
    first, second = declaration.each_child(named: true).to_a
    expect(first.next_named_sibling).to eq(second)
    expect(second.previous_named_sibling).to eq(first)
    expect(first.next_sibling.type).to eq(',')
    expect(first.next_sibling.previous_sibling).to eq(first)
    name = first.child_by_field_name('name')
    expect(name.text).to eq('x')
    expect(first.children_by_field_name('name')).to eq([name])
    expect(first.field_name_for_child(0)).to eq('name')
    expect(first.child_by_field_name('absent')).to be_nil
    expect(first.children_by_field_name('absent')).to eq([])
    expect(first.field_name_for_child(100)).to be_nil
    expect(name.child(0)).to be_nil
    expect(name.named_child(0)).to be_nil
    expect(name.last_child).to be_nil
    expect(name.last_named_child).to be_nil
    expect { root.child(-1) }.to raise_error(RangeError)
    expect(root.descendant_for_byte_range(6, 7)).to eq(name)
    expect(root.descendant_for_byte_range(6, 7, named: true)).to eq(name)
    expect(root.descendant_for_point_range(Mallorn::Point.new(0, 6), Mallorn::Point.new(0, 7))).to eq(name)
    expect(root.descendant_for_point_range(Mallorn::Point.new(0, 6), Mallorn::Point.new(0, 7), named: true)).to eq(name)
    expect { root.descendant_for_byte_range(5, 2) }.to raise_error(ArgumentError)
    expect(name.span).to eq(Mallorn::Span.new(6, 7, Mallorn::Point.new(0, 6), Mallorn::Point.new(0, 7)))
    expect(name.grammar_type).to eq('identifier')
    expect(name.grammar_symbol_id).to be_a(Integer)
    expect(name.parse_state).to be_a(Integer)
    expect(name.next_parse_state).to be_a(Integer)
    expect([name.extra?, name.error?, name.missing?, name.has_error?, name.has_changes?]).to eq([false] * 5)
    expect(declaration.child_count).to be > declaration.named_child_count
    expect(root.each_child { |child| child.text }).to equal(root)
  end

  it 'scopes node equality and hashes to snapshots' do
    tree = @parser.parse('x')
    node = tree.root_node.first_named_child.first_named_child
    again = tree.root_node.first_named_child.first_named_child
    expect(node).to eql(again)
    expect({node => 1}[again]).to eq(1)
    expect(node).not_to eq(tree.copy.root_node.first_named_child.first_named_child)
    expect(node).not_to eq(nil)
  end

  it 'moves, copies, and resets tree cursors without changing other cursors' do
    tree = @parser.parse('let x = 1;')
    cursor = tree.root_node.walk
    expect(cursor.depth).to eq(0)
    expect(cursor.goto_parent).to be(false)
    expect(cursor.goto_first_child).to be(true)
    expect(cursor.goto_first_child).to be(true)
    expect(cursor.node.type).to eq('let')
    expect(cursor.field_name).to eq('kind')
    expect(cursor.goto_next_sibling).to be(true)
    expect(cursor.goto_first_child).to be(true)
    expect(cursor.node.text).to eq('x')
    expect(cursor.field_name).to eq('name')
    expect(cursor.field_id).to eq(@language.field_id('name'))
    copy = cursor.copy
    expect(copy.node).to eq(cursor.node)
    expect(copy.depth).to eq(cursor.depth)
    expect(copy.goto_next_sibling).to be(true)
    expect(cursor.node.text).to eq('x')
    expect(copy.goto_previous_sibling).to be(true)
    expect(copy.goto_parent).to be(true)
    expect(copy.goto_last_child).to be(true)
    expect(copy.node.text).to eq('1')
    other = @parser.parse('other').root_node
    expect(cursor.reset(other)).to equal(cursor)
    expect(cursor.tree).to equal(other.tree)
    expect(cursor.depth).to eq(0)
    cursor.close
    cursor.close
    expect(cursor).to be_closed
    expect { cursor.node }.to raise_error(Mallorn::ClosedError)
    copy.close
  end

  it 'exposes language symbols, fields, transitions, and lookahead' do
    node = @parser.parse('let x = 1;').root_node.first_named_child.first_named_child.child_by_field_name('name')
    expect(@language.symbol_name(node.symbol_id)).to eq('identifier')
    expect(@language.symbol_named?(node.symbol_id)).to be(true)
    expect(@language.symbol_visible?(node.symbol_id)).to be(true)
    expect(@language.field_name(@language.field_id('name'))).to eq('name')
    expect(@language.field_id('missing')).to be_nil
    expect(@language.field_name(0)).to be_nil
    expect(@language.next_state(node.parse_state, node.grammar_symbol_id)).to eq(node.next_parse_state)
    expect(@language.lookahead(node.parse_state)).to be_a(Enumerator)
    expect(@language.lookahead(node.parse_state).to_a).to include(node.grammar_symbol_id)
    expect { @language.symbol_name(0x10000) }.to raise_error(ArgumentError)
  end

  it 'compiles queries and reports precise query errors' do
    query = @language.query('((identifier) @id (#eq? @id "x") (#set! kind "local"))')
    expect(query.pattern_count).to eq(1)
    expect(query.capture_names).to eq(['id'])
    expect(query.capture_names).to be_frozen
    expect(query.predicates(0)).to eq([
      Mallorn::Predicate.new('eq?', [Mallorn::CaptureReference.new('id'), 'x']),
      Mallorn::Predicate.new('set!', ['kind', 'local'])
    ])
    expect { @language.query('(nonexistent_node) @x') }.to raise_error(Mallorn::QueryError) { |error|
      expect(error.byte_offset).to eq(1)
      expect(error.error_type).to eq(:node_type)
    }
    expect { @language.query('(identifier') }.to raise_error(Mallorn::QueryError)
    query.close
    expect(query).to be_closed
    expect { query.cursor }.to raise_error(Mallorn::ClosedError)
  end

  {
    'eq?' => ['x', ['x']],
    'not-eq?' => ['x', ['y', 'xyz']],
    'any-eq?' => ['x', ['x']],
    'any-not-eq?' => ['x', ['y', 'xyz']],
    'match?' => ['^x', ['x', 'xyz']],
    'not-match?' => ['^x', ['y']],
    'any-match?' => ['^x', ['x', 'xyz']],
    'any-not-match?' => ['^x', ['y']]
  }.each do |predicate, (argument, expected)|
    it "evaluates ##{predicate} using source text" do
      expect(query_captures("((identifier) @id (##{predicate} @id \"#{argument}\"))", 'x; y; xyz;')).to eq(expected)
    end
  end

  it 'evaluates alternatives and capture-to-capture predicates' do
    expect(query_captures('((identifier) @id (#any-of? @id "x" "z"))', 'x; y; z;')).to eq(['x', 'z'])
    expect(query_captures('((identifier) @id (#not-any-of? @id "x" "z"))', 'x; y; z;')).to eq(['y'])
    pattern = '((assignment_expression left: (identifier) @a right: (identifier) @b) (#eq? @a @b))'
    expect(query_captures(pattern, 'x = x; x = y;')).to eq(['x', 'x'])
  end

  it 'handles quantified captures and any- predicates' do
    all = '((program (expression_statement)+ @id) (#eq? @id "x;"))'
    any = '((program (expression_statement)+ @id) (#any-eq? @id "x;"))'
    expect(query_captures(all, 'x; x;')).to eq(['x;', 'x;'])
    expect(query_captures(all, 'x; y;')).to eq([])
    expect(query_captures(any, 'x; y;')).to eq(['x;', 'y;'])
    expect(query_captures(any, 'y; y;')).to eq([])
  end

  it 'returns lazy matches with properties and captures in engine order, including duplicates' do
    tree = @parser.parse('let x = y;')
    query = @language.query('((identifier) @one @two (#set! role "local"))')
    cursor = query.cursor
    enumerator = cursor.matches(tree.root_node)
    expect(enumerator).to be_a(Enumerator)
    matches = enumerator.to_a
    expect(matches.map(&:pattern_index)).to eq([0, 0])
    expect(matches.map(&:properties)).to eq([{'role' => 'local'}] * 2)
    captures = cursor.captures(tree.root_node).to_a
    expect(captures.map(&:name)).to eq(['one', 'two', 'one', 'two'])
    expect(captures.map { |capture| capture.node.text }).to eq(['x', 'x', 'y', 'y'])
    expect(cursor).not_to be_exceeded_match_limit
    cursor.close
  end

  it 'preserves unknown operations and requires explicit handlers' do
    query = @language.query('((identifier) @id (#custom? @id) (#decorate! "value"))')
    expect(query.predicates(0).map(&:name)).to eq(['custom?', 'decorate!'])
    expect { query.cursor }.to raise_error(Mallorn::QueryError, /Unhandled/)
    tree = @parser.parse('x; y;')
    cursor = query.cursor(handlers: {
      'custom?' => ->(predicate, match) { match.captures.first.node.text == 'x' && predicate.arguments.first.name == 'id' },
      'decorate!' => ->(_predicate, _match) { {'custom' => true} }
    })
    matches = cursor.matches(tree.root_node).to_a
    expect(matches.length).to eq(1)
    expect(matches.first.properties).to eq('custom' => true)
    cursor.close
  end

  it 'rejects malformed standard predicate arguments and invalid regexps' do
    expect { @language.query('((identifier) @id (#eq? "x" @id))').cursor }.to raise_error(Mallorn::QueryError)
    expect { @language.query('((identifier) @id (#match? @id "["))').cursor }.to raise_error(Mallorn::QueryError)
  end

  it 'matches Unicode substrings with RE2 in each supported source encoding' do
    pattern = '((identifier) @id (#match? @id "fé"))'
    Mallorn::SUPPORTED_ENCODINGS.each do |encoding|
      captures = query_captures(pattern, 'café; other;'.encode(encoding))
      expect(captures).to eq(['café'])
    end
  end

  it 'filters byte/point ranges and resets depth limits between executions' do
    tree = @parser.parse("x;\ny;\nz;")
    cursor = @language.query('(identifier) @id').cursor
    expect(cursor.captures(tree.root_node, byte_range: 3...5).map { |capture| capture.node.text }).to eq(['y'])
    points = Mallorn::Point.new(1, 0)...Mallorn::Point.new(2, 0)
    expect(cursor.captures(tree.root_node, point_range: points).map { |capture| capture.node.text }).to eq(['y'])
    expect(cursor.captures(tree.root_node, byte_range: 0...0).to_a).to eq([])
    expect(cursor.captures(tree.root_node, max_start_depth: 0).to_a).to eq([])
    expect(cursor.captures(tree.root_node).count).to eq(3)
    expect { cursor.matches(tree.root_node, byte_range: 0..3).to_a }.to raise_error(ArgumentError)
    expect { cursor.matches(tree.root_node, match_limit: 0).to_a }.to raise_error(ArgumentError)
    cursor.close
  end

  it 'reports exhausted match limits and resets them on subsequent executions' do
    tree = @parser.parse('[x, y, z, a, b, c]')
    cursor = @language.query('(array (identifier) @a (identifier) @b)').cursor
    cursor.matches(tree.root_node, match_limit: 1).to_a
    expect(cursor.exceeded_match_limit?).to be(true)
    expect(cursor.matches(tree.root_node).count).to be > 0
    expect(cursor.exceeded_match_limit?).to be(false)
    cursor.close
  end

  it 'releases query execution after custom handlers fail and rejects closed queries' do
    tree = @parser.parse('x;')
    query = @language.query('((identifier) @id (#custom? @id))')
    failing = true
    cursor = query.cursor(handlers: {'custom?' => ->(_predicate, _match) {
      raise ArgumentError, 'handler failed' if failing
      true
    }})
    expect { cursor.matches(tree.root_node).to_a }.to raise_error(ArgumentError, 'handler failed')
    failing = false
    expect(cursor.matches(tree.root_node).count).to eq(1)
    query.close
    expect { cursor.matches(tree.root_node).to_a }.to raise_error(Mallorn::ClosedError)
    cursor.close
  end

  it 'recovers after query cancellation, custom handler errors, and early termination' do
    tree = @parser.parse('let x = 1;' * 1000)
    cursor = @language.query('(identifier) @id').cursor
    expect { cursor.matches(tree.root_node, cancellation: -> { true }).to_a }.to raise_error(Mallorn::CancelledError)
    calls = 0
    expect do
      cursor.matches(tree.root_node, cancellation: -> { calls += 1; calls > 5 }).to_a
    end.to raise_error(Mallorn::CancelledError)
    expect(cursor.matches(tree.root_node).take(1).length).to eq(1)
    expect(cursor.captures(tree.root_node).count).to eq(1000)
    cursor.close
    cursor.close
    expect(cursor).to be_closed
    expect { cursor.matches(tree.root_node).to_a }.to raise_error(Mallorn::ClosedError)
  end

  it 'rejects reentrant query execution and runtime close invalidates retained nodes' do
    tree = @parser.parse('x; y;')
    cursor = @language.query('(identifier) @id').cursor
    expect do
      cursor.matches(tree.root_node).each { cursor.matches(tree.root_node).to_a }
    end.to raise_error(Mallorn::Error, /already in use/)
    expect(cursor.matches(tree.root_node).count).to eq(2)
    node = tree.root_node
    node.type # Cache properties before closing.
    @runtime.close
    expect { node.type }.to raise_error(Mallorn::ClosedError)
    expect { node.to_sexp }.to raise_error(Mallorn::ClosedError)
    expect(@parser).to be_closed
    expect(cursor).to be_closed
    @parser.close
    cursor.close
  end
end
