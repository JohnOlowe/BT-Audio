#!/usr/bin/env bash
# prepare-tools.sh [ensure|status|clean]
#
# Keep the optional Windows test toolchain out of the checkout. `ensure` reuses
# the pinned system SDK when available or lets cscheck.sh fetch it into the
# external cache; `clean` removes only that cache and generated harness files.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CACHE="${BTAUDIO_WINDOWS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/btaudio/windows}"
case "$CACHE" in /*) ;; *) CACHE="$PWD/$CACHE" ;; esac
export BTAUDIO_WINDOWS_CACHE="$CACHE"
ACTION="${1:-ensure}"

case "$ACTION" in
  ensure|setup)
    bash "$HERE/cscheck.sh" bootstrap
    mkdir -p "$CACHE/pwsh"
    export DOTNET_ROOT="$CACHE"
    export DOTNET_CLI_HOME="$CACHE/dotnet-cli"
    export NUGET_PACKAGES="$CACHE/nuget"
    export PATH="$CACHE/pwsh:$CACHE:$PATH"
    if ! command -v pwsh >/dev/null 2>&1; then
      echo "==> installing pinned PowerShell 7.4.6 into $CACHE/pwsh"
      "$CACHE/dotnet" tool install --tool-path "$CACHE/pwsh" PowerShell --version 7.4.6
    fi
    echo "Windows build tools ready:"
    "$CACHE/dotnet" --version
    if command -v pwsh >/dev/null 2>&1; then
      pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    fi
    echo "  cache: $CACHE"
    ;;
  status)
    echo "Windows build-tool cache: $CACHE"
    if [ -x "$CACHE/dotnet" ]; then "$CACHE/dotnet" --version; else echo ".NET SDK: not cached"; fi
    if command -v dotnet >/dev/null 2>&1; then dotnet --list-sdks; else echo "system dotnet: not found"; fi
    if command -v pwsh >/dev/null 2>&1; then pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'; else echo "pwsh: not found"; fi
    for tool in python3 socat javac; do
      if command -v "$tool" >/dev/null 2>&1; then printf '%-8s %s\n' "$tool" "$(command -v "$tool")"; else printf '%-8s %s\n' "$tool" "not found"; fi
    done
    ;;
  clean)
    CACHE="${CACHE%/}"
    case "$CACHE" in
      ""|"/"|"$HOME"|"$ROOT"|"$ROOT"/*)
        echo "refusing unsafe cache cleanup path: $CACHE" >&2
        exit 2
        ;;
    esac
    case "$CACHE" in
      */btaudio/windows|*/btaudio-windows) ;;
      *)
        echo "refusing cleanup: cache must end in /btaudio/windows (or /btaudio-windows)" >&2
        exit 2
        ;;
    esac
    if [ -L "$CACHE" ]; then rm -f -- "$CACHE"; else rm -rf -- "$CACHE"; fi
    rm -rf -- "$HERE/build" "$ROOT/pscheck/build"
    echo "Removed the external Windows tool cache and generated harness files."
    echo "Source files and checked-in Windows binaries were left untouched."
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage: bash btaudio/windows/prepare-tools.sh [ensure|status|clean]

  ensure  Reuse or fetch the pinned .NET SDK, net48 reference assemblies,
          and PowerShell 7.4.6 (default).
  status  Report installed tools without downloading anything.
  clean   Remove only BTAUDIO_WINDOWS_CACHE and ignored harness build output.

Set BTAUDIO_WINDOWS_CACHE to move the external cache. ensure requires network
access to the pinned .NET SDK and NuGet package URLs when those tools are absent.
EOF
    ;;
  *) echo "unknown action: $ACTION (expected ensure, status, or clean)" >&2; exit 2 ;;
esac
