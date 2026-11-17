#include "parser.h"

// Minimal language records for export selection and metadata tests only.
// These records have no parse tables and must not be used for parsing.
static const TSLanguage first = {
  .abi_version = 15,
  .symbol_count = 3,
  .field_count = 1,
  .state_count = 2,
  .metadata = { .major_version = 1, .minor_version = 2, .patch_version = 3 },
};

static const TSLanguage second = {
  .abi_version = 15,
  .symbol_count = 5,
  .field_count = 2,
  .state_count = 4,
  .metadata = { .major_version = 4, .minor_version = 5, .patch_version = 6 },
};

const TSLanguage *tree_sitter_first(void) {
  return &first;
}

const TSLanguage *tree_sitter_first_alias(void) {
  return &first;
}

const TSLanguage *tree_sitter_second(void) {
  return &second;
}
