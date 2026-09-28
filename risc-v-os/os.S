# ===========================================================================
# Toy RISC-V OS - a tiny bare-metal shell for qemu-system-riscv64 (virt)
# ===========================================================================
#
# Boots in supervisor mode at 0x80200000 (OpenSBI has already run from the
# default -bios), talks to the NS16550A UART at 0x10000000 and provides a
# minimal interactive shell.  No libc, no C, only machine code.
#
# ---------------------------------------------------------------------------
# A 60-second RISC-V primer (everything this file relies on)
# ---------------------------------------------------------------------------
# RISC-V is a load/store architecture: arithmetic works on registers only,
# memory is touched exclusively by load (l*) and store (s*) instructions.
#
# A few of the 32 integer registers and the role of each in this code:
#   zero/x0 : always reads as 0, writes are discarded
#   ra  /x1 : return address   - set by `call`, read by `ret`
#   sp  /x2 : stack pointer    - grows DOWN, must stay 16-byte aligned
#   a0-a7   : argument registers - first 8 arguments / return values
#   t0-t6   : temporaries      - caller-saved, free to trash
#   s0-s11  : saved registers  - callee-saved, must be restored if used
#
# Calling convention used throughout this file:
#   * arguments go in a0, a1, a2, ...
#   * the return value comes back in a0
#   * `call sym` jumps to sym and leaves the return address in ra
#   * `ret` jumps back to the address in ra
#   * any function that itself calls another function must first save ra
#     (and any s-registers it uses) on the stack, then restore them at the
#     end.  That is what the `addi sp,sp,-16 / sd ra,8(sp) / ... / ld ra,8(sp)
#     / addi sp,sp,16` prologue/epilogue pattern all over this file does.
#
# Instruction suffixes you will see:
#   b  = byte (8 bit),  h = half (16 bit),  w = word (32 bit), d = double (64)
#   u  = unsigned load (zero-extends),  no u = signed load (sign-extends)
#   i  = immediate operand encoded inside the instruction
#   labels like "1:", "2:" are numeric local labels; "1b" means the nearest
#   previous "1:" and "1f" the nearest following one.
#
# ---------------------------------------------------------------------------
# Fake physical memory map on the qemu "virt" machine
# ---------------------------------------------------------------------------
#   0x00100000  SiFive test / power-off finisher (write 0x5555 to reset)
#   0x10000000  NS16550A UART: +0x00 THR (tx/rx data), +0x05 LSR (line status)
#   0x80200000  where the kernel is loaded and starts executing
#
# Layout of the filesystem: a tree of fixed-size nodes (see node_pool below),
# each holding a name, a parent pointer, a first-child pointer and a
# next-sibling pointer.  run.sh feeds in the host's directory names at assembly
# time so the toy root "/" looks pleasantly familiar, but the tree can also be
# saved to a real block device and reloaded on the next boot.  The "disk" is a
# virtio-blk device that run.sh attaches as a host file (disk.img); see the
# block driver and the fs_buf serializer further down.  When no virtio-blk
# device is present the owner simply keeps everything in RAM as before.
#
# Commands:
#   printf("text")   print the text between the double quotes
#   mkdir "path"     create a directory (creates missing parents, like -p)
#   cd "path"        walk a path (supports /, ., .., e.g. cd ../../)
#   pwd              print the current directory path
#   ls               list the children of the current directory
#   tree             draw the directory tree (square marks where you are)
#   help             show the command list
#   uname            show system information
#   clear            clear the screen
#   halt, exit       power off the machine
#
# Up/down arrows walk back and forth through the command history; left/right
# arrows move the cursor so characters can be inserted or deleted mid-line.
# Ctrl-C powers off the machine from anywhere in the shell.
# ===========================================================================

# ---------------------------------------------------------------------------
# Hardware and shell constants.  `.equ` is the assembler's "#define": it just
# gives a name to a number, it does not allocate any memory.
# ---------------------------------------------------------------------------

# NS16550A UART.  The chip exposes a handful of byte-wide registers relative
# to its base address; only two of them matter for this toy.
.equ UART_BASE, 0x10000000   # MMIO base address of the serial port
.equ UART_THR,  0x00         # transmit holding register: write to send, read to receive
.equ UART_LSR,  0x05         # line status register: tells us when tx/rx is ready
.equ LSR_RX,    0x01         # LSR bit 0: 1 when a received byte is waiting
.equ LSR_TX,    0x20         # LSR bit 5: 1 when the transmit FIFO is empty

# Sizes of the shell's fixed buffers.  Everything is statically allocated in
# .bss, there is no allocator for these.
.equ BUF_SIZE,  128          # max length of one input line (including NUL)
.equ PATH_SIZE, 128          # max length of a path argument such as "a/b/c"
.equ HIST_MAX,  16           # how many previous commands to remember

# In-memory directory tree node layout (an array of fixed-size nodes linked
# together with first-child / next-sibling pointers, a classic "LCRS" tree).
# Each .equ below is a byte offset from the start of a node.
.equ NAME_LEN,   24          # fixed name field size (23 chars + NUL)
.equ NODE_NAME,  0           # char[NODE_NAME .. +NAME_LEN)
.equ NODE_PARENT,24          # node *  -> parent directory (NULL for root)
.equ NODE_FIRST, 32          # node *  -> first child in the list
.equ NODE_NEXT,  40          # node *  -> next sibling in the parent's list
.equ NODE_SIZE,  48          # total bytes per node (must cover all fields)
.equ MAX_NODES,  256         # size of the static node pool

# ---------------------------------------------------------------------------
# virtio-blk over virtio-mmio (the "SSD").
# ---------------------------------------------------------------------------
# run.sh attaches a host file as a virtio block device.  On the qemu "virt"
# board the virtio-mmio transport lives at 0x10001000 and up; each slot is a
# page of registers.  We probe those slots for a device whose magic spells
# "virt", whose version is the modern 2, and whose device id is 2 (block).
# The register offsets below are from the virtio 1.x MMIO specification.
.equ VIRT_MAGIC,        0x000  # "virt" magic value, read to spot a device
.equ VIRT_VERSION,      0x004  # 1 = legacy, 2 = modern (we require 2)
.equ VIRT_DEVICE_ID,    0x008  # 2 = block device
.equ VIRT_MAGIC_VAL,    0x74726976  # the little-endian word "virt"
.equ VIRT_VERSION_2,    2
.equ VIRTIO_DEV_BLK,    2

.equ VIRT_DEV_FEAT,     0x010  # device feature bits (selected by ..._SEL)
.equ VIRT_DEV_FEAT_SEL, 0x014  # which 32-bit half of the features to read
.equ VIRT_DRV_FEAT,     0x020  # driver feature bits (what we accept)
.equ VIRT_DRV_FEAT_SEL, 0x024  # which half of the features we write
.equ VIRT_QUEUE_SEL,    0x030  # pick a virtqueue (we only use queue 0)
.equ VIRT_QUEUE_NUMMAX, 0x034  # largest queue the device allows
.equ VIRT_QUEUE_NUM,    0x038  # queue size we choose (power of two)
.equ VIRT_QUEUE_READY,  0x044  # 1 once desc/avail/used are configured
.equ VIRT_QUEUE_NOTIFY, 0x050  # write to this to kick the device
.equ VIRT_STATUS,       0x070  # device status byte (ACK/DRIVER/... bits)
.equ VIRT_QDESC_LOW,    0x080  # descriptor table address, low  32 bits
.equ VIRT_QDESC_HIGH,   0x084  # descriptor table address, high 32 bits
.equ VIRT_QDRIVER_LOW,  0x090  # available ring address, low  32 bits
.equ VIRT_QDRIVER_HIGH, 0x094  # available ring address, high 32 bits
.equ VIRT_QDEVICE_LOW,  0x0a0  # used ring address, low  32 bits
.equ VIRT_QDEVICE_HIGH, 0x0a4  # used ring address, high 32 bits

.equ VIRT_STATUS_ACK,    1     # "I have noticed the device"
.equ VIRT_STATUS_DRIVER, 2     # "I know how to drive it"
.equ VIRT_STATUS_FEATURES_OK, 8  # "the features we agreed on are usable"
.equ VIRT_STATUS_DRIVER_OK, 4  # "setup is done, let's go"
.equ VIRT_DESC_F_VERSION_1, 32 # bit 32 (word 1 bit 0) must be accepted

# The split virtqueue we build.  VQ_SIZE descriptors is small but more than
# enough: each 512-byte transfer uses three of them (header, data, status).
.equ VQ_SIZE, 8

# Descriptor flags and the two request types the block layer understands.
.equ VRING_DESC_F_NEXT,  1     # this descriptor chains to .next
.equ VRING_DESC_F_WRITE, 2     # ...and the device writes (rather than reads)
.equ BLK_T_IN,  0              # read a sector from the disk
.equ BLK_T_OUT, 1              # write a sector to the disk

# On-disk layout of the saved filesystem (see save_fs / load_fs).  A single
# header is followed by one fixed-size record per non-root node.  Records are
# in node-pool order, and a record stores the parent's INDEX (not a pointer)
# plus the name; that is all load_fs needs to rebuild the tree.
.equ FS_MAGIC,     0x31305346534F5652  # the 8 bytes "RVOSFS01"
.equ FS_HDR_SIZE,  16          # magic (8) + node count (4) + padding (4)
.equ FS_REC_SIZE,  28          # parent index (4) + name (NAME_LEN = 24)
.equ SECTOR_SIZE,  512         # everything talks in 512-byte blocks

# ---------------------------------------------------------------------------
# Code starts here.  `.text` is the executable section, `_start` is the symbol
# the linker places at the entry address.  `.globl` makes it visible outside
# this file (the linker script asks for it by name).
# ---------------------------------------------------------------------------
.section .text
.globl _start

