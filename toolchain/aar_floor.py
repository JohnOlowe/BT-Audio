#!/usr/bin/env python3
"""Audit the vendored AndroidX AARs' own minSdkVersion against ours.

Gradle merges every library's manifest into the app's, and a library that declares a
higher minSdkVersion than the app would raise the app's own floor. This toolchain has no
Gradle - it links the app manifest alone (see toolchain/README.md) - so nothing else
would notice: the APK would keep claiming minSdk 19 while shipping a library that was
built for, say, 21, and the failure would appear as a NoSuchMethodError on the oldest
phone we support. Hence this check, run by build.sh, right where the AARs are unpacked.

Usage: python3 toolchain/aar_floor.py [min-api] [vendor-dir]

Exit 0 if every AAR is at or below the floor (or if there are no AARs to look at),
1 if one asks for more. AndroidX AAR manifests are plain text in this vendor tree, but
a binary (AXML) manifest is decoded too rather than silently skipped, so a future
vendor-tree change cannot turn this check into a no-op.
"""

import pathlib
import re
import sys

AXML_MAGIC = b"\x03"


def min_sdk(manifest: pathlib.Path) -> int:
    """The highest minSdkVersion declared in one AAR manifest, or 0 if none is."""
    raw = manifest.read_bytes()
    # Binary AXML stores its strings as UTF-16; the decimal values come out intact, which
    # is all this check needs (a full AXML parse is not required to read an integer).
    text = raw.decode("utf-16-le", "ignore") if raw[:1] == AXML_MAGIC else raw.decode("utf-8", "ignore")
    return max((int(v) for v in re.findall(r"minSdkVersion\D{0,12}(\d+)", text)), default=0)


def main() -> int:
    floor = int(sys.argv[1]) if len(sys.argv) > 1 else 19
    vendor = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "toolchain/vendor/androidx/aar")

    manifests = sorted(vendor.glob("*/AndroidManifest.xml"))
    if not manifests:
        print("  no AAR manifests at %s - nothing to audit" % vendor)
        return 0

    levels = [(min_sdk(m), m.parent.name) for m in manifests]
    worst, worst_lib = max(levels)
    print("  %d AARs declare minSdk <= %d (highest: %s at %d)"
          % (len(manifests), floor, worst_lib if worst else "-", worst))

    over = ["%s declares minSdk %d" % (lib, lvl) for lvl, lib in levels if lvl > floor]
    if over:
        print("  FAIL: a library needs a newer platform than the APK claims:", file=sys.stderr)
        for line in over:
            print("    " + line, file=sys.stderr)
        print("  (raise --min-api, or drop the library - unmerged manifests hide this)",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
