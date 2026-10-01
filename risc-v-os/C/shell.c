/* ===========================================================================
 * shell.c - the line editor, the command parser and the commands themselves.
 * ===========================================================================
 *
 * The shell is an infinite loop in kernel_main with three phases:
 *   1. print a prompt,
 *   2. read and edit one line (read_line),
 *   3. hand the finished line to the parser (parse_line).
 *
 * Up/down arrows walk back and forth through the command history; left/right
 * arrows move the cursor so characters can be inserted or deleted mid-line.
 * Ctrl-C powers off the machine.
 * =========================================================================== */

#include "os.h"

/* ---------------------------------------------------------------------------
 * Editor state.  These were callee-saved registers in the assembly version
 * (s0..s3) that had to survive the whole line; here they are ordinary storage.
 * --------------------------------------------------------------------------- */
char        linebuf[BUF_SIZE];                  /* the line being edited     */
char        hist_entries[BUF_SIZE * HIST_MAX];  /* ring of previous commands */
uint64_t    hist_count;                         /* how many entries exist    */
uint64_t    hist_pos;                           /* arrow-key browse position */
const char *arg_ptr;                            /* current command argument  */

/* Growing prefix string used by the `tree` command. */
static char     tree_indent[256];
static uint64_t tree_indent_len;

/* Forward declaration: read_line calls this on Ctrl-C. */
static void do_halt(void);

/* ---------------------------------------------------------------------------
 * UTF-8 art used by `tree` (bytes spelled out so no locale is involved).
 * --------------------------------------------------------------------------- */
#define ART_CIRCLE "\xe2\x97\x8b"                        /* open circle  */
#define ART_SQUARE "\xe2\x96\xa0"                        /* filled square */
#define ART_TEE    "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 " /* "|- "        */
#define ART_ELL    "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " /* "`- "        */
#define ART_PIPE   "\xe2\x94\x82   "                     /* "|   "        */
#define ART_INDENT "    "                                /* "    "        */

/* ---------------------------------------------------------------------------
 * Read-only message strings.
 * --------------------------------------------------------------------------- */
static const char msg_uname[] =
    "Toy RISC-V OS - 64-bit RISC-V, supervisor mode, UART 16550 @ 0x10000000\r\n";

static const char msg_clear[] = "\033[2J\033[H";

static const char msg_help[] =
    "Available commands:\r\n"
    "  printf(\"text\")  print the text between the quotes\r\n"
    "  mkdir \"path\"    create a directory (parents are created too)\r\n"
    "  cd \"path\"       walk a path: cd a/b, cd .., cd ../.., cd / etc.\r\n"
    "  pwd             print the current directory path\r\n"
    "  ls              list the current directory\r\n"
    "  tree            draw the tree (square marks where you are)\r\n"
    "  help            show this help\r\n"
    "  uname           show system information\r\n"
    "  clear           clear the screen\r\n"
    "  halt, exit      power off the machine\r\n"
    "Tip: up/down = command history, left/right = move the cursor.\r\n";

/* ===========================================================================
 * Line editor.
 * =========================================================================== */

/* cursor_left: move the visual cursor left n columns by sending n backspaces. */
static void cursor_left(size_t n)
{
    while (n--)
        uart_putc(0x08);
}

/* echo_range: print buf[from .. to) to the terminal. */
static void echo_range(const char *buf, size_t from, size_t to)
{
    for (size_t i = from; i < to; i++)
        uart_putc(buf[i]);
}

/* erase_line: wipe the whole visible input line and reset the editor state.
 * The usual "BS, space, BS" rub-out trick avoids terminal-specific sequences. */
static void erase_line(char *buf, size_t *len, size_t *cur)
{
    (void)buf;                       /* only the counters change */

    cursor_left(*len - *cur);        /* first move to the end of the line */
    for (size_t i = 0; i < *len; i++) {
        uart_putc(0x08);
        uart_putc(' ');
        uart_putc(0x08);
    }
    *len = 0;
    *cur = 0;
}

/* load_hist: copy a saved history string into the line buffer and echo it.
 * This is the inverse of erase_line: it fills the gap it just cleared. */
static void load_hist(char *buf, const char *src, size_t *len, size_t *cur)
{
    size_t n = 0;
    while (src[n]) {
        buf[n] = src[n];
        n++;
    }
    echo_range(buf, 0, n);
    *len = n;
    *cur = n;                        /* cursor ends up at the end of the line */
}

/* hist_push: append one command to the history ring.  When the array is full
 * we drop the oldest entry by shifting the whole array down one slot. */