# ------------------------------------------------------------------ entry ---
# OpenSBI drops us here in supervisor mode with no stack set up.  Our first
# job is to point sp at the top of our statically reserved stack (see the
# .bss section) and hand control to the kernel.  If kernel_main ever returns
# we have nothing left to do, so park the CPU with the "wait for interrupt"
# instruction.
_start:
    la   sp, stack_top       # load the address of the stack top into sp
    call kernel_main         # run the OS; ra holds the address of `_hang`
_hang:
    wfi                      # sleep until an interrupt arrives (saves power)
    j    _hang               # if one does, just go back to sleep

# ------------------------------------------------------------------- UART ---
# A tiny serial driver.  The UART has no interrupt wiring here (we are too
# primitive for that); instead every function polls the status register in a
# busy-wait loop.  Simple, slow, and completely sufficient for a shell.

# uart_putc: send one byte.
#   in : a0 = character to transmit
#   out: none            clobbers: t0, t1 (a0 is preserved)
uart_putc:
    li   t0, UART_BASE       # t0 = UART base address
1:  lbu  t1, UART_LSR(t0)    # read the line status register
    andi t1, t1, LSR_TX      # keep just the "transmit ready" bit
    beqz t1, 1b              # bit clear? FIFO full, loop until it drains
    sb   a0, UART_THR(t0)    # store the byte into the transmit register
    ret                      # done; hardware shifts it out at line rate

# uart_getc: wait for and read one byte.
#   in : none            out: a0 = received character (0..255)
#   clobbers: t0, t1
uart_getc:
    li   t0, UART_BASE
1:  lbu  t1, UART_LSR(t0)    # poll the line status register
    andi t1, t1, LSR_RX      # keep just the "data available" bit
    beqz t1, 1b              # nothing yet, keep spinning
    lbu  a0, UART_THR(t0)    # reading THR fetches the received byte
    ret

# uart_puts: print a NUL terminated string.
#   in : a0 = pointer to string    out: none    clobbers: t0, t1, a0
# We keep the string cursor in t2 and stash ra in t3 because uart_putc is a
# function call and would otherwise overwrite ra, losing our way back here.
uart_puts:
    mv   t2, a0              # t2 = walking pointer over the string
    mv   t3, ra              # t3 = save our return address
1:  lbu  a0, 0(t2)           # load next character
    beqz a0, 2f              # NUL terminator? we are done
    addi t2, t2, 1           # advance the cursor
    call uart_putc           # (this clobbers ra, but we saved it in t3)
    j    1b
2:  mv   ra, t3              # restore the return address
    ret

# uart_newline: emit CR + LF, the conventional end-of-line for serial
# terminals (CR moves to column 0, LF moves down a line).
uart_newline:
    addi sp, sp, -16         # we call a function, so make room to save ra
    sd   ra, 8(sp)
    li   a0, 0x0d            # '\r' carriage return
    call uart_putc
    li   a0, 0x0a            # '\n' line feed
    call uart_putc
    ld   ra, 8(sp)           # restore ra and the stack pointer
    addi sp, sp, 16
    ret

# ---------------------------------------------------------------- helpers ---
# Little string routines.  The whole OS is freestanding (no libc), so even
# strcmp has to be written by hand.

# streq: compare two NUL terminated strings.
#   in : a0 = ptr, a1 = ptr
#   out: a0 = 1 if byte-for-byte equal, 0 otherwise
# The loop loads one byte from each string and compares them; when both are
# NUL we reached the ends together and the strings match.
streq:
    addi sp, sp, -16         # this function calls nothing, but we still save
    sd   ra, 8(sp)           #   ra defensively and keep sp 16-byte aligned
1:  lbu  t0, 0(a0)           # t0 = byte from string A
    lbu  t1, 0(a1)           # t1 = byte from string B
    bne  t0, t1, 2f          # differ? not equal
    beqz t0, 3f              # equal and it is NUL? both ended, match
    addi a0, a0, 1           # advance both cursors
    addi a1, a1, 1
    j    1b
2:  li   a0, 0               # return false
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret
3:  li   a0, 1               # return true
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# starts_with: does string a0 begin with string a1?
#   in : a0 = candidate, a1 = prefix
#   out: a0 = 1 when prefix is a prefix of candidate, else 0
# Walk the prefix; if it ends (NUL) before any mismatch we matched.
starts_with:
1:  lbu  t0, 0(a1)           # next prefix character
    beqz t0, 2f              # end of prefix -> success
    lbu  t1, 0(a0)           # corresponding candidate character
    bne  t0, t1, 3f          # mismatch -> failure
    addi a0, a0, 1
    addi a1, a1, 1
    j    1b
2:  li   a0, 1
    ret
3:  li   a0, 0
    ret

# copy_name: turn a raw command argument into a NUL terminated name.
#   in : a0 = source argument text, a1 = destination buffer
#   out: a0 = 1 when a non-empty name was copied, 0 otherwise
# Two accepted forms:
#   "a b/c"   -> surrounding double quotes are stripped, spaces allowed inside
#   a b/c     -> everything up to the next space
# t2 counts the bytes copied so we can enforce PATH_SIZE-1 and detect "" .
copy_name:
    li   t2, ' '             # t2 is reused below as the length counter
    lbu  t1, 0(a0)           # peek at the first character
    li   t0, '"'
    bne  t1, t0, cn_plain    # not a quote -> unquoted branch
    # ---- quoted form: copy until the closing quote or NUL ----
    addi a0, a0, 1           # step over the opening quote
    li   t2, 0               # t2 = number of bytes copied
cn_qloop:
    lbu  t1, 0(a0)
    beqz t1, cn_end          # opening quote with no close: stop at NUL
    li   t0, '"'
    beq  t1, t0, cn_end      # closing quote: stop
    li   t0, PATH_SIZE-1
    bge  t2, t0, cn_end      # buffer full: stop (truncate)
    sb   t1, 0(a1)           # store the byte
    addi a0, a0, 1
    addi a1, a1, 1
    addi t2, t2, 1
    j    cn_qloop
    # ---- unquoted form: copy until a space or NUL ----
cn_plain:
    li   t2, 0
cn_ploop:
    lbu  t1, 0(a0)
    beqz t1, cn_end
    li   t0, ' '
    beq  t1, t0, cn_end      # space delimits the argument
    li   t0, PATH_SIZE-1
    bge  t2, t0, cn_end
    sb   t1, 0(a1)
    addi a0, a0, 1
    addi a1, a1, 1
    addi t2, t2, 1
    j    cn_ploop
cn_end:
    sb   zero, 0(a1)         # NUL terminate the destination
    beqz t2, cn_empty        # copied nothing -> empty name
    li   a0, 1
    ret
cn_empty:
    li   a0, 0
    ret

# ------------------------------------------------------------ filesystem ---
# The "filesystem" is a statically sized pool of nodes (node_pool in .bss).
# A node stores a short name and three pointers, giving a tree where each
# directory links to its first child and each child links to its next sibling:
#
#        node_pool[0] "/"  (root)
#              |
#          NODE_FIRST
#              v
#           "usr" --NODE_NEXT--> "etc" --NODE_NEXT--> "home" ...
#              |
#          NODE_FIRST
#              v
#           "bin" -> ...
#
# NODE_PARENT points back up.  Walking ".." is just following parent pointers.

# print_name: print the NUL terminated name stored inside a node.
#   in : a0 = node pointer    clobbers: t0, a0 (uses s3, saved)
print_name:
    addi sp, sp, -16         # save ra + one saved register (s3)
    sd   ra, 0(sp)
    sd   s3, 8(sp)
    mv   s3, a0              # s3 = cursor into the name field
pn_loop:
    lbu  a0, NODE_NAME(s3)   # load one character of the name
    beqz a0, pn_done         # NUL terminates the name
    call uart_putc           # (clobbers ra; ours is safe on the stack)
    addi s3, s3, 1
    j    pn_loop
pn_done:
    ld   ra, 0(sp)
    ld   s3, 8(sp)
    addi sp, sp, 16
    ret

# print_path: print the absolute path of a node, e.g. "/usr/bin".
#   in : a0 = node        clobbers: t0, a0 (uses s3, saved)
# This is a textbook recursion.  To print my path I first ask my parent to
# print its path, then append "/" + my own name.  The base case is the root,
# whose parent is NULL and which prints as a single "/".
print_path:
    addi sp, sp, -16
    sd   ra, 0(sp)
    sd   s3, 8(sp)
    mv   s3, a0              # remember myself across the recursive call
    ld   t0, NODE_PARENT(s3)
    beqz t0, pp_root         # parent == NULL  ->  I am the root
    mv   a0, t0
    call print_path          # first, print the parent's path
    # Decide whether a separator is needed.  The root's path already ends in
    # "/", so skip the extra slash when the grandparent (parent's parent) is
    # NULL, i.e. when my parent is the root.
    ld   t0, NODE_PARENT(s3)
    ld   t0, NODE_PARENT(t0)
    beqz t0, pp_name
    li   a0, '/'
    call uart_putc
pp_name:
    mv   a0, s3
    call print_name          # then append my own name
    j    pp_done
pp_root:
    li   a0, '/'
    call uart_putc           # base case: the root prints as "/"
pp_done:
    ld   ra, 0(sp)
    ld   s3, 8(sp)
    addi sp, sp, 16
    ret

# alloc_node: hand out the next free slot from the node pool.
#   out: a0 = pointer to a zeroed node, or 0 when the pool is exhausted
# The pool is a plain array plus a bump counter (node_count).  Allocating is
# just "return &pool[count++]" and clearing the memory.
alloc_node:
    la   t0, node_count      # t0 = address of the counter
    ld   t1, 0(t0)           # t1 = number of nodes handed out so far
    li   t2, MAX_NODES
    bge  t1, t2, an_fail     # full? return NULL
    li   t2, NODE_SIZE
    mul  t3, t1, t2          # t3 = index * stride = byte offset into the pool
    la   t4, node_pool
    add  a0, t4, t3          # a0 = &node_pool[count]
    addi t1, t1, 1
    sd   t1, 0(t0)           # bump the counter
    # zero the whole node so all pointers start out NULL
    mv   t0, a0              # t0 = write cursor
    li   t1, NODE_SIZE       # t1 = bytes left to clear
