#!/usr/bin/env bash
# publish-apk.sh -- publish the built APKs to a branch that NEVER accumulates history.
#
#   bash publish-apk.sh [--apk FILE] [--debug-apk FILE] [--branch apk] [--remote origin]
#                       [--no-push]
#
# Two APKs, one commit: the R8-shrunk release build and the unshrunk/debuggable build.
# Whichever you grab, it is the same app - same package, same key, same versionCode -
# so either installs straight over the other. That is checked below, not
# assumed: a mismatched pair would fail with INSTALL_FAILED_UPDATE_INCOMPATIBLE on the
# phone, which is a bad place to find out.
#
# WHY A SEPARATE BRANCH
# ---------------------
# Both APKs change on every build. Committing them to the source branch
# would add new blobs to history on every push, so `git clone` would hand you every APK
# ever built, forever. Binary blobs do not delta-compress like source does, so that grows
# without bound.
#
# Instead the APKs live on their own branch, and every publish REPLACES that branch with
# a single parentless commit:
#
#     apk:  *  (these builds)        <- always exactly one commit, always two APKs
#     main: *---*---*---*---*        <- source history only, never a binary
#
# A fresh clone of `main` downloads source and nothing else; anyone who wants an APK
# clones/fetches `apk` and pays for exactly one copy of each.
#
# HOW IT WORKS WITHOUT SWITCHING BRANCHES
# ---------------------------------------
# git plumbing writes the commit object directly - no checkout, no working-tree changes,
# nothing to stash:
#   hash-object -w   store each APK as a blob
#   mktree           build a tree from "mode sha path" lines
#   commit-tree      make a commit with NO parent (that is what makes it orphan)
#   push --force     point the remote branch at it, discarding the previous one
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

BRANCH="apk"
REMOTE="origin"
APK="btaudio/build/btaudio.apk"
DEBUG_APK="btaudio/build/btaudio-debug.apk"
DEBUG_APK_GIVEN=0
NAME="btaudio.apk"
DEBUG_NAME="btaudio-debug.apk"
PUSH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --debug-apk) DEBUG_APK="$2"; DEBUG_APK_GIVEN=1; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -s "$APK" ] || { echo "no APK at $APK -- build it first:" >&2
                   echo "  bash build.sh --publish    (builds both, then publishes)" >&2
                   exit 1; }

# The debug build is optional in the sense that publishing a release-only branch is still
# valid - but if the caller named a file, it had better exist.
if [ ! -s "$DEBUG_APK" ]; then
  if [ "$DEBUG_APK_GIVEN" = "1" ]; then
    echo "no debug APK at $DEBUG_APK (it was named explicitly, so this is an error)" >&2
    exit 1
  fi
  echo "note: no debug APK at $DEBUG_APK - publishing the release build only" >&2
  echo "      (bash build.sh --both builds the pair)" >&2
  DEBUG_APK=""
fi

JAVA=""
[ -x toolchain/vendor/jre/bin/java ] && JAVA="toolchain/vendor/jre/bin/java"
APKSIGNER="toolchain/vendor/apksigner.jar"
AAPT2="toolchain/vendor/aapt2"

# ---------------------------------------------------------------- sanity checks
# A valid signature says nothing about whether R8 kept the code the framework reaches by
# name - check that too, so a shrunk-away feature can never be published.
for f in "$APK" ${DEBUG_APK:+"$DEBUG_APK"}; do
  if ! python3 verify_apk.py "$f" --project btaudio; then
    echo "refusing to publish: $f is missing required classes or resources" >&2
    exit 1
  fi
done

signer_cert() {   # prints the SHA-256 of signer #1, empty if unsigned
  [ -n "$JAVA" ] && [ -s "$APKSIGNER" ] || return 0
  "$JAVA" -jar "$APKSIGNER" verify --print-certs "$1" 2>/dev/null \
    | sed -n 's/^Signer #1 certificate SHA-256 digest: //p'
}
signer_dn() {
  [ -n "$JAVA" ] && [ -s "$APKSIGNER" ] || return 0
  "$JAVA" -jar "$APKSIGNER" verify --print-certs "$1" 2>/dev/null \
    | sed -n 's/^Signer #1 certificate DN: //p'
}

