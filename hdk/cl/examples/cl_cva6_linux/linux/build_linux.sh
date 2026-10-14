#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sources.env.sh
source "$ROOT/sources.env.sh"
OUT="${OUT_DIR:-$ROOT/out}"
JOBS="${JOBS:-$(nproc)}"
CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}"

LINUX="$VERIFIRE_LINUX"
OPENSBI="$VERIFIRE_OPENSBI"
BUSYBOX="$VERIFIRE_BUSYBOX"
LINUX_OUT="$OUT/linux"
OPENSBI_OUT="$OUT/opensbi"
BUSYBOX_OUT="$OUT/busybox"
ROOTFS="$OUT/rootfs"
DTB="$OUT/cl_cva6_linux.dtb"
MUSL_PREFIX="$OUT/musl"
MUSL_GCC="$MUSL_PREFIX/bin/riscv64-musl-gcc"

# Paths baked in when trees lived under .../sle-wajahat/{aws-fpga,busybox,...}.
LEGACY_OUT="/projects/prj1/sle-wajahat/aws-fpga/hdk/cl/examples/cl_cva6_linux/linux/out"
LEGACY_BUSYBOX="/projects/prj1/sle-wajahat/busybox"

fix_musl_toolchain() {
  [[ -d "$MUSL_PREFIX" ]] || return 0
  local f specs="$MUSL_PREFIX/lib/musl-gcc.specs"
  [[ -f "$specs" ]] || return 0

  if grep -q "$LEGACY_OUT" "$specs" 2>/dev/null; then
    echo "== Relocating musl toolchain paths to $MUSL_PREFIX =="
    grep -rl "$LEGACY_OUT" "$MUSL_PREFIX" 2>/dev/null | while read -r f; do
      sed -i "s|$LEGACY_OUT|$OUT|g" "$f"
    done
  fi

  cat > "$MUSL_PREFIX/bin/riscv64-musl-gcc" <<EOF
#!/bin/sh
exec riscv64-linux-gnu-gcc -march=rv64imfdc -mabi=lp64d -specs $MUSL_PREFIX/lib/musl-gcc.specs "\$@"
EOF
  chmod +x "$MUSL_PREFIX/bin/riscv64-musl-gcc"
}

maybe_clean_stale_busybox() {
  [[ -d "$BUSYBOX_OUT" ]] || return 0
  if grep -qr "$LEGACY_OUT\|$LEGACY_BUSYBOX" "$BUSYBOX_OUT" 2>/dev/null; then
    echo "== Clearing BusyBox object dir (stale paths from pre–sle-verifire layout) =="
    rm -rf "$BUSYBOX_OUT"
  fi
}

for dir in "$LINUX" "$OPENSBI" "$BUSYBOX"; do
  [[ -d "$dir" ]] || {
    echo "Missing $dir; run fetch_repos.sh / cl_cva6_linux.sh fetch first" >&2
    exit 1
  }
done
command -v "${CROSS_COMPILE}gcc" >/dev/null || {
  echo "Missing ${CROSS_COMPILE}gcc (install gcc-riscv64-linux-gnu)" >&2
  exit 1
}
command -v dtc >/dev/null || {
  echo "Missing dtc (install device-tree-compiler)" >&2
  exit 1
}

mkdir -p "$OUT" "$LINUX_OUT" "$OPENSBI_OUT" "$BUSYBOX_OUT" "$ROOTFS"

fix_musl_toolchain
maybe_clean_stale_busybox

echo "== Device tree =="
dtc -I dts -O dtb -o "$DTB" "$ROOT/cl_cva6_linux.dts"

echo "== BusyBox static initramfs =="
# glibc is built with the A extension. HBM never completes LR/SC, so a
# glibc busybox hangs in the first userspace lock. Link the no-A musl instead.
BB_CC=()
if [[ -x "$MUSL_GCC" ]]; then
  BB_CC=(CC="$MUSL_GCC")
fi
make -C "$BUSYBOX" O="$BUSYBOX_OUT" ARCH=riscv \
  CROSS_COMPILE="$CROSS_COMPILE" "${BB_CC[@]}" cl_cva6_f2_defconfig
make -C "$BUSYBOX" O="$BUSYBOX_OUT" ARCH=riscv \
  CROSS_COMPILE="$CROSS_COMPILE" "${BB_CC[@]}" -j"$JOBS"
make -C "$BUSYBOX" O="$BUSYBOX_OUT" ARCH=riscv \
  CROSS_COMPILE="$CROSS_COMPILE" "${BB_CC[@]}" CONFIG_PREFIX="$ROOTFS" install
install -m 0755 "$ROOT/init" "$ROOTFS/init"
mkdir -p "$ROOTFS"/{dev,proc,sys,tmp}
# Device nodes cannot be created on this filesystem. The kernel opens
# /dev/console before /init (and before devtmpfs), so list them for gen_init_cpio.
DEVNODES="$OUT/devnodes.list"
cat > "$DEVNODES" <<'EOF'
nod /dev/console 622 0 0 c 5 1
nod /dev/null 666 0 0 c 1 3
EOF

echo "== Linux kernel + embedded initramfs =="
make -C "$LINUX" O="$LINUX_OUT" ARCH=riscv \
  CROSS_COMPILE="$CROSS_COMPILE" defconfig
"$LINUX/scripts/kconfig/merge_config.sh" -m -O "$LINUX_OUT" \
  "$LINUX_OUT/.config" "$ROOT/kernel.config.fragment"
{
  echo "CONFIG_INITRAMFS_SOURCE=\"$ROOTFS $DEVNODES\""
  echo 'CONFIG_INITRAMFS_ROOT_UID=0'
  echo 'CONFIG_INITRAMFS_ROOT_GID=0'
} >> "$LINUX_OUT/.config"
make -C "$LINUX" O="$LINUX_OUT" ARCH=riscv \
  CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -C "$LINUX" O="$LINUX_OUT" ARCH=riscv \
  CROSS_COMPILE="$CROSS_COMPILE" syncconfig
grep -q '^CONFIG_CVA6_F2_NO_AMO=y$' "$LINUX_OUT/.config" || {
  echo "F2 Linux build requires CONFIG_CVA6_F2_NO_AMO=y" >&2
  exit 1
}
make -C "$LINUX" O="$LINUX_OUT" ARCH=riscv \
  CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image

echo "== OpenSBI fw_payload =="
make -C "$OPENSBI" O="$OPENSBI_OUT" PLATFORM=generic \
  CROSS_COMPILE="$CROSS_COMPILE" \
  FW_PAYLOAD_PATH="$LINUX_OUT/arch/riscv/boot/Image" \
  FW_FDT_PATH="$DTB" \
  FW_TEXT_START=0x80000000 \
  -j"$JOBS"

cp "$OPENSBI_OUT/platform/generic/firmware/fw_payload.bin" \
  "$OUT/cl_cva6_linux.bin"

echo
echo "Boot image: $OUT/cl_cva6_linux.bin"
ls -lh "$OUT/cl_cva6_linux.bin" "$DTB" \
  "$LINUX_OUT/arch/riscv/boot/Image"
