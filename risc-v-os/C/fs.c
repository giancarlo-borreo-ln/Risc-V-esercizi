/* ===========================================================================
 * fs.c - the in-memory filesystem and its on-disk persistence.
 * ===========================================================================
 *
 * The "filesystem" is a statically sized pool of nodes (node_pool).  A node
 * stores a short name and three pointers, giving a tree where each directory
 * links to its first child and each child links to its next sibling.  See the
 * diagram next to NODE_SIZE in os.h.
 *
 * save_fs packs the tree into fs_buf and writes it to sector 0 onward; load_fs
 * reads the header, validates the magic and rebuilds node_pool from the
 * records.  Both are no-ops when blk_ready is 0, so a machine booted without a
 * disk still works.  The serialised layout is described in os.h.
 * =========================================================================== */

#include "os.h"

/* ---------------------------------------------------------------------------
 * Global filesystem state.  Kept as plain globals so the unit tests can reset
 * and inspect them.
 * --------------------------------------------------------------------------- */
node_t   node_pool[MAX_NODES];       /* the in-memory filesystem tree       */
uint64_t node_count;                 /* nodes handed out by alloc_node      */
node_t  *cwd_ptr;                    /* current working directory node      */
char     pathbuf[PATH_SIZE];         /* scratch for a whole path argument   */

/* Scratch for one path component while walking a path. */
static char compbuf[NAME_LEN];

/* Staging buffer for the serialised filesystem image.  MAX_NODES records plus
 * the header need 16 + 256*28 = 7156 bytes, so one 8 KiB page is plenty. */
static uint8_t fs_buf[8192] __attribute__((aligned(8)));

/* print_name: print the NUL terminated name stored inside a node. */
void print_name(const node_t *n)
{
    for (const char *p = n->name; *p; p++)
        uart_putc(*p);
}

/* print_path: print the absolute path of a node, e.g. "/usr/bin".
 *
 * This is a textbook recursion: to print my path I first ask my parent to
 * print its path, then append "/" + my own name.  The root is the base case. */
void print_path(const node_t *n)
{
    if (!n->parent) {
        uart_putc('/');              /* the root prints as a single "/" */
        return;
    }
    print_path(n->parent);
    /* The root's path already ends in "/", so skip the extra slash when our
     * parent is the root (i.e. the grandparent is NULL). */
    if (n->parent->parent)
        uart_putc('/');
    print_name(n);
}

/* set_name: store a NUL terminated name in a node, truncating if needed. */
static void set_name(node_t *n, const char *name)
{
    size_t i = 0;
    while (i < NAME_LEN - 1 && name[i]) {
        n->name[i] = name[i];
        i++;
    }
    n->name[i] = 0;
}

/* make_root: reset node_pool[0] to a fresh "/" and make it the cwd.  Used both
 * when building a default tree and when reloading one from disk. */
static void make_root(void)
{
    node_t *root = &node_pool[0];
    bytes_zero(root, NODE_SIZE);
    set_name(root, "/");
    cwd_ptr = root;
}

/* alloc_node: hand out the next free slot from the node pool.
 * Returns a zeroed node, or NULL when the pool is exhausted. */
node_t *alloc_node(void)
{
    if (node_count >= MAX_NODES)
        return NULL;

    node_t *n = &node_pool[node_count++];

    /* Zero the whole node so all pointers start out NULL. */
    bytes_zero(n, NODE_SIZE);
    return n;
}

/* find_child: look up a direct child of a directory by name.
 * Returns the matching child node, or NULL if not found. */
node_t *find_child(node_t *parent, const char *name)
{
    for (node_t *c = parent->first; c; c = c->next) {
        const char *a = c->name;
        const char *b = name;
        while (*a && *a == *b) {
            a++;
            b++;
        }
        if (*a == 0 && *b == 0)
            return c;
    }
    return NULL;
}

/* link_child: append a node to the end of a directory's child list. */
void link_child(node_t *parent, node_t *child)
{
    if (!parent->first) {
        parent->first = child;       /* empty list: child becomes the first */
        return;
    }
    node_t *t = parent->first;
    while (t->next)                  /* otherwise find the current tail */
        t = t->next;
    t->next = child;
}

/* path_walk: the heart of the filesystem, a mini pathname resolver.
 *
 * It splits the path on '/' and processes one component at a time, handling a
 * leading '/' (start at the root), "." (stay put) and ".." (move to parent).
 *
 *   start : the starting node (usually the cwd)
 *   path  : the path string
 *   mode  : 0 = cd    (every component must already exist)
 *           1 = mkdir (create missing components as we go)
 *
 * Returns the resulting node, or NULL on failure. */
