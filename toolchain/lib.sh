#!/usr/bin/env bash
# lib.sh -- shared helpers for check.sh / build.sh. Sourced, not executed.

set -euo pipefail

TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ=""
SRC_DIR=""
RES_DIR=""
MANIFEST=""
JAVA_SRC_LEVEL=8
MIN_API=""

# Signing. Defaults are the vendor debug key; resolve_signing() below prefers a
# keystore committed in the project, and every SIGN_* value is overridable.
SIGN_KEYSTORE="${SIGN_KEYSTORE:-}"
SIGN_ALIAS="${SIGN_ALIAS:-androiddebugkey}"
SIGN_STORE_PASS="${SIGN_STORE_PASS:-android}"
SIGN_KEY_PASS="${SIGN_KEY_PASS:-android}"

msg()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m %s\n' "$*"; }
die()  { printf '\033[31m    error:\033[0m %s\n' "$*" >&2; exit 1; }

load_env() {
  if [ -f "$TC_DIR/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$TC_DIR/env.sh"
  else
    export GH_TOOLCHAIN="$TC_DIR/vendor"
    export JAVA_HOME="$GH_TOOLCHAIN/jre"
    export ECJ_JAR="$GH_TOOLCHAIN/ecj.jar"
    export D8_JAR="$GH_TOOLCHAIN/d8.jar"
    export APKSIGNER_JAR="$GH_TOOLCHAIN/apksigner.jar"
    export APKTOOL_JAR="$GH_TOOLCHAIN/apktool.jar"
    export ANDROID_JAR="$GH_TOOLCHAIN/android.jar"
    export ANDROID_CLASSPATH_JAR="$GH_TOOLCHAIN/android-classpath.jar"
    export AAPT2="$GH_TOOLCHAIN/aapt2"
    export DEBUG_KEYSTORE="$GH_TOOLCHAIN/debug.keystore"
    export JUNIT_JAR="$GH_TOOLCHAIN/junit.jar"
    export HAMCREST_JAR="$GH_TOOLCHAIN/hamcrest.jar"
    export LAMBDA_STUBS_JAR="$GH_TOOLCHAIN/core-lambda-stubs.jar"
  fi
  [ -x "$JAVA_HOME/bin/java" ] || die "no JRE at $JAVA_HOME -- run: bash toolchain/setup.sh"
  [ -s "$ECJ_JAR" ]           || die "no ECJ at $ECJ_JAR -- run: bash toolchain/setup.sh"
  [ -x "$AAPT2" ]             || die "no aapt2 at $AAPT2 -- run: bash toolchain/setup.sh"
  JAVA=("$JAVA_HOME/bin/java")
  androidx_setup
}

# resolve_signing PROJECT_ROOT -- prefer the repo's own keystore over the vendor
# debug key, so every build of this project carries one stable signature and a new
# APK installs cleanly over the previous one. Explicit SIGN_* env vars still win.
#
# Credentials are read from the project's gradle.properties when present: the app
# was originally set up for Gradle, and keeping one source of truth for the key
# means the two build systems can never disagree about which key signed what.
resolve_signing() {
  local proj="$1" root props ks
  root="$(dirname "$proj")"
  for props in "$proj/gradle.properties" "$root/gradle.properties"; do
    [ -s "$props" ] || continue
    local file alias_ store key
    file=$(sed -n 's/^GHOSTHAND_STORE_FILE=//p'      "$props" | sed -n '1p')
    store=$(sed -n 's/^GHOSTHAND_STORE_PASSWORD=//p' "$props" | sed -n '1p')
    alias_=$(sed -n 's/^GHOSTHAND_KEY_ALIAS=//p'     "$props" | sed -n '1p')
    key=$(sed -n 's/^GHOSTHAND_KEY_PASSWORD=//p'     "$props" | sed -n '1p')
    [ -n "$store" ] && SIGN_STORE_PASS="$store"
    [ -n "$alias_" ] && SIGN_ALIAS="$alias_"
    [ -n "$key" ] && SIGN_KEY_PASS="$key"
    [ -n "$file" ] && [ -s "$root/$file" ] && SIGN_KEYSTORE="$root/$file"
    break
  done

  for ks in "$SIGN_KEYSTORE" "$proj/keystore/damjay_debug.keystore" \
            "$root/keystore/damjay_debug.keystore"; do
    if [ -n "$ks" ] && [ -s "$ks" ]; then SIGN_KEYSTORE="$ks"; break; fi
  done
  [ -n "$SIGN_KEYSTORE" ] || SIGN_KEYSTORE="$DEBUG_KEYSTORE"

  # PKCS12 stores have no separate key password (keytool prints "Different store and
  # key passwords not supported for PKCS12" and ignores the difference), so a shorter
  # key password than the store password is a typo, not a second credential.
  [ -n "${SIGN_KEY_PASS:-}" ] || SIGN_KEY_PASS="$SIGN_STORE_PASS"
  if [ "${#SIGN_KEY_PASS}" -lt "${#SIGN_STORE_PASS}" ]; then
    SIGN_KEY_PASS="$SIGN_STORE_PASS"
  fi
}

# sign_apk ALIGNED_APK OUT_APK -- apksigner with whichever key resolve_signing picked.
sign_apk() {
  local aligned="$1" out="$2" v1=false
  # v1 (JAR) signatures only matter below API 24, and apksigner writes META-INF/*
  # after alignment, so enabling them would undo zipalign.
  [ "${MIN_API:-24}" -lt 24 ] && v1=true
  "$JAVA" -jar "$APKSIGNER_JAR" sign \
    --ks "$SIGN_KEYSTORE" --ks-key-alias "$SIGN_ALIAS" \
    --ks-pass "pass:$SIGN_STORE_PASS" --key-pass "pass:$SIGN_KEY_PASS" \
    --v1-signing-enabled "$v1" --v2-signing-enabled true \
    --out "$out" "$aligned" 2>/dev/null \
    || die "apksigner failed (keystore $SIGN_KEYSTORE, alias $SIGN_ALIAS)"
}

# --- AndroidX (optional) ----------------------------------------------------
# toolchain/androidx.sh installs vendor/androidx/{androidx.jar,res/*.zip,
# packages.txt}. When present, every AndroidX reference resolves without any
# flag: the jar goes on ECJ's classpath and into the dexer, the compiled
# resources go to aapt2 link with -R, and --extra-packages makes aapt2 emit
# each library's R class (the same trick AGP uses). ANDROIDX_OFF=1 skips all of
# it, which is what --no-androidx sets.
androidx_setup() {
  ANDROIDX_DIR="${ANDROIDX_DIR:-$GH_TOOLCHAIN/androidx}"
  ANDROIDX_CLASSES=""
  ANDROIDX_ARGS=()
  ANDROIDX_STATE="off (--no-androidx)"
  [ "${ANDROIDX_OFF:-0}" = "1" ] && return 0
  [ -s "$ANDROIDX_DIR/androidx.jar" ] && ANDROIDX_CLASSES="$ANDROIDX_DIR/androidx.jar"
  # Kotlin's runtime is not optional here. Some of the harvested AndroidX libraries are
  # compiled from Kotlin (fragment, activity, window, lifecycle-viewmodel), so their
  # classes call kotlin.jvm.internal.Intrinsics on ordinary code paths - starting with
  # AppCompatActivity's constructor. Gradle would add kotlin-stdlib as a transitive
  # dependency; with no Gradle, it has to be appended next to androidx.jar.
  #
  # Getting this wrong is silent: R8 only *warns* about a missing class, the build goes
  # green, and the app dies at launch with ClassNotFoundException. That is exactly what
  # shipped in the first published build. verify_apk.py now fails an APK whose dex
  # references androidX/com.google/kotlin types it does not itself define, so the next
  # time this goes missing the build stops here instead.
  if [ -n "$ANDROIDX_CLASSES" ] && [ -s "$GH_TOOLCHAIN/kotlin-stdlib.jar" ]; then
    ANDROIDX_CLASSES="$ANDROIDX_CLASSES:$GH_TOOLCHAIN/kotlin-stdlib.jar"
    [ -s "$GH_TOOLCHAIN/kotlin-annotations.jar" ] \
      && ANDROIDX_CLASSES="$ANDROIDX_CLASSES:$GH_TOOLCHAIN/kotlin-annotations.jar"
  fi
  # Shizuku's client API rides the same list on purpose: one variable feeds the
  # compiler, both dexers and verify_apk's self-containment gate, so the library
  # cannot be compiled in but dexed out (or vice versa). Vendored, see
  # toolchain/shizuku/PROVENANCE.md - no network, no Maven, no Gradle.
  # NOTE: committed in the repo (toolchain/shizuku/), NOT in vendor/ - vendor is
  # rebuilt from the network on every fresh sandbox, and this must survive that.
  if [ -n "$ANDROIDX_CLASSES" ] && [ -s "$TC_DIR/shizuku/shizuku.jar" ]; then
    ANDROIDX_CLASSES="$ANDROIDX_CLASSES:$TC_DIR/shizuku/shizuku.jar"
  fi
  if [ -d "$ANDROIDX_DIR/res" ]; then
    for z in "$ANDROIDX_DIR"/res/*.zip; do
      [ -s "$z" ] && ANDROIDX_ARGS+=(-R "$z")
    done
  fi
  if [ -f "$ANDROIDX_DIR/packages.txt" ]; then
    while IFS= read -r pkg; do
      [ -n "$pkg" ] && ANDROIDX_ARGS+=(--extra-packages "$pkg")
    done < "$ANDROIDX_DIR/packages.txt"
  fi
  # Library res/ dirs, so xmlcheck can resolve @style/Theme.Material3... and
  # friends before aapt2 is asked to.
  ANDROIDX_XML_ARGS=()
  if [ -n "$ANDROIDX_CLASSES" ] && [ -d "$ANDROIDX_DIR/aar" ]; then
    for d in "$ANDROIDX_DIR"/aar/*/res; do
      [ -d "$d" ] && ANDROIDX_XML_ARGS+=(--extra-res "$d")
    done
  fi
}

# Accept both the flat layout (res/, src/, AndroidManifest.xml) and the Gradle
# layout (src/main/...). Sets PROJ SRC_DIR RES_DIR MANIFEST ASSETS_DIR.
detect_layout() {
  local dir="$1"
  PROJ="$(cd "$dir" && pwd)" || die "no such project: $dir"
  if [ -d "$PROJ/src/main" ]; then
    SRC_DIR="$PROJ/src/main/java"
    [ -d "$SRC_DIR" ] || SRC_DIR="$PROJ/src/main"
    RES_DIR="$PROJ/src/main/res"
    MANIFEST="$PROJ/src/main/AndroidManifest.xml"
  else
    SRC_DIR="$PROJ/src"
    RES_DIR="$PROJ/res"
    MANIFEST="$PROJ/AndroidManifest.xml"
  fi
  ASSETS_DIR="$(dirname "$MANIFEST")/assets"
  [ -f "$MANIFEST" ] || die "no AndroidManifest.xml under $dir"
  androidx_apply
}

# AndroidX is linked in only when the project mentions it somewhere (source,
# resources or manifest): an `androidx.` symbol, a Material Components theme,
# AppCompat, `com.google.android.material`. Framework themes such as
# `@android:style/Theme.Material.Light` do not count. GH_ANDROIDX=on forces it
# in, GH_ANDROIDX=off forces it out.
androidx_apply() {
  local mode="${GH_ANDROIDX:-auto}"
  case "$mode" in
    off) ANDROIDX_CLASSES=""; ANDROIDX_ARGS=(); ANDROIDX_XML_ARGS=(); return 0 ;;
    on)  return 0 ;;
  esac
  [ -n "$ANDROIDX_CLASSES" ] || return 0
  local paths=("$SRC_DIR" "$MANIFEST")
  [ -d "$RES_DIR" ] && paths+=("$RES_DIR")
  [ -d "${TEST_DIR:-}" ] && paths+=("$TEST_DIR")
  # Deliberately narrow: `@android:style/Theme.Material.Light` is the *framework*
  # theme and must not drag AndroidX in, while any TextAppearance.Material3 or
  # Theme.AppCompat reference must.
  if ! grep -rqEl 'androidx\.[a-z]|com\.google\.android\.material|Theme\.AppCompat|Theme\.Material3|MaterialComponents' "${paths[@]}" 2>/dev/null; then
    ANDROIDX_CLASSES=""; ANDROIDX_ARGS=(); ANDROIDX_XML_ARGS=()
    ANDROIDX_STATE="skipped (project does not mention AndroidX; GH_ANDROIDX=on forces it)"
  else
    ANDROIDX_STATE="$ANDROIDX_DIR"
  fi
  return 0
}