void hist_push(const char *cmd)
{
    uint64_t count = hist_count;

    if (count >= HIST_MAX) {
        bytes_copy(hist_entries, hist_entries + BUF_SIZE,
                   (HIST_MAX - 1) * BUF_SIZE);
        count = HIST_MAX - 1;
    }

    char *dst = hist_entries + count * BUF_SIZE;
    while ((*dst++ = *cmd++))
        ;                            /* copy including the terminator */

    if (hist_count < HIST_MAX)
        hist_count++;

    /* Browsing starts from "one past the newest" (an empty extra slot). */
    hist_pos = hist_count;
}

/* hist_up: recall the previous command (walk backwards in history). */
static void hist_up(char *buf, size_t *len, size_t *cur)
{
    if (hist_count == 0 || hist_pos == 0)
        return;
    hist_pos--;
    const char *src = hist_entries + hist_pos * BUF_SIZE;
    erase_line(buf, len, cur);
    load_hist(buf, src, len, cur);
}

/* hist_down: recall the next command (walk forwards in history). */
static void hist_down(char *buf, size_t *len, size_t *cur)
{
    if (hist_pos >= hist_count)
        return;
    hist_pos++;
    erase_line(buf, len, cur);
    if (hist_pos == hist_count)
        return;                      /* stepped past the newest: leave it empty */
    load_hist(buf, hist_entries + hist_pos * BUF_SIZE, len, cur);
}

/* read_line: read and edit one line until Enter is pressed.  Implements the
 * original read_char loop plus arrow-key history and mid-line cursor editing.
 *
 * On return buf holds the NUL terminated line and *out_len its length. */
void read_line(char *buf, size_t *out_len)
{
    size_t len = 0;                  /* line length                       */
    size_t cur = 0;                  /* cursor position (0 = before first)*/

    for (;;) {
        int ch = uart_getc();

        /* ESC starts an ANSI arrow-key sequence: ESC '[' A/B/C/D. */
        if (ch == 0x1b) {
            if (uart_getc() != '[')
                continue;
            int k = uart_getc();
            if (k == 'A')
                hist_up(buf, &len, &cur);
            else if (k == 'B')
                hist_down(buf, &len, &cur);
            else if (k == 'C') {
                if (cur < len) {                 /* right */
                    uart_putc(buf[cur]);
                    cur++;
                }
            } else if (k == 'D') {
                if (cur) {                       /* left */
                    cur--;
                    uart_putc(0x08);
                }
            }
            continue;
        }

        if (ch == 0x0d || ch == 0x0a) {          /* Enter */
            buf[len] = 0;
            *out_len = len;
            return;
        }

        if (ch == 0x7f || ch == 0x08) {          /* backspace */
            if (!cur)
                continue;

            /* Close the gap in the buffer by shifting the tail left. */
            for (size_t i = cur - 1; i + 1 < len; i++)
                buf[i] = buf[i + 1];
            len--;
            cur--;
            uart_putc(0x08);

            /* Redraw the tail that moved left... */
            echo_range(buf, cur, len);

            /* ...blot out the old last character and walk the cursor back. */
            uart_putc(' ');
            cursor_left(len - cur + 1);
            continue;
        }

        if (ch == 0x03)                          /* Ctrl-C: power off */
            do_halt();

        if (ch < 0x20)                           /* other controls: ignore */
            continue;
        if (len >= BUF_SIZE - 1)                 /* line already full */
            continue;

        /* Insert ch at the cursor, shifting the tail one byte to the right. */
        for (size_t i = len; i > cur; i--)
            buf[i] = buf[i - 1];
        buf[cur] = (char)ch;
        len++;
        cur++;

        /* Re-print from the inserted character to the end, then back the
         * visual cursor up if the insertion happened mid-line. */
        echo_range(buf, cur - 1, len);
        cursor_left(len - cur);
    }
}

/* print_prompt: draw the shell prompt, e.g. "riscv:/usr/bin> ". */
void print_prompt(void)
{
    uart_puts("riscv:");
    print_path(cwd_ptr);
    uart_puts("> ");
}

/* ===========================================================================
 * Commands.
 * =========================================================================== */

/* do_printf: implement printf("text").  cmd points at the start of the line,
 * which we know is "printf(".  Spaces inside the quotes are preserved. */
static void do_printf(const char *cmd)
{
    const char *p = cmd + 7;         /* skip the 7 characters of "printf(" */
    while (*p == ' ')
        p++;
    if (*p != '"')
        return;                      /* malformed, no opening quote: give up */
    p++;
    while (*p && *p != '"') {
        uart_putc(*p);
        p++;
    }
    uart_newline();
}

