#!/bin/sh
set -eu

RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf-}"
OUT_DIR="tests/generated"

mkdir -p "$OUT_DIR"

"${RISCV_PREFIX}gcc" -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
  -T tests/common/linker.ld tests/asm/blink.S -o "$OUT_DIR/blink.elf"
"${RISCV_PREFIX}objcopy" -O binary "$OUT_DIR/blink.elf" "$OUT_DIR/blink.bin"
"${RISCV_PREFIX}objdump" -d "$OUT_DIR/blink.elf" > "$OUT_DIR/blink.dis"

#Convert each littl endian 32-bit instruction word into one hex line
od -An -v -t x4 "$OUT_DIR/blink.bin" | tr -s ' ' '\n' | sed '/^$/d' > "$OUT_DIR/blink.hex"

echo "Built $OUT_DIR/blink.hex"

