#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh

# Use the official release asset instead of cli.codecov.io, whose TLS handshake
# can fail before the action downloads either the CLI or its signature files.
# Pin the release digest here, independently of the downloaded file.
version=11.3.1
expected=ffb2b821551076b69d3267508b2d5dc10925c821c436521f2216f5ead62cb138
mkdir -p .tools
curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --max-time 180 \
  "https://github.com/codecov/codecov-cli/releases/download/v${version}/codecovcli_macos" \
  -o .tools/codecov
actual=$(shasum -a 256 .tools/codecov | awk '{print $1}')
test "$actual" = "$expected" || { echo 'Codecov checksum mismatch' >&2; exit 1; }
chmod +x .tools/codecov
.tools/codecov --version
