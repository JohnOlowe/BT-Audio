#!/usr/bin/env bash
# Compatibility entry point: the Windows PowerShell sender's source and test
# runner live together under btaudio/windows/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/../btaudio/windows/pscheck.sh" "$@"
