#!/usr/bin/env bash
# setup.sh -- build an Android Java + XML toolchain out of nothing but PyPI,
# npm and GitHub, with no root, no apt, no SDK manager and no Maven.
#
#   bash toolchain/setup.sh [--api 34] [--vendor DIR]
#
# Everything lands in toolchain/vendor/ (gitignored). Re-runnable; already
# downloaded artefacts are kept. Each tool is executed at the end of its step,
# so a silent failure is impossible.
set -euo pipefail

API=34
# The minimum API level the app claims to support. Its android.jar is fetched as a
# *reference* for check_api.py (see step 6b): compiling needs API 34, but proving that
# nothing uses a post-19 API needs API 19's own jar.
REF_API=19
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$HERE/vendor"
while [ $# -gt 0 ]; do
  case "$1" in
    --api) API="$2"; shift 2 ;;
    --ref-api) REF_API="$2"; shift 2 ;;
    --vendor) VENDOR="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$VENDOR" "$VENDOR/tmp"
TMP="$VENDOR/tmp"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

get() { # get URL DEST
  [ -s "$2" ] && return 0
  curl -fsSL --retry 3 --max-time 600 -o "$2.part" "$1" || die "download failed: $1"
  mv "$2.part" "$2"
}

npm_url() { # npm_url <pkg> [version] -> tarball URL (latest by default)
  local pkg="$1" ver="${2:-}" meta
  meta=$(curl -fsSL --max-time 60 "https://registry.npmjs.org/$(python3 -c \
      'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$pkg")") \
    || die "npm registry unreachable for $pkg"
  printf '%s' "$meta" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ver = sys.argv[1] if len(sys.argv) > 1 else ""
ver = ver or d["dist-tags"]["latest"]
print(d["versions"][ver]["dist"]["tarball"])' "$ver"
}

# ---------------------------------------------------------------------------
say "1/7 Java runtime  (PyPI: jdk4py)"
if [ ! -x "$VENDOR/jre/bin/java" ]; then
  rm -rf "$VENDOR/tmp/jdk4py"
  python3 -m pip download --no-deps --only-binary :all: -q -d "$TMP" jdk4py \
    || die "pip could not reach PyPI for jdk4py"
  WHEEL=$(ls "$TMP"/jdk4py-*.whl | tail -1)
  python3 -m zipfile -e "$WHEEL" "$VENDOR/tmp/jdk4py"
  rm -rf "$VENDOR/jre"
  mv "$VENDOR/tmp/jdk4py/jdk4py/java-runtime" "$VENDOR/jre"
  chmod +x "$VENDOR/jre/bin/"*
fi
"$VENDOR/jre/bin/java" -version 2>&1 | sed -n "1p" | grep -q . || die "jre/bin/java does not run"
ok "$("$VENDOR/jre/bin/java" -version 2>&1 | sed -n '1p')  [JRE only - no javac, by design]"

# ---------------------------------------------------------------------------
say "2/7 javac replacement (npm: @vscjava/java-language-server -> Eclipse ECJ)"
# The VS Code Java language server is a legitimate bundle of JDT, and JDT ships
# the Eclipse batch compiler: pure Java, so it runs on any modern JRE.
if [ ! -s "$VENDOR/ecj.jar" ] || [ ! -s "$VENDOR/junit.jar" ]; then
  url=$(npm_url "@vscjava/java-language-server")
  get "$url" "$TMP/jls.tgz"
  tar xzf "$TMP/jls.tgz" -C "$TMP" \
    --wildcards 'package/server/plugins/org.eclipse.jdt.core.compiler.batch_*.jar' \
    || die "no ECJ inside the language-server tarball"
  cp "$TMP"/package/server/plugins/org.eclipse.jdt.core.compiler.batch_*.jar "$VENDOR/ecj.jar"
  # The same bundle carries JUnit 4 + Hamcrest, so unit tests can actually RUN
  # on the JVM (not just compile): see toolchain/test.sh.
  tar xzf "$TMP/jls.tgz" -C "$TMP" \
    --wildcards 'package/server/plugins/org.junit_*.jar' \
                'package/server/plugins/org.hamcrest_*.jar' 2>/dev/null || true
  if ls "$TMP"/package/server/plugins/org.junit_*.jar >/dev/null 2>&1; then
    cp "$TMP"/package/server/plugins/org.junit_*.jar    "$VENDOR/junit.jar"
    cp "$TMP"/package/server/plugins/org.hamcrest_*.jar "$VENDOR/hamcrest.jar"
  else
    warn "no JUnit jar in the bundle -- test.sh will not be available"
  fi
