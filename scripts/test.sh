#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
python3 scripts/test-icloud-profile.py
scripts/bootstrap.sh
scripts/build-mcp.sh
swift build --build-tests --enable-code-coverage -Xswiftc -warnings-as-errors
coverage_dir="$(swift build --show-bin-path)/codecov"
mkdir -p "$coverage_dir"
rm -f "$coverage_dir"/*.profraw "$coverage_dir"/*.profdata
rm -rf build/coverage
test_status=0
# A crash in a native UI test prints its stack instead of only a signal number.
export SWIFT_BACKTRACE="${SWIFT_BACKTRACE:-enable=yes,interactive=no}"
LEFTBLANK_INTEGRATION=1 swift test --skip-build --enable-code-coverage "$@" || test_status=$?
coverage_status=0
python3 scripts/coverage.py --minimum 80 || coverage_status=$?
if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
exit "$coverage_status"
