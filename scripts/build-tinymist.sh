#!/bin/bash
# Build the Mac Tinymist helper from the pinned upstream revision with LeftBlank's
# engine fixes. Every Mac distribution bundles this one binary:
# - tinymist-native-tls.patch: reqwest uses macOS Security Framework, not Rust TLS
#   (App Store export compliance; system trust settings for every channel).
# - tinymist-vfs.patch: unread VFS cells are not shared between revisions, so a
#   compile still reading an old revision cannot leave stale include contents.
#
# Usage: scripts/build-tinymist.sh [--stamp|--check]
#   (none)   build .tools/tinymist unless its stamp matches the current inputs
#   --stamp  print the expected stamp without building
#   --check  fail unless .tools/tinymist was built from the current inputs
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.15.8
revision=32f908199ee17ea295512bbc27166e890c438175
toolchain=1.92.0
# macOS 27 rejects misaligned proc-macro dylibs produced when debug info is stripped.
build_env=(MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=1
  CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none)
build_args=(build --release --locked -p tinymist-cli)
patches=(scripts/tinymist-native-tls.patch scripts/tinymist-vfs.patch)
binary=.tools/tinymist
stamp_file=.tools/tinymist.stamp

# The stamp lists every build input, so it also documents which patches the
# bundled binary contains. CI caches the binary under a hash of this script and
# the patches.
stamp() {
  printf 'tinymist %s %s\nrust %s\nbuild %s cargo %s\n' "$version" "$revision" "$toolchain" \
    "${build_env[*]}" "${build_args[*]}"
  local patch
  for patch in "${patches[@]}"; do
    printf 'patch %s %s\n' "$patch" "$(shasum -a 256 "$patch" | awk '{print $1}')"
  done
}

current() {
  [ -x "$binary" ] && [ "$(cat "$stamp_file" 2>/dev/null)" = "$(stamp)" ] &&
    "$binary" --version | grep "v$version" >/dev/null
}

case "${1:-}" in
  --stamp) stamp; exit 0 ;;
  --check)
    current || { echo "$binary was not built from the current pinned source and patches; run scripts/build-tinymist.sh" >&2; exit 1; }
    exit 0 ;;
  '') ;;
  *) echo 'Usage: scripts/build-tinymist.sh [--stamp|--check]' >&2; exit 2 ;;
esac

source scripts/environment.sh
if current; then
  "$binary" --version
  exit 0
fi
source_dir="$PWD/.tools/tinymist-mac-source"
mkdir -p .tools
if [ ! -d "$source_dir" ]; then
  git clone --depth 1 --branch "v$version" https://github.com/Myriad-Dreamin/tinymist.git "$source_dir"
fi
test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision"
# Start from pristine tracked sources so a changed patch set never stacks on an
# older one. Untracked target and Cargo directories stay for incremental builds.
git -C "$source_dir" reset --quiet --hard "$revision"
for patch in "${patches[@]}"; do
  git -C "$source_dir" apply "$PWD/$patch"
done
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  rustup toolchain install "$toolchain" --profile minimal
fi
(cd "$source_dir" && env CARGO_HOME="$source_dir/.cargo-home" "${build_env[@]}" \
  cargo "+$toolchain" "${build_args[@]}")
rm -f "$stamp_file"
# Replace rather than overwrite, so a running helper keeps its signed pages.
cp "$source_dir/target/release/tinymist" "$binary.new"
chmod +x "$binary.new"
mv -f "$binary.new" "$binary"
stamp > "$stamp_file"
"$binary" --version