# count_java -> number of .java files in the project sources
count_java() { find "$SRC_DIR" -name '*.java' 2>/dev/null | wc -l | tr -d ' '; }

# aapt2_compile_res OUT_ZIP
aapt2_compile_res() {
  local out="$1"
  if [ -d "$RES_DIR" ]; then
    "$AAPT2" compile --dir "$RES_DIR" -o "$out" || die "aapt2 compile failed (see errors above)"
  else
    python3 - "$out" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    pass
PY
  fi
}

# aapt2_link OUT_APK GEN_DIR [extra args...]
aapt2_link() {
  local out="$1" gen="$2"; shift 2
  mkdir -p "$gen"
  local args=(-o "$out" -I "$ANDROID_JAR" --manifest "$MANIFEST"
              --auto-add-overlay --java "$gen")
  [ -n "${RES_ZIP:-}" ] && [ -s "$RES_ZIP" ] && args+=(-R "$RES_ZIP")
  [ "${#ANDROIDX_ARGS[@]}" -gt 0 ] && args+=("${ANDROIDX_ARGS[@]}")
  [ -d "$ASSETS_DIR" ] && args+=(-A "$ASSETS_DIR")
  [ -n "${MIN_API:-}" ] && args+=(--min-sdk-version "$MIN_API")
  [ -n "${TARGET_API:-}" ] && args+=(--target-sdk-version "$TARGET_API")
  # The support-library vector path, and aapt2 must not second-guess it. With
  # --min-sdk-version 19 aapt2 otherwise "versions" every vector: the API-21 attributes
  # (viewportWidth, fillColor, pathData) move to res/drawable-v21/ and the base file is
  # left as a gutted <vector>. On a KitKat phone AppCompat's VdcInflateDelegate then
  # inflates that base, fails ("tag requires viewportWidth > 0"), falls back to the
  # platform which has never heard of <vector>, and the app dies at launch with
  # Resources$NotFoundException. 59 of 74 drawable pairs shipped like that - including
  # this app's own icons - because the flag's own description fits us exactly: "Use
  # this only when building with vector drawable support library."
  # verify_apk.py fails any APK whose base vectors are stripped, so this cannot rot.
  args+=(--no-version-vectors)
  "$AAPT2" link "${args[@]}" "$@" || die "aapt2 link failed (this is the XML/resource compile step)"
}

