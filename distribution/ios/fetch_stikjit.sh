#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOWNLOAD_DIR="${MELONX_DOWNLOAD_DIR:-$REPO_ROOT/.local/downloads}"
mkdir -p "$DOWNLOAD_DIR"
ARCHIVE="${MELONX_STIKJIT_ARCHIVE:-$DOWNLOAD_DIR/StikJIT.xcframework-1.9.0.zip}"
if [ ! -f "$ARCHIVE" ]; then
  curl --fail --location --retry 2 --output "$ARCHIVE" https://github.com/StikDebug/StikJIT/releases/download/1.9.0/StikJIT.xcframework.zip
fi
EXPECTED=806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060
ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "StikJIT 1.9.0 checksum mismatch; dependency was not changed." >&2
  exit 1
fi
DEST="$REPO_ROOT/src/MeloNX/JITDependencies"
mkdir -p "$DEST"
# Keep an existing unpacked framework; no unverified overwrite.
if [ ! -d "$DEST/StikJIT.xcframework" ]; then
  unzip -q "$ARCHIVE" -d "$DEST"
fi
