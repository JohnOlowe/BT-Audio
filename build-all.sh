#!/usr/bin/env bash
# Compile, test, package, and verify every Android project in this repository.
#
#   bash build-all.sh               # btaudio + the framework/AndroidX samples
#   bash build-all.sh --windows     # also run the Windows sender compile/integration checks
#   bash build-all.sh --quick       # skip JVM unit tests
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PROJECTS=(btaudio sample sample-androidx)
API=""
SOURCE=8
RUN_TESTS=1
WINDOWS="auto"            # auto | on | off

usage() {
  cat <<'EOF'
Usage: bash build-all.sh [options]

Builds all Android project directories (btaudio, sample, sample-androidx):
XML/resource lint, Java compilation, D8, unit tests, signed release APK,
structural artifact verification, and minimum-API audit.

Options:
  --api N        Android compile/target API (defaults to the project manifests)
  --source N     Java source level (default: 8)
  --quick        Skip unit tests
  --windows      Also compile/test the Windows sender (requires .NET, PowerShell, socat)
  --no-windows   Do not auto-run Windows checks
  -h, --help     Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api) API="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --quick|--no-tests) RUN_TESTS=0; shift ;;
    --windows) WINDOWS="on"; shift ;;
    --no-windows) WINDOWS="off"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

project_value() { python3 toolchain/project_info.py "$1" "$2"; }
if [ -z "$API" ]; then
  API="$(project_value btaudio target-api)"
fi

bold() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

bold "Toolchain setup (Android API $API)"
MIN_APIS=()
for project in "${PROJECTS[@]}"; do
  min_api="$(project_value "$project" min-api)"
  case " ${MIN_APIS[*]} " in
    *" $min_api "*) ;;
    *) MIN_APIS+=("$min_api") ;;
  esac
done

if [ ! -x toolchain/vendor/jre/bin/java ] || [ ! -s toolchain/vendor/ecj.jar ] \
   || [ ! -x toolchain/vendor/aapt2 ] || [ ! -s toolchain/vendor/android.jar ]; then
  bash toolchain/setup.sh --api "$API" --ref-api "${MIN_APIS[0]}"
fi
for min_api in "${MIN_APIS[@]}"; do
  if [ ! -s "toolchain/vendor/android-$min_api.jar" ]; then
    bash toolchain/setup.sh --api "$API" --ref-api "$min_api"
  fi
done

if [ ! -s toolchain/vendor/androidx/androidx.jar ]; then
  bold "Fetch/assemble AndroidX for sample-androidx"
  bash toolchain/androidx.sh
fi

for project in "${PROJECTS[@]}"; do
  min_api="$(project_value "$project" min-api)"
  version_code="$(project_value "$project" version-code)"
  version_name="$(project_value "$project" version-name)"
  apk="$project/build/$(basename "$project").apk"

  bold "$project: compile XML, Java, and dex"
  bash toolchain/check.sh "$project" --api "$API" --min-api "$min_api" --source "$SOURCE"

  if [ "$RUN_TESTS" = 1 ]; then
    if [ -d "$project/test" ] || [ -d "$project/src/test/java" ]; then
      bold "$project: JVM unit tests"
      bash toolchain/test.sh "$project" --source "$SOURCE"
    else
      echo "  no JVM test sources under $project"
    fi
  fi

  bold "$project: release APK"
  VERSION_CODE="$version_code" VERSION_NAME="$version_name" \
    bash toolchain/build.sh "$project" --api "$API" --min-api "$min_api" \
      --source "$SOURCE" --out "$apk" --release --verify

  bold "$project: artifact and API verification"
  python3 verify_apk.py "$apk" --project "$project" --min-api "$min_api"
  python3 check_api.py "$project/build/stage/classes" --min-api "$min_api" \
    --android-jar "toolchain/vendor/android-$min_api.jar" --apk "$apk"
done

if [ "$WINDOWS" = "auto" ]; then
  WINDOWS_CACHE="${BTAUDIO_WINDOWS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/btaudio/windows}"
  if [ -x "$WINDOWS_CACHE/dotnet" ] && command -v pwsh >/dev/null 2>&1 \
     && command -v socat >/dev/null 2>&1; then
    WINDOWS="on"
  else
    WINDOWS="off"
    echo
    echo "Windows sender checks skipped: the .NET SDK/reference assemblies, PowerShell,"
    echo "and socat are not all installed. Use --windows to request them explicitly."
  fi
fi

if [ "$WINDOWS" = "on" ]; then
  bold "Windows PowerShell sender (C# + protocol integration tests)"
  bash btaudio/windows/pscheck.sh
  bold "Windows GUI sender (WinForms compile + phone-decoder integration tests)"
  bash pscheck/guicheck.sh
fi

bold "All requested targets passed"
for project in "${PROJECTS[@]}"; do
  printf '  %-34s %s\n' "$project/build/$(basename "$project").apk" \
    "$(du -h "$project/build/$(basename "$project").apk" | cut -f1)"
done
