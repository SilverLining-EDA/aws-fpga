PREFIX ?= riscv32-unknown-elf
CC      := $(PREFIX)-gcc
OBJCOPY := $(PREFIX)-objcopy
OBJDUMP := $(PREFIX)-objdump

CFLAGS := -march=rv32ima -mabi=ilp32 -static -mcmodel=medany \
          -fvisibility=hidden -nostdlib -nostartfiles -O2 -Wall
LDFLAGS := -T link.ld

.PHONY: all clean

all: hello_world.bin hello_world.elf

hello_world.elf: crt.S hello_world.c uart.c link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) crt.S hello_world.c uart.c -o $@
	$(OBJDUMP) -d $@ > hello_world.dump

hello_world.bin: hello_world.elf
	$(OBJCOPY) -O binary $< $@
	@echo "Built $@ (`wc -c < $@` bytes)"

clean:
	rm -f hello_world.elf hello_world.bin hello_world.dump