fi
"$VENDOR/jre/bin/java" -jar "$VENDOR/ecj.jar" -help 2>&1 | sed -n "1p" | grep -q "Eclipse Compiler" \
  || die "ecj.jar is not runnable"
ok "$("$VENDOR/jre/bin/java" -jar "$VENDOR/ecj.jar" -help 2>&1 | sed -n '1p')"

# ---------------------------------------------------------------------------
say "3/7 dexer + signer + platform jar  (npm: @drxiaozhi/minapk)"
# A single npm package that vendors the Android tools as plain jars:
#   tools/d8.jar        R8/D8 dexer (JVM bytecode -> classes.dex)
#   tools/apksigner.jar APK signer (v1/v2/v3)
#   tools/android.jar   API 34 platform (the "bootclasspath" for Android Java)
#   tools/debug.keystore
if [ ! -s "$VENDOR/d8.jar" ]; then
  url=$(npm_url "@drxiaozhi/minapk")
  get "$url" "$TMP/minapk.tgz"
  tar xzf "$TMP/minapk.tgz" -C "$TMP"
  cp "$TMP/package/tools/d8.jar"        "$VENDOR/d8.jar"
  cp "$TMP/package/tools/apksigner.jar" "$VENDOR/apksigner.jar"
  cp "$TMP/package/tools/debug.keystore" "$VENDOR/debug.keystore"
  [ -s "$VENDOR/ecj.jar" ] || cp "$TMP/package/tools/ecj-3.45.0.jar" "$VENDOR/ecj.jar"
  [ -s "$VENDOR/android.jar" ] || cp "$TMP/package/tools/android.jar" "$VENDOR/android.jar"
fi
"$VENDOR/jre/bin/java" -cp "$VENDOR/d8.jar" com.android.tools.r8.D8 --version 2>&1 | grep -q "^D8" \
  || die "d8.jar is not runnable"
ok "$("$VENDOR/jre/bin/java" -cp "$VENDOR/d8.jar" com.android.tools.r8.D8 --version 2>&1 | sed -n '1p')"
"$VENDOR/jre/bin/java" -cp "$VENDOR/d8.jar" com.android.tools.r8.R8 --version 2>&1 | grep -q "^R8" \
  || die "R8 is not runnable"
ok "$("$VENDOR/jre/bin/java" -cp "$VENDOR/d8.jar" com.android.tools.r8.R8 --version 2>&1 | sed -n '1p')"
ok "apksigner.jar $(du -h "$VENDOR/apksigner.jar" | cut -f1), android.jar (API 34) $(du -h "$VENDOR/android.jar" | cut -f1)"

# ---------------------------------------------------------------------------
say "4/7 aapt2, the resource/XML compiler  (PyPI: aapt2)"
# The wheel is just three prebuilt aapt2 binaries; the Linux one runs here.
if [ ! -x "$VENDOR/aapt2" ]; then
  python3 -m pip download --no-deps --only-binary :all: -q -d "$TMP" aapt2 || true
  WHL=$(ls "$TMP"/aapt2-*.whl 2>/dev/null | tail -1 || true)
  if [ -n "${WHL:-}" ]; then
    python3 -m zipfile -e "$WHL" "$VENDOR/tmp/aapt2pkg"
    cp "$VENDOR/tmp/aapt2pkg/aapt2/bin/Linux/aapt2" "$VENDOR/aapt2"
    chmod +x "$VENDOR/aapt2"
  fi
