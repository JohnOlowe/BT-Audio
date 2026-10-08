#!/usr/bin/env python3
"""Read build settings from either supported Android project layout.

Usage: python3 toolchain/project_info.py PROJECT [min-api|target-api|version-code|version-name|package|manifest]

Projects may be flat (AndroidManifest.xml at the project root) or use the
standard Gradle layout (src/main/AndroidManifest.xml). Keeping manifest values
as the source of truth prevents wrapper scripts from accidentally building an
APK whose declared SDK/version disagrees with its source manifest.
"""

import os
import sys
import xml.etree.ElementTree as ET

ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
FIELDS = {"min-api", "target-api", "version-code", "version-name", "package", "manifest"}


def find_manifest(project):
    project = os.path.abspath(project)
    if os.path.isfile(project):
        return project
    candidates = (
        os.path.join(project, "src", "main", "AndroidManifest.xml"),
        os.path.join(project, "AndroidManifest.xml"),
    )
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    raise FileNotFoundError("no AndroidManifest.xml under %s" % project)


def values(project):
    manifest = find_manifest(project)
    root = ET.parse(manifest).getroot()
    uses_sdk = root.find("uses-sdk")
    package = root.get("package", "")
    min_api = uses_sdk.get(ANDROID_NS + "minSdkVersion", "1") if uses_sdk is not None else "1"
    target_api = uses_sdk.get(ANDROID_NS + "targetSdkVersion", min_api) if uses_sdk is not None else min_api
    return {
        "min-api": min_api,
        "target-api": target_api,
        "version-code": root.get(ANDROID_NS + "versionCode", "1"),
        "version-name": root.get(ANDROID_NS + "versionName", "1.0"),
        "package": package,
        "manifest": manifest,
    }


def main(argv):
    if len(argv) not in (2, 3) or (len(argv) == 3 and argv[2] not in FIELDS):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        info = values(argv[1])
    except (OSError, ET.ParseError, FileNotFoundError) as exc:
        print("project_info: %s" % exc, file=sys.stderr)
        return 1
    if len(argv) == 2:
        for field in ("package", "min-api", "target-api", "version-code", "version-name", "manifest"):
            print("%s=%s" % (field, info[field]))
    else:
        print(info[argv[2]])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
