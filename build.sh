#!/usr/bin/env bash
# build.sh -- one command, no arguments, from a fresh clone to a signed APK.
#
#   bash build.sh              setup -> unit tests -> release APK (R8, ~2.2 MB)
#   bash build.sh --debug      same but unshrunk (D8, ~5.4 MB) - the safe fallback
#   bash build.sh --publish    ... and push it to the history-less `apk` branch
#   bash build.sh --quick      skip the unit tests
#   bash build.sh --both       build BOTH configurations into separate files
#
# --release (default) -> app/build/app.apk            R8-shrunk, 2.2 MB, API 19+ (one dex)
# --debug             -> app/build/app-debug.apk      unshrunk + debuggable, API 21+ (six)
# --both              -> app/build/app.apk + app/build/app-debug.apk

# The release build is the one that runs on Android 4.4: it is a single classes.dex, and
# Dalvik cannot load a second one without the multidex library. verify_apk.py enforces
# that invariant, so a release that grows past 64K methods fails the build here rather
# than on the phone.
#
# app/build/app.apk is ALWAYS the release build - the debug one never overwrites it - so
# the two files cannot be confused by a later publish.
#
# --publish implies --both, because the `apk` branch carries both APKs: the shrunk one
# for a normal download and the unobfuscated one for when something about the shrunk
# build is suspect. Both are signed with the same key, so either installs over the
# other (publish-apk.sh refuses to publish a pair that would not).
#
# The APK is verified in both configurations (verify_apk.py): R8 can delete code the
# framework reaches by name, and the release APK is the only artifact a phone ever
# sees, so the artifact itself is checked rather than trusted.
#
# No Gradle and no Android SDK: see toolchain/README.md. AndroidX (appcompat,
# Material 3, RecyclerView, ConstraintLayout) is fetched from a committed Gradle
# cache by toolchain/androidx.sh and linked automatically - see RECIPE.md §9.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

API=34
# Android 4.4 (API 19) is the floor, and it is the interesting one: a 4.4 phone cannot
# capture its own screen (MediaProjection is API 21) and cannot be touched
# (dispatchGesture is API 24), but as the *guest* it needs nothing newer - so an old
# phone makes a first-class controller for a modern one. ApiLevels holds that policy.
MIN_API=19
# The debug configuration is dexed with a higher floor on purpose. R8 shrinks the
# release build into a single classes.dex, which Dalvik (API < 21) can load; the
# unshrunk debug build is ~6 dex files and Dalvik only ever loads the first one, so a
# debug APK claiming 19 would install and then die with NoClassDefFoundError. Native
# multidex starts at 21, so that is what it declares. (It is not a preference: D8
# refuses to emit the extra dex files below 21 without a main-dex list, because a
# min-api-19 build must fit in one dex. The release build is checked for exactly that.)
DEBUG_MIN_API=21
SOURCE=8            # 8 = compile against the real Android API surface (see RECIPE.md)
# versionCode 2 fixes the launch crash of versionCode 1 (missing Kotlin runtime):
# a new code lets the store/ adb update path be seen to work, and the same code is used
# for both configurations, which is what keeps them installable over each other.
# versionCode 7: first release with the guest's host-navigation buttons
# (GLOBAL_ACTION), a host-side frame-rate selector (default 20 for lower lag) and
# 1-second keyframes (glitch clock). History of why versions roll: vc2 launched
# nothing (R8 ate the unlisted SplashActivity), vc3 unlaunchable on 4.4 (aapt2
# stripped vector bases), vc4 crashed on Android 14 (second createVirtualDisplay on
# a one-shot consent), vc5 showed grey/green on 4.4 (csd without Annex-B start
# codes). Both configurations always share the code, so they stay installable over
# each other and over anything older.
# vc13: fix the vc12 guest crash (setButtonTintList reached the API-21 framework
# method through the static AppCompat receiver type - tintChoice now uses setSupportButtonTintList).
# vc14: the docked bar now occupies its reserved band (no root padding - FrameLayout
# gravity sits above padding, which is why the bar overlaid the picture with an
# empty strip below); the settings radios are driven explicitly (RadioGroup's
# exclusion dance lit the wrong option); live touch tries the STOCK inject code
# before the Lineage one (API 34 stock is 10 - the old table's 12 landed on
# verifyInputEvent and silently disabled streaming); two-finger pinch is on the
# wire (actions 4/5/6) for both injection paths.
VERSION_CODE=14
VERSION_NAME=0.2.13-androidx
MODE="release"      # release | debug | both
PUBLISH=0
RUN_TESTS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) MODE="debug"; shift ;;
    --release) MODE="release"; shift ;;
    --both) MODE="both"; shift ;;
    --publish) PUBLISH=1; shift ;;
    --quick|--no-tests) RUN_TESTS=0; shift ;;
    --api) API="$2"; shift 2 ;;
    --min-api) MIN_API="$2"; shift 2 ;;
    --version-name) VERSION_NAME="$2"; shift 2 ;;
    --version-code) VERSION_CODE="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Publishing hands out both APKs, so publishing builds both. (Unless the caller asked