# ecj_compile OUT_CLASSES GEN_DIR [extra args...]   -- javac, 100% Java, no JDK
ecj_compile() {
  local out="$1" gen="$2"; shift 2
  # Start from an empty directory. ECJ only writes the class files its sources need,
  # so a class whose source was refactored away stays on disk and goes on to be dexed
  # into the APK: stale bytecode that nothing in the source explains, referencing types
  # that may no longer exist. (Found the honest way: an anonymous class removed during
  # the API-19 work was still being packaged, and check_api.py pointed at it because its
  # supertype does not exist below API 24.) javac and AGP both clean their output
  # directory; this now does too.
  rm -rf "$out"
  mkdir -p "$out"
  local files
  files=$(find "$SRC_DIR" "$gen" -name '*.java' 2>/dev/null)
  [ -n "$files" ] || die "no .java files found under $SRC_DIR"
  local common=(-encoding UTF-8 -proc:none -parameters -d "$out")
  if [ "$JAVA_SRC_LEVEL" -le 8 ]; then
    # <=8: -bootclasspath makes java.* resolve against android.jar, exactly like
    # javac with a real Android SDK. Above 8 ECJ refuses -bootclasspath.
    local boot="$ANDROID_JAR"
    # android.jar has no LambdaMetafactory, so -source 8 + any lambda needs the
    # stub jar setup.sh builds (AGP: core-lambda-stubs.jar from build-tools).
    [ -s "${LAMBDA_STUBS_JAR:-}" ] && boot="$boot:$LAMBDA_STUBS_JAR"
    "$JAVA" -jar "$ECJ_JAR" -source "$JAVA_SRC_LEVEL" -target "$JAVA_SRC_LEVEL" \
      -bootclasspath "$boot" \
      -classpath "$ANDROID_JAR${ANDROIDX_CLASSES:+:$ANDROIDX_CLASSES}" \
      "${common[@]}" "$@" $files
  else
    # Above source level 8 the module system makes -bootclasspath illegal, so
    # android.* comes from the filtered jar while java.* comes from the JRE.
    # Language features are checked strictly; the Java API surface is not
    # restricted to Android's (see toolchain/README.md).
    local cp="$ANDROID_CLASSPATH_JAR"
    [ -s "$cp" ] || cp="$ANDROID_JAR"
    [ -n "$ANDROIDX_CLASSES" ] && cp="$cp:$ANDROIDX_CLASSES"
    "$JAVA" -jar "$ECJ_JAR" -source "$JAVA_SRC_LEVEL" -target "$JAVA_SRC_LEVEL" \
      -classpath "$cp" "${common[@]}" "$@" $files
  fi
}

