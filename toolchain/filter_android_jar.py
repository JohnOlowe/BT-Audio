#!/usr/bin/env python3
"""filter_android_jar.py -- strip the packages the JRE already owns from android.jar.

Why this exists: below source level 9, ECJ is given android.jar as the *boot*
classpath, so `java.util.List` resolves to Android's stub and a Java API that
Android does not have is a compile error -- exactly what we want. From 9 up, the
module system rejects `-bootclasspath` ("The package java.util is accessible
from more than one module: <unnamed>, java.base") because the jar lands in the
unnamed module while java.base exports the same package.

The workaround is to hand ECJ a jar without the overlapping packages: android.*
and friends still come from the Android platform, java.* comes from the running
JRE. Language features are still checked rigorously; the Java API surface is just
no longer restricted to Android's.

    python3 filter_android_jar.py android.jar android-classpath.jar
"""

import sys
import zipfile

# Packages also provided by java.base / java.xml / java.desktop / java.sql ...
EXCLUDE = (
    "java/", "javax/", "jdk/", "sun/", "com/sun/", "org/w3c/",
    "org/xml/", "org/ietf/", "org/omg/",
)


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    src, dst = argv
    kept = dropped = 0
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            if item.filename.startswith(EXCLUDE):
                dropped += 1
                continue
            zout.writestr(item, zin.read(item.filename))
            kept += 1
    print("    %s: %d classes kept, %d platform-owned classes dropped"
          % (dst, kept, dropped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