if [ -n "$JAVA" ] && [ -s "$APKSIGNER" ]; then
  for f in "$APK" ${DEBUG_APK:+"$DEBUG_APK"}; do
    if ! "$JAVA" -jar "$APKSIGNER" verify "$f" >/dev/null 2>&1; then
      echo "refusing to publish: $f is not a validly signed APK" >&2
      exit 1
    fi
  done
  SIGNER="$(signer_dn "$APK")"
else
  SIGNER="(apksigner not installed - signature not re-checked)"
fi

# What "either installs over the other" actually means, in the order Android checks it:
# the package name must match, the APK must not be a versionCode downgrade, and it must
# be signed by the same certificate (a mismatch is INSTALL_FAILED_UPDATE_INCOMPATIBLE).
# Everything else - including whether the APK is debuggable or R8-renamed - is
# irrelevant to the installer.
# `badging | grep -q` looks obvious and is a trap: grep -q exits at the first match,
# aapt2 is killed by SIGPIPE, and `set -o pipefail` (set at the top) reports the whole
# pipeline as failed - so a debuggable APK was reported as "debuggable=no" here.
# Reading the output into a variable first has no pipe to break.
badging() { "$AAPT2" dump badging "$1" 2>/dev/null || true; }
pkg_line() { badging "$1" | sed -n '1p'; }
# Anchored: the badging line also carries platformBuildVersionName / platformBuildVersionCode,
# so a greedy .* would report the build-tools version instead of the app's own.
pkg_name()  { pkg_line "$1" | sed -n "s/^package: name='\([^']*\)'.*/\1/p"; }
pkg_code()  { pkg_line "$1" | sed -n "s/^package: name='[^']*' versionCode='\([^']*\)'.*/\1/p"; }
min_sdk()   { badging "$1" | sed -n "s/^sdkVersion:'\([0-9]*\)'.*/\1/p"; }
is_debug() {
  local info; info="$(badging "$1")"
  case "$info" in *application-debuggable*) return 0 ;; *) return 1 ;; esac
}

if [ -s "$AAPT2" ] && [ -n "$DEBUG_APK" ]; then
  A_NAME="$(pkg_name "$APK")";    A_CODE="$(pkg_code "$APK")"
  B_NAME="$(pkg_name "$DEBUG_APK")"; B_CODE="$(pkg_code "$DEBUG_APK")"
  A_CERT="$(signer_cert "$APK")"; B_CERT="$(signer_cert "$DEBUG_APK")"
  INCOMPAT=""
  [ -n "$A_NAME" ] && [ "$A_NAME" = "$B_NAME" ] || INCOMPAT="package name ($A_NAME vs $B_NAME)"
  [ -n "$A_CODE" ] && [ "$A_CODE" = "$B_CODE" ] || INCOMPAT="versionCode ($A_CODE vs $B_CODE)"
  [ -n "$A_CERT" ] && [ "$A_CERT" = "$B_CERT" ] || INCOMPAT="signing certificate"
  if [ -n "$INCOMPAT" ]; then
    echo "refusing to publish: the two APKs differ in $INCOMPAT" >&2
    echo "one would not install over the other (INSTALL_FAILED_UPDATE_INCOMPATIBLE)." >&2
    exit 1
  fi
  echo "installable pair: $A_NAME v$A_CODE, both signed by"
  echo "  $A_CERT"
  echo "  release: minSdk $(min_sdk "$APK"), debuggable=$(is_debug "$APK" && echo yes || echo no)"
  echo "  debug:   minSdk $(min_sdk "$DEBUG_APK"), debuggable=$(is_debug "$DEBUG_APK" && echo yes || echo no)"
  # Different minSdkValues are fine - each APK is installable over the other on any
  # device that accepts both - but they are not the same *claim*, so they are printed
  # rather than assumed equal.
