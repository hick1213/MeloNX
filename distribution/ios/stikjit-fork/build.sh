#!/usr/bin/env bash
set -euo pipefail
FORK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$FORK_DIR/../../.." && pwd)"
TOOLS_ROOT="${MELONX_TOOLS_ROOT:-$REPO_ROOT/.local/build-tools}"
UPSTREAM="${MELONX_STIKJIT_SOURCE:-$TOOLS_ROOT/StikJIT-source-1.9.0}"
EXPECTED=32287268fa5824f9edce4cb359f5833ce0cf7b00
if [ ! -d "$UPSTREAM/.git" ]; then
  git clone --depth 1 --branch 1.9.0 https://github.com/StikDebug/StikJIT.git "$UPSTREAM"
fi
[ "$(git -C "$UPSTREAM" rev-parse HEAD)" = "$EXPECTED" ] || { echo 'Unexpected StikJIT source revision' >&2; exit 1; }
BUILD_ROOT="$TOOLS_ROOT/StikJIT-owned-build"
mkdir -p "$BUILD_ROOT"
/usr/bin/ditto "$FORK_DIR/Sources" "$BUILD_ROOT/Sources"
/usr/bin/ditto "$FORK_DIR/Resources" "$BUILD_ROOT/Resources"
/usr/bin/ditto "$FORK_DIR/owned" "$BUILD_ROOT/owned"
/usr/bin/ditto "$UPSTREAM/idevice" "$BUILD_ROOT/idevice"
/usr/bin/ditto "$UPSTREAM/iokit" "$BUILD_ROOT/iokit"
cp "$FORK_DIR/project.yml" "$BUILD_ROOT/project.yml"
export IPHONEOS_DEPLOYMENT_TARGET=17.4
cargo build --manifest-path "$REPO_ROOT/distribution/ios/jit-session/Cargo.toml" --release --locked --target aarch64-apple-ios
cp "$REPO_ROOT/distribution/ios/jit-session/target/aarch64-apple-ios/release/libmelonx_jit_session.a" "$BUILD_ROOT/owned/"
xcodegen generate --spec "$BUILD_ROOT/project.yml" --project "$BUILD_ROOT"
xcodebuild -project "$BUILD_ROOT/StikJIT.xcodeproj" -scheme StikJIT -configuration Release -destination generic/platform=iOS -derivedDataPath "$BUILD_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO CONFIGURATION_BUILD_DIR="$BUILD_ROOT/products" build
# Install the fork only after the complete source build succeeds. Preserve the
# original official artifact under downloads for provenance and comparison.
DEST="$REPO_ROOT/src/MeloNX/JITDependencies/StikJIT.xcframework/ios-arm64/StikJIT.framework"
/usr/bin/ditto "$BUILD_ROOT/products/StikJIT.framework" "$DEST"
