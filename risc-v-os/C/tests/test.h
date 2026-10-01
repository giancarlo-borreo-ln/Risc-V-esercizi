/* ===========================================================================
 * tests/test.h - a tiny assert-style test framework.
 * ===========================================================================
 *
 * Every test file includes os.h (for the declarations under test) and this
 * header.  The macros bump global counters, so a suite never has to add up its
 * own results; test_main.c prints the totals at the end.
 * =========================================================================== */

#ifndef TEST_H
#define TEST_H

#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* Defined in test_main.c. */
extern int test_checks;
extern int test_failures;

/* CHECK: the condition must be non-zero. */
#define CHECK(cond)                                                     \
    do {                                                                \
        test_checks++;                                                  \
        if (!(cond)) {                                                  \
            test_failures++;                                            \
            printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                               \
    } while (0)

/* CHECK_STR_EQ: two NUL terminated strings must be byte-for-byte equal. */
#define CHECK_STR_EQ(got, want)                                         \
    do {                                                                \
        const char *_g = (got);                                         \
        const char *_w = (want);                                        \
        test_checks++;                                                  \
        if (strcmp(_g, _w) != 0) {                                      \
            test_failures++;                                            \
            printf("    FAIL %s:%d: got \"%s\", want \"%s\"\n",         \
                   __FILE__, __LINE__, _g, _w);                         \
        }                                                               \
    } while (0)

/* CHECK_INT_EQ: two integer values must be equal. */
#define CHECK_INT_EQ(got, want)                                         \
    do {                                                                \
        long long _g = (long long)(got);                                \
        long long _w = (long long)(want);                               \
        test_checks++;                                                  \
        if (_g != _w) {                                                 \
            test_failures++;                                            \
            printf("    FAIL %s:%d: got %lld, want %lld\n",            \
                   __FILE__, __LINE__, _g, _w);                         \
        }                                                               \
    } while (0)

/* ---------------------------------------------------------------------------
 * Host stand-ins for the hardware boundary (mock_platform.c).
 * --------------------------------------------------------------------------- */
void        mock_reset(void);              /* clear captured output + input */
void        mock_set_input(const char *s); /* queue bytes for uart_getc      */
const char *mock_output(void);             /* NUL terminated captured output */
size_t      mock_output_len(void);
void        mock_disk_reset(void);         /* zero the in-memory disk        */
uint8_t    *mock_disk_data(void);
size_t      mock_disk_size(void);

/* Test suites (one per file). */
void test_strutil(void);
void test_fs(void);
void test_shell(void);

#endif /* TEST_H */
