#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sources.env.sh
source "$ROOT/sources.env.sh"

tree_present() {
  local dst="$1"
  [[ -d "$dst" ]] && [[ -n "$(ls -A "$dst" 2>/dev/null)" ]]
}

clone() {
  local ref="$1" dst="$2" url="$3"
  if tree_present "$dst"; then
    echo "Skip existing tree $dst"
    return 0
  fi
  rm -rf "$dst"
  echo "Cloning $ref from $url -> $dst"
  git clone --depth 1 --branch "$ref" "$url" "$dst"
  rm -rf "$dst/.git"
}

# Upstream: NeuQore/* @ cva6 (VeriFire sle-verifire checkout paths)
clone cva6 "$VERIFIRE_LINUX" https://github.com/NeuQore/linux.git
clone cva6 "$VERIFIRE_OPENSBI" https://github.com/NeuQore/opensbi.git
clone cva6 "$VERIFIRE_BUSYBOX" https://github.com/NeuQore/busybox.git

echo "Sources:"
echo "  linux   $VERIFIRE_LINUX"
echo "  opensbi $VERIFIRE_OPENSBI"
echo "  busybox $VERIFIRE_BUSYBOX"
