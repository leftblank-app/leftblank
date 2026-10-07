#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
mkdir -p .tools
case "$(uname -m)" in
  arm64) ;;
  *) echo 'LeftBlank supports Apple Silicon (arm64) only' >&2; exit 1 ;;
esac
# Every distribution bundles the patched source build; see build-tinymist.sh.
scripts/build-tinymist.sh
version=0.15.8
.tools/tinymist --version | grep "v$version" >/dev/null || { echo "Tinymist is not v$version" >&2; exit 1; }
scripts/build-tinymist.sh --check
.tools/tinymist --version
