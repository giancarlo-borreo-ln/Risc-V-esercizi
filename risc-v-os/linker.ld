/* ---------------------------------------------------------------------------
 * Linker script for the toy RISC-V OS.
 *
 * The linker combines our object files into one executable and decides at
 * which addresses each section lives.  Comments here are C-style because this
 * is a linker script, not assembly.
 *
 *   OUTPUT_ARCH(riscv)  the machine type recorded in the output file
 *   ENTRY(_start)       which symbol the program begins executing at
 *
 * QEMU's "virt" machine loads the kernel -kernel blob at 0x80200000 (RAM
 * starts at 0x80000000, and the first 2 MiB are reserved for OpenSBI), so all
 * our sections are laid out contiguously from there.
 * ------------------------------------------------------------------------ */
OUTPUT_ARCH(riscv)
ENTRY(_start)

/* Base virtual/physical address where our image is loaded. */
BASE = 0x80200000;

SECTIONS
{
    /* The dot is the "location counter": the current output address.  Setting
     * it once at the start means the following sections flow upward from BASE. */
    . = BASE;

    /* Executable code and read-only data first, so they can share a page and
     * be marked executable/read-only. */
    .text : {
        *(.text)        /* our plain .text section (from os.S) */
        *(.text.*)      /* compiler-generated per-function sections, if any */
    }

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }

    /* Realign so the following writable data starts on a 16-byte boundary.
     * The RISC-V ABI wants at least 8-byte alignment for data; 16 keeps the
     * stack and everything else comfortably aligned. */
    . = ALIGN(16);

    /* Initialised writable data.  We have none in this program, but a linker
     * script normally still lists the section. */
    .data : {
        *(.data)
        *(.data.*)
    }

    /* Zero-initialised writable data, including COMMON symbols.  This is where
     * linebuf, node_pool, the stack and friends end up; the loader (or, in
     * bare-metal terms, the all-zero RAM) makes them zero. */
    .bss : {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    }

    /* A convenient symbol marking the end of our image.  Nothing currently
     * reads it, but it is useful for things like a simple heap. */
    _end = .;
}
