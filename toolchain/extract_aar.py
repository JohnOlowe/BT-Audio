#!/usr/bin/env python3
"""extract_aar.py -- explode AARs so the toolchain can use them like AGP does.

An AAR is just a zip:
    classes.jar      the library's classes      -> compile classpath, dex input
    res/             the library's resources    -> aapt2 compile, link with -R
    R.txt            its resource symbol list   -> used to regenerate R classes
    AndroidManifest.xml  its package name + components -> manifest merge, R package
    libs/*.jar       bundled dependencies       -> classpath, dex input
    assets/, jni/    payload                    -> APK

Usage: extract_aar.py AAR_DIR OUT_DIR [--quiet]
"""

import os
import shutil
import sys
import zipfile

KEEP_TOP = ("classes.jar", "R.txt", "AndroidManifest.xml", "proguard.txt")
KEEP_DIRS = ("res/", "libs/", "assets/", "jni/")


def extract(aar_path, out_root):
    name = os.path.basename(aar_path)[:-4]
    dest = os.path.join(out_root, name)
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    stats = {"res": 0, "libs": 0, "assets": 0, "classes": 0}
    with zipfile.ZipFile(aar_path) as z:
        for item in z.infolist():
            fn = item.filename
            if fn.endswith("/"):
                continue
            if fn in KEEP_TOP:
                z.extract(item, dest)
            elif fn.startswith(KEEP_DIRS):
                z.extract(item, dest)
                top = fn.split("/")[0]
                stats[top if top != "res" else "res"] += 1
    har = os.path.join(dest, "classes.jar")
    if os.path.isfile(har):
        with zipfile.ZipFile(har) as z:
            stats["classes"] = len(z.namelist())
    return name, stats


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    quiet = "--quiet" in argv
    if len(args) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    aar_dir, out_dir = args
    os.makedirs(out_dir, exist_ok=True)
    count = 0
    for name in sorted(os.listdir(aar_dir)):
        if not name.endswith(".aar"):
            continue
        short, stats = extract(os.path.join(aar_dir, name), out_dir)
        count += 1
        if not quiet:
            print("    %-40s classes=%-5d res=%-4d libs=%d" %
                  (short, stats["classes"], stats["res"], stats["libs"]))
    print("    extracted %d AARs" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
