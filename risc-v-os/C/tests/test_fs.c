/* ===========================================================================
 * tests/test_fs.c - unit tests for the filesystem and its persistence.
 * =========================================================================== */

#include "os.h"
#include "test.h"

/* Reset all mutable filesystem state to a clean slate. */
static void fs_reset(void)
{
    memset(node_pool, 0, sizeof node_pool);
    node_count = 0;
    cwd_ptr = NULL;
}

/* Build the default tree from tests/test_fakeroot.c. */
static void fs_build(void)
{
    fs_reset();
    init_fs();
}

void test_fs(void)
{
    /* ---- init_fs builds the whole fake tree ---- */
    {
        fs_build();
        node_t *root = &node_pool[0];

        CHECK_INT_EQ(node_count, 7);          /* root + six directories */
        CHECK_STR_EQ(root->name, "/");
        CHECK(root->parent == NULL);
        CHECK(cwd_ptr == root);

        node_t *usr   = find_child(root, "usr");
        node_t *etc   = find_child(root, "etc");
        node_t *home  = find_child(root, "home");
        CHECK(usr != NULL);
        CHECK(etc != NULL);
        CHECK(home != NULL);

        CHECK_INT_EQ(strlen(usr->name), 3);
        CHECK(find_child(root, "does-not-exist") == NULL);

        node_t *bin = find_child(usr, "bin");
        CHECK(bin != NULL);
        CHECK_INT_EQ(strlen(bin->name), 3);
        CHECK(find_child(bin, "tools") != NULL);
    }

    /* ---- path_walk: absolute and relative resolution ---- */
    {
        fs_build();
        node_t *root = &node_pool[0];
        node_t *bin  = find_child(find_child(root, "usr"), "bin");

        CHECK(path_walk(root, "/usr/bin", 0) == bin);
        CHECK(path_walk(bin, "../../etc", 0) == find_child(root, "etc"));
        CHECK(path_walk(bin, ".", 0) == bin);
        CHECK(path_walk(root, "/", 0) == root);
        CHECK(path_walk(root, "usr/./bin", 0) == bin);
        CHECK(path_walk(root, "//usr///bin//", 0) == bin);

        /* cd mode refuses a missing component */
        CHECK(path_walk(root, "nope", 0) == NULL);

        /* ".." at the root stays at the root */
        CHECK(path_walk(root, "..", 0) == root);
    }

    /* ---- path_walk: mkdir mode creates missing parents ---- */
    {
        fs_build();
        node_t *root = &node_pool[0];
        uint64_t before = node_count;

        node_t *deep = path_walk(root, "a/b/c", 1);
        CHECK(deep != NULL);
        CHECK_INT_EQ(node_count - before, 3);
        CHECK_STR_EQ(deep->name, "c");

        node_t *a = find_child(root, "a");
        node_t *b = find_child(a, "b");
        CHECK(a != NULL);
        CHECK(b != NULL);
        CHECK(find_child(b, "c") == deep);

        /* Creating an existing path allocates nothing. */
        CHECK(path_walk(root, "a/b/c", 1) == deep);
        CHECK_INT_EQ(node_count - before, 3);
    }

    /* ---- alloc_node eventually reports the pool is full ---- */
    {
        fs_reset();
        CHECK(alloc_node() != NULL);
        CHECK_INT_EQ(node_count, 1);

        node_count = MAX_NODES;
        CHECK(alloc_node() == NULL);
        CHECK_INT_EQ(node_count, MAX_NODES);
    }

    /* ---- persistence: save then load rebuilds the same tree ---- */
    {
        fs_build();
        uint64_t saved_count = node_count;

        blk_ready = 1;
        mock_disk_reset();
        save_fs();

        /* Wipe RAM completely, including the root, to prove load_fs rebuilds. */
        fs_reset();
        CHECK_INT_EQ(node_count, 0);

        CHECK_INT_EQ(load_fs(), 1);
        CHECK_INT_EQ(node_count, saved_count);

        node_t *root = &node_pool[0];
        CHECK_STR_EQ(root->name, "/");
        CHECK(root->parent == NULL);
        CHECK(cwd_ptr == root);

        node_t *usr = find_child(root, "usr");
        node_t *bin = find_child(usr, "bin");
        CHECK(usr != NULL);
        CHECK(bin != NULL);
        CHECK(find_child(bin, "tools") != NULL);
        CHECK(find_child(root, "etc") != NULL);
        CHECK(find_child(root, "home") != NULL);
    }

    /* ---- persistence: a blank disk is not a valid filesystem ---- */
    {
        blk_ready = 1;
        mock_disk_reset();
        CHECK_INT_EQ(load_fs(), 0);
    }

    /* ---- persistence: without a device everything is a silent no-op ---- */
    {
        blk_ready = 0;
        fs_reset();
        /* save_fs with no device must not touch the disk or crash. */
        save_fs();
        CHECK_INT_EQ(mock_disk_data()[0], 0);
        CHECK_INT_EQ(load_fs(), 0);
    }

    /* ---- persistence: a node count larger than the pool is rejected ---- */
    {
        blk_ready = 1;
        mock_disk_reset();

        uint8_t *disk = mock_disk_data();
        *(uint64_t *)disk = FS_MAGIC;
        *(uint32_t *)(disk + 8) = MAX_NODES + 1;

        CHECK_INT_EQ(load_fs(), 0);
    }
}