node_t *path_walk(node_t *start, const char *path, int mode)
{
    node_t *cur = start;
    const char *s = path;

    /* A leading '/' means the path is absolute: start the walk at the root. */
    if (*s == '/')
        cur = &node_pool[0];

    for (;;) {
        while (*s == '/')            /* collapse runs of slashes */
            s++;
        if (*s == 0)
            break;                   /* resolved everything */

        /* Collect the next component into compbuf (up to '/' or NUL). */
        size_t n = 0;
        while (*s && *s != '/') {
            if (n < NAME_LEN - 1)
                compbuf[n++] = *s;
            s++;
        }
        compbuf[n] = 0;

        /* "." means "this directory": nothing to do. */
        if (streq(compbuf, "."))
            continue;

        /* ".." means "go to the parent" (the root stays at the root). */
        if (streq(compbuf, "..")) {
            if (cur->parent)
                cur = cur->parent;
            continue;
        }

        /* Ordinary name: does the current directory already have it? */
        node_t *child = find_child(cur, compbuf);
        if (child) {
            cur = child;
            continue;
        }

        if (mode == 0)
            return NULL;             /* cd: a missing component is an error */

        /* mkdir mode: create the missing directory on the fly. */
        node_t *nn = alloc_node();
        if (!nn)
            return NULL;             /* pool full */

        set_name(nn, compbuf);
        nn->parent = cur;
        link_child(cur, nn);         /* first/next were zeroed by alloc_node */
        cur = nn;
    }
    return cur;
}

/* init_fs: build the initial filesystem.
 *
 * It creates the root node, then replays every directory path that the build
 * harvested from the host into the tree (using mkdir mode so missing parents
 * spring into existence).  Finally the shell's cwd is set to "/". */
void init_fs(void)
{
    node_count = 1;
    make_root();
    node_t *root = &node_pool[0];

    /* fake_paths is a NUL separated list of paths ending with an empty
     * string, exactly as generated from the host's directory names. */
    const char *p = (const char *)fake_paths;
    while (*p) {
        path_walk(root, p, 1);
        while (*p)                   /* advance past this NUL terminated path */
            p++;
        p++;                         /* step over the NUL separator */
    }
}

/* ===========================================================================
 * Persistence.
 * =========================================================================== */

/* save_fs: serialise the current tree to disk.  Failures are silent; the RAM
 * tree remains authoritative. */
void save_fs(void)
{
    if (!blk_ready)
        return;                      /* no disk attached: nothing to do */

    uint64_t n = node_count;

    /* --- header: magic + node count --- */
    fs_header_t *hdr = (fs_header_t *)fs_buf;
    hdr->magic      = FS_MAGIC;
    hdr->node_count = (uint32_t)n;
    hdr->reserved   = 0;

    /* --- one record per non-root node, in node-pool order --- */
    fs_record_t *rec = (fs_record_t *)(fs_buf + sizeof(fs_header_t));
    for (uint64_t i = 1; i < n; i++) {
        node_t *nd = &node_pool[i];

        /* Store the parent as an INDEX so pointers do not leak into the image. */
        rec[i - 1].parent = (uint32_t)(nd->parent - node_pool);
        bytes_copy(rec[i - 1].name, nd->name, NAME_LEN);
    }

    /* --- how many sectors does the image occupy?  at least one. --- */
    uint64_t bytes   = FS_HDR_SIZE + (n - 1) * FS_REC_SIZE;
    uint64_t sectors = (bytes + SECTOR_SIZE - 1) >> 9;   /* ceil(bytes / 512) */
    if (!sectors)
        sectors = 1;

    blk_rw(BLK_T_OUT, 0, fs_buf, (uint32_t)sectors);
}

/* load_fs: try to rebuild node_pool from disk.
 * Returns 1 on success, 0 when there is no disk or no valid image.  On success
 * node_count and cwd_ptr are updated; on failure the caller should build the
 * default tree with init_fs instead. */
int load_fs(void)
{
    if (!blk_ready)
        return 0;

    /* --- read the header sector and check it --- */
    if (blk_rw(BLK_T_IN, 0, fs_buf, 1))
        return 0;

    fs_header_t *hdr = (fs_header_t *)fs_buf;
    if (hdr->magic != FS_MAGIC)
        return 0;                    /* blank/foreign disk: build the fake tree */

    uint64_t n = hdr->node_count;
    if (n < 1 || n > MAX_NODES)
        return 0;
    node_count = n;

    /* --- pull in the rest of the image if it spans several sectors --- */
    uint64_t bytes   = FS_HDR_SIZE + (n - 1) * FS_REC_SIZE;
    uint64_t sectors = (bytes + SECTOR_SIZE - 1) >> 9;
    if (sectors > 1) {
        if (blk_rw(BLK_T_IN, 0, fs_buf, (uint32_t)sectors))
            return 0;
    }

    /* --- recreate the root, then replay every record --- */
    make_root();

    fs_record_t *rec = (fs_record_t *)(fs_buf + sizeof(fs_header_t));
    for (uint64_t i = 1; i < n; i++) {
        node_t *nd = &node_pool[i];

        nd->parent = &node_pool[rec[i - 1].parent];  /* index -> pointer */
        bytes_copy(nd->name, rec[i - 1].name, NAME_LEN);
        nd->first = NULL;            /* rebuild the child links from scratch */
        nd->next = NULL;
        link_child(nd->parent, nd);
    }
    return 1;
}
