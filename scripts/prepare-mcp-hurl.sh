#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
# Local Hurl execution is reserved for diagnosing a failed GitHub CI run.
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Hurl setup is CI-only.' >&2; exit 1; }
version=8.0.1
case "$(uname -m)" in
  arm64) arch=aarch64; checksum=b57928e246617df73cb1b2157f31f507dcbde6ae12e828cc53dde0e40e05bbbb ;;
  x86_64) arch=x86_64; checksum=55e95bb7a8d61ae6919eaaf96f260f0836f5b34c1b0f7731e38be803f6984367 ;;
  *) exit 1 ;;
esac
name="hurl-$version-$arch-apple-darwin"
mkdir -p .tools/hurl
curl --fail --location --retry 3 "https://github.com/Orange-OpenSource/hurl/releases/download/$version/$name.tar.gz" -o .tools/hurl/archive.tar.gz
echo "$checksum  .tools/hurl/archive.tar.gz" | shasum -a 256 --check
tar -xzf .tools/hurl/archive.tar.gz -C .tools/hurl --strip-components=1
rm .tools/hurl/archive.tar.gz
.tools/hurl/bin/hurlfmt --check Tests/MCP/editing.hurl