an_zero:
    beqz t1, an_done
    sb   zero, 0(t0)
    addi t0, t0, 1
    addi t1, t1, -1
    j    an_zero
an_done:
    ret
an_fail:
    li   a0, 0
    ret

# find_child: look up a direct child of a directory by name.
#   in : a0 = parent node, a1 = name string
#   out: a0 = matching child node, or 0 if not found
# This walks the first-child / next-sibling chain (the parent's child list)
# and does an inline byte-by-byte name comparison for each candidate.
find_child:
    ld   t0, NODE_FIRST(a0)  # t0 = candidate node, starting at first child
fc_loop:
    beqz t0, fc_none         # ran off the sibling list -> not present
    mv   t1, t0              # t1 = cursor into candidate's name
    mv   t2, a1              # t2 = cursor into the wanted name
fc_cmp:
    lbu  t3, 0(t1)
    lbu  t4, 0(t2)
    bne  t3, t4, fc_next     # mismatch -> try the next sibling
    beqz t3, fc_found        # both NUL -> exact match
    addi t1, t1, 1
    addi t2, t2, 1
    j    fc_cmp
fc_found:
    mv   a0, t0
    ret
fc_next:
    ld   t0, NODE_NEXT(t0)   # advance to next sibling
    j    fc_loop
fc_none:
    li   a0, 0
    ret

# link_child: append a node to the end of a directory's child list.
#   in : a0 = parent node, a1 = child node
link_child:
    ld   t0, NODE_FIRST(a0)
    bnez t0, lc_walk         # list not empty -> find the tail
    sd   a1, NODE_FIRST(a0)  # empty list: child becomes the first entry
    ret
lc_walk:
    ld   t2, NODE_NEXT(t0)   # peek at the next sibling
    beqz t2, lc_append       # no next -> t0 is the tail
    mv   t0, t2
    j    lc_walk
lc_append:
    sd   a1, NODE_NEXT(t0)   # hang the new node off the tail
    ret

# path_walk: the heart of the filesystem, a mini pathname resolver.
#   in : a0 = starting node (usually the cwd), a1 = path string,
#        a2 = mode (0 = cd, every component must already exist;
#                   1 = mkdir, create missing components as we go)
#   out: a0 = resulting node, or 0 on failure
# It splits the path on '/' and processes one component at a time, handling a
# leading '/' (start at the root), "." (stay put) and ".." (move to parent).
# The main loop is: skip slashes -> collect one component into compbuf ->
# resolve it -> repeat.
path_walk:
    addi sp, sp, -48
    sd   ra, 0(sp)              # save return address
    sd   s4, 8(sp)              # saved registers we are about to use
    sd   s5, 16(sp)
    sd   s6, 24(sp)
    sd   s7, 32(sp)
    sd   s8, 40(sp)
    mv   s4, a0                 # s4 = current node (the "walking" pointer)
    mv   s5, a1                 # s5 = path cursor
    mv   s6, a2                 # s6 = mode (cd vs mkdir)
    # A leading '/' means the path is absolute: start the walk at the root.
    lbu  t0, 0(s5)
    li   t1, '/'
    bne  t0, t1, pw_loop
    la   s4, node_pool          # node_pool[0] is always the root "/"
pw_loop:
    # Collapse any run of slashes ("//", trailing "/") down to none.
    lbu  t0, 0(s5)
    li   t1, '/'
    bne  t0, t1, pw_component
    addi s5, s5, 1              # consume this slash and re-check
    j    pw_loop
pw_component:
    beqz t0, pw_done            # end of string -> we resolved everything
    # Copy the next component (up to '/' or NUL) into the scratch buffer.
    la   t1, compbuf
    li   s7, 0                  # s7 = number of bytes copied
pw_copy:
    lbu  t0, 0(s5)
    beqz t0, pw_copied          # end of whole path
    li   t2, '/'
    beq  t0, t2, pw_copied      # end of this component
    li   t2, NAME_LEN-1
    bge  s7, t2, pw_skip        # would overflow the name field: drop the byte
    sb   t0, 0(t1)
    addi t1, t1, 1
    addi s7, s7, 1
pw_skip:
    addi s5, s5, 1
    j    pw_copy
pw_copied:
    sb   zero, 0(t1)            # NUL terminate compbuf
    # Special component "." means "this directory": nothing to do.
    la   a0, compbuf
    la   a1, str_dot
    call streq
    bnez a0, pw_next
    # Special component ".." means "go to the parent".
    la   a0, compbuf
    la   a1, str_dotdot
    call streq
    bnez a0, pw_parent
    # Ordinary name: does the current directory already have this child?
    mv   a0, s4
    la   a1, compbuf
    call find_child
    bnez a0, pw_enter           # found it -> descend
    beqz s6, pw_fail            # cd mode: a missing component is an error
    # mkdir mode: create the missing directory on the fly.
    call alloc_node
    beqz a0, pw_fail            # pool full
    mv   s8, a0                 # s8 = the freshly created node
    # copy the component name into the node's name field
    la   t0, compbuf
    mv   t1, s8
pw_cpname:
    lbu  t2, 0(t0)
    sb   t2, 0(t1)
    beqz t2, pw_named
    addi t0, t0, 1
    addi t1, t1, 1
    j    pw_cpname
pw_named:
    sd   s4, NODE_PARENT(s8)    # parent = where we currently are
    sd   zero, NODE_FIRST(s8)   # new directory has no children yet
    sd   zero, NODE_NEXT(s8)    # and no sibling yet
    mv   a0, s4
    mv   a1, s8
    call link_child             # append it to the parent's child list
    mv   a0, s8
pw_enter:
    mv   s4, a0                 # descend into the resolved component
pw_next:
    j    pw_loop                # look for the next component
pw_parent:
    ld   t0, NODE_PARENT(s4)
    beqz t0, pw_next            # at the root, ".." keeps you at the root
    mv   s4, t0
    j    pw_next
pw_done:
    mv   a0, s4                 # success: return where we ended up
    j    pw_ret
pw_fail:
    li   a0, 0                  # failure: NULL
pw_ret:
    ld   ra, 0(sp)
    ld   s4, 8(sp)
    ld   s5, 16(sp)
    ld   s6, 24(sp)
    ld   s7, 32(sp)
    ld   s8, 40(sp)
    addi sp, sp, 48
    ret

# init_fs: build the initial filesystem.
# It creates the root node, then replays every directory path that run.sh
# harvested from the host into the tree (using mkdir mode so missing parents
# spring into existence).  Finally the shell's current directory is set to "/".
init_fs:
    addi sp, sp, -16
    sd   ra, 8(sp)
    # --- create the root node at node_pool[0] ---
    la   t0, node_count
    li   t1, 1
    sd   t1, 0(t0)              # one node (the root) is now in use
    la   t0, node_pool          # t0 = &node_pool[0] = the root
    li   t1, '/'
    sb   t1, NODE_NAME(t0)      # name = "/"
    sb   zero, NODE_NAME+1(t0)  # NUL terminator
    sd   zero, NODE_PARENT(t0)  # root has no parent
    sd   zero, NODE_FIRST(t0)   # no children yet
    sd   zero, NODE_NEXT(t0)
    la   t1, cwd_ptr
    sd   t0, 0(t1)              # start the shell in the root
    # --- replay the fake host tree, one path at a time ---
    la   s9, fake_paths         # s9 = cursor into the NUL separated path list
if_loop:
    lbu  t0, 0(s9)
    beqz t0, if_done            # empty string marks the end of the list
    la   a0, node_pool          # start each absolute path at the root
    mv   a1, s9
    li   a2, 1                  # mode 1 = mkdir (create as needed)
    call path_walk
if_adv:
    # advance s9 past this NUL terminated string
    lbu  t0, 0(s9)
    addi s9, s9, 1
    bnez t0, if_adv
    j    if_loop
if_done:
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# ===========================================================================
# Block layer: virtio-blk over virtio-mmio.
# ===========================================================================
# The whole driver is deliberately minimal.  A virtio split virtqueue is three
# arrays that we and the device share in RAM:
#
#   descriptor table : one 16-byte entry per buffer we want transferred
#   available ring   : "driver wrote here, device please look"
#   used ring        : "device is done with these"
#
# A block request is just three chained descriptors: a 16-byte request header
# (type + sector number), the 512-byte data buffer, and a one-byte status the
# device writes when it finishes.  We publish the request in the available
# ring, ring the doorbell (QueueNotify), then poll the used ring until the
# device reports it is done.  No interrupts are used anywhere in this OS.

# find_virtio_blk: scan the virtio-mmio slots for a block device.
#   out: a0 = 1 and blk_base set on success, 0 otherwise
# The virt board wires up to eight virtio-mmio windows starting at 0x10001000,
# one page apart.  A populated slot answers the "virt" magic; we also insist
# on the modern interface and device id 2 so we know our register layout and
# request format are the ones the device expects.
find_virtio_blk:
    li   t0, 0x10001000       # first virtio-mmio slot
    li   t1, 0x10008000       # last slot we will look at
fvb_loop:
    lw   t2, VIRT_MAGIC(t0)   # every virtio-mmio window starts with "virt"
    li   t3, VIRT_MAGIC_VAL
    bne  t2, t3, fvb_next
    lw   t2, VIRT_VERSION(t0) # we implement the modern (version 2) interface
    li   t3, VIRT_VERSION_2
    bne  t2, t3, fvb_next
    lw   t2, VIRT_DEVICE_ID(t0)  # 2 == block device
    li   t3, VIRTIO_DEV_BLK
    bne  t2, t3, fvb_next
    la   t3, blk_base         # remember where we found it
    sd   t0, 0(t3)
    li   a0, 1
    ret