# for --debug explicitly, which cannot be published alone - say so instead of guessing.)
if [ "$PUBLISH" = "1" ] && [ "$MODE" != "both" ]; then
  if [ "$MODE" = "debug" ]; then
    echo "--publish builds both configurations; ignoring --debug" >&2
  fi
  MODE="both"
fi

bold() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

bold "1/5 toolchain"
if [ -x toolchain/vendor/jre/bin/java ] && [ -s toolchain/vendor/ecj.jar ]; then
  echo "already installed in toolchain/vendor (delete it to force a re-download)"
else
  bash toolchain/setup.sh --api "$API"
fi

bold "2/5 AndroidX"
if [ -s toolchain/vendor/androidx/androidx.jar ]; then
  echo "already assembled in toolchain/vendor/androidx"
else
  # One-off: ~35 s, ~33 MB. Fetches appcompat/material/recyclerview/... AARs from a
  # Gradle cache committed to GitHub (Maven is unreachable here) and rewrites them
  # into a classpath jar + compiled resources + a per-library R-class list.
  bash toolchain/androidx.sh
fi

# A library may not ask for a newer platform than the APK promises. Gradle would catch
# this by merging every AAR manifest into the app's; there is no Gradle here, and the
# link step only sees the app manifest, so the audit is explicit.
python3 toolchain/aar_floor.py "$MIN_API"

if [ "$RUN_TESTS" = "1" ]; then
  bold "3/5 unit tests"
  bash toolchain/test.sh app --source "$SOURCE"
else
  bold "3/5 unit tests (skipped)"
fi

# One configuration, one file. The debug and release APKs are deliberately kept in
# separate files rather than overwriting each other, because --publish hands out both.
build_apk() {   # $1 = release|debug, $2 = output file, $3 = min api
  local cfg="$1" out="$2" minapi="$3" extra=()
  [ "$cfg" = "release" ] && extra+=(--release)
  echo "  -> $cfg: $out  (minSdk $minapi)"
  VERSION_CODE="$VERSION_CODE" VERSION_NAME="$VERSION_NAME" \
    bash toolchain/build.sh app --api "$API" --min-api "$minapi" --source "$SOURCE" \
         --out "$out" --verify "${extra[@]+"${extra[@]}"}"
}

APK="app/build/app.apk"
DEBUG_APK="app/build/app-debug.apk"
VERIFY=()

bold "4/5 APK"
case "$MODE" in
  debug)   build_apk debug   "$DEBUG_APK" "$DEBUG_MIN_API"; VERIFY=("$DEBUG_APK") ;;
  release) build_apk release "$APK"       "$MIN_API";       VERIFY=("$APK") ;;
  both)    build_apk release "$APK"       "$MIN_API"
           build_apk debug   "$DEBUG_APK" "$DEBUG_MIN_API"; VERIFY=("$APK" "$DEBUG_APK") ;;
esac

bold "5/5 verify the artifact"
for f in "${VERIFY[@]}"; do
  if ! python3 verify_apk.py "$f"; then
    echo "the APK above is missing things the app needs - not installing or publishing it" >&2
    exit 1
  fi
done

# The other half of "does it work": minSdkVersion is a promise that the Java compiler
# cannot check, because it compiles against API $API. check_api.py reads the compiled
# classes and asks a real API $MIN_API jar whether every framework call exists there.
REF_JAR="toolchain/vendor/android-$MIN_API.jar"
if [ -s "$REF_JAR" ]; then
  API_ARGS=(--min-api "$MIN_API" --android-jar "$REF_JAR")
  [ -s "$APK" ] && API_ARGS+=(--apk "$APK")
  python3 check_api.py app/build/stage/classes "${API_ARGS[@]}"
else
  echo "  note: no $REF_JAR - skipping the API level check"
  echo "        (toolchain/setup.sh fetches it; see check_api.py)"
fi

bold "done"
for f in "${VERIFY[@]}"; do
  printf '  %-28s %s\n' "$f" "$(du -h "$f" | cut -f1)"
done
echo
echo "  install:  adb install -r ${VERIFY[0]}"
echo "  (release: Android 4.4+ / one dex   -   debug: Android 5.0+ / six dex files)"
echo "  api floor: $MIN_API (release) / $DEBUG_MIN_API (debug) - see check_api.py + api-levels.txt"
echo "  ship it:  bash publish-apk.sh   (replaces the single artifact on the 'apk' branch)"

if [ "$PUBLISH" = "1" ]; then
  bold "publishing"
  bash publish-apk.sh --apk "$APK" --debug-apk "$DEBUG_APK"
fi