fi
if ! "$VENDOR/aapt2" version >/dev/null 2>&1; then
  warn "PyPI aapt2 did not run; falling back to npm aaptjs3"
  url=$(npm_url "aaptjs3")
  get "$url" "$TMP/aaptjs3.tgz"
  tar xzf "$TMP/aaptjs3.tgz" -C "$TMP" package/bin/x64/linux/aapt2
  cp "$TMP/package/bin/x64/linux/aapt2" "$VENDOR/aapt2"
  chmod +x "$VENDOR/aapt2"
fi
"$VENDOR/aapt2" version >/dev/null 2>&1 || die "no working aapt2"
ok "$("$VENDOR/aapt2" version 2>&1 | tail -1)"

# ---------------------------------------------------------------------------
say "5/7 apktool  (npm: apktool-jar)  -- offline APK disassembly, optional but used by --verify"
if [ ! -s "$VENDOR/apktool.jar" ]; then
  url=$(npm_url "apktool-jar")
  get "$url" "$TMP/apktool.tgz"
  tar xzf "$TMP/apktool.tgz" -C "$TMP" package/bin/apktool_2.4.1.jar
  cp "$TMP/package/bin/apktool_2.4.1.jar" "$VENDOR/apktool.jar"
fi
ok "$("$VENDOR/jre/bin/java" -jar "$VENDOR/apktool.jar" --version 2>/dev/null | tail -1 || echo 'apktool present')"

# ---------------------------------------------------------------------------
say "6/7 platform android.jar for API $API  (GitHub: Sable/android-platforms)"
# minapk already gave us API 34. Any other level comes from a git partial clone:
# GitHub is reachable, and a blob-filtered clone pulls only the blob we ask for.
if [ "$API" != "34" ] || [ ! -s "$VENDOR/android.jar" ]; then
  CLONE="$TMP/android-platforms"
  if [ ! -d "$CLONE/.git" ]; then
    git clone --depth 1 --filter=blob:none --no-checkout \
      https://github.com/Sable/android-platforms.git "$CLONE" >/dev/null 2>&1 \
      || die "could not clone Sable/android-platforms"
  fi
  ( cd "$CLONE" && git checkout HEAD -- "android-$API/android.jar" ) \
    || die "no android.jar for API $API in Sable/android-platforms"
  cp "$CLONE/android-$API/android.jar" "$VENDOR/android.jar"
fi
python3 - "$VENDOR/android.jar" <<'PY' || die "android.jar looks wrong"
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = set(z.namelist())
missing = [n for n in ("android/app/Activity.class", "android/os/Bundle.class") if n not in names]
print("    android.jar: %d classes%s" % (len(names), "" if not missing else " MISSING " + str(missing)))
sys.exit(1 if missing else 0)
PY
ok "android.jar API $API ready"

# ---------------------------------------------------------------------------
say "6b/7 reference android.jar for API $REF_API  (for check_api.py)"

# Compiling against API 34 says nothing about what exists on API 19: the compiler has no
# idea what the minSdkVersion promise is, so `MediaCodec.getInputBuffer()` (API 21)
# compiles happily into a min-api-19 dex and throws NoSuchMethodError on the device.
# check_api.py closes that hole by checking every framework reference against a real
# android.jar *of the minimum level*. This fetches that jar - not for compiling, purely
# as a reference - from the same partial clone as above.
if [ ! -s "$VENDOR/android-$REF_API.jar" ]; then
  CLONE="$TMP/android-platforms"
  if [ ! -d "$CLONE/.git" ]; then
    git clone --depth 1 --filter=blob:none --no-checkout \
      https://github.com/Sable/android-platforms.git "$CLONE" >/dev/null 2>&1 \
      || die "could not clone Sable/android-platforms"
  fi
  ( cd "$CLONE" && git checkout HEAD -- "android-$REF_API/android.jar" ) \
    || die "no android-$REF_API/android.jar in Sable/android-platforms"
  cp "$CLONE/android-$REF_API/android.jar" "$VENDOR/android-$REF_API.jar"
fi
ok "android-$REF_API.jar ready ($(du -h "$VENDOR/android-$REF_API.jar" | cut -f1))"

# ---------------------------------------------------------------------------
say "6c/7 Kotlin runtime  (npm: kotlin-compiler, for the AndroidX libraries)"