fvb_next:
    li   t2, 0x1000            # 0x1000 does not fit an addi immediate
    add  t0, t0, t2           # try the next slot
    ble  t0, t1, fvb_loop
    li   a0, 0                # nothing there: caller falls back to RAM-only
    ret

# vq_zero: clear the three virtqueue arrays and the ring counters.  .bss is
# already zero on a cold boot, but blk_init may run more than once in spirit,
# and a stale avail/used index would confuse the device.  Touches only
# temporaries, so it needs no frame.
vq_zero:
    la   t0, vq_desc
    li   t1, 16*VQ_SIZE       # descriptor table is 16 bytes per entry
    add  t1, t0, t1
vz_desc:
    bge  t0, t1, vz_avail
    sb   zero, 0(t0)
    addi t0, t0, 1
    j    vz_desc
vz_avail:
    la   t0, vq_avail
    li   t1, 64
    add  t1, t0, t1
vz_a:
    bge  t0, t1, vz_used
    sb   zero, 0(t0)
    addi t0, t0, 1
    j    vz_a
vz_used:
    la   t0, vq_used
    li   t1, 128
    add  t1, t0, t1
vz_u:
    bge  t0, t1, vz_idx
    sb   zero, 0(t0)
    addi t0, t0, 1
    j    vz_u
vz_idx:
    la   t0, blk_avail_idx
    sh   zero, 0(t0)          # we have not submitted anything yet
    ret

# blk_init: find the device and drive it through the virtio setup dance.
#   out: a0 = 1 when a usable block device was found, 0 otherwise
# blk_ready is cleared first so that, if anything below fails, save_fs and
# load_fs quietly turn into no-ops and the OS falls back to a RAM-only tree.
blk_init:
    addi sp, sp, -16
    sd   ra, 8(sp)            # vq_zero is a call, so we must save ra
    la   t0, blk_ready
    sd   zero, 0(t0)
    call find_virtio_blk
    beqz a0, bi_done
    la   t0, blk_base
    ld   t0, 0(t0)            # t0 = MMIO base of our block device

    # --- status handshake: reset, then acknowledge and claim the device ---
    sw   zero, VIRT_STATUS(t0)          # 0 = reset the device
    li   t1, VIRT_STATUS_ACK
    sw   t1, VIRT_STATUS(t0)            # ACKNOWLEDGE
    li   t1, VIRT_STATUS_ACK|VIRT_STATUS_DRIVER
    sw   t1, VIRT_STATUS(t0)            # DRIVER: we know the protocol

    # --- feature negotiation: we must accept VIRTIO_F_VERSION_1 ---
    # The feature bits are 64 wide, exposed 32 at a time through the SEL
    # registers.  Version 1 is bit 32, i.e. bit 0 of the high half.
    li   t1, 1
    sw   t1, VIRT_DEV_FEAT_SEL(t0)      # read feature bits 32..63
    lw   t1, VIRT_DEV_FEAT(t0)
    andi t1, t1, 1                      # is version 1 offered?
    beqz t1, bi_fail
    li   t1, 1
    sw   t1, VIRT_DRV_FEAT_SEL(t0)      # accept feature bit 32...
    sw   t1, VIRT_DRV_FEAT(t0)
    sw   zero, VIRT_DRV_FEAT_SEL(t0)    # ...and no features in the low half
    sw   zero, VIRT_DRV_FEAT(t0)

    # --- confirm the negotiated feature set, then finish the handshake ---
    li   t1, VIRT_STATUS_ACK|VIRT_STATUS_DRIVER|VIRT_STATUS_FEATURES_OK
    sw   t1, VIRT_STATUS(t0)
    lw   t1, VIRT_STATUS(t0)            # device clears FEATURES_OK on refusal
    andi t1, t1, VIRT_STATUS_FEATURES_OK
    beqz t1, bi_fail

    # --- set up virtqueue 0 ---
    sw   zero, VIRT_QUEUE_SEL(t0)
    lw   t1, VIRT_QUEUE_NUMMAX(t0)      # how many descriptors does it allow?
    li   t2, VQ_SIZE
    blt  t1, t2, bi_fail                # too small for our three-descriptor chain
    sw   t2, VIRT_QUEUE_NUM(t0)         # ask for exactly VQ_SIZE
    la   t1, vq_desc                    # hand over the three ring addresses;
    sw   t1, VIRT_QDESC_LOW(t0)         #   high halves are zero because our
    srli t2, t1, 32                     #   image lives well below 4 GiB
    sw   t2, VIRT_QDESC_HIGH(t0)
    la   t1, vq_avail
    sw   t1, VIRT_QDRIVER_LOW(t0)
    srli t2, t1, 32
    sw   t2, VIRT_QDRIVER_HIGH(t0)
    la   t1, vq_used
    sw   t1, VIRT_QDEVICE_LOW(t0)
    srli t2, t1, 32
    sw   t2, VIRT_QDEVICE_HIGH(t0)
    li   t1, 1
    sw   t1, VIRT_QUEUE_READY(t0)       # the queue is live

    # --- tell the device we are ready for business ---
    li   t1, VIRT_STATUS_ACK|VIRT_STATUS_DRIVER|VIRT_STATUS_FEATURES_OK|VIRT_STATUS_DRIVER_OK
    sw   t1, VIRT_STATUS(t0)

    call vq_zero                        # start from a clean queue
    la   t0, blk_ready
    li   t1, 1
    sd   t1, 0(t0)
    li   a0, 1
    j    bi_done
bi_fail:
    li   a0, 0
bi_done:
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# blk_rw: move data between RAM and the block device, one request at a time.
#   in : a0 = BLK_T_IN (read) or BLK_T_OUT (write)
#        a1 = starting sector (LBA, 512-byte units)
#        a2 = RAM buffer
#        a3 = number of sectors (a2 must hold 512*a3 bytes)
#   out: a0 = 0 on success, -1 on failure
# The request is described by three chained descriptors and submitted to the
# available ring.  We then spin on the used ring; because we submit and reap
# one request at a time, the used index must simply catch up to the available
# index we just published.  `fence` instructions order our RAM writes before
# the doorbell and the device's writes before we read them back.
blk_rw:
    la   t0, blk_ready
    ld   t1, 0(t0)
    beqz t1, brw_fail           # no device: report failure, caller ignores it
    la   t0, blk_base
    ld   t0, 0(t0)              # t0 = virtio-mmio base

    # --- fill in the 16-byte request header ---
    la   t1, blk_hdr
    sw   a0, 0(t1)              # type: read or write
    sw   zero, 4(t1)            # reserved
    sd   a1, 8(t1)              # starting sector

    # --- descriptor 0: the request header, chained to descriptor 1 ---
    la   t1, vq_desc
    la   t2, blk_hdr
    sd   t2, 0(t1)              # address
    li   t2, 16
    sw   t2, 8(t1)              # length
    li   t2, VRING_DESC_F_NEXT
    sh   t2, 12(t1)             # flags
    li   t2, 1
    sh   t2, 14(t1)             # next descriptor

    # --- descriptor 1: the data buffer, chained to descriptor 2 ---
    addi t1, t1, 16
    sd   a2, 0(t1)              # address of the caller's buffer
    slli t2, a3, 9              # length = sectors * 512
    sw   t2, 8(t1)
    li   t2, VRING_DESC_F_NEXT
    beqz a0, brw_read_data      # a read wants the device to WRITE into RAM
    j    brw_data_flags
brw_read_data:
    li   t2, VRING_DESC_F_NEXT|VRING_DESC_F_WRITE
brw_data_flags:
    sh   t2, 12(t1)
    li   t2, 2
    sh   t2, 14(t1)             # next descriptor

    # --- descriptor 2: the one-byte status the device writes back ---
    addi t1, t1, 16
    la   t2, blk_status
    sd   t2, 0(t1)
    li   t2, 1
    sw   t2, 8(t1)
    li   t2, VRING_DESC_F_WRITE
    sh   t2, 12(t1)
    sh   zero, 14(t1)           # end of the chain
    li   t2, 0xff               # sentinel: a real status is 0
    la   t3, blk_status
    sb   t2, 0(t3)

    # --- publish the head descriptor in the available ring ---
    la   t1, blk_avail_idx
    lhu  t2, 0(t1)              # t2 = this request's ring slot index
    la   t3, vq_avail
    andi t4, t2, VQ_SIZE-1      # slot = idx % VQ_SIZE
    slli t4, t4, 1
    addi t4, t4, 4              # the ring[] array starts 4 bytes into the ring
    add  t4, t3, t4
    sh   zero, 0(t4)            # ring[slot] = head descriptor (always 0)
    fence rw, rw                # descriptors and ring entry visible first...
    addi t5, t2, 1
    sh   t5, 2(t3)              # ...then bump avail.idx
    fence rw, rw
    sh   t5, 0(t1)              # remember where we are for the next request

    # --- ring the doorbell and wait for the device to finish ---
    sw   zero, VIRT_QUEUE_NOTIFY(t0)
    la   t3, vq_used
brw_poll:
    lhu  t4, 2(t3)              # used.idx advances once per completed request
    bne  t4, t5, brw_poll
    fence rw, rw                # device's writes are visible after this
    la   t1, blk_status
    lbu  t2, 0(t1)              # 0 = OK, anything else = the device said no
    bnez t2, brw_fail
    li   a0, 0
    ret
brw_fail:
    li   a0, -1
    ret

# ===========================================================================
# Filesystem persistence: turn the node tree into sectors, and back.
# ===========================================================================
# save_fs packs the tree into fs_buf and writes it to sector 0 onward; load_fs
# reads the header, validates the magic and rebuilds node_pool from the
# records.  Both are no-ops when blk_ready is 0, so a machine booted without a
# disk still works.  Neither uses s-registers, so they are safe to call from
# inside the shell's parser without disturbing its saved state.

