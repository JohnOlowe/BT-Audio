#!/usr/bin/env bash
# check.sh -- test-compile an Android project's Java and XML, without building an
# installable APK. Fast loop: XML lint -> aapt2 (resources+manifest) -> ECJ
# (Java) -> D8 (bytecode validity).
#
#   bash toolchain/check.sh PROJECT_DIR [--api 34] [--min-api 24] [--source 8]
#                                       [--no-dex] [--no-xml-lint] [--no-androidx]
#                                       [--full-dex]
#
# Exit code 0 means: every XML file parses, every resource reference resolves,
# the manifest survives aapt2 link, and every .java file type-checks against
# android.jar with Eclipse ECJ.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_env

TARGET_API=34
XML_LINT=1
NO_DEX=0
PROJ_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --api) TARGET_API="$2"; MIN_API="${MIN_API:-$TARGET_API}"; shift 2 ;;
    --min-api) MIN_API="$2"; shift 2 ;;
    --source) JAVA_SRC_LEVEL="$2"; shift 2 ;;
    --no-dex) NO_DEX=1; shift ;;
    --no-xml-lint) XML_LINT=0; shift ;;
    --no-androidx) ANDROIDX_OFF=1; shift ;;
    --full-dex) FULL_DEX=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) PROJ_ARG="$1"; shift ;;
  esac
done
[ -n "$PROJ_ARG" ] || die "usage: check.sh PROJECT_DIR [options]"
[ -n "$MIN_API" ] || MIN_API=24
androidx_setup
# Fast loop: dex only the project's own classes. --full-dex also dexes the
# AndroidX jar (build.sh always does; check.sh should stay quick).
[ "${FULL_DEX:-0}" = "1" ] || DEX_SKIP_ANDROIDX=1

detect_layout "$PROJ_ARG"
[ "$ANDROID_JAR" = "$GH_TOOLCHAIN/android.jar" ] && export ANDROID_JAR
BUILD="$PROJ/build/check"
rm -rf "$BUILD"; mkdir -p "$BUILD"
START=$(date +%s)
FAILED=0

msg "checking $PROJ   (${JAVA_SRC_LEVEL} source level, min API ${MIN_API})"
info "sources: $SRC_DIR ($(count_java) .java files)"
info "res:     $RES_DIR"
info "jre:     $("$JAVA_HOME/bin/java" -version 2>&1 | sed -n '1p')"
info "androidx: ${ANDROIDX_STATE:-none}"

# --- 1. XML ---------------------------------------------------------------
if [ "$XML_LINT" = "1" ]; then
  msg "1/4 XML lint (xmlcheck.py)"
  python3 "$HERE/xmlcheck.py" "$PROJ" "${ANDROIDX_XML_ARGS[@]+"${ANDROIDX_XML_ARGS[@]}"}" || FAILED=1
else
  info "1/4 XML lint skipped"
fi

# --- 2. resources + manifest ---------------------------------------------
msg "2/4 aapt2: compile resources + link manifest (this is the XML compiler)"
aapt2_compile_res "$BUILD/res.zip"
RES_ZIP="$BUILD/res.zip"
aapt2_link "$BUILD/base.apk" "$BUILD/gen" --min-sdk-version "${MIN_API}"
info "generated R.java: $(find "$BUILD/gen" -name 'R.java' | sed -n '1p')"

# --- 3. Java --------------------------------------------------------------
msg "3/4 ECJ: compile Java against android.jar (javac replacement)"
if ecj_compile "$BUILD/classes" "$BUILD/gen"; then
  ok "$(find "$BUILD/classes" -name '*.class' | wc -l | tr -d ' ') class files"
else
  FAILED=1
fi

# --- 4. dex ---------------------------------------------------------------
if [ "$NO_DEX" = "0" ] && [ "$FAILED" = "0" ]; then
  msg "4/4 D8: lower the class files to dex (proves the bytecode is valid Android bytecode)"
  CLASSES_DIR="$BUILD/classes"
  dex "$BUILD/dex"
  ok "classes.dex $(du -h "$BUILD/dex/classes.dex" | cut -f1)"
else
  info "4/4 D8 skipped"
fi

ELAPSED=$(( $(date +%s) - START ))
echo
if [ "$FAILED" = "0" ]; then
  printf '\033[1;32mCHECK PASSED\033[0m  (%ss)  artifacts in %s\n' "$ELAPSED" "$BUILD"
else
  printf '\033[1;31mCHECK FAILED\033[0m  (%ss)\n' "$ELAPSED"
fi
exit "$FAILED"
