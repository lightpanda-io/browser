/* Darwin-only strchrnul shim for libidn2.

   strchrnul is a glibc extension. macOS libc lacks it before 15.4, and
   libidn2's lib/lookup.c never includes <string.h> — so even on newer
   macOS the declaration would not reach the call site. The matching
   prototype is declared next to the strverscmp shim in
   vendor/libidn2/config.h (within the _LIBIDN2_LP_DECLS block, gated on
   __APPLE__), so callers compile; this file provides the symbol so
   they link.

   gnulib's strchrnul.c falls through to rawmemchr() when the search byte
   is NUL — also a glibc extension. libidn2 only ever searches for '.', so
   a straight byte scan is enough and avoids dragging in a second shim. */

char *strchrnul(const char *s, int c_in) {
    const unsigned char c = (unsigned char) c_in;
    const unsigned char *p = (const unsigned char *) s;
    while (*p && *p != c) p++;
    return (char *) p;
}
