#!/bin/bash
# Keep iPad-only engine fixes separate from the macOS CLI; the VFS fix is shared.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
source_dir="$PWD/.tools/tinymist-ipad-source"
revision=32f908199ee17ea295512bbc27166e890c438175
if [ ! -d "$source_dir" ]; then
  git clone --depth 1 --branch v0.15.8 https://github.com/Myriad-Dreamin/tinymist.git "$source_dir"
fi
test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision"
for patch in "$PWD/scripts/tinymist-ipad.patch" "$PWD/scripts/tinymist-ipad-export.patch" \
  "$PWD/scripts/tinymist-vfs.patch"; do
  if git -C "$source_dir" apply --check "$patch" 2>/dev/null; then
    git -C "$source_dir" apply "$patch"
  else
    git -C "$source_dir" apply --reverse --check "$patch"
  fi
done