# save_fs: serialise the current tree to disk.
#   out: none (failures are silent; the RAM tree remains authoritative)
save_fs:
    addi sp, sp, -16
    sd   ra, 8(sp)
    la   t0, blk_ready
    ld   t0, 0(t0)
    beqz t0, sf_done            # no disk attached: nothing to do

    # --- header: magic + node count ---
    la   t0, fs_buf
    li   t1, FS_MAGIC
    sd   t1, 0(t0)
    la   t1, node_count
    ld   t1, 0(t1)              # t1 = number of live nodes (root included)
    sw   t1, 8(t0)
    sw   zero, 12(t0)

    # --- one record per non-root node, in node-pool order ---
    li   t2, 1                  # t2 = node index i
sf_loop:
    bge  t2, t1, sf_write
    li   t3, NODE_SIZE
    mul  t3, t2, t3
    la   t4, node_pool
    add  t4, t4, t3             # t4 = &node_pool[i]
    addi t3, t2, -1
    li   t5, FS_REC_SIZE
    mul  t3, t3, t5
    la   t5, fs_buf
    addi t5, t5, FS_HDR_SIZE
    add  t5, t5, t3             # t5 = &fs_buf.records[i-1]
    # store the parent as an index so pointers do not leak into the image
    ld   t3, NODE_PARENT(t4)
    la   t6, node_pool
    sub  t3, t3, t6
    li   t6, NODE_SIZE
    divu t3, t3, t6             # parent_index = (parent - pool) / NODE_SIZE
    sw   t3, 0(t5)
    # copy the fixed-size name field verbatim
    addi t5, t5, 4
    li   t6, 0
sf_nloop:
    lbu  t3, 0(t4)
    sb   t3, 0(t5)
    addi t4, t4, 1
    addi t5, t5, 1
    addi t6, t6, 1
    li   t3, NAME_LEN
    blt  t6, t3, sf_nloop
    addi t2, t2, 1
    j    sf_loop
sf_write:
    # --- how many sectors does the image occupy?  at least one. ---
    addi t2, t1, -1
    li   t3, FS_REC_SIZE
    mul  t2, t2, t3
    addi t2, t2, FS_HDR_SIZE
    addi t2, t2, SECTOR_SIZE-1
    srli t2, t2, 9              # ceil(bytes / 512)
    bnez t2, sf_go
    li   t2, 1
sf_go:
    li   a0, BLK_T_OUT
    li   a1, 0                  # starting sector
    la   a2, fs_buf
    mv   a3, t2                 # sector count
    call blk_rw
sf_done:
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# load_fs: try to rebuild node_pool from disk.
#   out: a0 = 1 on success, 0 when there is no disk or no valid image
# On success node_count and cwd_ptr are updated.  On failure the caller is
# expected to build the default tree with init_fs instead.
load_fs:
    addi sp, sp, -32
    sd   ra, 0(sp)
    sd   s2, 8(sp)              # s2 = node count
    sd   s3, 16(sp)             # s3 = loop index
    sd   s4, 24(sp)             # s4 = current node
    la   t0, blk_ready
    ld   t0, 0(t0)
    beqz t0, lf_fail

    # --- read the header sector and check it ---
    li   a0, BLK_T_IN
    li   a1, 0
    la   a2, fs_buf
    li   a3, 1
    call blk_rw
    bnez a0, lf_fail
    la   t0, fs_buf
    ld   t1, 0(t0)
    li   t2, FS_MAGIC
    bne  t1, t2, lf_fail        # blank/foreign disk: build the fake tree
    lw   s2, 8(t0)              # node count
    li   t1, 1
    blt  s2, t1, lf_fail        # a valid image always has at least the root
    li   t1, MAX_NODES
    bgt  s2, t1, lf_fail        # more nodes than our pool can hold
    la   t1, node_count
    sd   s2, 0(t1)

    # --- pull in the rest of the image if it spans several sectors ---
    addi t1, s2, -1
    li   t2, FS_REC_SIZE
    mul  t1, t1, t2
    addi t1, t1, FS_HDR_SIZE
    addi t1, t1, SECTOR_SIZE-1
    srli t1, t1, 9
    li   t2, 1
    ble  t1, t2, lf_rebuild     # header sector already holds everything
    li   a0, BLK_T_IN
    li   a1, 0
    la   a2, fs_buf
    mv   a3, t1
    call blk_rw
    bnez a0, lf_fail

lf_rebuild:
    # --- recreate the root at node_pool[0] ---
    la   s4, node_pool
    li   t0, '/'
    sb   t0, NODE_NAME(s4)
    sb   zero, NODE_NAME+1(s4)
    sd   zero, NODE_PARENT(s4)
    sd   zero, NODE_FIRST(s4)
    sd   zero, NODE_NEXT(s4)
    la   t0, cwd_ptr
    sd   s4, 0(t0)              # the shell starts at "/"
    # --- replay each record: alloc-order gives us node_pool[1], [2], ... ---
    li   s3, 1
lf_rec:
    bge  s3, s2, lf_ok
    li   t0, NODE_SIZE
    mul  t0, s3, t0
    la   s4, node_pool
    add  s4, s4, t0             # s4 = &node_pool[i]
    addi t0, s3, -1
    li   t1, FS_REC_SIZE
    mul  t0, t0, t1
    la   t1, fs_buf
    addi t1, t1, FS_HDR_SIZE
    add  t1, t1, t0             # t1 = the record for node i
    # parent index -> parent pointer
    lw   t0, 0(t1)
    li   t2, NODE_SIZE
    mul  t0, t0, t2
    la   t2, node_pool
    add  t0, t0, t2
    sd   t0, NODE_PARENT(s4)
    sd   zero, NODE_FIRST(s4)
    sd   zero, NODE_NEXT(s4)
    # copy NAME_LEN bytes into the node's name field
    addi t1, t1, 4
    li   t2, 0
lf_name:
    lbu  t0, 0(t1)
    add  t3, s4, t2
    sb   t0, 0(t3)
    addi t1, t1, 1
    addi t2, t2, 1
    li   t0, NAME_LEN
    blt  t2, t0, lf_name
    # hang the node off its parent (link_child clobbers t0/t2, which is why
    # the loop state lives in s-registers here)
    ld   a0, NODE_PARENT(s4)
    mv   a1, s4
    call link_child
    addi s3, s3, 1
    j    lf_rec
lf_ok:
    li   a0, 1
    j    lf_ret
lf_fail:
    li   a0, 0
lf_ret:
    ld   ra, 0(sp)
    ld   s2, 8(sp)
    ld   s3, 16(sp)
    ld   s4, 24(sp)
    addi sp, sp, 32
    ret

# print_prompt: draw the shell prompt, e.g. "riscv:/usr/bin> ".
print_prompt:
    addi sp, sp, -16
    sd   ra, 8(sp)
    la   a0, msg_prompt         # "riscv:"
    call uart_puts
    la   t0, cwd_ptr
    ld   a0, 0(t0)              # a0 = current directory node
    call print_path             # print its absolute path
    la   a0, msg_prompt_end     # "> "
    call uart_puts
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# ----------------------------------------------------------------- kernel ---
# kernel_main: initialise the filesystem, print the banner, and drop into the
# read-eval-print loop forever.
kernel_main:
    # Bring up the block device (if any), then prefer a filesystem already
    # saved on disk.  A blank or absent image falls back to the fake host tree,
    # which we immediately persist so the next boot finds it.
    call blk_init
    call load_fs
    bnez a0, km_fs_ready
    call init_fs
    call save_fs
km_fs_ready:
    la   a0, msg_banner
    call uart_puts

# The shell is an infinite loop with three phases:
#   1. print a prompt,
#   2. read and edit one line (read_char and friends),
#   3. hand the finished line to the parser (line_done).
# Line editor state, held in callee-saved registers for the whole line:
#   s0 = base address of linebuf
#   s1 = number of characters currently in the line
#   s2 = cursor position (0 = before the first char) for mid-line editing
#   s3 = scratch index used while re-drawing the line
shell_loop:
    call print_prompt
    la   s0, linebuf
    li   s1, 0
    li   s2, 0            # s2 = cursor position inside the line

# read_char: fetch one byte and decide what it means.  Control characters
# that we care about are checked with a chain of compare-and-branch; anything
# Anything else below 0x20 is ignored, and printable bytes are inserted.
read_char:
    call uart_getc
    li   t0, 0x1b
    beq  a0, t0, do_escape     # ESC starts an arrow-key sequence
    li   t0, 0x0d
    beq  a0, t0, line_done     # CR = Enter
    li   t0, 0x0a
    beq  a0, t0, line_done     # LF = Enter (terminals may send either)
    li   t0, 0x7f
    beq  a0, t0, do_backspace  # DEL (most terminals' backspace key)
    li   t0, 0x08
    beq  a0, t0, do_backspace  # BS (the classic control code for backspace)
    li   t0, 0x03
    beq  a0, t0, do_halt       # Ctrl-C: power off
    li   t0, 0x20
    blt  a0, t0, read_char     # other control characters: ignore
    li   t0, BUF_SIZE-1
    bge  s1, t0, read_char     # line already full: ignore the key
    # ---- insert a0 at the cursor, shifting the tail one byte to the right ----
    # Walk backwards from the old end down to the cursor, copying each byte
    # one slot to the right.  `ble t0, s2` stops once we reach the cursor.
    mv   t0, s1
ins_shift:
    ble  t0, s2, ins_store
    addi t1, t0, -1
    add  t2, s0, t1            # source = linebuf[t0-1]
    lbu  t3, 0(t2)
    add  t4, s0, t0            # destination = linebuf[t0]
    sb   t3, 0(t4)
    addi t0, t0, -1
    j    ins_shift
