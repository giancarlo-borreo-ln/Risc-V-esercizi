/* ---------------------------------------------------------------------------
 * Linker script for the toy RISC-V OS (C translation).
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

BASE = 0x80200000;

SECTIONS
{
    . = BASE;

    .text : {
        *(.text.start)   /* _start must sit exactly at BASE (0x80200000) */
        *(.text)
        *(.text.*)
    }

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }

    . = ALIGN(16);

    .data : {
        *(.data)
        *(.data.*)
    }

    .bss : {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    }

    _end = .;
}
