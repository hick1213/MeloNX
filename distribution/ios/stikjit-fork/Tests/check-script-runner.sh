#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${MELONX_TEST_OUTPUT:?Set MELONX_TEST_OUTPUT to the external test artifact directory}"
mkdir -p "$MELONX_TEST_OUTPUT"
cat "$root/Sources/ScriptRunner.swift" "$root/Tests/ScriptRunnerChecks.swift" > "$MELONX_TEST_OUTPUT/main.swift"
xcrun swiftc -module-cache-path "$MELONX_TEST_OUTPUT/module-cache" "$MELONX_TEST_OUTPUT/main.swift" -o "$MELONX_TEST_OUTPUT/script-runner-checks"
"$MELONX_TEST_OUTPUT/script-runner-checks"
