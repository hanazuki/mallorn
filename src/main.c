#include <stdint.h>
#include <stdlib.h>
#include <tree_sitter/api.h>

// Functions explicitly marked here form Mallorn's Wasm API. Pointers are
// wasm32 linear-memory offsets; lengths and positions are always in bytes.
#define EXPORT(name) __attribute__((export_name(#name)))

EXPORT(mallorn_alloc)
void *mallorn_alloc(uint32_t size) {
  return malloc(size);
}

EXPORT(mallorn_free)
void mallorn_free(void *pointer) {
  free(pointer);
}

EXPORT(mallorn_calloc)
void *mallorn_calloc(uint32_t count, uint32_t size) {
  return calloc(count, size);
}

EXPORT(mallorn_language_symbol_count)
uint32_t mallorn_language_symbol_count(const TSLanguage *language) {
  return ts_language_symbol_count(language);
}

EXPORT(mallorn_language_field_count)
uint32_t mallorn_language_field_count(const TSLanguage *language) {
  return ts_language_field_count(language);
}

EXPORT(mallorn_language_state_count)
uint32_t mallorn_language_state_count(const TSLanguage *language) {
  return ts_language_state_count(language);
}

EXPORT(mallorn_language_metadata)
const TSLanguageMetadata *mallorn_language_metadata(const TSLanguage *language) {
  return ts_language_metadata(language);
}

EXPORT(mallorn_language_version)
uint32_t mallorn_language_version(void) {
  return TREE_SITTER_LANGUAGE_VERSION;
}

EXPORT(mallorn_min_compatible_language_version)
uint32_t mallorn_min_compatible_language_version(void) {
  return TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION;
}

EXPORT(mallorn_parser_new)
TSParser *mallorn_parser_new(void) {
  return ts_parser_new();
}

EXPORT(mallorn_parser_delete)
void mallorn_parser_delete(TSParser *parser) {
  ts_parser_delete(parser);
}

EXPORT(mallorn_parser_reset)
void mallorn_parser_reset(TSParser *parser) {
  ts_parser_reset(parser);
}

// language must be a TSLanguage in this module's memory, with scanner functions
// in its function table. Loading/linking grammar modules is a separate layer.
EXPORT(mallorn_parser_set_language)
bool mallorn_parser_set_language(TSParser *parser, const TSLanguage *language) {
  return ts_parser_set_language(parser, language);
}

// Encoding values follow TSInputEncoding: UTF-8=0, UTF-16LE=1, UTF-16BE=2.
// Custom decoding is not part of Mallorn's input contract.
EXPORT(mallorn_parser_parse_string)
TSTree *mallorn_parser_parse_string(
  TSParser *parser,
  const TSTree *old_tree,
  const char *source,
  uint32_t length,
  uint32_t encoding
) {
  if (encoding > TSInputEncodingUTF16BE) return NULL;
  return ts_parser_parse_string_encoding(parser, old_tree, source, length, encoding);
}

EXPORT(mallorn_tree_copy)
TSTree *mallorn_tree_copy(const TSTree *tree) {
  return ts_tree_copy(tree);
}

EXPORT(mallorn_tree_delete)
void mallorn_tree_delete(TSTree *tree) {
  ts_tree_delete(tree);
}

// The host writes a TSInputEdit into linear memory before calling this function.
EXPORT(mallorn_tree_edit)
void mallorn_tree_edit(TSTree *tree, const TSInputEdit *edit) {
  ts_tree_edit(tree, edit);
}

// Returns an allocated TSRange array; count points to a uint32_t in memory.
// Release the returned array with mallorn_free.
EXPORT(mallorn_tree_changed_ranges)
TSRange *mallorn_tree_changed_ranges(
  const TSTree *old_tree,
  const TSTree *new_tree,
  uint32_t *count
) {
  return ts_tree_get_changed_ranges(old_tree, new_tree, count);
}

