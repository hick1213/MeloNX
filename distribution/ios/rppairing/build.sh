#!/usr/bin/env bash
set -euo pipefail
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../../.." && pwd)"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
# Cargo searches ancestor configs from cwd; /tmp avoids a global mirror above the checkout.
cd "${TMPDIR:-/tmp}"
cargo build --manifest-path "$BUILD_DIR/Cargo.toml" --release --locked --target aarch64-apple-ios
cp "$BUILD_DIR/target/aarch64-apple-ios/release/libmelonx_rppairing.a" "$REPO_ROOT/src/MeloNX/MeloNX/Dependencies/libmelonx_rppairing.a"
mkdir -p "$REPO_ROOT/src/MeloNX/MeloNX/Resources"
python3 "$BUILD_DIR/notices.py" "$REPO_ROOT/src/MeloNX/MeloNX/Resources/LICENSES-rppairing-crates.txt"
