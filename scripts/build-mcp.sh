#!/bin/bash
# macOS-only helper; never called by the iPad build or its Rust engine graph.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
export CARGO_HOME="$PWD/.tools/cargo-mcp"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  rustup toolchain install 1.92.0 --profile minimal --component rustfmt --component clippy
fi
cargo +1.92.0 build --locked --release --manifest-path Tools/MCPServer/Cargo.toml
mkdir -p .tools
cp Tools/MCPServer/target/release/leftblank-mcp .tools/leftblank-mcp
python3 scripts/mcp-licenses.py
