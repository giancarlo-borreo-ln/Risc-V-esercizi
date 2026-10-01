/* ===========================================================================
 * tests/test_shell.c - unit tests for the line editor and command parser.
 * =========================================================================== */

#include "os.h"
#include "test.h"

static void fs_build(void)
{
    memset(node_pool, 0, sizeof node_pool);
    node_count = 0;
    cwd_ptr = NULL;
    init_fs();
}

void test_shell(void)
{
    /* ---- printf("...") prints exactly the quoted text ---- */
    {
        char line[] = "printf(\"hello world\")";
        mock_reset();
        parse_line(line);
        CHECK_STR_EQ(mock_output(), "hello world\r\n");
    }

    /* ---- printf with spaces before the quote and an empty body ---- */
    {
        char line[] = "printf(   \"\" )";
        mock_reset();
        parse_line(line);
        CHECK_STR_EQ(mock_output(), "\r\n");
    }

    /* ---- an unknown command echoes the name ---- */
    {
        char line[] = "frobnicate";
        mock_reset();
        parse_line(line);
        CHECK_STR_EQ(mock_output(), "unknown command: frobnicate\r\n");
    }

    /* ---- blank input produces no output ---- */
    {
        char line[] = "    ";
        mock_reset();
        parse_line(line);
        CHECK_INT_EQ(mock_output_len(), 0);
    }

    /* ---- mkdir + cd + pwd ---- */
    {
        fs_build();
        char mk[]  = "mkdir \"a/b\"";
        char cd[]  = "cd a/b";
        char pwd[] = "pwd";

        mock_reset();
        parse_line(mk);
        parse_line(cd);
        mock_reset();
        parse_line(pwd);
        CHECK_STR_EQ(mock_output(), "/a/b\r\n");
    }

    /* ---- ls lists the children of the current directory ---- */
    {
        fs_build();
        char ls[] = "ls";
        mock_reset();
        parse_line(ls);
        CHECK(strstr(mock_output(), "usr\r\n") != NULL);
        CHECK(strstr(mock_output(), "etc\r\n") != NULL);
        CHECK(strstr(mock_output(), "home\r\n") != NULL);
    }

    /* ---- cd to a missing directory reports an error ---- */
    {
        fs_build();
        char cd[] = "cd nowhere";
        mock_reset();
        parse_line(cd);
        CHECK(strstr(mock_output(), "cd: no such directory: nowhere") != NULL);
    }

    /* ---- line editor: plain typing ---- */
    {
        size_t len;
        mock_reset();
        mock_set_input("abc\r");
        read_line(linebuf, &len);
        CHECK_INT_EQ(len, 3);
        CHECK_STR_EQ(linebuf, "abc");
    }

    /* ---- line editor: backspace deletes the previous character ---- */
    {
        size_t len;
        mock_reset();
        mock_set_input("abc\x7f" "Z\r");
        read_line(linebuf, &len);
        CHECK_STR_EQ(linebuf, "abZ");
        CHECK_INT_EQ(len, 3);
    }

    /* ---- line editor: left arrow then insert moves mid-line ---- */
    {
        size_t len;
        mock_reset();
        mock_set_input("ac\x1b[Db\r");       /* a, c, left, b, Enter */
        read_line(linebuf, &len);
        CHECK_STR_EQ(linebuf, "abc");
        CHECK_INT_EQ(len, 3);
    }

    /* ---- line editor: right arrow does not run past the end ---- */
    {
        size_t len;
        mock_reset();
        mock_set_input("hi\x1b[C\x1b[C!\r"); /* two rights are no-ops */
        read_line(linebuf, &len);
        CHECK_STR_EQ(linebuf, "hi!");
    }

    /* ---- history: up recalls the newest command ---- */
    {
        size_t len;
        hist_count = 0;
        hist_pos = 0;
        hist_push("one");
        hist_push("two");

        mock_reset();
        mock_set_input("\x1b[A\r");          /* up, Enter */
        read_line(linebuf, &len);
        CHECK_STR_EQ(linebuf, "two");

        /* and another up walks back to the older entry */
        mock_reset();
        mock_set_input("\x1b[A\r");
        read_line(linebuf, &len);
        CHECK_STR_EQ(linebuf, "one");
    }

    /* ---- history: down returns toward the newest / empty slot ---- */
    {
        size_t len;
        hist_count = 0;
        hist_pos = 0;
        hist_push("only");

        mock_reset();
        mock_set_input("\x1b[A\x1b[A\x1b[B\r"); /* up, up(no-op), down, Enter */
        read_line(linebuf, &len);
        /* stepping down past the newest leaves an empty line */
        CHECK_STR_EQ(linebuf, "");
        CHECK_INT_EQ(len, 0);
    }

    /* ---- history: the ring drops the oldest entries when full ---- */
    {
        hist_count = 0;
        hist_pos = 0;
        for (int i = 0; i < HIST_MAX + 4; i++) {
            char cmd[16];
            cmd[0] = '0' + (char)(i / 10);
            cmd[1] = '0' + (char)(i % 10);
            cmd[2] = 0;
            hist_push(cmd);
        }
        CHECK_INT_EQ(hist_count, HIST_MAX);
        CHECK_STR_EQ(hist_entries + 0 * BUF_SIZE, "04");              /* oldest */
        CHECK_STR_EQ(hist_entries + (HIST_MAX - 1) * BUF_SIZE, "19"); /* newest */
    }
}