# This one is not a nicety. Several of the AndroidX libraries we vendor are compiled
# from Kotlin by Google - fragment, activity, window, lifecycle-viewmodel - so their
# classes call kotlin.jvm.internal.Intrinsics from ordinary code paths, including
# AppCompatActivity's constructor. Gradle pulls kotlin-stdlib in automatically as a
# transitive dependency; this toolchain has no Gradle, so the runtime has to be taken
# from somewhere explicitly. Without it every launch dies with
# ClassNotFoundException: kotlin.jvm.internal.Intrinsics - and, worse, the *build*
# still succeeds, because R8 only warns about a missing class.
#
# There is no stdlib-only artifact on PyPI or npm, so it comes out of the official
# Kotlin distribution published to npm as `kotlin-compiler`: the distribution ships
# lib/kotlin-stdlib.jar next to the compiler, and we extract exactly that one file
# (1.7 MB out of an 87 MB tarball, which is deleted straight after). The version is
# pinned to the 1.9 line on purpose: it is the generation the vendored AndroidX
# (appcompat 1.6.1, material 1.10.0, activity 1.8.0) was built against, and the 2.x
# stdlib raises its own Android floor.
KOTLIN_VERSION="${KOTLIN_VERSION:-1.9.25}"
if [ ! -s "$VENDOR/kotlin-stdlib.jar" ] || [ ! -s "$VENDOR/kotlin-annotations.jar" ]; then
  url=$(npm_url "kotlin-compiler" "$KOTLIN_VERSION")
  get "$url" "$TMP/kotlin-compiler.tgz"
  tar xzf "$TMP/kotlin-compiler.tgz" -C "$TMP" \
      package/lib/kotlin-stdlib.jar package/lib/annotations-13.0.jar \
    || die "the kotlin-compiler tarball has no lib/kotlin-stdlib.jar"
  cp "$TMP/package/lib/kotlin-stdlib.jar" "$VENDOR/kotlin-stdlib.jar"
  # The stdlib references org.jetbrains.annotations (@NotNull/@Nullable) in its own
  # signatures. Those annotations have CLASS retention: tools read them, a device never
  # loads them, so this jar is a *library* input for the dexers and does not ship.
  # Vendoring it beats another -dontwarn, which is exactly what hid the missing runtime
  # class in the published build.
  cp "$TMP/package/lib/annotations-13.0.jar" "$VENDOR/kotlin-annotations.jar"
  rm -rf "$TMP/package" "$TMP/kotlin-compiler.tgz"
fi
python3 - "$VENDOR/kotlin-stdlib.jar" "$VENDOR/kotlin-annotations.jar" <<'CHK' || die "the Kotlin jars look wrong"
import sys, zipfile
stdlib, annotations = sys.argv[1], sys.argv[2]
names = {path: set(zipfile.ZipFile(path).namelist()) for path in (stdlib, annotations)}
want = {
    "kotlin/jvm/internal/Intrinsics.class": stdlib,
    "kotlin/Unit.class": stdlib,
    "org/jetbrains/annotations/NotNull.class": annotations,
}
bad = [n for n, p in want.items() if n not in names[p]]
for path in (stdlib, annotations):
    print("    %-22s %d classes" % (path.rsplit("/", 1)[-1] + ":", len(names[path])))
if bad:
    print("    MISSING: %s" % bad)
sys.exit(1 if bad else 0)
CHK
ok "kotlin-stdlib.jar $KOTLIN_VERSION + annotations ready ($(du -h "$VENDOR/kotlin-stdlib.jar" | cut -f1))"

# ---------------------------------------------------------------------------
say "7/9 language-level classpath (android.jar minus the packages the JRE owns)"
# ECJ cannot be handed an alternate *bootclasspath* above source level 8: the
# module system refuses it ("package java.util is accessible from more than one
# module"). So for -source 11/17 we compile against this filtered android.jar and
# java.* comes from the running JRE. That keeps language checking strict but
# loosens API checking (Java APIs Android lacks will still resolve). The default
# source level stays 8, which uses the real android.jar as bootclasspath and is
# API-accurate.
python3 "$HERE/filter_android_jar.py" "$VENDOR/android.jar" "$VENDOR/android-classpath.jar"

