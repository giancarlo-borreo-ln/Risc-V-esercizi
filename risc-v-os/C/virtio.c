/* ===========================================================================
 * virtio.c - the virtio-blk over virtio-mmio "SSD" driver.
 * ===========================================================================
 *
 * The whole driver is deliberately minimal.  A virtio split virtqueue is three
 * arrays that we and the device share in RAM:
 *
 *   descriptor table : one 16-byte entry per buffer we want transferred
 *   available ring   : "driver wrote here, device please look"
 *   used ring        : "device is done with these"
 *
 * A block request is just three chained descriptors: a 16-byte request header
 * (type + sector number), the 512-byte data buffer, and a one-byte status the
 * device writes when it finishes.  We publish the request in the available
 * ring, ring the doorbell (QueueNotify), then poll the used ring until the
 * device reports it is done.  No interrupts are used anywhere in this OS.
 * =========================================================================== */

#include "os.h"

/* ---------------------------------------------------------------------------
 * virtio-mmio transport registers.  On the qemu "virt" board the transport
 * lives at 0x10001000 and up; each slot is a page of registers.  We probe
 * those slots for a device whose magic spells "virt", whose version is the
 * modern 2, and whose device id is 2 (block).  Offsets are from the virtio
 * 1.x MMIO specification.
 * --------------------------------------------------------------------------- */
#define VIRT_MAGIC        0x000
#define VIRT_VERSION      0x004
#define VIRT_DEVICE_ID    0x008
#define VIRT_MAGIC_VAL    0x74726976u   /* the little-endian word "virt" */
#define VIRT_VERSION_2    2
#define VIRTIO_DEV_BLK    2

#define VIRT_DEV_FEAT     0x010
#define VIRT_DEV_FEAT_SEL 0x014
#define VIRT_DRV_FEAT     0x020
#define VIRT_DRV_FEAT_SEL 0x024
#define VIRT_QUEUE_SEL    0x030
#define VIRT_QUEUE_NUMMAX 0x034
#define VIRT_QUEUE_NUM    0x038
#define VIRT_QUEUE_READY  0x044
#define VIRT_QUEUE_NOTIFY 0x050
#define VIRT_STATUS       0x070
#define VIRT_QDESC_LOW    0x080
#define VIRT_QDESC_HIGH   0x084
#define VIRT_QDRIVER_LOW  0x090
#define VIRT_QDRIVER_HIGH 0x094
#define VIRT_QDEVICE_LOW  0x0a0
#define VIRT_QDEVICE_HIGH 0x0a4

#define VIRT_STATUS_ACK          1   /* "I have noticed the device"          */
#define VIRT_STATUS_DRIVER       2   /* "I know how to drive it"             */
#define VIRT_STATUS_FEATURES_OK  8   /* "the features we agreed on are usable" */
#define VIRT_STATUS_DRIVER_OK    4   /* "setup is done, let's go"            */

/* The split virtqueue we build.  Eight descriptors is small but more than
 * enough: each transfer uses three of them (header, data, status). */
#define VQ_SIZE 8

#define VRING_DESC_F_NEXT  1         /* this descriptor chains to .next */
#define VRING_DESC_F_WRITE 2         /* ...and the device writes (not reads) */

/* ---------------------------------------------------------------------------
 * MMIO helpers.  The compiler must not cache or reorder device accesses.
 * --------------------------------------------------------------------------- */
