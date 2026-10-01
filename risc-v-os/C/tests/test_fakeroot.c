/* ===========================================================================
 * tests/test_fakeroot.c - the fake host tree used by the tests.
 * ===========================================================================
 *
 * The real build generates a large table from the host's directories.  The
 * tests need something small and deterministic instead: a NUL separated list
 * of paths ending with an empty string (the single trailing NUL that the C
 * compiler adds to the literal).
 * =========================================================================== */

#include "os.h"

const unsigned char fake_paths[] =
    "/usr\0"
    "/usr/bin\0"
    "/usr/bin/tools\0"
    "/etc\0"
    "/home\0"
    "/home/user\0";
