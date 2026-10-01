/* ===========================================================================
 * strutil.c - the few string routines the OS needs.
 * ===========================================================================
 *
 * The OS is freestanding (no libc), so even strcmp has to be written by hand.
 * These functions are pure: they touch no hardware and no global state, which
 * makes them the easiest part of the OS to unit test.
 * =========================================================================== */

#include "os.h"

/* streq: compare two NUL terminated strings byte for byte.
 *
 * Walking both cursors while the bytes are equal works because the final NUL
 * is compared too: when both strings end together the loop stops with *a == 0,
 * and the trailing check confirms that *b also ended. */
int streq(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return *a == 0 && *b == 0;
}

/* starts_with: does string a begin with string b?
 *
 * Walk the prefix; if it ends (NUL) before any mismatch, it was a prefix. */
int starts_with(const char *a, const char *b)
{
    while (*b) {
        if (*a != *b)
            return 0;
        a++;
        b++;
    }
    return 1;
}

/* copy_name: turn a raw command argument into a NUL terminated name.
 *
 * Two accepted forms:
 *   "a b/c"   -> surrounding double quotes are stripped, spaces allowed inside
 *   a b/c     -> everything up to the next space
 *
 * Returns 1 when a non-empty name was copied, 0 otherwise.  The destination is
 * always NUL terminated, and at most PATH_SIZE-1 bytes are written. */
int copy_name(const char *src, char *dst)
{
    size_t n = 0;

    if (*src == '"') {
        src++;                       /* step over the opening quote */
        while (*src && *src != '"' && n < PATH_SIZE - 1)
            dst[n++] = *src++;
    } else {
        while (*src && *src != ' ' && n < PATH_SIZE - 1)
            dst[n++] = *src++;
    }

    dst[n] = 0;
    return n != 0;
}

/* bytes_copy / bytes_zero: the two libc calls the OS would otherwise want.
 * Written by hand because there is no libc under -ffreestanding. */
void bytes_copy(void *dst, const void *src, size_t n)
{
    uint8_t       *d = dst;
    const uint8_t *s = src;
    while (n--)
        *d++ = *s++;
}

void bytes_zero(void *dst, size_t n)
{
    uint8_t *d = dst;
    while (n--)
        *d++ = 0;
}