// Convenience entrypoints for verifying linked grammars before the Ruby node
// interface is implemented. The returned string is released with mallorn_free.
EXPORT(mallorn_tree_string)
char *mallorn_tree_string(const TSTree *tree) {
  return ts_node_string(ts_tree_root_node(tree));
}

EXPORT(mallorn_tree_has_error)
bool mallorn_tree_has_error(const TSTree *tree) {
  return ts_node_has_error(ts_tree_root_node(tree));
}

// Host callbacks copy into a caller-provided buffer. They never unwind through
// C: Ruby records exceptions, signals cancellation, and raises after C returns.
__attribute__((import_module("mallorn"), import_name("read")))
extern uint32_t host_read(uint32_t, uint32_t, uint32_t, char *, uint32_t);
__attribute__((import_module("mallorn"), import_name("cancel")))
extern uint32_t host_cancel(void);

static const char *read_input(void *payload, uint32_t offset, TSPoint point, uint32_t *length) {
  *length = host_read(offset, point.row, point.column, payload, 16384);
  return payload;
}

static bool parse_progress(TSParseState *state) {
  (void)state;
  return host_cancel() != 0;
}

static bool query_progress(TSQueryCursorState *state) {
  (void)state;
  return host_cancel() != 0;
}

EXPORT(mallorn_parser_parse)
TSTree *mallorn_parser_parse(TSParser *parser, const TSTree *old_tree, uint32_t encoding) {
  char *buffer = malloc(16384);
  if (!buffer) return NULL;
  TSInput input = {.payload = buffer, .read = read_input, .encoding = encoding};
  TSParseOptions options = {.progress_callback = parse_progress};
  TSTree *tree = ts_parser_parse_with_options(parser, old_tree, input, options);
  free(buffer);
  return tree;
}

EXPORT(mallorn_parser_ranges)
bool mallorn_parser_ranges(TSParser *parser, const TSRange *ranges, uint32_t count) {
  return ts_parser_set_included_ranges(parser, ranges, count);
}

EXPORT(mallorn_tree_ranges)
const TSRange *mallorn_tree_ranges(const TSTree *tree, uint32_t *count) {
  return ts_tree_included_ranges(tree, count);
}

// All aggregate ABI layouts used by Ruby are checked here for wasm32.
_Static_assert(sizeof(TSNode) == 24, "unexpected TSNode layout");
_Static_assert(sizeof(TSRange) == 24, "unexpected TSRange layout");
_Static_assert(sizeof(TSInputEdit) == 36, "unexpected TSInputEdit layout");
_Static_assert(sizeof(TSQueryCapture) == 28, "unexpected TSQueryCapture layout");

EXPORT(mallorn_tree_root)
void mallorn_tree_root(const TSTree *tree, TSNode *result) {
  *result = ts_tree_root_node(tree);
}

// Fetch immutable node properties in one crossing. Node values themselves are
// copied to Ruby; only trees and stateful cursors own persistent allocations.
EXPORT(mallorn_node_info)
void mallorn_node_info(const TSNode *node, uint32_t *result) {
  TSNode n = *node;
  TSPoint start = ts_node_start_point(n), end = ts_node_end_point(n);
  result[0] = (uintptr_t)ts_node_type(n);
  result[1] = (uintptr_t)ts_node_grammar_type(n);
  result[2] = ts_node_symbol(n);
  result[3] = ts_node_grammar_symbol(n);
  result[4] = ts_node_start_byte(n);
  result[5] = ts_node_end_byte(n);
  result[6] = start.row;
  result[7] = start.column;
  result[8] = end.row;
  result[9] = end.column;
  result[10] = ts_node_is_named(n) | (ts_node_is_extra(n) << 1) |
    (ts_node_is_error(n) << 2) | (ts_node_is_missing(n) << 3) |
    (ts_node_has_error(n) << 4) | (ts_node_has_changes(n) << 5);
  result[11] = ts_node_parse_state(n);
  result[12] = ts_node_next_parse_state(n);
  result[13] = ts_node_child_count(n);
  result[14] = ts_node_named_child_count(n);
}

