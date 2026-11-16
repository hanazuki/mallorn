// A relocatable module with an intentionally unsupported grammar ABI.
static const unsigned language = 999;

#ifdef TRAP_INITIALIZER
__attribute__((constructor)) static void trap_initializer(void) {
  __builtin_trap();
}
#endif

const void *tree_sitter_incompatible(void) {
  return &language;
}
