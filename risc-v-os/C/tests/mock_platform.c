/* ===========================================================================
 * tests/mock_platform.c - host stand-ins for the hardware boundary.
 * ===========================================================================
 *
 * The real uart.c / virtio.c talk to qemu.  For the host tests we replace both
 * with in-memory versions:
 *
 *   * uart output is appended to a capture buffer and uart input is served
 *     from a scripted byte string, so the line editor can be driven exactly;
 *   * the block device is a RAM buffer, so save_fs / load_fs can round-trip.
 *
 * Only the symbols declared in os.h are provided; nothing else from the real
 * hardware files is needed by the tested code.
 * =========================================================================== */

#include "os.h"
#include "test.h"

/* ---------------------------------------------------------------------------
 * Block device.
 * --------------------------------------------------------------------------- */
uint64_t blk_ready;                       /* toggled by the tests directly */

static uint8_t mock_disk[64 * 1024];

int blk_init(void)
{
    blk_ready = 1;
    return 1;
}

int blk_rw(uint32_t type, uint64_t sector, void *buf, uint32_t nsectors)
{
    size_t off = (size_t)(sector * SECTOR_SIZE);
    size_t len = (size_t)nsectors * SECTOR_SIZE;

    if (off + len > sizeof mock_disk)
        return -1;

    if (type == BLK_T_IN)
        memcpy(buf, mock_disk + off, len);
    else
        memcpy(mock_disk + off, buf, len);
    return 0;
}

/* ---------------------------------------------------------------------------
 * UART.
 * --------------------------------------------------------------------------- */
static char   out_buf[65536];
static size_t out_len;
static char   in_buf[1024];
static size_t in_len;
static size_t in_pos;

void uart_putc(char c)
{
    if (out_len < sizeof out_buf - 1)
        out_buf[out_len++] = c;
}

int uart_getc(void)
{
    if (in_pos < in_len)
        return (unsigned char)in_buf[in_pos++];
    return -1;                            /* end of scripted input */
}

void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

void uart_newline(void)
{
    uart_putc('\r');
    uart_putc('\n');
}

/* platform_halt: the tests never expect to reach this.  Looping keeps the
 * process alive (and the function's "never returns" contract) if a test
 * accidentally triggers a halt. */
void platform_halt(void)
{
    for (;;)
        ;
}

/* ---------------------------------------------------------------------------
 * Helpers used by the tests.
 * --------------------------------------------------------------------------- */
void mock_reset(void)
{
    out_len = 0;
    in_len = 0;
    in_pos = 0;
    memset(out_buf, 0, sizeof out_buf);
}

void mock_set_input(const char *s)
{
    size_t n = strlen(s);
    if (n > sizeof in_buf)
        n = sizeof in_buf;
    memcpy(in_buf, s, n);
    in_len = n;
    in_pos = 0;
}

const char *mock_output(void)
{
    out_buf[out_len] = 0;
    return out_buf;
}

size_t mock_output_len(void)
{
    return out_len;
}

void mock_disk_reset(void)
{
    memset(mock_disk, 0, sizeof mock_disk);
}

uint8_t *mock_disk_data(void)
{
    return mock_disk;
}

size_t mock_disk_size(void)
{
    return sizeof mock_disk;
}
