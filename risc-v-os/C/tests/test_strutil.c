/* ===========================================================================
 * tests/test_strutil.c - unit tests for strutil.c.
 * =========================================================================== */

#include "os.h"
#include "test.h"

void test_strutil(void)
{
    /* ---- streq ---- */
    CHECK(streq("", ""));
    CHECK(streq("abc", "abc"));
    CHECK(!streq("abc", "abd"));
    CHECK(!streq("abc", "ab"));
    CHECK(!streq("ab", "abc"));
    CHECK(!streq("", "x"));

    /* ---- starts_with ---- */
    CHECK(starts_with("hello", ""));
    CHECK(starts_with("hello", "he"));
    CHECK(starts_with("hello", "hello"));
    CHECK(!starts_with("hello", "world"));
    CHECK(!starts_with("he", "hello"));
    CHECK(!starts_with("", "x"));

    /* ---- copy_name: simple unquoted word ---- */
    {
        char dst[PATH_SIZE];
        CHECK_INT_EQ(copy_name("usr", dst), 1);
        CHECK_STR_EQ(dst, "usr");
    }

    /* ---- copy_name: unquoted stops at the first space ---- */
    {
        char dst[PATH_SIZE];
        CHECK_INT_EQ(copy_name("usr/bin extra", dst), 1);
        CHECK_STR_EQ(dst, "usr/bin");
    }

    /* ---- copy_name: quoted keeps embedded spaces ---- */
    {
        char dst[PATH_SIZE];
        CHECK_INT_EQ(copy_name("\"a b/c\"", dst), 1);
        CHECK_STR_EQ(dst, "a b/c");
    }

    /* ---- copy_name: quotes are not required to close ---- */
    {
        char dst[PATH_SIZE];
        CHECK_INT_EQ(copy_name("\"unterminated", dst), 1);
        CHECK_STR_EQ(dst, "unterminated");
    }

    /* ---- copy_name: empty inputs return 0 ---- */
    {
        char dst[PATH_SIZE];
        CHECK_INT_EQ(copy_name("", dst), 0);
        CHECK_STR_EQ(dst, "");
        CHECK_INT_EQ(copy_name("\"\"", dst), 0);
        CHECK_STR_EQ(dst, "");
    }

    /* ---- copy_name: never writes more than PATH_SIZE-1 bytes ---- */
    {
        char src[PATH_SIZE + 40];
        char dst[PATH_SIZE];
        for (size_t i = 0; i < sizeof src - 1; i++)
            src[i] = 'x';
        src[sizeof src - 1] = 0;

        CHECK_INT_EQ(copy_name(src, dst), 1);
        CHECK_INT_EQ(strlen(dst), PATH_SIZE - 1);
    }
}
