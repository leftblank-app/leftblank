#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
scripts/bootstrap.sh
scripts/build-mcp.sh
configuration=${1:-debug}
swift build -c "$configuration"
binary_dir=$(swift build -c "$configuration" --show-bin-path)
app=$(python3 scripts/package-app.py "$binary_dir")
scripts/sign-app.sh "$app"
echo "Built $PWD/$app"
