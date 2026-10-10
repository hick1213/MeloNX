#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/sdk" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MELONX_TEST_ARGS"
STUB
chmod +x "$TASK_TMP/sdk"
if ! MELONX_TEST_ARGS="$TASK_TMP/args" MELONX_DOTNET="$TASK_TMP/sdk" bash "$ROOT/distribution/ios/build.sh" > "$TASK_TMP/output" 2>&1; then
  tail -12 "$TASK_TMP/output" >&2
  echo "FAIL: selected SDK invocation exited before the stub ran" >&2
  exit 1
fi
if [ ! -f "$TASK_TMP/args" ]; then
  echo 'FAIL: explicit SDK executable was not invoked' >&2
  exit 1
fi
cat > "$TASK_TMP/expected" <<'ARGS'
publish
-c
Release
-r
ios-arm64
-p:ExtraDefineConstants=DISABLE_UPDATER
src/Ryujinx.Library
--self-contained
true
ARGS
cmp "$TASK_TMP/args" "$TASK_TMP/expected"
if MELONX_DOTNET="$TASK_TMP/missing-sdk" bash "$ROOT/distribution/ios/build.sh" > "$TASK_TMP/missing-output" 2>&1; then
  echo 'FAIL: missing explicitly selected SDK must fail' >&2
  exit 1
fi
printf '<configuration/>\n' > "$TASK_TMP/config with spaces.xml"
MELONX_TEST_ARGS="$TASK_TMP/args" MELONX_DOTNET="$TASK_TMP/sdk" MELONX_NUGET_CONFIG="$TASK_TMP/config with spaces.xml" bash "$ROOT/distribution/ios/build.sh" > "$TASK_TMP/config-output" 2>&1
printf '%s\n' '--configfile' "$TASK_TMP/config with spaces.xml" >> "$TASK_TMP/expected"
cmp "$TASK_TMP/args" "$TASK_TMP/expected"
if MELONX_TEST_ARGS="$TASK_TMP/args" MELONX_DOTNET="$TASK_TMP/sdk" MELONX_NUGET_CONFIG="$TASK_TMP/missing-config" bash "$ROOT/distribution/ios/build.sh" > "$TASK_TMP/missing-config-output" 2>&1; then
  echo 'FAIL: missing explicitly selected config must fail' >&2
  exit 1
fi
printf 'PASS: selected SDK/config arguments and missing-path rejection\n' 
