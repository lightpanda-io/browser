/* macOS libc lacks strchrnul (a glibc extension). libidn2's lib/lookup.c
   calls it directly to walk DNS label boundaries. Upstream's portable build
   relies on gnulib substituting <string.h> with a declaration and linking
   gl/strchrnul.c, but this build does not wire up that overlay. We provide
   a small Darwin-only shim with the same semantics.

   gnulib's strchrnul.c falls through to rawmemchr() when the search byte is
   NUL — also a glibc extension. libidn2 only ever searches for '.', so a
   straightforward byte scan is sufficient and avoids pulling in a second
   shim. */

#include "strchrnul.h"

char *strchrnul(const char *s, int c_in) {
    const unsigned char c = (unsigned char) c_in;
    const unsigned char *p = (const unsigned char *) s;
    while (*p && *p != c) p++;
    return (char *) p;
}
