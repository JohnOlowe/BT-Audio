#!/usr/bin/env python3
"""androidx_assemble.py -- turn exploded AARs into what the toolchain consumes.

Produces, under --out:

    androidx.jar      every library's classes.jar merged with the plain jars
                      (annotations, collection, lifecycle-common, ...) into one
                      fat jar: it goes on ECJ's -classpath, into D8/R8 as a
                      program input, and is what makes the APK self-contained.
    res/<name>.zip    per-library `aapt2 compile` output: aapt2 link takes each
                      with -R so the APK gets the merged resource table.
    packages.txt      the library package names (`androidx.appcompat`,
                      `com.google.android.material`, ...). aapt2 link
                      --extra-packages X emits X's R.java, which is how AGP
                      gives each library its R class; we do the same, so
                      library code compiles unmodified.

Usage:
    androidx_assemble.py --stage DIR --jars DIR --out DIR --aapt2 PATH [--quiet]
"""

import argparse
import os
import re
import subprocess
import sys
import zipfile

SKIP_ENTRY = re.compile(r"^(META-INF/|module-info\.class$|.*\.kotlin_module$|kotlin/)")
PKG_RE = re.compile(r'package="([^"]+)"')
IGNORE_JAR = ("-sources", "-javadoc", " (1)")


def merge_jar(jars, out_path, quiet):
    """Write one jar with the contents of all inputs; first definition wins."""
    names = {}
    collisions = 0
    for jar in jars:
        with zipfile.ZipFile(jar) as z:
            for item in z.infolist():
                if item.is_dir() or SKIP_ENTRY.match(item.filename):
                    continue
                if item.filename in names:
                    collisions += 1
                    continue
                names[item.filename] = (jar, item)
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as out:
        for filename, (jar, item) in names.items():
            with zipfile.ZipFile(jar) as z:
                out.writestr(filename, z.read(item.filename))
    if not quiet:
        print("        %d classes/resources from %d jars (%d duplicate names skipped)"
              % (len(names), len(jars), collisions))
    return len(names)


def compile_res(aapt2, res_dir, out_zip):
    proc = subprocess.run([aapt2, "compile", "--dir", res_dir, "-o", out_zip],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout + proc.stderr)
        return False
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--stage", required=True, help="dir of exploded AARs")
    ap.add_argument("--jars", default="", help="dir of plain jars from the dump")
    ap.add_argument("--out", required=True)
    ap.add_argument("--aapt2", required=True)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    res_out = os.path.join(args.out, "res")
    os.makedirs(res_out, exist_ok=True)

    stages = sorted(d for d in os.listdir(args.stage)
                    if os.path.isdir(os.path.join(args.stage, d)))
    jars = [os.path.join(args.stage, d, "classes.jar") for d in stages]
    jars = [j for j in jars if os.path.isfile(j)]
    if args.jars:
        for name in sorted(os.listdir(args.jars)):
            if name.endswith(".jar") and not any(x in name for x in IGNORE_JAR):
                jars.append(os.path.join(args.jars, name))
    if not jars:
        print("        no classes.jar found under %s" % args.stage)
        return 1

    classes = merge_jar(jars, os.path.join(args.out, "androidx.jar"), args.quiet)

    compiled = failed = 0
    for d in stages:
        res_dir = os.path.join(args.stage, d, "res")
        if not os.path.isdir(res_dir) or not os.listdir(res_dir):
            continue
        if compile_res(args.aapt2, res_dir, os.path.join(res_out, d + ".zip")):
            compiled += 1
        else:
            failed += 1
            print("        aapt2 compile FAILED for %s" % d)

    packages = set()
    for d in stages:
        manifest = os.path.join(args.stage, d, "AndroidManifest.xml")
        if os.path.isfile(manifest):
            with open(manifest, encoding="utf-8", errors="ignore") as fh:
                m = PKG_RE.search(fh.read())
            if m:
                packages.add(m.group(1))
    with open(os.path.join(args.out, "packages.txt"), "w", encoding="utf-8") as fh:
        for pkg in sorted(packages):
            fh.write(pkg + "\n")

    size = os.path.getsize(os.path.join(args.out, "androidx.jar"))
    print("        androidx.jar %.1f MB, %d class entries" % (size / 1e6, classes))
    print("        resources: %d libraries compiled, %d failed" % (compiled, failed))
    print("        packages: %d (for aapt2 --extra-packages)" % len(packages))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