fi

sha256_of() { sha256sum "$1" | awk '{print $1}'; }
size_of()   { du -h "$1" | cut -f1; }
bytes_of()  { stat -c%s "$1"; }
dex_count() { python3 - "$1" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(sum(1 for name in z.namelist() if name.endswith('.dex')))
PY
}

SHA256="$(sha256_of "$APK")"
SIZE="$(size_of "$APK")"
SOURCE_REV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
SOURCE_DESC="$(git log -1 --pretty=%s 2>/dev/null || echo unknown)"
STAMP="$(date -u '+%Y-%m-%d %H:%M UTC')"

if [ -n "$DEBUG_APK" ]; then
  DEBUG_SHA256="$(sha256_of "$DEBUG_APK")"
  DEBUG_SIZE="$(size_of "$DEBUG_APK")"
  APK_COUNT_WORD="two APKs"
else
  # Keep the generated artifact count explicit; it is easier to review than a nested
  # parameter expansion in the README template.
  APK_COUNT_WORD="one APK"
fi

# ------------------------------------------------------------- build the branch
BLOB="$(git hash-object -w "$APK")"
[ -n "$DEBUG_APK" ] && DEBUG_BLOB="$(git hash-object -w "$DEBUG_APK")"

# The release build is the shrunk artifact; the debug build stays unshrunk and debuggable.
dex_description() {
  if [ "$1" -eq 1 ]; then printf '1 dex file'; else printf '%s dex files' "$1"; fi
}
RELEASE_DEXES="$(dex_count "$APK")"
RELEASE_DEX_DESCRIPTION="$(dex_description "$RELEASE_DEXES")"
if [ -n "$DEBUG_APK" ]; then
  DEBUG_DEXES="$(dex_count "$DEBUG_APK")"
  DEBUG_DEX_DESCRIPTION="$(dex_description "$DEBUG_DEXES")"
  APK_TABLE="| File | Size | Runs on | Build | DEX files | SHA-256 |