# dex OUT_DIR  (D8 keeps it quick; --release uses R8 with shrinking)
dex() {
  local out="$1"; shift
  rm -rf "$out"; mkdir -p "$out"
  local min_api="${MIN_API:-24}"
  local classes; classes=$(find "$CLASSES_DIR" -name '*.class')
  [ -n "$classes" ] || die "nothing to dex: $CLASSES_DIR is empty"
  # AndroidX classes are program input, not a library: they must land in the dex.
  # ANDROIDX_CLASSES is a colon-joined *classpath* (what ECJ wants); the dexers take
  # one path per argument, so it is split here rather than joined.
  local ax=()
  if [ -n "$ANDROIDX_CLASSES" ] && [ "${DEX_SKIP_ANDROIDX:-0}" != "1" ]; then
    IFS=':' read -r -a ax <<< "$ANDROIDX_CLASSES"
  fi
  # Library inputs: resolvable, never emitted. The Kotlin annotations live here rather
  # than in the dex - they are CLASS-retention metadata, not runtime classes.
  local libs=(--lib "$ANDROID_JAR")
  [ -s "$GH_TOOLCHAIN/kotlin-annotations.jar" ] \
    && libs+=(--lib "$GH_TOOLCHAIN/kotlin-annotations.jar")
  if [ "${RELEASE:-0}" = "1" ]; then
    local pgconf="$PROJ/proguard.pro"
    local extra=()
    [ -f "$pgconf" ] && extra=(--pg-conf "$pgconf")
    # R8 never reads AndroidManifest.xml. The activities and services the *framework*
    # instantiates by name look to R8 like ordinary unused classes, so it deletes them -
    # which shipped once: the splash activity was in the manifest and not in any keep
    # list, and the release APK could not launch. AGP generates these rules from the
    # merged manifest; manifest_keep.py does it here, from ours, so a newly declared
    # component cannot be forgotten. verify_apk.py independently checks the finished APK
    # against the same manifest, so even a bypass of this step gets caught.
    local manifest_keep
    manifest_keep="$(mktemp "${TMPDIR:-/tmp}/ghosthand-manifest-keep.XXXXXX")"
    # TC_DIR, not GH_TOOLCHAIN: GH_TOOLCHAIN is the *vendor* directory; the generator
    # is a checked-in tool next to this script.
    python3 "$TC_DIR/manifest_keep.py" ${MANIFEST:+"$MANIFEST"} --out "$manifest_keep" \
      || { rm -f "$manifest_keep"; die "could not generate manifest keep rules"; }
    extra+=(--pg-conf "$manifest_keep")
    "$JAVA" -cp "$D8_JAR" com.android.tools.r8.R8 --release --dex \
      --min-api "$min_api" "${libs[@]}" "${extra[@]}" "$@" \
      --output "$out" $classes "${ax[@]}" \
      || { local rc=$?; rm -f "$manifest_keep"; die "R8 failed"; }
    rm -f "$manifest_keep"
  else
    "$JAVA" -cp "$D8_JAR" com.android.tools.r8.D8 \
      --min-api "$min_api" "${libs[@]}" "$@" \
      --output "$out" $classes "${ax[@]}" || die "D8 failed (Java bytecode the dexer rejects?)"
  fi
}