EXPORT(mallorn_node_parent)
void mallorn_node_parent(const TSNode *node, TSNode *result) {
  *result = ts_node_parent(*node);
}

EXPORT(mallorn_node_next_sibling)
void mallorn_node_next_sibling(const TSNode *node, TSNode *result) {
  *result = ts_node_next_sibling(*node);
}

EXPORT(mallorn_node_previous_sibling)
void mallorn_node_previous_sibling(const TSNode *node, TSNode *result) {
  *result = ts_node_prev_sibling(*node);
}

EXPORT(mallorn_node_next_named_sibling)
void mallorn_node_next_named_sibling(const TSNode *node, TSNode *result) {
  *result = ts_node_next_named_sibling(*node);
}

EXPORT(mallorn_node_previous_named_sibling)
void mallorn_node_previous_named_sibling(const TSNode *node, TSNode *result) {
  *result = ts_node_prev_named_sibling(*node);
}

EXPORT(mallorn_node_child)
void mallorn_node_child(const TSNode *node, uint32_t index, TSNode *result) {
  *result = ts_node_child(*node, index);
}

EXPORT(mallorn_node_named_child)
void mallorn_node_named_child(const TSNode *node, uint32_t index, TSNode *result) {
  *result = ts_node_named_child(*node, index);
}

EXPORT(mallorn_node_child_by_field_id)
void mallorn_node_child_by_field_id(const TSNode *node, uint32_t index, TSNode *result) {
  *result = ts_node_child_by_field_id(*node, index);
}

EXPORT(mallorn_node_descendant_for_byte_range)
void mallorn_node_descendant_for_byte_range(const TSNode *node, uint32_t start, uint32_t end, TSNode *result) {
  *result = ts_node_descendant_for_byte_range(*node, start, end);
}

EXPORT(mallorn_node_descendant_for_point_range)
void mallorn_node_descendant_for_point_range(const TSNode *node, uint32_t sr, uint32_t sc, uint32_t er, uint32_t ec, TSNode *result) {
  *result = ts_node_descendant_for_point_range(*node, (TSPoint){sr, sc}, (TSPoint){er, ec});
}

EXPORT(mallorn_node_named_descendant_for_byte_range)
void mallorn_node_named_descendant_for_byte_range(const TSNode *node, uint32_t start, uint32_t end, TSNode *result) {
  *result = ts_node_named_descendant_for_byte_range(*node, start, end);
}

EXPORT(mallorn_node_named_descendant_for_point_range)
void mallorn_node_named_descendant_for_point_range(const TSNode *node, uint32_t sr, uint32_t sc, uint32_t er, uint32_t ec, TSNode *result) {
  *result = ts_node_named_descendant_for_point_range(*node, (TSPoint){sr, sc}, (TSPoint){er, ec});
}

EXPORT(mallorn_node_children)
TSNode *mallorn_node_children(const TSNode *node, bool named, uint32_t *count) {
  *count = named ? ts_node_named_child_count(*node) : ts_node_child_count(*node);
  TSNode *nodes = malloc(*count * sizeof(TSNode));
  TSTreeCursor cursor = ts_tree_cursor_new(*node);
  uint32_t i = 0;
  if (ts_tree_cursor_goto_first_child(&cursor)) do {
    TSNode child = ts_tree_cursor_current_node(&cursor);
    if (!named || ts_node_is_named(child)) nodes[i++] = child;
  } while (ts_tree_cursor_goto_next_sibling(&cursor));
  ts_tree_cursor_delete(&cursor);
  return nodes;
}

EXPORT(mallorn_node_field)
const char *mallorn_node_field(const TSNode *node, uint32_t index) {
  return ts_node_field_name_for_child(*node, index);
}

