/* ===========================================================================
 * main.c - boot entry point and the kernel main loop.
 * ===========================================================================
 *
 * OpenSBI loads this kernel at 0x80200000 and jumps to it with no stack set
 * up.  _start points sp at the top of our static stack and hands control to
 * kernel_main, which brings up the filesystem and then drops into the shell's
 * read-eval-print loop forever.
 * =========================================================================== */

#include "os.h"

/* ---------------------------------------------------------------------------
 * The kernel stack.  It grows downward, so _start sets sp to
 * stack_area + sizeof(stack_area).  Sixteen KiB is plenty for our shallow
 * recursion (print_path and tree_walk).
 * --------------------------------------------------------------------------- */
uint8_t stack_area[16384] __attribute__((aligned(16)));

static const char msg_banner[] =
    "\r\n"
    "  ____  ___ ____   __     __\r\n"
    " |  _ \\|_ _/ ___|  \\ \\   / /\r\n"
    " | |_) || |\\___ \\   \\ \\ / / \r\n"
    " |  _ < | | ___) |   \\ V /  \r\n"
    " |_| \\_\\___|____/     \\_/   \r\n"
    "\r\n"
    "Toy RISC-V OS v1.0 (RV64, qemu virt)\r\n"
    "Type 'help' for the list of commands.\r\n\r\n";

/* kernel_main: initialise the filesystem, print the banner, run the shell. */
void kernel_main(void) __attribute__((used, noreturn));
void kernel_main(void)
{
    /* Bring up the block device (if any), then prefer a filesystem already
     * saved on disk.  A blank or absent image falls back to the fake host
     * tree, which we immediately persist so the next boot finds it. */
    blk_init();
    if (!load_fs()) {
        init_fs();
        save_fs();
    }

    uart_puts(msg_banner);

    for (;;) {
        print_prompt();

        size_t len;
        read_line(linebuf, &len);

        /* Remember non-empty lines so the arrows can walk back through them. */
        if (len)
            hist_push(linebuf);

        uart_newline();
        parse_line(linebuf);
    }
}

/* ---------------------------------------------------------------------------
 * _start: the linker script puts .text.start first, so this symbol sits at the
 * very base of the image (0x80200000) where OpenSBI jumps.  A naked function
 * has no compiler-generated prologue, which is essential because sp is not
 * valid yet.
 * --------------------------------------------------------------------------- */
void _start(void) __attribute__((naked, noreturn, section(".text.start")));
void _start(void)
{
    __asm__ volatile(
        "la t0, stack_area\n"        /* t0 = bottom of the kernel stack */
        "lui t1, 4\n"                /* t1 = 16384 (0x4000)             */
        "add sp, t0, t1\n"           /* sp = top of the kernel stack    */
        "call kernel_main\n"         /* run the OS; never returns       */
        "1:\n"
        "wfi\n"                      /* if it ever does, just sleep     */
        "j 1b\n");
}
