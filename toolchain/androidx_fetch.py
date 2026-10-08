#!/usr/bin/env python3
"""androidx_fetch.py -- build a local AndroidX "Maven repo" from a GitHub dump.

There is no Maven here: repo.maven.apache.org, dl.google.com/dl/android/maven2,
maven.google.com, jitpack, aliyun, huaweicloud, tencent and every other mirror
answer 000 from this sandbox (see RECIPE.md section on network probing). So the
toolchain gets AndroidX the only way left open: from a *git repository that has
committed the resolved Gradle cache as ordinary blobs*.

Source of record: github.com/AuntiSaha/weather_app -- a flat dump of
~/.gradle/caches/modules-2/files-2.1 with 69 real AARs and 10 real jars,
including appcompat-1.6.1, material-1.10.0, core-1.10.1, recyclerview,
constraintlayout, fragment, lifecycle, navigation. It is fetched with a
blobless partial clone, so only the selected artifacts cost bandwidth.

Usage:
    python3 androidx_fetch.py --repo URL --dest DIR [--dry-run] [--keep-clone]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from select_androidx import WANT_AARS, WANT_JARS, parse  # noqa: E402

DEFAULT_REPO = "https://github.com/AuntiSaha/weather_app.git"
# Artifacts whose classes are needed to *compile* a Material/AppCompat app.
# Everything else is optional (only pulled in when it is small).
DUMMY = tempfile.mkdtemp


def run(cmd, cwd=None, quiet=True):
    """Run a command, return (rc, output)."""
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, shell=isinstance(cmd, str))
    out = proc.stdout + proc.stderr
    if not quiet and out.strip():
        print(out.rstrip())
    return proc.returncode, out


def clone(repo, dest):
    """Blobless, no-checkout clone: metadata + trees only, ~1 MB."""
    rc, out = run(["git", "clone", "--depth", "1", "--filter=blob:none",
                   "--no-checkout", repo, dest])
    if rc != 0:
        print("    clone failed: %s" % out.strip().splitlines()[-1])
        return False
    return True


def choose(files):
    """Pick highest version of every wanted artifact from a name listing."""
    wanted = {a: "aar" for a in WANT_AARS}
    wanted.update({j: "jar" for j in WANT_JARS})
    best = {}
    for path in files:
        name = os.path.basename(path)
        base, numbers, suffix = parse(name)
        if base is None or base not in wanted:
            continue
        if not name.endswith("." + wanted[base]):
            continue
        rank = (numbers, suffix)
        if base not in best or rank > best[base][0]:
            best[base] = (rank, path)
    return sorted(v[1] for v in best.values())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--dest", required=True, help="destination, e.g. toolchain/androidx")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--keep-clone", action="store_true")
    args = ap.parse_args(argv)

    clone_dir = os.path.join(tempfile.gettempdir(), "androidx_src")
    if os.path.isdir(clone_dir):
        shutil.rmtree(clone_dir)
    print("  [1/4] blobless clone of %s" % args.repo)
    if not clone(args.repo, clone_dir):
        return 1
    rc, out = run(["git", "ls-tree", "-r", "--name-only", "HEAD"], cwd=clone_dir)
    files = [ln for ln in out.splitlines() if ln.strip()]
    print("        %d files in the dump" % len(files))

    chosen = choose(files)
    if not chosen:
        print("        nothing matched -- wrong repo?")
        return 1
    print("  [2/4] %d artifacts selected:" % len(chosen))
    aars = [c for c in chosen if c.endswith(".aar")]
    jars = [c for c in chosen if c.endswith(".jar")]
    for path in chosen:
        print("        %s" % os.path.basename(path))
    if args.dry_run:
        return 0

    print("  [3/4] fetching blobs (this is the only network step)")
    rc, out = run(["git", "checkout", "HEAD", "--"] + aars + jars, cwd=clone_dir)
    if rc != 0:
        print("        checkout failed: %s" % out.strip().splitlines()[-1])
        return 1

    print("  [4/4] assembling %s" % args.dest)
    if os.path.isdir(args.dest):
        shutil.rmtree(args.dest)
    flat = os.path.join(args.dest, "maven")
    os.makedirs(flat)
    for path in chosen:
        base = os.path.basename(path)
        src = os.path.join(clone_dir, path)
        shutil.copy2(src, os.path.join(flat, base))
        print("        %-46s %9d B" % (base, os.path.getsize(src)))
    total = sum(os.path.getsize(os.path.join(flat, f)) for f in os.listdir(flat))
    print("        total %.1f MB" % (total / 1e6))
    if not args.keep_clone:
        shutil.rmtree(clone_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
