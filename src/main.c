#include <stdint.h>
#include <stdlib.h>
#include <wctype.h>
#include <tree_sitter/api.h>

// Only functions explicitly marked here form Mallorn's Wasm API. Pointers are
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

EXPORT(mallorn_iswspace)
int32_t mallorn_iswspace(uint32_t code_point) {
  return iswspace(code_point);
}

EXPORT(mallorn_iswalpha)
int32_t mallorn_iswalpha(uint32_t code_point) {
  return iswalpha(code_point);
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