ins_store:
    add  t1, s0, s2            # linebuf[cursor] = new character
    sb   a0, 0(t1)
    addi s1, s1, 1             # line grew by one
    addi s2, s2, 1             # cursor sits after the new character
    # A terminal has already printed the old tail, so re-print everything from
    # the inserted character to the end to keep the display in sync.
    addi s3, s2, -1
ins_echo:
    bge  s3, s1, ins_reposition
    add  t1, s0, s3
    lbu  a0, 0(t1)
    call uart_putc
    addi s3, s3, 1
    j    ins_echo
ins_reposition:
    # If we inserted in the middle, the visible cursor is now past the end of
    # the line; emit one backspace per character to its right.
    sub  s3, s1, s2
    beqz s3, read_char
ins_bs:
    li   a0, 0x08
    call uart_putc
    addi s3, s3, -1
    bnez s3, ins_bs
    j    read_char

# do_escape: decode an ANSI escape sequence.  Arrow keys arrive as three
# bytes: ESC '[' then a letter (A=up, B=down, C=right, D=left).  If the bytes
# do not match that shape we simply resume reading.
do_escape:
    call uart_getc
    li   t0, '['
    bne  a0, t0, read_char     # not a CSI sequence, ignore it
    call uart_getc
    li   t0, 'A'
    beq  a0, t0, do_up
    li   t0, 'B'
    beq  a0, t0, do_down
    li   t0, 'C'
    beq  a0, t0, do_right
    li   t0, 'D'
    beq  a0, t0, do_left
    j    read_char

# do_left: move the cursor one character toward the start of the line.
# Visually we send BS (0x08) which moves the terminal cursor left without
# erasing anything, and decrement the logical cursor s2 to match.
do_left:
    beqz s2, read_char
    addi s2, s2, -1
    li   a0, 0x08
    call uart_putc
    j    read_char

# do_right: move the cursor one character toward the end of the line.  We can
# only move right if there is a character there (s2 < s1); we re-print that
# character so the physical terminal cursor advances with the logical one.
do_right:
    bge  s2, s1, read_char
    add  t1, s0, s2
    lbu  a0, 0(t1)
    call uart_putc
    addi s2, s2, 1
    j    read_char

# erase_line: wipe the whole visible input line and reset the editor state.
#   in/out: s1 = line length (set to 0), s2 = cursor (set to 0)
#   clobbers: s1, s2, s3, a0; preserves s0 (the buffer base)
# Used when recalling history: delete what is on screen, then write the old
# command in its place.
erase_line:
    addi sp, sp, -16
    sd   ra, 8(sp)
    # First move the visual cursor to the end of the line (the usual position).
    sub  s3, s1, s2
    beqz s3, el_erase
el_endbs:
    li   a0, 0x08
    call uart_putc
    addi s3, s3, -1
    bnez s3, el_endbs
el_erase:
    # For each character: BS, space (overwrite it), BS (back to its column).
    # This "rub out" trick avoids needing terminal-specific clear sequences.
    beqz s1, el_done
el_loop:
    li   a0, 0x08
    call uart_putc
    li   a0, 0x20
    call uart_putc
    li   a0, 0x08
    call uart_putc
    addi s1, s1, -1
    bnez s1, el_loop
el_done:
    li   s2, 0
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# load_hist: copy a saved history string into linebuf and echo it.
#   in : a1 = source history string
#   out: s1 = length of the copied line, s2 = cursor at the end of it
# This is the inverse of erase_line: it fills the gap it just cleared.
load_hist:
    addi sp, sp, -16
    sd   ra, 8(sp)
    mv   t3, s0                # t3 = write cursor into linebuf
    li   s1, 0
lh_loop:
    lbu  a0, 0(a1)
    beqz a0, lh_done           # NUL ends the stored command
    sb   a0, 0(t3)             # store it...
    addi t3, t3, 1
    addi a1, a1, 1
    addi s1, s1, 1
    call uart_putc             # ...and print it, so it appears on screen
    j    lh_loop
lh_done:
    mv   s2, s1                # cursor ends up at the end of the line
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# hist_push: append one command to the history ring.
#   in : a0 = pointer to a NUL terminated command line
# hist_entries is a fixed array of HIST_MAX slots, each BUF_SIZE bytes.
# hist_count is how many are valid; hist_pos is the arrow-key browse position.
# When the array is full we drop the oldest entry by shifting the whole array
# down by one slot, then store the new command in the last slot.
hist_push:
    addi sp, sp, -16
    sd   ra, 8(sp)
    la   t0, hist_count
    ld   t1, 0(t0)
    li   t2, HIST_MAX
    bge  t1, t2, hp_shift      # already full -> make room by shifting
    li   t2, BUF_SIZE
    mul  t3, t1, t2            # t3 = count * BUF_SIZE
    la   t4, hist_entries
    add  t4, t4, t3            # t4 = &hist_entries[count]
    j    hp_copy
hp_shift:
    # memmove entries[1..] down to entries[0..], dropping entries[0]
    la   t4, hist_entries      # destination = slot 0
    li   t3, BUF_SIZE
    add  t5, t4, t3            # source = slot 1
    li   t6, (HIST_MAX-1)*BUF_SIZE   # bytes to move
hp_shloop:
    beqz t6, hp_shdone
    lbu  t2, 0(t5)
    sb   t2, 0(t4)
    addi t4, t4, 1
    addi t5, t5, 1
    addi t6, t6, -1
    j    hp_shloop
hp_shdone:
    li   t1, HIST_MAX-1        # the new command goes into the last slot
hp_copy:
    # copy the NUL terminated command, including its terminator
    mv   t5, a0
hp_cploop:
    lbu  t2, 0(t5)
    sb   t2, 0(t4)
    addi t5, t5, 1
    addi t4, t4, 1
    bnez t2, hp_cploop
    # bump hist_count unless it is already at its maximum
    la   t0, hist_count
    ld   t1, 0(t0)
    li   t2, HIST_MAX
    bge  t1, t2, hp_reset
    addi t1, t1, 1
    sd   t1, 0(t0)
hp_reset:
    # browsing starts from "one past the newest" (an empty extra slot)
    la   t0, hist_count
    ld   t1, 0(t0)
    la   t0, hist_pos
    sd   t1, 0(t0)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

# do_up: recall the previous command (walk backwards in history).
do_up:
    la   t0, hist_count
    ld   t1, 0(t0)
    beqz t1, read_char
    la   t0, hist_pos
    ld   t2, 0(t0)
    beqz t2, read_char           # already at the oldest entry
    addi t2, t2, -1
    sd   t2, 0(t0)               # remember the new browse position
    li   t3, BUF_SIZE
    mul  t3, t2, t3              # t3 = offset of slot hist_pos
    la   a1, hist_entries
    add  a1, a1, t3              # a1 = &hist_entries[hist_pos]
    call erase_line
    call load_hist
    j    read_char

# do_down: recall the next command (walk forwards in history).
do_down:
    la   t0, hist_count
    ld   t1, 0(t0)
    la   t0, hist_pos
    ld   t2, 0(t0)
    bge  t2, t1, read_char       # already at the newest entry
    addi t2, t2, 1
    sd   t2, 0(t0)
    call erase_line
    beq  t2, t1, read_char       # stepped past the newest: leave an empty line
    li   t3, BUF_SIZE
    mul  t3, t2, t3
    la   a1, hist_entries
    add  a1, a1, t3
    call load_hist
    j    read_char

# do_backspace: delete the character before the cursor.
do_backspace:
    beqz s2, read_char
    # First close the gap in the buffer: shift everything after the deleted
    # byte one position to the left, from index (cursor-1) onward.
    addi s3, s2, -1
    addi t0, s1, -1
bs_shift:
    bge  s3, t0, bs_after
    add  t1, s0, s3            # dest = linebuf[i]
    addi t2, s3, 1
    add  t2, s0, t2            # src  = linebuf[i+1]
    lbu  t3, 0(t2)
    sb   t3, 0(t1)
    addi s3, s3, 1
    j    bs_shift
bs_after:
    addi s1, s1, -1            # line shorter by one
    addi s2, s2, -1            # cursor moved left
    li   a0, 0x08
    call uart_putc             # step the visual cursor back over the gap
    # Redraw the tail that moved left...
    mv   s3, s2
bs_echo:
    bge  s3, s1, bs_erase
    add  t1, s0, s3
    lbu  a0, 0(t1)
    call uart_putc
    addi s3, s3, 1
    j    bs_echo
bs_erase:
    # ...then print a space to blot out the character formerly at the end and
    # walk the cursor back to where it belongs.
    li   a0, 0x20
    call uart_putc
    sub  s3, s1, s2
    addi s3, s3, 1
bs_bs:
    li   a0, 0x08
    call uart_putc
    addi s3, s3, -1
    bnez s3, bs_bs
    j    read_char

# line_done: the user pressed Enter.  NUL terminate the buffer, save the
# command to history (unless it was empty), move to a fresh line, and run it.
line_done:
    add  t1, s0, s1
    sb   zero, 0(t1)           # linebuf[length] = '\0'
    # remember this line so the arrows can walk back through it
    beqz s1, hist_skip         # skip empty lines
    mv   a0, s0
    call hist_push
hist_skip:
    call uart_newline
    mv   a0, s0
    call parse_line            # run the command
    j    shell_loop            # and prompt again

# ----------------------------------------------------------------- parser ---
# parse_line: turn a raw input line into a command and an optional argument,
# then dispatch.  No real grammar here; it is deliberately tiny:
#   * skip leading spaces,
#   * the first word is the command (we NUL terminate it in place),
#   * the next word is the argument (stored in arg_ptr).
# printf("...") is special-cased first because its argument contains spaces.
#   in : a0 = pointer to the NUL terminated input line
parse_line:
    addi sp, sp, -32           # save ra and the s-registers we use
    sd   ra, 0(sp)
    sd   s2, 8(sp)
    sd   s3, 16(sp)
    sd   s4, 24(sp)
    mv   t1, a0                # t1 = tokenizer cursor

