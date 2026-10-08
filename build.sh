#!/usr/bin/env bash
# Build the BT Audio Android receiver from a clean checkout.
#
#   bash build.sh              setup -> unit tests -> verified release APK
#   bash build.sh --debug      unshrunk/debuggable APK
#   bash build.sh --both       release + debug APKs
#   bash build.sh --quick      skip unit tests
#
# The Android project is btaudio/ (flat layout), not the stale app/ path used by
# the original wrapper. The toolchain also accepts standard src/main layouts.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PROJECT="btaudio"
MODE="release"
API=""
MIN_API=""
SOURCE=8
PUBLISH=0
RUN_TESTS=1
VERSION_CODE=""
VERSION_NAME=""

usage() {
  sed -n '1,12p' "$0"
  cat <<'EOF'

Options:
  --release / --debug / --both  Select APK configuration (default: release)
  --api N                      Compile/target against Android API N
  --min-api N                  Override the manifest's minSdkVersion
  --source N                   Java source level (default: 8)
  --version-code N             Override the manifest versionCode
  --version-name NAME          Override the manifest versionName
  --quick                      Skip unit tests
  --publish                    Build both APKs and publish to the apk branch
  -h, --help                   Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) MODE="debug"; shift ;;
    --release) MODE="release"; shift ;;
    --both) MODE="both"; shift ;;
    --publish) PUBLISH=1; shift ;;
    --quick|--no-tests) RUN_TESTS=0; shift ;;
    --api) API="$2"; shift 2 ;;
    --min-api) MIN_API="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --version-code) VERSION_CODE="$2"; shift 2 ;;
    --version-name) VERSION_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

project_value() { python3 toolchain/project_info.py "$PROJECT" "$1"; }
MIN_API="${MIN_API:-$(project_value min-api)}"
API="${API:-$(project_value target-api)}"
VERSION_CODE="${VERSION_CODE:-$(project_value version-code)}"
VERSION_NAME="${VERSION_NAME:-$(project_value version-name)}"

if [ "$PUBLISH" = 1 ]; then MODE="both"; fi

bold() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

bold "Android toolchain"
if [ ! -x toolchain/vendor/jre/bin/java ] || [ ! -s toolchain/vendor/ecj.jar ] \
   || [ ! -x toolchain/vendor/aapt2 ] || [ ! -s "toolchain/vendor/android.jar" ] \
   || [ ! -s "toolchain/vendor/android-$MIN_API.jar" ]; then
  bash toolchain/setup.sh --api "$API" --ref-api "$MIN_API"
else
  echo "already installed in toolchain/vendor"
fi

bold "BT Audio unit tests"
if [ "$RUN_TESTS" = 1 ]; then
  bash toolchain/test.sh "$PROJECT" --source "$SOURCE"
else
  echo "skipped (--quick)"
fi

APK="$PROJECT/build/btaudio.apk"
DEBUG_APK="$PROJECT/build/btaudio-debug.apk"
VERIFY=()

build_apk() { # config output path
  local config="$1" output="$2"
  local release=()
  [ "$config" = release ] && release=(--release)
  printf '\n  -> %s: %s (minSdk %s)\n' "$config" "$output" "$MIN_API"
  VERSION_CODE="$VERSION_CODE" VERSION_NAME="$VERSION_NAME" \
    bash toolchain/build.sh "$PROJECT" --api "$API" --min-api "$MIN_API" \
      --source "$SOURCE" --out "$output" --verify "${release[@]}"

  python3 verify_apk.py "$output" --project "$PROJECT" --min-api "$MIN_API"
  python3 check_api.py "$PROJECT/build/stage/classes" --min-api "$MIN_API" \
    --android-jar "toolchain/vendor/android-$MIN_API.jar" --apk "$output"
}

bold "Build APK"
case "$MODE" in
  release)
    build_apk release "$APK"
    VERIFY=("$APK")
    ;;
  debug)
    build_apk debug "$DEBUG_APK"
    VERIFY=("$DEBUG_APK")
    ;;
  both)
    build_apk release "$APK"
    build_apk debug "$DEBUG_APK"
    VERIFY=("$APK" "$DEBUG_APK")
    ;;
esac

bold "Done"
for artifact in "${VERIFY[@]}"; do
  printf '  %-34s %s\n' "$artifact" "$(du -h "$artifact" | cut -f1)"
done
printf '\n  install: adb install -r %s\n' "${VERIFY[0]}"
echo "  Android minSdk: $MIN_API; API-level audit is checked against android-$MIN_API.jar"
echo "  Compile every Android project: bash build-all.sh"

if [ "$PUBLISH" = 1 ]; then
  bold "Publish"
  bash publish-apk.sh --apk "$APK" --debug-apk "$DEBUG_APK"
fi
