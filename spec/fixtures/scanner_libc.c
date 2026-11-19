#include <stdlib.h>
#include <wctype.h>
#include "parser.h"

static const TSLanguage language = { .abi_version = 15 };

const TSLanguage *tree_sitter_scanner_libc(void) {
  char *buffer = malloc(1);
  if (!buffer) return NULL;

  buffer[0] = '7';
  char *resized = realloc(buffer, 2);
  if (!resized) {
    free(buffer);
    return NULL;
  }

  int valid = iswdigit(resized[0]);
  free(resized);
  return valid ? &language : NULL;
}