/* do_mkdir: create a directory (and any missing parents, like mkdir -p). */
static void do_mkdir(void)
{
    if (!copy_name(arg_ptr, pathbuf)) {
        uart_puts("mkdir: missing name (usage: mkdir \"name\")\r\n");
        return;
    }
    node_t *n = path_walk(cwd_ptr, pathbuf, 1);
    if (!n) {
        uart_puts("mkdir: no space left in the node pool\r\n");
        return;
    }
    save_fs();                       /* persist the new directory to disk */
}

/* do_cd: change the current directory.  With no argument we go to the root;
 * otherwise the target must already exist (path_walk mode 0). */
static void do_cd(void)
{
    if (!copy_name(arg_ptr, pathbuf)) {
        cwd_ptr = &node_pool[0];
        return;
    }
    node_t *n = path_walk(cwd_ptr, pathbuf, 0);
    if (!n) {
        uart_puts("cd: no such directory: ");
        uart_puts(pathbuf);
        uart_newline();
        return;
    }
    cwd_ptr = n;
}

/* do_pwd: print the absolute path of the current directory. */
static void do_pwd(void)
{
    print_path(cwd_ptr);
    uart_newline();
}

/* do_ls: walk the current directory's child list and print each name. */
static void do_ls(void)
{
    for (node_t *c = cwd_ptr->first; c; c = c->next) {
        print_name(c);
        uart_newline();
    }
}

/* tree_walk: print every descendant of dir, one per line, with indentation.
 *
 * The indentation is a growing string in tree_indent that prefixes each line:
 * "|   " under a non-last branch and "    " under a last one.  We remember the
 * length before extending so the string can be restored after recursing. */
static void tree_walk(node_t *dir)
{
    for (node_t *c = dir->first; c; c = c->next) {
        uart_puts(tree_indent);

        int last = (c->next == 0);
        uart_puts(last ? ART_ELL : ART_TEE);
        uart_puts(c == cwd_ptr ? ART_SQUARE : ART_CIRCLE);
        uart_putc(' ');
        print_name(c);
        uart_newline();

        if (c->first) {              /* recurse only when it has children */
            uint64_t saved = tree_indent_len;
            const char *ext = last ? ART_INDENT : ART_PIPE;
            char *d = tree_indent + saved;
            while ((*d++ = *ext++))
                ;                    /* append ext (including its NUL) */
            tree_indent_len = (uint64_t)((d - 1) - tree_indent);

            tree_walk(c);

            tree_indent_len = saved; /* restore the indent to this level */
            tree_indent[saved] = 0;
        }
    }
}

/* do_tree: draw the whole tree from the root; a filled square marks the
 * current directory and an open circle every other one. */
static void do_tree(void)
{
    tree_indent[0] = 0;
    tree_indent_len = 0;

    node_t *root = &node_pool[0];
    uart_puts(root == cwd_ptr ? ART_SQUARE : ART_CIRCLE);
    uart_putc(' ');
    print_name(root);
    uart_newline();

    tree_walk(root);
}

/* do_halt: power the machine off. */
static void do_halt(void)
{
    uart_puts("\r\nPowering off. Bye!\r\n");
    platform_halt();                 /* never returns */
}

/* parse_line: turn a raw input line into a command and an optional argument,
 * then dispatch.  It NUL terminates the command word in place. */
void parse_line(char *line)
{
    char *p = line;
    while (*p == ' ')                /* skip leading spaces */
        p++;
    if (*p == 0)
        return;                      /* blank line: nothing to do */

    char *cmd = p;

    /* printf("...") is handled before tokenizing so spaces inside quotes work. */
    if (starts_with(cmd, "printf(")) {
        do_printf(cmd);
        return;
    }

    /* Find the end of the command word (a space or the NUL terminator). */
    while (*p && *p != ' ')
        p++;
    if (*p == 0) {
        arg_ptr = p;                 /* empty argument points at the NUL */
    } else {
        *p = 0;                      /* end the command word */
        p++;
        while (*p == ' ')            /* skip the spaces before the argument */
            p++;
        arg_ptr = p;
    }

    if (streq(cmd, "help"))
        uart_puts(msg_help);
    else if (streq(cmd, "uname"))
        uart_puts(msg_uname);
    else if (streq(cmd, "clear"))
        uart_puts(msg_clear);
    else if (streq(cmd, "mkdir"))
        do_mkdir();
    else if (streq(cmd, "cd"))
        do_cd();
    else if (streq(cmd, "pwd"))
        do_pwd();
    else if (streq(cmd, "ls"))
        do_ls();
    else if (streq(cmd, "tree"))
        do_tree();
    else if (streq(cmd, "halt") || streq(cmd, "exit"))
        do_halt();
    else {
        uart_puts("unknown command: ");
        uart_puts(cmd);
        uart_newline();
    }
}
