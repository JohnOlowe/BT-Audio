#!/usr/bin/env bash
# test.sh -- compile and RUN JVM unit tests (JUnit 4) for the pure-Java part of
# an Android project. No Gradle, no device, no emulator.
#
#   bash toolchain/test.sh PROJECT_DIR [--source 8] [--filter SomeTest] [--no-androidx]
#
# Test sources are picked up from test/ (flat layout) or src/test/java (Gradle
# layout). Anything that actually calls android.* at runtime cannot work here:
# the platform classes in android.jar are stubs that throw "Stub!" -- keep the
# logic you test free of framework calls, which is where unit tests belong
# anyway.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_env

PROJ_ARG=""
FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) JAVA_SRC_LEVEL="$2"; shift 2 ;;
    --filter) FILTER="$2"; shift 2 ;;
    --no-androidx) ANDROIDX_OFF=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) PROJ_ARG="$1"; shift ;;
  esac
done
[ -n "$PROJ_ARG" ] || die "usage: test.sh PROJECT_DIR [--filter ClassName]"
androidx_setup
[ -s "$JUNIT_JAR" ] || die "no junit.jar -- re-run: bash toolchain/setup.sh"

detect_layout "$PROJ_ARG"
if [ -d "$PROJ/src/test/java" ]; then TEST_DIR="$PROJ/src/test/java"
elif [ -d "$PROJ/test" ]; then TEST_DIR="$PROJ/test"
else die "no test sources (looked for $PROJ/src/test/java and $PROJ/test)"; fi

OUT="$PROJ/build/test"
rm -rf "$OUT"; mkdir -p "$OUT/classes"

msg "unit tests for $PROJ"
info "test sources: $TEST_DIR"

msg "1/4 generate R.java (aapt2 compile + link, so sources referencing R compile)"
aapt2_compile_res "$OUT/res.zip"
RES_ZIP="$OUT/res.zip"
aapt2_link "$OUT/base.apk" "$OUT/gen"

msg "2/4 compile main + test sources (ECJ, source level $JAVA_SRC_LEVEL)"
MAIN_FILES=$(find "$SRC_DIR" -name '*.java')
TEST_FILES=$(find "$TEST_DIR" -name '*.java')
# android.jar is on the classpath, not the bootclasspath: tests may *reference*
# framework types, they just cannot execute them.
BOOT=()
if [ "$JAVA_SRC_LEVEL" -le 8 ]; then
  BOOT=(-bootclasspath "$ANDROID_JAR${LAMBDA_STUBS_JAR:+:$LAMBDA_STUBS_JAR}")
fi
"$JAVA" -jar "$ECJ_JAR" -source "$JAVA_SRC_LEVEL" -target "$JAVA_SRC_LEVEL" \
  -encoding UTF-8 -proc:none "${BOOT[@]+"${BOOT[@]}"}" \
  -classpath "$ANDROID_JAR:$JUNIT_JAR:$HAMCREST_JAR${ANDROIDX_CLASSES:+:$ANDROIDX_CLASSES}" \
  -d "$OUT/classes" $MAIN_FILES $TEST_FILES $(find "$OUT/gen" -name '*.java') \
  || die "test compilation failed"
ok "$(find "$OUT/classes" -name '*.class' | wc -l | tr -d ' ') class files"

msg "3/4 discover tests"
CLASSES=$(cd "$OUT/classes" && find . -name '*Test.class' -o -name '*Tests.class' -o -name 'Test*.class' \
          | sed 's|^\./||; s|\.class$||; s|/|.|g' | sort)
[ -n "$FILTER" ] && CLASSES=$(printf '%s\n' "$CLASSES" | grep -i "$FILTER" || true)
if [ -z "$CLASSES" ]; then
  die "no test classes found (name them *Test/*Tests or pass --filter)"
fi
printf '    %s\n' $CLASSES

msg "4/4 run (JUnit 4 on the bundled JRE)"
# shellcheck disable=SC2086
"$JAVA" -cp "$OUT/classes:$JUNIT_JAR:$HAMCREST_JAR:$ANDROID_JAR${ANDROIDX_CLASSES:+:$ANDROIDX_CLASSES}" \
  org.junit.runner.JUnitCore $CLASSES
