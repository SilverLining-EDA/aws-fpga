# VeriFire firmware paths (sle-verifire layout). Set by cl_cva6_linux.sh or defaults below.
_SLE_VERIFIRE="${SLE_VERIFIRE_ROOT:-/projects/prj1/sle-wajahat/sle-verifire}"
VERIFIRE_SRC_ROOT="${VERIFIRE_SRC_ROOT:-$_SLE_VERIFIRE}"
export VERIFIRE_LINUX="${VERIFIRE_LINUX:-$VERIFIRE_SRC_ROOT/linux}"
export VERIFIRE_OPENSBI="${VERIFIRE_OPENSBI:-$VERIFIRE_SRC_ROOT/opensbi}"
export VERIFIRE_BUSYBOX="${VERIFIRE_BUSYBOX:-$VERIFIRE_SRC_ROOT/busybox}"
