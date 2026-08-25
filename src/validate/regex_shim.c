// Shim around POSIX regex.h.
//
// Zig's C importer produces an opaque type for `regex_t` when translating
// glibc's regex.h (the struct's layout is gated behind macros translate-c
// can't resolve), so Zig code can never declare a `regex_t` value directly
// on Linux — only ever a pointer that the C side allocated and sized
// itself. This shim keeps every regex_t access on the C side; Zig only
// ever holds an opaque pointer to a C-malloc'd buffer.
#include <regex.h>
#include <stdlib.h>

void *forge_regex_alloc(void) {
    return malloc(sizeof(regex_t));
}

void forge_regex_dealloc(void *preg) {
    free(preg);
}

int forge_regcomp(void *preg, const char *pattern) {
    return regcomp((regex_t *)preg, pattern, REG_EXTENDED | REG_NOSUB);
}

int forge_regexec(const void *preg, const char *string) {
    return regexec((const regex_t *)preg, string, 0, NULL, 0);
}

void forge_regfree(void *preg) {
    regfree((regex_t *)preg);
}
