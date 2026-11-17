// Linking succeeds; invoking the language entry point traps.
const void *tree_sitter_trapping(void) {
  __builtin_trap();
}
