// A relocatable module with an intentionally unsupported grammar ABI.
static const unsigned language = 999;

const void *tree_sitter_incompatible(void) {
  return &language;
}