EXPORT(mallorn_node_string)
char *mallorn_node_string(const TSNode *node) { return ts_node_string(*node); }

EXPORT(mallorn_cursor_new)
TSTreeCursor *mallorn_cursor_new(const TSNode *node) {
  TSTreeCursor *cursor = malloc(sizeof(TSTreeCursor));
  if (cursor) *cursor = ts_tree_cursor_new(*node);
  return cursor;
}

EXPORT(mallorn_cursor_delete)
void mallorn_cursor_delete(TSTreeCursor *cursor) {
  ts_tree_cursor_delete(cursor);
  free(cursor);
}

EXPORT(mallorn_cursor_copy)
TSTreeCursor *mallorn_cursor_copy(const TSTreeCursor *cursor) {
  TSTreeCursor *copy = malloc(sizeof(TSTreeCursor));
  if (copy) *copy = ts_tree_cursor_copy(cursor);
  return copy;
}

EXPORT(mallorn_cursor_node)
void mallorn_cursor_node(const TSTreeCursor *cursor, TSNode *node) {
  *node = ts_tree_cursor_current_node(cursor);
}

EXPORT(mallorn_cursor_field)
uint32_t mallorn_cursor_field(const TSTreeCursor *cursor) {
  return ts_tree_cursor_current_field_id(cursor);
}

EXPORT(mallorn_cursor_depth)
uint32_t mallorn_cursor_depth(const TSTreeCursor *cursor) {
  return ts_tree_cursor_current_depth(cursor);
}

EXPORT(mallorn_cursor_goto_parent)
bool mallorn_cursor_goto_parent(TSTreeCursor *cursor) {
  return ts_tree_cursor_goto_parent(cursor);
}

EXPORT(mallorn_cursor_goto_first_child)
bool mallorn_cursor_goto_first_child(TSTreeCursor *cursor) {
  return ts_tree_cursor_goto_first_child(cursor);
}

EXPORT(mallorn_cursor_goto_last_child)
bool mallorn_cursor_goto_last_child(TSTreeCursor *cursor) {
  return ts_tree_cursor_goto_last_child(cursor);
}

EXPORT(mallorn_cursor_goto_next_sibling)
bool mallorn_cursor_goto_next_sibling(TSTreeCursor *cursor) {
  return ts_tree_cursor_goto_next_sibling(cursor);
}

EXPORT(mallorn_cursor_goto_previous_sibling)
bool mallorn_cursor_goto_previous_sibling(TSTreeCursor *cursor) {
  return ts_tree_cursor_goto_previous_sibling(cursor);
}

EXPORT(mallorn_cursor_reset)
void mallorn_cursor_reset(TSTreeCursor *cursor, const TSNode *node) {
  ts_tree_cursor_reset(cursor, *node);
}

EXPORT(mallorn_language_symbol_name)
const char *mallorn_language_symbol_name(const TSLanguage *language, uint32_t symbol) {
  return ts_language_symbol_name(language, symbol);
}

EXPORT(mallorn_language_symbol_type)
uint32_t mallorn_language_symbol_type(const TSLanguage *language, uint32_t symbol) {
  return ts_language_symbol_type(language, symbol);
}

EXPORT(mallorn_language_field_name)
const char *mallorn_language_field_name(const TSLanguage *language, uint32_t field) {
  return ts_language_field_name_for_id(language, field);
}

EXPORT(mallorn_language_field_id)
uint32_t mallorn_language_field_id(const TSLanguage *language, const char *name, uint32_t length) {
  return ts_language_field_id_for_name(language, name, length);
}

EXPORT(mallorn_language_next_state)
uint32_t mallorn_language_next_state(const TSLanguage *language, uint32_t state, uint32_t symbol) {
  return ts_language_next_state(language, state, symbol);
}

