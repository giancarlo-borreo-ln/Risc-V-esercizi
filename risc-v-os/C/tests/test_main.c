/* ===========================================================================
 * tests/test_main.c - the host test runner.
 * ===========================================================================
 *
 * Builds the tested modules (strutil.c, fs.c, shell.c) together with the
 * hardware mocks and the test suites, then reports the totals.  Exits with a
 * non-zero status when anything failed so `make test` stops the chain.
 * =========================================================================== */

#include "test.h"

int test_checks;
int test_failures;

int main(void)
{
    printf("== strutil tests ==\n");
    test_strutil();

    printf("== filesystem tests ==\n");
    test_fs();

    printf("== shell tests ==\n");
    test_shell();

    printf("\n%d checks, %d failure(s)\n", test_checks, test_failures);
    return test_failures == 0 ? 0 : 1;
}
