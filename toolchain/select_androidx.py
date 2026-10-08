#!/usr/bin/env python3
"""select_androidx.py -- choose which AARs/JARs to take from a cache dump.

The GitHub repos we harvest from are *flat dumps of a Gradle cache*: every
artifact the project ever resolved, including duplicates across versions (two
`transition` versions), Kotlin-only variants (`core-ktx`), test infrastructure
(`espresso-core`, `runner`) and unrelated tooling (`gradle-8.12.2.jar`).

So the selection is explicit rather than clever: a WANT list of the artifacts *this*
app needs, the highest version of each, plus the plain jars (annotation, collection,
arch core, ...). Everything else is ignored.

The list is deliberately short. Every library that is not in it is a library whose
references cannot dangle, whose resources cannot leak into the APK and whose classes
cannot be loaded by accident - and the APK is smaller for it. navigation-* and
slidingpanelayout/window were removed on evidence, not taste: nothing outside
navigation itself referenced navigation, nothing outside navigation referenced
slidingpanelayout, and nothing outside slidingpanelayout referenced window (checked
with a scan of the merged jar in the PR/commit notes).

Usage:
    python3 select_androidx.py LISTING_FILE OUT_FILE
where LISTING_FILE is one path per line (`git ls-tree --name-only HEAD`).
"""

import os
import re
import sys

# AAR artifacts (group:artifact -> artifact directory base name in the dump)
WANT_AARS = [
    "activity",
    "annotation-experimental",
    "appcompat",
    "appcompat-resources",
    "cardview",
    "constraintlayout",
    "coordinatorlayout",
    "core",
    "core-runtime",
    "cursoradapter",
    "customview",
    "documentfile",
    "drawerlayout",
    "dynamicanimation",
    "emoji2",
    "emoji2-views-helper",
    "fragment",
    "interpolator",
    "legacy-support-core-utils",
    "lifecycle-livedata",
    "lifecycle-livedata-core",
    "lifecycle-process",
    "lifecycle-runtime",
    "lifecycle-viewmodel",
    # Kept even though this app has no ViewModels: ComponentActivity's *constructor*
    # calls SavedStateHandleSupport.enableSavedStateHandles(), so R8 fails the build
    # without it. That failure is how this line was written - which is the point of
    # failing on a missing class instead of warning about it.
    "lifecycle-viewmodel-savedstate",
    "loader",
    "localbroadcastmanager",
    "material",
    "print",
    "profileinstaller",
    "recyclerview",
    "savedstate",
    "startup-runtime",
    "tracing",
    "transition",
    "vectordrawable",
    "vectordrawable-animated",
    "versionedparcelable",
    "viewpager",
    "viewpager2",
]

# Plain jars: androidx.annotation / collection / arch core / constraintlayout
# solver / compile-time annotations. Some carry real classes (collection,
# lifecycle-common, core-common, constraintlayout-core) -- they are required.
WANT_JARS = [
    "annotation-jvm",
    "collection",
    "concurrent-futures",
    "constraintlayout-core",
    "core-common",
    "lifecycle-common",
    "resourceinspection-annotation",
    "listenablefuture",
    "jsr305",
    "error_prone_annotations",
]

VERSION_RE = re.compile(r"^(?P<base>.+?)-(?P<ver>\d+(?:\.\d+)*(?:[-.][A-Za-z0-9]+)*)$")
SUFFIX_RANK = {"alpha": 0, "beta": 1, "rc": 2}


def parse(name):
    """('core', (1,10,1,'')) for 'core-1.10.1.aar'; None if unparseable."""
    stem, ext = os.path.splitext(name)
    if ext not in (".aar", ".jar"):
        return None, None, None
    if any(x in stem for x in ("-sources", "-javadoc", " (1)")):
        return None, None, None
    m = VERSION_RE.match(stem)
    if not m:
        return None, None, None
    base, ver = m.group("base"), m.group("ver")
    parts = re.split(r"[.-]", ver)
    nums, suffix = [], ""
    for part in parts:
        if part.isdigit():
            nums.append(int(part))
        else:
            suffix = part
    return base, tuple(nums) + (0,) * (3 - len(nums)), (SUFFIX_RANK.get(suffix, 3), suffix)


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    listing_path, out_path = argv
    with open(listing_path, encoding="utf-8") as fh:
        entries = [line.strip() for line in fh if line.strip()]

    wanted = {a: "aar" for a in WANT_AARS}
    wanted.update({j: "jar" for j in WANT_JARS})
    best = {}
    for entry in entries:
        name = os.path.basename(entry)
        if any(ch in name for ch in " ()"):          # "(1)" duplicates
            continue
        base, numbers, suffix = parse(name)
        if base is None or base not in wanted:
            continue
        if not name.endswith("." + wanted[base]):
            continue
        key = base
        rank = (numbers, suffix)
        if key not in best or rank > best[key][0]:
            best[key] = (rank, entry)

    chosen = sorted(v[1] for v in best.values())
    with open(out_path, "w", encoding="utf-8") as fh:
        for line in chosen:
            fh.write(line + "\n")

    missing = [a for a in WANT_AARS if a not in best] + \
              [j for j in WANT_JARS if j not in best]
    print("    selected %d artifacts (%d AARs, %d jars)" %
          (len(chosen), sum(1 for c in chosen if c.endswith(".aar")),
           sum(1 for c in chosen if c.endswith(".jar"))))
    if missing:
        print("    not present in this source (fine if nothing needs them): %s"
              % ", ".join(sorted(missing)[:12]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