# Skip any run of leading spaces.
skip_spaces:
    lbu  t0, 0(t1)
    beqz t0, parse_ret         # blank line: nothing to do
    li   t2, ' '
    bne  t0, t2, got_cmd
    addi t1, t1, 1
    j    skip_spaces

got_cmd:
    mv   s2, t1                # s2 = start of the command word
    # printf("...")  is handled before tokenizing so spaces inside quotes work.
    mv   a0, s2
    la   a1, cmd_printf_prefix
    call starts_with
    bnez a0, do_printf         # starts with "printf(" -> dedicated handler
    mv   t1, s2                # the call above clobbered the tokenizer pointer

# Find the end of the command word (a space or the NUL terminator).
find_end:
    lbu  t0, 0(t1)
    beqz t0, no_arg            # no space: command with no argument
    li   t2, ' '
    beq  t0, t2, split
    addi t1, t1, 1
    j    find_end

split:
    sb   zero, 0(t1)           # overwrite the space with NUL, ending the command
    addi t1, t1, 1
# Skip the spaces between the command and its argument.
skip_arg:
    lbu  t0, 0(t1)
    beqz t0, store_arg
    li   t2, ' '
    bne  t0, t2, store_arg
    addi t1, t1, 1
    j    skip_arg

store_arg:
    la   t2, arg_ptr
    sd   t1, 0(t2)             # arg_ptr = start of the argument text
    j    dispatch

no_arg:
    la   t2, arg_ptr
    sd   t1, 0(t2)             # points at the NUL, i.e. an empty argument

# Dispatch: compare the command word against each known name.  A hand-written
# compare chain is the clearest thing at this scale; add a new command by
# adding a `streq` block here and a handler below.
dispatch:
    mv   a0, s2
    la   a1, cmd_help
    call streq
    bnez a0, do_help

    mv   a0, s2
    la   a1, cmd_uname
    call streq
    bnez a0, do_uname

    mv   a0, s2
    la   a1, cmd_clear
    call streq
    bnez a0, do_clear

    mv   a0, s2
    la   a1, cmd_mkdir
    call streq
    bnez a0, do_mkdir

    mv   a0, s2
    la   a1, cmd_cd
    call streq
    bnez a0, do_cd

    mv   a0, s2
    la   a1, cmd_pwd
    call streq
    bnez a0, do_pwd

    mv   a0, s2
    la   a1, cmd_ls
    call streq
    bnez a0, do_ls

    mv   a0, s2
    la   a1, cmd_tree
    call streq
    bnez a0, do_tree

    mv   a0, s2
    la   a1, cmd_halt
    call streq
    bnez a0, do_halt

    mv   a0, s2
    la   a1, cmd_exit
    call streq
    bnez a0, do_halt           # "exit" is an alias for "halt"

    # Fallthrough: nothing matched.
    la   a0, msg_unknown
    call uart_puts
    mv   a0, s2
    call uart_puts
    call uart_newline
    j    parse_ret

# ----------------------------------------------------------------- commands -
# do_printf: implement printf("text").  s2 points at the start of the line,
# which we know is "printf(".  Step past the name, allow optional spaces, then
# require a double quote and copy everything up to the closing quote.
do_printf:
    addi t3, s2, 7             # skip the 7 characters of "printf("
dp_skip:
    lbu  t0, 0(t3)
    li   t1, ' '
    bne  t0, t1, dp_quote
    addi t3, t3, 1
    j    dp_skip
dp_quote:
    li   t1, '"'
    bne  t0, t1, parse_ret     # malformed, no opening quote: give up quietly
    addi t3, t3, 1             # step over the opening quote
dp_loop:
    lbu  a0, 0(t3)
    beqz a0, dp_done           # ran out of line before closing quote
    li   t1, '"'
    beq  a0, t1, dp_done       # closing quote ends the text
    call uart_putc
    addi t3, t3, 1
    j    dp_loop
dp_done:
    call uart_newline
    j    parse_ret

# do_mkdir: create a directory (and any missing parents, like mkdir -p).
# The argument text is cleaned up by copy_name, then handed to path_walk in
# mode 1 (create).  A NULL result means either the name was empty or the node
# pool ran out of space; both have their own message.
do_mkdir:
    la   t0, arg_ptr
    ld   a0, 0(t0)             # a0 = raw argument text
    la   a1, pathbuf
    call copy_name             # strip quotes, copy into pathbuf
    beqz a0, mkdir_noarg       # no name given
    la   t0, cwd_ptr
    ld   a0, 0(t0)             # start from the current directory
    la   a1, pathbuf
    li   a2, 1                 # mode 1 = create missing components
    call path_walk
    beqz a0, mkdir_full        # creation failed (pool exhausted)
    call save_fs               # persist the new directory to disk
    j    parse_ret
mkdir_noarg:
    la   a0, msg_mkdir_arg
    call uart_puts
    j    parse_ret
mkdir_full:
    la   a0, msg_mkdir_full
    call uart_puts
    j    parse_ret

# do_cd: change the current directory.  With no argument (or an empty one) we
# go to the root; otherwise path_walk in mode 0 requires the target to exist,
# and on success stores the result in cwd_ptr.
do_cd:
    la   t0, arg_ptr
    ld   a0, 0(t0)
    la   a1, pathbuf
    call copy_name
    beqz a0, cd_root           # "cd" with no argument -> go home to "/"
    la   t0, cwd_ptr
    ld   a0, 0(t0)
    la   a1, pathbuf
    li   a2, 0                 # mode 0 = must exist
    call path_walk
    beqz a0, cd_fail           # not found
    la   t1, cwd_ptr
    sd   a0, 0(t1)             # success: this is the new current directory
    j    parse_ret
cd_root:
    la   t0, cwd_ptr
    la   t1, node_pool         # node_pool[0] is the root
    sd   t1, 0(t0)
    j    parse_ret
cd_fail:
    la   a0, msg_cd_fail       # "cd: no such directory: "
    call uart_puts
    la   a0, pathbuf
    call uart_puts
    call uart_newline
    j    parse_ret

# do_pwd: print the absolute path of the current directory.
do_pwd:
    la   t0, cwd_ptr
    ld   a0, 0(t0)
    call print_path
    call uart_newline
    j    parse_ret

# do_ls: walk the current directory's child list and print each name.
do_ls:
    la   t0, cwd_ptr
    ld   t0, 0(t0)             # t0 = current directory node
    ld   s3, NODE_FIRST(t0)    # s3 = first child
ls_loop:
    beqz s3, parse_ret         # end of the sibling chain
    mv   a0, s3
    call print_name
    call uart_newline
    ld   s3, NODE_NEXT(s3)     # advance to the next sibling
    j    ls_loop

# do_tree: print the directory tree starting from the root, using the
# box-drawing characters.  The current directory gets a filled square, every
# other directory an open circle.  The tricky part is the indentation: as the
# recursion descends it keeps a growing string in tree_indent that prefixes
# each line, using "|   " under a non-last branch and "    " under a last one.
do_tree:
    addi sp, sp, -48
    sd   ra, 0(sp)              # save ra + s1..s5 (used by tree_walk too)
    sd   s1, 8(sp)
    sd   s2, 16(sp)
    sd   s3, 24(sp)
    sd   s4, 32(sp)
    sd   s5, 40(sp)
    # reset the running indent to an empty string
    la   t0, tree_indent
    sb   zero, 0(t0)
    la   t0, tree_indent_len
    sd   zero, 0(t0)
    # root line: square when the shell sits at the root, circle otherwise
    la   s1, node_pool          # s1 = the root node
    la   t0, cwd_ptr
    ld   t0, 0(t0)
    bne  s1, t0, dt_root_circle
    la   a0, art_square
    j    dt_root_mark
dt_root_circle:
    la   a0, art_circle
dt_root_mark:
    call uart_puts              # print the marker glyph
    li   a0, ' '
    call uart_putc
    mv   a0, s1
    call print_name             # then "/"
    call uart_newline
    mv   a0, s1
    call tree_walk              # and recurse into the root's children
    ld   ra, 0(sp)
    ld   s1, 8(sp)
    ld   s2, 16(sp)
    ld   s3, 24(sp)
    ld   s4, 32(sp)
    ld   s5, 40(sp)
    addi sp, sp, 48
    j    parse_ret

# tree_walk: print every descendant of a0, one per line, with indentation.
#   in : a0 = directory whose children are printed
# Register roles:
#   s1 = the directory being walked        s2 = current child
#   s3 = 1 when the child is the last sibling (controls the "elbow" shape)
#   s4 = the indent length before this level, restored after recursing
tree_walk:
    addi sp, sp, -48
    sd   ra, 0(sp)
    sd   s1, 8(sp)
    sd   s2, 16(sp)
    sd   s3, 24(sp)
    sd   s4, 32(sp)
    sd   s5, 40(sp)
    mv   s1, a0                # s1 = directory to walk
    ld   s2, NODE_FIRST(s1)    # s2 = its first child
tw_loop:
    beqz s2, tw_done           # no more siblings -> done
    # leading indent built from the ancestors
    la   a0, tree_indent
    call uart_puts
    # branch connector; remember whether this is the last sibling
    ld   t0, NODE_NEXT(s2)
    bnez t0, tw_notlast
    la   a0, art_ell
    call uart_puts
    li   s3, 1
    j    tw_marker
tw_notlast:
    la   a0, art_tee
    call uart_puts
    li   s3, 0
tw_marker:
    # square for the current directory, circle for every other one
    la   t0, cwd_ptr
    ld   t0, 0(t0)
    beq  t0, s2, tw_square
    la   a0, art_circle
    j    tw_putmark
tw_square:
    la   a0, art_square
