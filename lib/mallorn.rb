module Mallorn
  VERSION = '0.1.0'

  SUPPORTED_ENCODINGS = [Encoding::UTF_8, Encoding::UTF_16LE, Encoding::UTF_16BE].freeze

  class Error < StandardError; end
  class UnsupportedEncodingError < Error; end
  class IncompatibleLanguageError < Error; end
  class IncompatibleRuntimeError < Error; end
  class ClosedError < Error; end
  class CancelledError < Error; end
  class QueryError < Error; end

  # Rows and columns are zero-based. Columns count bytes since the last LF,
  # in the source encoding, including for UTF-16 input.
  Point = Data.define(:row, :column)

  # Byte intervals are half-open: start_byte...end_byte.
  Span = Data.define(:start_byte, :end_byte, :start_point, :end_point)

  # Start and old-end coordinates refer to the source before the edit;
  # new-end coordinates refer to the source after the edit.
  InputEdit = Data.define(
    :start_byte, :old_end_byte, :new_end_byte,
    :start_point, :old_end_point, :new_end_point
  )

  # Owns the Wasm instance, memory, and loaded modules. Operations within one
  # runtime are serialized initially. Objects from different runtimes cannot
  # exchange backend handles. GC releases resources; close releases them early.
  class Runtime
    def initialize
      fail 'TODO'
    end

    def load_language(path, name:)
      fail 'TODO'
    end

    def load_language_bytes(bytes, name:)
      fail 'TODO'
    end

    # Invalidates every object belonging to this runtime. Idempotent.
    def close
      fail 'TODO'
    end

    def closed?
      fail 'TODO'
    end
  end

  class Language
    attr_reader :runtime, :name, :abi_version, :metadata
    attr_reader :symbol_count, :field_count, :state_count

    # Instances are returned by Runtime; no public constructor.
    private_class_method :new

    def symbol_name(symbol_id)
      fail 'TODO'
    end

    def symbol_named?(symbol_id)
      fail 'TODO'
    end

    def symbol_visible?(symbol_id)
      fail 'TODO'
    end

    def field_name(field_id)
      fail 'TODO'
    end

    def field_id(name)
      fail 'TODO'
    end

    def next_state(state, symbol_id)
      fail 'TODO'
    end

    # Enumerator of symbol IDs valid after a parse state.
    def lookahead(state)
      fail 'TODO'
    end

    def query(pattern)
      fail 'TODO'
    end
  end

  class Parser
    attr_reader :language

    def initialize(language:)
      fail 'TODO'
    end

    # Accept a String or a caller-owned object responding to:
    #   encoding -> an Encoding from SUPPORTED_ENCODINGS
    #   read_at(byte_offset, point:) -> String or nil
    #
    # read_at returns bytes starting exactly at byte_offset; nil or an empty
    # String means EOF. Reads may be nonsequential or repeated. point is a Point
    # supplied as a hint. Returned strings carry the input encoding, without
    # transcoding. Chunk boundaries may split characters, including UTF-16
    # surrogate pairs; the bridge handles decoder boundaries.
    #
    # String input is snapshotted. Caller-owned input is retained for Node#text
    # and must remain a stable revision for the resulting tree's lifetime.
    #
    # old_tree must have the same runtime, language, and source encoding, and
    # must have been edited to match all changes to the input. Encoding changes
    # require a fresh parse. Reuse never mutates old_tree.
    #
    # included_ranges: nil parses the whole source; otherwise supply sorted,
    # nonoverlapping Spans in full-source coordinates. [] is rejected to avoid
    # confusion with Tree-sitter's empty-list-means-whole-source convention.
    #
    # cancellation is an optional zero-argument callable returning true to
    # cancel. Cancellation raises CancelledError and resets parser state, so
    # the next call starts a new operation. Syntax errors still return a Tree.
    def parse(source, old_tree: nil, included_ranges: nil, cancellation: nil)
      fail 'TODO'
    end

    def reset
      fail 'TODO'
    end

    def close
      fail 'TODO'
    end

    def closed?
      fail 'TODO'
    end
  end

  # A persistent syntax snapshot. Nodes and cursors retain their tree, which
  # retains its runtime, language, and source. No public constructor.
  class Tree
    private_class_method :new

    attr_reader :runtime, :language, :encoding, :source, :included_ranges

    def root_node
      fail 'TODO'
    end

    # Return a cheap independent tree copy.
    def copy
      fail 'TODO'
    end

    # Copy and adjust coordinates for incremental reuse, without reparsing.
    # Multiple edits apply sequentially: each uses the preceding edit's output
    # coordinates. Existing trees and nodes remain unchanged.
    #
    # The returned tree has source == nil: its syntax is an intermediate reuse
    # structure. Its nodes cannot supply text until the source is reparsed.
    def edited(*edits)
      fail 'TODO'
    end

    # Array<Span> of syntactic changes, in the new tree's coordinates. Call on
    # the edited reuse tree with the freshly parsed tree. These ranges do not
    # necessarily include every textual edit; preserve InputEdits separately.
    def changed_ranges(new_tree)
      fail 'TODO'
    end
  end

  class Node
    private_class_method :new

    attr_reader :tree

    # Node identity is scoped to a tree snapshot, not a stable identifier across
    # document revisions. ==, eql?, and hash use the same snapshot identity.
    def ==(other)
      fail 'TODO'
    end
    alias eql? ==

    def hash
      fail 'TODO'
    end

    def type
      fail 'TODO'
    end

    def grammar_type
      fail 'TODO'
    end

    def symbol_id
      fail 'TODO'
    end

    def grammar_symbol_id
      fail 'TODO'
    end

    def start_byte
      fail 'TODO'
    end

    def end_byte
      fail 'TODO'
    end

    def start_point
      fail 'TODO'
    end

    def end_point
      fail 'TODO'
    end

    def span
      fail 'TODO'
    end

    def named?
      fail 'TODO'
    end

    def extra?
      fail 'TODO'
    end

    def error?
      fail 'TODO'
    end

    def missing?
      fail 'TODO'
    end

    def has_error?
      fail 'TODO'
    end

    def has_changes?
      fail 'TODO'
    end

    def parse_state
      fail 'TODO'
    end

    def next_parse_state
      fail 'TODO'
    end

    def parent
      fail 'TODO'
    end

    def child_count
      fail 'TODO'
    end

    def named_child_count
      fail 'TODO'
    end

    def first_child
      fail 'TODO'
    end

    def last_child
      fail 'TODO'
    end

    def first_named_child
      fail 'TODO'
    end

    def last_named_child
      fail 'TODO'
    end

    def next_sibling
      fail 'TODO'
    end

    def previous_sibling
      fail 'TODO'
    end

    def next_named_sibling
      fail 'TODO'
    end

    def previous_named_sibling
      fail 'TODO'
    end

    # Return nil when the child does not exist; negative indexes are rejected.
    def child(index)
      fail 'TODO'
    end

    def named_child(index)
      fail 'TODO'
    end

    def child_by_field_name(name)
      fail 'TODO'
    end

    def children_by_field_name(name)
      fail 'TODO'
    end

    def field_name_for_child(index)
      fail 'TODO'
    end

    # Return self with a block, or an Enumerator without one. Child traversal
    # should batch backend reads rather than cross Wasm once per property.
    def each_child(named: false, &block)
      fail 'TODO'
    end

    def descendant_for_byte_range(start_byte, end_byte, named: false)
      fail 'TODO'
    end

    def descendant_for_point_range(start_point, end_point, named: false)
      fail 'TODO'
    end

    def walk
      fail 'TODO'
    end

    # Assemble only this node's bytes, preserving the source encoding.
    # Raises Error when tree.source is nil.
    def text
      fail 'TODO'
    end

    # Yield encoded String fragments covering exactly this node's byte range.
    # Fragments may split characters. Return self, or an Enumerator without a
    # block. Raises Error when tree.source is nil.
    def each_text_chunk(&block)
      fail 'TODO'
    end

    def to_sexp
      fail 'TODO'
    end
  end

  # Stateful traversal. Movement returns true on success, false otherwise.
  class TreeCursor
    private_class_method :new

    attr_reader :tree

    def node
      fail 'TODO'
    end

    def field_name
      fail 'TODO'
    end

    def field_id
      fail 'TODO'
    end

    def depth
      fail 'TODO'
    end

    def goto_parent
      fail 'TODO'
    end

    def goto_first_child
      fail 'TODO'
    end

    def goto_last_child
      fail 'TODO'
    end

    def goto_next_sibling
      fail 'TODO'
    end

    def goto_previous_sibling
      fail 'TODO'
    end

    def reset(node)
      fail 'TODO'
    end

    def copy
      fail 'TODO'
    end

    def close
      fail 'TODO'
    end

    def closed?
      fail 'TODO'
    end
  end

  Capture = Data.define(:name, :node)
  Match = Data.define(:pattern_index, :captures, :properties)

  class Query
    private_class_method :new

    attr_reader :language, :pattern_count, :capture_names

    # Introspection preserves predicates/directives, including unknown ones.
    def predicates(pattern_index)
      fail 'TODO'
    end

    # Standard text predicates are evaluated by the binding. handlers maps
    # additional predicate/directive names to callables. Unhandled operations
    # raise QueryError rather than silently changing query semantics.
    def cursor(handlers: {})
      fail 'TODO'
    end
  end

  # Each execution uses one node's source snapshot for predicate evaluation.
  # A cursor cannot execute concurrently or reentrantly.
  class QueryCursor
    private_class_method :new

    # Return an Enumerator<Match>. Byte and point ranges, when supplied, are
    # half-open Ruby Ranges; matches may extend beyond the filtering range.
    # cancellation has the same contract as Parser#parse.
    def matches(node, byte_range: nil, point_range: nil, match_limit: nil,
                max_start_depth: nil, cancellation: nil)
      fail 'TODO'
    end

    # Return an Enumerator<Capture> in Tree-sitter capture order, retaining
    # repeated captures and captures from distinct matches.
    def captures(node, byte_range: nil, point_range: nil, match_limit: nil,
                 max_start_depth: nil, cancellation: nil)
      fail 'TODO'
    end

    # Inspect after enumeration; reaching a match limit must be observable.
    def exceeded_match_limit?
      fail 'TODO'
    end

    def close
      fail 'TODO'
    end

    def closed?
      fail 'TODO'
    end
  end

end
