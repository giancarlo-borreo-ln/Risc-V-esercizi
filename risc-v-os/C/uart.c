/* ===========================================================================
 * uart.c - the NS16550A serial driver and the platform halt.
 * ===========================================================================
 *
 * This file is one half of the OS's hardware boundary (the other is virtio.c).
 * The UART has no interrupt wiring here; instead every function polls the line
 * status register in a busy-wait loop.  Simple, slow, and plenty for a shell.
 * =========================================================================== */

#include "os.h"

/* ---------------------------------------------------------------------------
 * NS16550A registers.  Only two matter for this toy: the transmit holding
 * register (read to receive, write to send) and the line status register.
 * --------------------------------------------------------------------------- */
#define UART_BASE 0x10000000UL   /* MMIO base address of the serial port */
#define UART_THR  0x00           /* transmit holding register            */
#define UART_LSR  0x05           /* line status register                 */
#define LSR_RX    0x01           /* LSR bit 0: a received byte is waiting */
#define LSR_TX    0x20           /* LSR bit 5: the transmit FIFO is empty */

/* MMIO loads must not be cached or reordered by the compiler. */
static inline uint8_t uart_read(uintptr_t off)
{
    return *(volatile uint8_t *)(UART_BASE + off);
}

/* uart_putc: send one byte, waiting until the transmit FIFO has room. */
void uart_putc(char c)
{
    while (!(uart_read(UART_LSR) & LSR_TX))
        ;
    *(volatile uint8_t *)(UART_BASE + UART_THR) = (uint8_t)c;
}

/* uart_getc: wait for and read one byte. */
int uart_getc(void)
{
    while (!(uart_read(UART_LSR) & LSR_RX))
        ;
    return uart_read(UART_THR);
}

/* uart_puts: print a NUL terminated string. */
void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

/* uart_newline: emit CR + LF, the conventional serial end-of-line. */
void uart_newline(void)
{
    uart_putc('\r');
    uart_putc('\n');
}

/* ---------------------------------------------------------------------------
 * platform_halt: power the machine off.  Two independent mechanisms are tried
 * because not every environment supports both.
 * --------------------------------------------------------------------------- */
void platform_halt(void)
{
    /* Mechanism 1: the SBI "system reset" (SRST) extension.  Supervisor code
     * asks the firmware below us to shut down with an ecall carrying:
     *   a7 = extension id (0x08 = SRST), a6 = function id (0 = reset),
     *   a0 = reset type (0 = shutdown), a1 = reset reason (0 = none). */
    __asm__ volatile(
        "li a7, 0x08\n"
        "li a6, 0\n"
        "li a0, 0\n"
        "li a1, 0\n"
        "ecall\n"
        ::: "a0", "a1", "a6", "a7", "memory");

    /* Mechanism 2 (fallback): the SiFive test finisher on the qemu virt
     * machine.  Writing 0x5555 to 0x100000 asks qemu to exit. */
    *(volatile uint32_t *)0x100000 = 0x5555;

    /* If even that failed, spin forever in a low-power wait. */
    for (;;)
        __asm__ volatile("wfi");
}
