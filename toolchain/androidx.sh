#!/usr/bin/env bash
# androidx.sh -- get AndroidX into the toolchain and make it usable.
#
#   bash toolchain/androidx.sh [--repo URL] [--dest DIR] [--force] [--list]
#
# There is no Maven here: maven.google.com, repo.maven.apache.org, jitpack and
# every mirror answer 000 from this sandbox. The one route that works is
# fetching from a git repository that committed the resolved Gradle cache as
# ordinary blobs. This script does that, then rewrites the AARs into the shape
# check.sh / build.sh / test.sh expect, under toolchain/vendor/androidx:
#
#   androidx.jar     all library classes in one jar (classpath + dex input)
#   res/*.zip        compiled library resources (aapt2 link -R)
#   packages.txt     library packages (aapt2 link --extra-packages, gives each
#                    library its R class exactly like AGP does)
#   aar/, src/       exploded AARs and the downloaded artifacts (rebuild inputs)
#
# After it finishes, any project whose src/res reference AndroidX compiles with
# no further flags. --no-androidx on check.sh/build.sh/test.sh opts out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/vendor/androidx"
REPO="https://github.com/AuntiSaha/weather_app.git"
FORCE=0
LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

msg() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

if [ ! -f "$HERE/env.sh" ]; then
  echo "run 'bash toolchain/setup.sh' first (need aapt2 for resource compilation)" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$HERE/env.sh"
[ -x "${AAPT2:-}" ] || { echo "no aapt2 at ${AAPT2:-} -- run setup.sh" >&2; exit 1; }

if [ "$LIST" = "1" ]; then
  exec python3 "$HERE/androidx_fetch.py" --repo "$REPO" --dest "$DEST/src" --dry-run
fi

if [ -s "$DEST/androidx.jar" ] && [ "$FORCE" != "1" ]; then
  info "already assembled: $DEST/androidx.jar (use --force to rebuild)"
  exit 0
fi

msg "1/3 fetching AndroidX artifacts from a committed Gradle cache"
python3 "$HERE/androidx_fetch.py" --repo "$REPO" --dest "$DEST/src"

msg "2/3 exploding the AARs (classes.jar / res / R.txt / manifest)"
mkdir -p "$DEST/aar"
python3 "$HERE/extract_aar.py" "$DEST/src/maven" "$DEST/aar"

msg "3/3 assembling classpath jar + compiled resources + package list"
python3 "$HERE/androidx_assemble.py" \
  --stage "$DEST/aar" --jars "$DEST/src/maven" --out "$DEST" --aapt2 "$AAPT2"

echo
printf '\033[1;32mANDROIDX READY\033[0m  %s\n' "$DEST"
info "check.sh / build.sh / test.sh pick it up automatically"
info "example: bash toolchain/check.sh sample-androidx && bash toolchain/build.sh sample-androidx --verify"
