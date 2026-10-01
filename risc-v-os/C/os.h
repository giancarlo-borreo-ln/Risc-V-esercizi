/* ===========================================================================
 * os.h - shared definitions for the toy RISC-V OS.
 * ===========================================================================
 *
 * Everything the individual translation units need to agree on lives here:
 * the fixed sizes, the filesystem node layout, and the prototypes for the
 * three layers the OS is split into.
 *
 * The OS has a hard hardware boundary at two places only:
 *
 *   * the UART (uart_putc / uart_getc / uart_puts / uart_newline),
 *   * the block device (blk_init / blk_rw) and the platform halt.
 *
 * On the real target those are implemented in uart.c and virtio.c.  The unit
 * tests link small in-memory stand-ins instead, which is what makes the rest
 * of the OS testable on the host without a RISC-V machine.
 * =========================================================================== */

#ifndef OS_H
#define OS_H

#include <stdint.h>
#include <stddef.h>

/* ---------------------------------------------------------------------------
 * Shell buffer sizes.  Everything is statically allocated; there is no heap.
 * --------------------------------------------------------------------------- */
#define BUF_SIZE  128    /* max length of one input line (including NUL)      */
#define PATH_SIZE 128    /* max length of a path argument such as "a/b/c"      */
#define HIST_MAX  16     /* how many previous commands to remember             */

/* ---------------------------------------------------------------------------
 * In-memory directory tree node layout.  A node holds a short name and three
 * pointers, giving a tree where each directory links to its first child and
 * each child links to its next sibling (a classic "LCRS" tree):
 *
 *        node_pool[0] "/"  (root)
 *              |
 *           "usr" --next--> "etc" --next--> "home" ...
 *              |
 *            "bin" -> ...
 * --------------------------------------------------------------------------- */
#define NAME_LEN  24     /* fixed name field size (23 chars + NUL)             */
#define NODE_SIZE 48     /* total bytes per node (must cover all fields)       */
#define MAX_NODES 256u   /* size of the static node pool                       */

typedef struct node {
    char         name[NAME_LEN];   /* NUL terminated short name            */
    struct node *parent;           /* parent directory (NULL for the root) */
    struct node *first;            /* first child in the child list        */
    struct node *next;             /* next sibling in the parent's list    */
} node_t;

/* ---------------------------------------------------------------------------
 * On-disk layout of the saved filesystem (see save_fs / load_fs).
 * A single 16-byte header is followed by one 28-byte record per non-root node.
 * A record stores the parent's INDEX (not a pointer) plus the name, which is
 * all load_fs needs to rebuild the tree.
 * --------------------------------------------------------------------------- */
#define FS_MAGIC    0x31305346534F5652ULL  /* the 8 bytes "RVOSFS01"         */
#define FS_HDR_SIZE 16    /* magic (8) + node count (4) + padding (4)          */
#define FS_REC_SIZE 28    /* parent index (4) + name (NAME_LEN = 24)           */
#define SECTOR_SIZE 512   /* everything talks in 512-byte blocks               */

/* The image itself, so the persistence code can use named fields instead of
 * raw byte offsets.  The sizes must match FS_HDR_SIZE / FS_REC_SIZE. */
typedef struct {
    uint64_t magic;       /* always FS_MAGIC                  */
    uint32_t node_count;  /* number of live nodes, root included */
    uint32_t reserved;    /* padding, written as zero         */
} fs_header_t;

typedef struct {
    uint32_t parent;          /* index of the parent in node_pool */
    char     name[NAME_LEN];  /* fixed-size name field            */
} fs_record_t;

typedef char fs_header_size_assert[sizeof(fs_header_t) == FS_HDR_SIZE ? 1 : -1];
typedef char fs_record_size_assert[sizeof(fs_record_t) == FS_REC_SIZE ? 1 : -1];

/* Block request types understood by the generic virtio-blk layer. */
#define BLK_T_IN   0      /* read a sector from the disk  */
#define BLK_T_OUT  1      /* write a sector to the disk   */

/* ===========================================================================
 * Platform interface.  Real code lives in uart.c / virtio.c; the host test
 * build provides mocks in tests/mock_platform.c.
 * =========================================================================== */

/* Serial port. */
void uart_putc(char c);
int  uart_getc(void);
void uart_puts(const char *s);
void uart_newline(void);

/* Power the machine off.  Never returns. */
void platform_halt(void);

/* Block device.  blk_ready is 0 until blk_init succeeds; when it is 0 the
 * filesystem persistence routines quietly become no-ops. */
extern uint64_t blk_ready;
int blk_init(void);
int blk_rw(uint32_t type, uint64_t sector, void *buf, uint32_t nsectors);

/* ===========================================================================
 * String helpers (strutil.c).
 * =========================================================================== */
int  streq(const char *a, const char *b);
int  starts_with(const char *a, const char *b);
int  copy_name(const char *src, char *dst);
void bytes_copy(void *dst, const void *src, size_t n);
void bytes_zero(void *dst, size_t n);

/* ===========================================================================
 * Filesystem (fs.c).  The pool and the current directory are plain globals so
 * they can be inspected and reset from the unit tests.
 * =========================================================================== */
extern node_t   node_pool[MAX_NODES];
extern uint64_t node_count;
extern node_t  *cwd_ptr;
extern char     pathbuf[PATH_SIZE];

/* The fake host tree, generated at build time (fakeroot.c). */
extern const unsigned char fake_paths[];

void    print_name(const node_t *n);
void    print_path(const node_t *n);
node_t *alloc_node(void);
node_t *find_child(node_t *parent, const char *name);
void    link_child(node_t *parent, node_t *child);
node_t *path_walk(node_t *start, const char *path, int mode);
void    init_fs(void);
void    save_fs(void);
int     load_fs(void);

/* ===========================================================================
 * Shell (shell.c).  The editor state is exposed so the tests can inspect the
 * command history directly.
 * =========================================================================== */
extern char        linebuf[BUF_SIZE];
extern char        hist_entries[BUF_SIZE * HIST_MAX];
extern uint64_t    hist_count;
extern uint64_t    hist_pos;
extern const char *arg_ptr;

void print_prompt(void);
void hist_push(const char *cmd);
void read_line(char *buf, size_t *out_len);
void parse_line(char *line);

#endif /* OS_H */
