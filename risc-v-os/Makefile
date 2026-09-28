# ---------------------------------------------------------------------------
# Build rules for the toy RISC-V OS.
#
# We cross-compile: the compiler on this host produces RISC-V machine code that
# runs under qemu rather than natively.  `make` only rebuilds os.elf when one
# of its inputs changes.
#
#   CROSS  : prefix of the cross toolchain.  Override with `make CROSS=...`
#            if your distribution names the tools differently.
#   CC     : the compiler driver (also used, via CFLAGS, as the linker).
# ---------------------------------------------------------------------------
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy

# Flags explained:
#   -march=rv64gc   target the RV64G base ISA plus the C compressed extension
#   -mabi=lp64d     ABI: 64-bit longs/pointers, doubles in FP registers
#   -mcmodel=medany position-independent-ish code for any 2 GiB window
#   -nostdlib       do not link the standard C library (none exists bare-metal)
#   -nostartfiles   do not inject the usual C runtime startup (we have _start)
#   -ffreestanding  we provide our own environment; no main() or libc assumed
#   -fno-pie        no position-independent executable (fixed load address)
#   -Wl,--build-id=none  omit the build-id note, which bare-metal does not want
CFLAGS  := -march=rv64gc -mabi=lp64d -mcmodel=medany \
           -nostdlib -nostartfiles -ffreestanding -fno-pie \
           -Wl,--build-id=none

TARGET  := os.elf

all: $(TARGET)

# Compile and link in one step: os.S is assembled and linked against the
# linker script.  fakeroot.inc is a build product of run.sh listed as a
# dependency so a fresh checkout still has a file to .include.
$(TARGET): os.S linker.ld fakeroot.inc
	$(CC) $(CFLAGS) -T linker.ld -o $@ os.S

# Fallback so a bare `make` still assembles; ./run.sh overwrites this with the
# real directory listing from the host.
fakeroot.inc:
	@printf '# no fake filesystem generated (run ./run.sh)\n.byte 0\n' > $@

# Build and immediately boot the result under qemu.
run: $(TARGET)
	./run.sh

# Remove every generated file.
clean:
	rm -f $(TARGET) fakeroot.inc

.PHONY: all run clean