# ---------------------------------------------------------------------------
say "8/9 lambda stubs (the one class android.jar is missing)"
# -source 8 plus a lambda makes ECJ look for java.lang.invoke.LambdaMetafactory,
# which android.jar does not contain (AGP ships it as core-lambda-stubs.jar in
# build-tools). Compile our signature-only stub with ECJ itself; it is never run.
rm -rf "$TMP/lambda-stubs"; mkdir -p "$TMP/lambda-stubs"
"$VENDOR/jre/bin/java" -jar "$VENDOR/ecj.jar" -source 8 -target 8 -proc:none -nowarn \
  -bootclasspath "$VENDOR/android.jar" -d "$TMP/lambda-stubs" \
  "$HERE/lambda-stubs/java/lang/invoke/LambdaMetafactory.java" >/dev/null \
  || die "could not compile the lambda stub"
rm -f "$VENDOR/core-lambda-stubs.jar"
python3 - "$TMP/lambda-stubs" "$VENDOR/core-lambda-stubs.jar" <<'STUBS'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as z:
    for base, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(base, name)
            z.write(full, os.path.relpath(full, root))
STUBS
python3 - "$VENDOR/core-lambda-stubs.jar" <<'CHECK' || die "lambda stub jar is wrong"
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
want = "java/lang/invoke/LambdaMetafactory.class"
print("    core-lambda-stubs.jar: %s" % ", ".join(names))
sys.exit(0 if want in names else 1)
CHECK
ok "lambda stubs ready ($(du -h "$VENDOR/core-lambda-stubs.jar" | cut -f1))"

say "9/9 environment file"
# With a non-default --vendor the env file goes beside that vendor dir, so a
# throwaway "--vendor /tmp/v35" run does not repoint the real toolchain.
ENV_OUT="$HERE/env.sh"
[ "$VENDOR" = "$HERE/vendor" ] || ENV_OUT="$(cd "$VENDOR/.." && pwd)/env.sh"
cat > "$ENV_OUT" <<EOF
# generated by setup.sh -- source me:  . toolchain/env.sh
export GH_TOOLCHAIN="$VENDOR"
export JAVA_HOME="\$GH_TOOLCHAIN/jre"
export PATH="\$JAVA_HOME/bin:\$GH_TOOLCHAIN:\$PATH"
export ECJ_JAR="\$GH_TOOLCHAIN/ecj.jar"
export D8_JAR="\$GH_TOOLCHAIN/d8.jar"
export APKSIGNER_JAR="\$GH_TOOLCHAIN/apksigner.jar"
export APKTOOL_JAR="\$GH_TOOLCHAIN/apktool.jar"
export ANDROID_JAR="\$GH_TOOLCHAIN/android.jar"
export ANDROID_CLASSPATH_JAR="\$GH_TOOLCHAIN/android-classpath.jar"
export AAPT2="\$GH_TOOLCHAIN/aapt2"
export DEBUG_KEYSTORE="\$GH_TOOLCHAIN/debug.keystore"
export JUNIT_JAR="\$GH_TOOLCHAIN/junit.jar"
export HAMCREST_JAR="\$GH_TOOLCHAIN/hamcrest.jar"
export LAMBDA_STUBS_JAR="\$GH_TOOLCHAIN/core-lambda-stubs.jar"
EOF
ok "wrote $ENV_OUT"

if [ "${KEEP_TMP:-0}" != "1" ]; then
  rm -rf "$TMP"
  ok "cleaned download cache ($VENDOR/tmp); KEEP_TMP=1 re-run keeps it"
fi

printf '\n\033[1;32mToolchain ready.\033[0m  %s\n\n' "$VENDOR"
du -sh "$VENDOR"/* 2>/dev/null | sed 's/^/    /'
printf '\nNext:  . toolchain/env.sh && bash toolchain/check.sh sample   # test-compile\n'
printf '       . toolchain/env.sh && bash toolchain/build.sh sample   # signed APK\n\n'