tw_putmark:
    call uart_puts
    li   a0, ' '
    call uart_putc
    mv   a0, s2
    call print_name
    call uart_newline
    # recurse only when the child has children of its own
    ld   t0, NODE_FIRST(s2)
    beqz t0, tw_next
    la   t0, tree_indent_len
    ld   s4, 0(t0)             # remember the indent length for this level
    beqz s3, tw_pipe
    la   a0, indent_spaces
    j    tw_extend
tw_pipe:
    la   a0, indent_pipe
tw_extend:
    la   t1, tree_indent
    add  t1, t1, s4
tw_cp:
    lbu  t2, 0(a0)
    sb   t2, 0(t1)
    beqz t2, tw_cp_done
    addi a0, a0, 1
    addi t1, t1, 1
    j    tw_cp
tw_cp_done:
    la   t2, tree_indent
    sub  t1, t1, t2
    la   t2, tree_indent_len
    sd   t1, 0(t2)
    mv   a0, s2
    call tree_walk
    # restore the indent to this level's length
    la   t1, tree_indent_len
    sd   s4, 0(t1)
    la   t1, tree_indent
    add  t1, t1, s4
    sb   zero, 0(t1)
tw_next:
    ld   s2, NODE_NEXT(s2)
    j    tw_loop
tw_done:
    ld   ra, 0(sp)
    ld   s1, 8(sp)
    ld   s2, 16(sp)
    ld   s3, 24(sp)
    ld   s4, 32(sp)
    ld   s5, 40(sp)
    addi sp, sp, 48
    ret

# do_help: print the command reference.
do_help:
    la   a0, msg_help
    call uart_puts
    j    parse_ret

# do_uname: print a one-line description of the system.
do_uname:
    la   a0, msg_uname
    call uart_puts
    j    parse_ret

# do_clear: send the ANSI "clear screen + home cursor" escape sequence.
do_clear:
    la   a0, msg_clear
    call uart_puts
    j    parse_ret

# do_halt: power the machine off.  Reached by the "halt"/"exit" commands and
# by Ctrl-C.  Two independent mechanisms are tried, because not every
# environment supports both.
do_halt:
    la   a0, msg_bye
    call uart_puts
    # Mechanism 1: the SBI "system reset" (SRST) extension.  Supervisor code
    # asks the firmware below us to shut down by making an ecall with:
    #   a7 = extension id (0x08 = SRST), a6 = function id (0 = reset),
    #   a0 = reset type (0 = shutdown), a1 = reset reason (0 = none).
    li   a7, 0x08
    li   a6, 0
    li   a0, 0
    li   a1, 0
    ecall
    # Mechanism 2 (fallback, if the firmware ignored us): the SiFive test
    # finisher on the qemu virt machine.  Writing 0x5555 to 0x100000 asks
    # qemu to exit.  If even that fails we spin forever in a low-power wait.
    li   t0, 0x100000
    li   t1, 0x5555
    sw   t1, 0(t0)
2:  wfi                        # wait for an interrupt (there are none)
    j    2b                     # ...and keep waiting

# parse_ret: shared epilogue for parse_line and every command handler.  The
# handlers jump here instead of returning so there is a single place that
# unwinds parse_line's frame.  (Note this is why the command handlers may
# only be entered from parse_line, never called like normal functions.)
parse_ret:
    ld   ra, 0(sp)
    ld   s2, 8(sp)
    ld   s3, 16(sp)
    ld   s4, 24(sp)
    addi sp, sp, 32
    ret

# ------------------------------------------------------------------- data ---
# Read-only data.  `.rodata` lands in a read-only region.  Background:
#   .asciz "hi"   emits the characters plus a trailing NUL byte
#   .ascii "hi"   emits just the characters, no terminator
#   .byte 0x..    emits raw bytes we spell out ourselves
.section .rodata
# Directory paths harvested from the host by run.sh (NUL terminated, final
# entry is the empty string).  See fakeroot.inc.  init_fs replays these into
# the node tree at boot.
fake_paths:
    .include "fakeroot.inc"
msg_banner:
    .ascii "\r\n"
    .ascii "  ____  ___ ____   __     __\r\n"
    .ascii " |  _ \\|_ _/ ___|  \\ \\   / /\r\n"
    .ascii " | |_) || |\\___ \\   \\ \\ / / \r\n"
    .ascii " |  _ < | | ___) |   \\ V /  \r\n"
    .ascii " |_| \\_\\___|____/     \\_/   \r\n"
    .ascii "\r\n"
    .ascii "Toy RISC-V OS v1.0 (RV64, qemu virt)\r\n"
    .ascii "Type 'help' for the list of commands.\r\n\r\n"
    .byte 0

msg_prompt:     .asciz "riscv:"
msg_prompt_end: .asciz "> "
msg_uname:   .asciz "Toy RISC-V OS - 64-bit RISC-V, supervisor mode, UART 16550 @ 0x10000000\r\n"
msg_clear:   .asciz "\033[2J\033[H"
msg_bye:     .asciz "\r\nPowering off. Bye!\r\n"
msg_unknown: .asciz "unknown command: "
msg_mkdir_arg:  .asciz "mkdir: missing name (usage: mkdir \"name\")\r\n"
msg_mkdir_full: .asciz "mkdir: no space left in the node pool\r\n"
msg_cd_fail:    .asciz "cd: no such directory: "
msg_help:
    .ascii "Available commands:\r\n"
    .ascii "  printf(\"text\")  print the text between the quotes\r\n"
    .ascii "  mkdir \"path\"    create a directory (parents are created too)\r\n"
    .ascii "  cd \"path\"       walk a path: cd a/b, cd .., cd ../.., cd / etc.\r\n"
    .ascii "  pwd             print the current directory path\r\n"
    .ascii "  ls              list the current directory\r\n"
    .ascii "  tree            draw the tree (square marks where you are)\r\n"
    .ascii "  help            show this help\r\n"
    .ascii "  uname           show system information\r\n"
    .ascii "  clear           clear the screen\r\n"
    .ascii "  halt, exit      power off the machine\r\n"
    .ascii "Tip: up/down = command history, left/right = move the cursor.\r\n"
    .byte 0

cmd_printf_prefix: .asciz "printf("
cmd_help:  .asciz "help"
cmd_uname: .asciz "uname"
cmd_clear: .asciz "clear"
cmd_mkdir: .asciz "mkdir"
cmd_cd:    .asciz "cd"
cmd_pwd:   .asciz "pwd"
cmd_ls:    .asciz "ls"
cmd_tree:  .asciz "tree"
cmd_halt:  .asciz "halt"
cmd_exit:  .asciz "exit"

str_dot:        .asciz "."
str_dotdot:     .asciz ".."
str_dotdotslash:.asciz "../"
str_slash:      .asciz "/"

# UTF-8 art used by the tree command (bytes spelled out for the assembler)
art_circle:  .byte 0xe2,0x97,0x8b,0            # open circle  : a directory
art_square:  .byte 0xe2,0x96,0xa0,0            # filled square: where you are
art_tee:     .byte 0xe2,0x94,0x9c,0xe2,0x94,0x80,0xe2,0x94,0x80,0x20,0  # "├── "
art_ell:     .byte 0xe2,0x94,0x94,0xe2,0x94,0x80,0xe2,0x94,0x80,0x20,0  # "└── "
indent_pipe: .byte 0xe2,0x94,0x82,0x20,0x20,0x20,0    # "│   "
indent_spaces: .byte 0x20,0x20,0x20,0x20,0            # "    "

# -------------------------------------------------------------------- bss ---
# Uninitialised (zero-initialised) data.  `.space N` reserves N bytes; these
# labels are just names for offsets into that reserved memory.
.section .bss
.align 4
linebuf: .space BUF_SIZE                 # the line currently being edited
hist_entries: .space BUF_SIZE*HIST_MAX   # ring of previous commands
hist_count:   .space 8                   # how many history entries exist
hist_pos:     .space 8                   # which entry the arrows point at
arg_ptr: .space 8                        # pointer to the current argument
namebuf: .space NAME_LEN                 # scratch for a single name
pathbuf: .space PATH_SIZE                # scratch for a whole path argument
compbuf: .space NAME_LEN                 # one component while walking a path
tree_indent:     .space 256              # growing prefix string for `tree`
tree_indent_len: .space 8                # its current length in bytes
.align 3                                 # 8-byte alignment for the pointers
node_count: .space 8                     # nodes handed out by alloc_node
cwd_ptr:    .space 8                     # current working directory node
node_pool:  .space NODE_SIZE*MAX_NODES   # the in-memory filesystem tree

# --- block driver state ---
.align 3                                 # blk_base holds a 64-bit address
blk_base:      .space 8                  # MMIO base of the virtio-blk device
blk_ready:     .space 8                  # 1 once blk_init has succeeded
blk_avail_idx: .space 2                  # next available-ring index we will use
               .space 2                  # (padding to keep the next field aligned)
blk_hdr:       .space 16                 # virtio_blk_outhdr: type, reserved, sector
blk_status:    .space 8                  # one-byte status from the device
# Split virtqueue 0.  The descriptor table must be 16-byte aligned; the two
# rings have much weaker alignment requirements but plenty of slack here.
.align 4
vq_desc:  .space 16*VQ_SIZE              # descriptor table
vq_avail: .space 64                     # available ring (driver -> device)
vq_used:  .space 128                    # used ring (device -> driver)
# The serialised filesystem image, staged here on the way to/from the disk.
# MAX_NODES records plus the header need 16 + 256*28 = 7156 bytes, so one
# 8 KiB page comfortably covers any tree this OS can hold.
.align 3
fs_buf:   .space 8192                    # on-disk image buffer
# The stack.  It grows downward, so the "top" is the high address; _start
# points sp at stack_top.  16 KiB is plenty for this shallow recursion.
.align 16
stack_bottom:
    .space 16384
stack_top:

# Tell the linker this object needs no executable stack.  Harmless, and it
# silences a modern toolchain warning.
.section .note.GNU-stack,"",@progbits
