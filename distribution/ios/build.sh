#!/usr/bin/env bash
set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DOTNET="${MELONX_DOTNET:-$(command -v dotnet || true)}"

if [ -z "$DOTNET" ]; then
  for candidate in \
    "/opt/homebrew/bin/dotnet" \
    "/usr/local/bin/dotnet" \
    "/usr/local/share/dotnet/dotnet"
  do
    if [ -x "$candidate" ]; then
      DOTNET="$candidate"
      break
    fi
  done
fi

if [ -z "$DOTNET" ] || [ ! -x "$DOTNET" ]; then
  echo "dotnet not found or not executable: $DOTNET" >&2
  exit 1
fi

publish_args=(publish -c Release -r ios-arm64 -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true)
if [ -n "${MELONX_NUGET_CONFIG:-}" ]; then
  if [ ! -f "$MELONX_NUGET_CONFIG" ] || [ ! -r "$MELONX_NUGET_CONFIG" ]; then
    echo "NuGet configuration is not readable: $MELONX_NUGET_CONFIG" >&2
    exit 1
  fi
  publish_args+=(--configfile "$MELONX_NUGET_CONFIG")
fi
"$DOTNET" "${publish_args[@]}"