|---|---|---|---|---:|---|
| \`$NAME\` | $SIZE | Android $(min_sdk "$APK")+ | **release**, R8-shrunk | $RELEASE_DEXES | \`$SHA256\` |
| \`$DEBUG_NAME\` | $DEBUG_SIZE | Android $(min_sdk "$DEBUG_APK")+ | **debug**, unshrunk/debuggable | $DEBUG_DEXES | \`$DEBUG_SHA256\` |"
  VARIANT_NOTE="Both are the same app - package \`$(pkg_name "$APK")\`, versionCode \`$(pkg_code "$APK")\`, signed by the same key - so either installs straight over the other in either order, keeping your data. The release contains $RELEASE_DEX_DESCRIPTION; the debug build contains $DEBUG_DEX_DESCRIPTION. Each APK's Android version floor is listed in the table."
  INSTALL_LIST="git show FETCH_HEAD:$NAME > $NAME             # release, R8-shrunk
git show FETCH_HEAD:$DEBUG_NAME > $DEBUG_NAME  # debug, unshrunk/debuggable"
  ADB_INSTALL_LINE="adb install -r $NAME        # or $DEBUG_NAME; either order works"
  WHICH_ONE="* **Normal use or distribution:** \`$NAME\` is the R8-shrunk release build.
* **Debugging or inspection:** \`$DEBUG_NAME\` is unshrunk and debuggable, so stack traces retain source class names.
* **Android version support:** see each APK's \`Runs on\` entry in the table above."
else
  APK_TABLE="| File | Size | Runs on | Build | DEX files | SHA-256 |
|---|---|---|---|---:|---|
| \`$NAME\` | $SIZE | Android $(min_sdk "$APK")+ | **release**, R8-shrunk | $RELEASE_DEXES | \`$SHA256\` |"
  VARIANT_NOTE="This publish contains only the R8-shrunk release APK. It is signed with the stable project key; the minimum Android version and DEX count are shown in the table."
  INSTALL_LIST="git show FETCH_HEAD:$NAME > $NAME"
  ADB_INSTALL_LINE="adb install -r $NAME"
  WHICH_ONE="* **Only artifact in this publish:** \`$NAME\` is the R8-shrunk release build.
* **Android version support:** Android $(min_sdk "$APK")+ (API $(min_sdk "$APK")); see the table above. To publish the optional unshrunk/debuggable APK as well, build with \`bash build.sh --both\`."
fi

README_FILE="$(mktemp)"
trap 'rm -f "$README_FILE"' EXIT
cat > "$README_FILE" <<EOF
# BT Audio - build artifacts (generated, do not edit)

This branch exists only to hand out the APKs. It is **replaced on every publish** and
therefore always has exactly **one commit** and exactly **$APK_COUNT_WORD**.
That is on purpose: build output must never accumulate in the source history, or every
clone would drag along every APK ever built.

$APK_TABLE

$VARIANT_NOTE

## Install

\`\`\`bash
git fetch origin $BRANCH
$INSTALL_LIST

$ADB_INSTALL_LINE
\`\`\`

Every build is signed with the same key (\`keystore/damjay_debug.keystore\`), so a new
APK installs straight over the previous one - no uninstalling, no lost settings.

## Which one do I want

$WHICH_ONE

## Build them yourself

\`\`\`bash
bash build.sh                                 # setup + receiver unit tests + release APK
bash build.sh --both                          # both APKs into btaudio/build/
bash build.sh --publish                       # both, then replace this branch
\`\`\`

| | |
|---|---|
| Built | $STAMP |
| Source | \`$SOURCE_REV\` - $SOURCE_DESC |
| Signer | $SIGNER |
EOF
README_BLOB="$(git hash-object -w "$README_FILE")"

TREE_LINES="$(printf '100644 blob %s\t%s\n100644 blob %s\tREADME.md\n' \
               "$BLOB" "$NAME" "$README_BLOB")"
if [ -n "$DEBUG_APK" ]; then
  TREE_LINES="$(printf '%s\n100644 blob %s\t%s' \
                 "$TREE_LINES" "$DEBUG_BLOB" "$DEBUG_NAME")"
fi
TREE="$(printf '%s\n' "$TREE_LINES" | git mktree)"

COMMIT_MSG="BT Audio $NAME @ $SOURCE_REV

size:   $SIZE
sha256: $SHA256
${DEBUG_APK:+debug:  $DEBUG_SIZE
debug sha256: $DEBUG_SHA256
}signed: $SIGNER
built:  $STAMP

Single-commit branch: each publish replaces the previous one on purpose, so the
repository never accumulates build output in its history. Both APKs are signed with
the same key and share a package name and versionCode, so either installs over the
other."

# No -p (parent) argument: that is what makes this an orphan commit, so the branch is
# exactly one commit deep however many times it is published.
COMMIT="$(git commit-tree "$TREE" -m "$COMMIT_MSG")"

echo "apk    : $APK ($SIZE)"
echo "sha256 : $SHA256"
[ -n "$DEBUG_APK" ] && { echo "debug  : $DEBUG_APK ($DEBUG_SIZE)"; echo "sha256 : $DEBUG_SHA256"; }
echo "commit : $COMMIT"

if [ "$PUSH" = "1" ]; then
  echo "pushing -> $REMOTE $BRANCH (force: replaces the previous artifact commit)"
  git push --force "$REMOTE" "$COMMIT:refs/heads/$BRANCH"
  echo
  echo "The branch now holds exactly one commit and its artifacts:"
  echo "  git ls-tree -r --long $COMMIT"
else
  echo "(not pushed; --no-push was given)"
fi