static inline uint32_t mmio_r32(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void     mmio_w32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

/* A full read/write fence: our RAM writes become visible before the doorbell,
 * and the device's writes become visible before we read them back. */
static inline void fence_rw(void) { __sync_synchronize(); }

/* ---------------------------------------------------------------------------
 * Virtqueue structures (virtio 1.x split ring).
 * --------------------------------------------------------------------------- */
struct vring_desc {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
};

struct vring_avail {
    uint16_t flags;
    uint16_t idx;
    uint16_t ring[VQ_SIZE];
    uint16_t used_event;
};

struct vring_used_elem {
    uint32_t id;
    uint32_t len;
};

struct vring_used {
    uint16_t flags;
    uint16_t idx;
    struct vring_used_elem ring[VQ_SIZE];
    uint16_t avail_event;
};

/* ---------------------------------------------------------------------------
 * Driver state.  blk_ready is the flag the filesystem layer checks.
 * --------------------------------------------------------------------------- */
/* The 16-byte header that starts every block request. */
struct virtio_blk_req {
    uint32_t type;       /* BLK_T_IN or BLK_T_OUT */
    uint32_t reserved;
    uint64_t sector;     /* starting LBA */
};

uint64_t blk_ready;                       /* 0 until setup succeeds         */
static uint64_t blk_base;                 /* MMIO base of the device        */
static uint16_t blk_avail_idx;            /* next available-ring index      */
static struct virtio_blk_req blk_hdr;     /* request header                 */

/* The device reads and writes these behind our back, so they must be
 * volatile: otherwise the optimiser may hoist the used-ring poll out of its
 * loop and spin forever. */
static volatile uint8_t  blk_status[8];   /* device status byte             */
static struct vring_desc vq_desc[VQ_SIZE] __attribute__((aligned(16)));
static volatile struct vring_avail vq_avail;
static volatile struct vring_used  vq_used;

/* find_virtio_blk: scan the virtio-mmio slots for a block device. */
static int find_virtio_blk(void)
{
    for (uintptr_t base = 0x10001000; base <= 0x10008000; base += 0x1000) {
        if (mmio_r32(base + VIRT_MAGIC) != VIRT_MAGIC_VAL)
            continue;
        if (mmio_r32(base + VIRT_VERSION) != VIRT_VERSION_2)
            continue;
        if (mmio_r32(base + VIRT_DEVICE_ID) != VIRTIO_DEV_BLK)
            continue;
        blk_base = base;
        return 1;
    }
    return 0;
}

/* vq_zero: clear the three virtqueue arrays and the ring counters.  .bss is
 * already zero on a cold boot, but a stale avail/used index would confuse the
 * device, so we reset them explicitly. */
static void vq_zero(void)
{
    bytes_zero((void *)vq_desc, sizeof vq_desc);
    bytes_zero((void *)&vq_avail, sizeof vq_avail);
    bytes_zero((void *)&vq_used, sizeof vq_used);
    blk_avail_idx = 0;
}

/* blk_init: find the device and drive it through the virtio setup dance.
 * Returns 1 when a usable block device was found, 0 otherwise. */
int blk_init(void)
{
    blk_ready = 0;
    if (!find_virtio_blk())
        return 0;

    uintptr_t base = (uintptr_t)blk_base;

    /* --- status handshake: reset, then acknowledge and claim the device --- */
    mmio_w32(base + VIRT_STATUS, 0);
    mmio_w32(base + VIRT_STATUS, VIRT_STATUS_ACK);
    mmio_w32(base + VIRT_STATUS, VIRT_STATUS_ACK | VIRT_STATUS_DRIVER);

    /* --- feature negotiation: we must accept VIRTIO_F_VERSION_1 ---
     * VERSION_1 is bit 32, i.e. bit 0 of the high 32-bit half, selected via
     * the _SEL registers. */
    mmio_w32(base + VIRT_DEV_FEAT_SEL, 1);
    if (!(mmio_r32(base + VIRT_DEV_FEAT) & 1))
        return 0;
    mmio_w32(base + VIRT_DRV_FEAT_SEL, 1);
    mmio_w32(base + VIRT_DRV_FEAT, 1);
    mmio_w32(base + VIRT_DRV_FEAT_SEL, 0);
    mmio_w32(base + VIRT_DRV_FEAT, 0);

    /* --- confirm the feature set, then finish the handshake --- */
    mmio_w32(base + VIRT_STATUS,
             VIRT_STATUS_ACK | VIRT_STATUS_DRIVER | VIRT_STATUS_FEATURES_OK);
    if (!(mmio_r32(base + VIRT_STATUS) & VIRT_STATUS_FEATURES_OK))
        return 0;

    /* --- set up virtqueue 0 --- */
    mmio_w32(base + VIRT_QUEUE_SEL, 0);
    if (mmio_r32(base + VIRT_QUEUE_NUMMAX) < VQ_SIZE)
        return 0;                           /* too small for our chain */
    mmio_w32(base + VIRT_QUEUE_NUM, VQ_SIZE);

    uint64_t a;
    a = (uint64_t)(uintptr_t)vq_desc;
    mmio_w32(base + VIRT_QDESC_LOW, (uint32_t)a);
    mmio_w32(base + VIRT_QDESC_HIGH, (uint32_t)(a >> 32));
    a = (uint64_t)(uintptr_t)&vq_avail;
    mmio_w32(base + VIRT_QDRIVER_LOW, (uint32_t)a);
    mmio_w32(base + VIRT_QDRIVER_HIGH, (uint32_t)(a >> 32));
    a = (uint64_t)(uintptr_t)&vq_used;
    mmio_w32(base + VIRT_QDEVICE_LOW, (uint32_t)a);
    mmio_w32(base + VIRT_QDEVICE_HIGH, (uint32_t)(a >> 32));
    mmio_w32(base + VIRT_QUEUE_READY, 1);

    /* --- tell the device we are ready for business --- */
    mmio_w32(base + VIRT_STATUS,
             VIRT_STATUS_ACK | VIRT_STATUS_DRIVER |
             VIRT_STATUS_FEATURES_OK | VIRT_STATUS_DRIVER_OK);

    vq_zero();
    blk_ready = 1;
    return 1;
}

/* blk_rw: move data between RAM and the block device, one request at a time.
 *   type     : BLK_T_IN (read) or BLK_T_OUT (write)
 *   sector   : starting sector (LBA, 512-byte units)
 *   buf      : RAM buffer holding 512 * nsectors bytes
 *   nsectors : number of sectors to transfer
 * Returns 0 on success, -1 on failure. */
int blk_rw(uint32_t type, uint64_t sector, void *buf, uint32_t nsectors)
{
    if (!blk_ready)
        return -1;

    uintptr_t base = (uintptr_t)blk_base;

    /* --- fill in the request header --- */
    blk_hdr.type     = type;
    blk_hdr.reserved = 0;
    blk_hdr.sector   = sector;

    /* --- descriptor 0: the request header, chained to descriptor 1 --- */
    vq_desc[0].addr  = (uint64_t)(uintptr_t)&blk_hdr;
    vq_desc[0].len   = sizeof blk_hdr;
    vq_desc[0].flags = VRING_DESC_F_NEXT;
    vq_desc[0].next  = 1;

    /* --- descriptor 1: the data buffer, chained to descriptor 2 ---
     * A read wants the device to WRITE into RAM, hence the WRITE flag. */
    vq_desc[1].addr  = (uint64_t)(uintptr_t)buf;
    vq_desc[1].len   = nsectors << 9;            /* sectors * 512 */
    vq_desc[1].flags = (type == BLK_T_IN)
                       ? (VRING_DESC_F_NEXT | VRING_DESC_F_WRITE)
                       : VRING_DESC_F_NEXT;
    vq_desc[1].next  = 2;

    /* --- descriptor 2: the one-byte status the device writes back --- */
    vq_desc[2].addr  = (uint64_t)(uintptr_t)blk_status;
    vq_desc[2].len   = 1;
    vq_desc[2].flags = VRING_DESC_F_WRITE;
    vq_desc[2].next  = 0;                        /* end of the chain */
    blk_status[0] = 0xff;                        /* sentinel; real status is 0 */

    /* --- publish the head descriptor in the available ring --- */
    uint16_t idx  = blk_avail_idx;
    uint16_t slot = idx & (VQ_SIZE - 1);         /* slot = idx % VQ_SIZE */
    vq_avail.ring[slot] = 0;                     /* head descriptor is always 0 */
    fence_rw();                                  /* descriptors visible first... */
    uint16_t next = idx + 1;
    vq_avail.idx = next;                         /* ...then bump avail.idx */
    fence_rw();
    blk_avail_idx = next;                        /* remember for the next request */

    /* --- ring the doorbell and wait for the device to finish --- */
    mmio_w32(base + VIRT_QUEUE_NOTIFY, 0);
    while (vq_used.idx != next)
        ;
    fence_rw();                                  /* device writes now visible */

    return blk_status[0] == 0 ? 0 : -1;
}
