// Instantiating this module fails before any language can be selected.
__attribute__((constructor)) static void trap_initializer(void) {
  __builtin_trap();
}