EXPORT(mallorn_language_lookahead)
uint32_t *mallorn_language_lookahead(const TSLanguage *language, uint32_t state, uint32_t *count) {
  TSLookaheadIterator *iterator = ts_lookahead_iterator_new(language, state);
  if (!iterator) { *count = 0; return NULL; }
  uint32_t *symbols = malloc(ts_language_symbol_count(language) * sizeof(uint32_t));
  *count = 0;
  while (ts_lookahead_iterator_next(iterator)) symbols[(*count)++] = ts_lookahead_iterator_current_symbol(iterator);
  ts_lookahead_iterator_delete(iterator);
  return symbols;
}

EXPORT(mallorn_query_new)
TSQuery *mallorn_query_new(const TSLanguage *language, const char *source, uint32_t length, uint32_t *error) {
  return ts_query_new(language, source, length, &error[0], (TSQueryError *)&error[1]);
}

EXPORT(mallorn_query_delete)
void mallorn_query_delete(TSQuery *query) { ts_query_delete(query); }

EXPORT(mallorn_query_pattern_count)
uint32_t mallorn_query_pattern_count(const TSQuery *query) { return ts_query_pattern_count(query); }

EXPORT(mallorn_query_capture_count)
uint32_t mallorn_query_capture_count(const TSQuery *query) { return ts_query_capture_count(query); }

EXPORT(mallorn_query_capture_name)
const char *mallorn_query_capture_name(const TSQuery *query, uint32_t index, uint32_t *length) {
  return ts_query_capture_name_for_id(query, index, length);
}

EXPORT(mallorn_query_string)
const char *mallorn_query_string(const TSQuery *query, uint32_t index, uint32_t *length) {
  return ts_query_string_value_for_id(query, index, length);
}

EXPORT(mallorn_query_predicates)
const TSQueryPredicateStep *mallorn_query_predicates(const TSQuery *query, uint32_t index, uint32_t *count) {
  return ts_query_predicates_for_pattern(query, index, count);
}

typedef struct {
  TSQueryCursor *cursor;
  TSQueryCursorOptions options;
} MallornQueryCursor;

EXPORT(mallorn_query_cursor_new)
MallornQueryCursor *mallorn_query_cursor_new(void) {
  MallornQueryCursor *cursor = malloc(sizeof(MallornQueryCursor));
  if (!cursor) return NULL;
  cursor->cursor = ts_query_cursor_new();
  cursor->options = (TSQueryCursorOptions){.progress_callback = query_progress};
  return cursor;
}

EXPORT(mallorn_query_cursor_delete)
void mallorn_query_cursor_delete(MallornQueryCursor *cursor) {
  ts_query_cursor_delete(cursor->cursor);
  free(cursor);
}

EXPORT(mallorn_query_cursor_exec)
void mallorn_query_cursor_exec(MallornQueryCursor *cursor, const TSQuery *query, const TSNode *node,
                              const uint32_t *limits) {
  ts_query_cursor_set_byte_range(cursor->cursor, limits[0], limits[1]);
  ts_query_cursor_set_point_range(cursor->cursor, (TSPoint){limits[2], limits[3]}, (TSPoint){limits[4], limits[5]});
  ts_query_cursor_set_match_limit(cursor->cursor, limits[6]);
  ts_query_cursor_set_max_start_depth(cursor->cursor, limits[7]);
  ts_query_cursor_exec_with_options(cursor->cursor, query, *node, &cursor->options);
}

EXPORT(mallorn_query_cursor_next_match)
bool mallorn_query_cursor_next_match(MallornQueryCursor *cursor, uint32_t *info) {
  TSQueryMatch match;
  if (!ts_query_cursor_next_match(cursor->cursor, &match)) return false;
  info[0] = match.pattern_index;
  info[1] = match.capture_count;
  info[2] = (uintptr_t)match.captures;
  return true;
}

EXPORT(mallorn_query_cursor_exceeded)
bool mallorn_query_cursor_exceeded(const MallornQueryCursor *cursor) {
  return ts_query_cursor_did_exceed_match_limit(cursor->cursor);
}
