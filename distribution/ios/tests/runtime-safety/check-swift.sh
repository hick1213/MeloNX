#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
: "${MELONX_TEST_OUTPUT:?Set the external test artifact directory}"
mkdir -p "$MELONX_TEST_OUTPUT"
kind=${1:?statistics or memory}
if [ "$kind" = statistics ]; then
    source="$root/src/MeloNX/MeloNX/Common/StatisticsHandler.swift"
    driver="$(dirname "$0")/StatisticsChecks.swift"
else
    source="$MELONX_TEST_OUTPUT/MemoryUsageMonitor.swift"
    if [ -f "$root/src/MeloNX/MeloNX/Common/MemoryUsageMonitor.swift" ]; then
        cp "$root/src/MeloNX/MeloNX/Common/MemoryUsageMonitor.swift" "$source"
    else
        printf 'import SwiftUI\nimport Combine\nimport Foundation\n' > "$source"
        sed -n '/^@MainActor$/,/^struct EmulationView/ p' "$root/src/MeloNX/MeloNX/UI/Emulation/EmulationView.swift" | sed '$d' >> "$source"
    fi
    driver="$(dirname "$0")/MemoryMonitorChecks.swift"
fi
xcrun swiftc -module-cache-path "$MELONX_TEST_OUTPUT/module-cache" "$source" "$driver" -o "$MELONX_TEST_OUTPUT/$kind-checks"
"$MELONX_TEST_OUTPUT/$kind-checks"
