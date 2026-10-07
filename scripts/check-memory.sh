#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
mkdir -p build/memory
scripts/build-syntax.sh

case "${1:-}" in
  leaks)
    swift build --build-system native --build-tests -Xswiftc -warnings-as-errors
    rm -f build/memory/baseline.memgraph build/memory/lifecycle.memgraph
    LEFTBLANK_INTEGRATION=1 LEFTBLANK_MEMORY_CHECKS=1 MallocStackLogging=1 \
      LEFTBLANK_MEMORY_REPORT_DIR="$PWD/build/memory" \
      swift test --build-system native --skip-build \
      --filter repeatedWindowLifecycleReleasesOwnedObjects 2>&1 | tee build/memory/lifecycle.log
    # Require both a completed workload and actual snapshots of the test process.
    grep -q 'LEFTBLANK MEMORY: completed 10 window lifecycles' build/memory/lifecycle.log
    test -s build/memory/baseline.memgraph
    test -s build/memory/lifecycle.memgraph
    leaks --quiet --diffFrom=build/memory/baseline.memgraph \
      build/memory/lifecycle.memgraph 2>&1 | tee build/memory/leaks.log
    ;;
  address)
    # Native SwiftPM avoids the Xcode 26.3 sanitizer/filter runner bug. Sanitizer
    # builds use a separate directory and never supply performance measurements.
    swift test --build-system native --scratch-path .build/address --sanitize address \
      -Xswiftc -warnings-as-errors --filter LeftBlankCoreTests \
      2>&1 | tee build/memory/address.log
    ;;
  *) echo 'Usage: scripts/check-memory.sh {leaks|address}' >&2; exit 2 ;;
esac
