#!/usr/bin/env python3
"""Verify a built Android APK against its project manifest and dex contents.

Usage:
    python3 verify_apk.py [APK] [--project btaudio]

This verifier is project-agnostic: it checks that manifest components survived
R8, the APK's package/minSdk agree with the source manifest, old Dalvik builds do
not contain an unloadable secondary dex, and project/dependency classes referenced
by dex are actually packaged (or explicitly allowlisted for that project).
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import zipfile

LIBRARY_PREFIXES = ("androidx/", "com/google/", "kotlin/", "kotlinx/",
                    "org/jetbrains/")


def fail(message):
    print("\033[31m    FAIL\033[0m %s" % message)
    return 1


def info(message):
    print("    %s" % message)


def project_manifest(project):
    project = os.path.abspath(project)
    candidates = (
        os.path.join(project, "src", "main", "AndroidManifest.xml"),
        os.path.join(project, "AndroidManifest.xml"),
    )
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return None


def project_manifest_info(manifest_path):
    if not manifest_path:
        return None, []
    toolchain = os.path.join(os.path.dirname(os.path.abspath(__file__)), "toolchain")
    sys.path.insert(0, toolchain)
    from manifest_keep import components
    with open(manifest_path, encoding="utf-8") as handle:
        return components(handle.read(), manifest_path)


def aapt2_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "toolchain", "vendor", "aapt2")


def apk_metadata(apk):
    """Return aapt2's badging text, or None if the tool is not installed."""
    tool = aapt2_path()
    if not os.path.isfile(tool):
        return None
    try:
        return subprocess.check_output([tool, "dump", "badging", apk],
                                       stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except (OSError, subprocess.CalledProcessError):
        return None


def metadata_value(text, pattern):
    if text is None:
        return None
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1) if match else None


def dex_types(data):
    """Return (defined, referenced) type descriptors from one dex file."""
    if len(data) < 0x70 or data[:4] != b"dex\n":
        raise ValueError("not a dex file")
    if struct.unpack_from("<I", data, 0x28)[0] != 0x12345678:
        raise ValueError("reverse-endian dex is unsupported")
    string_ids_size, string_ids_off = struct.unpack_from("<II", data, 0x38)
    type_ids_size, type_ids_off = struct.unpack_from("<II", data, 0x40)
    class_defs_size, class_defs_off = struct.unpack_from("<II", data, 0x60)

    def string_at(index):
        (offset,) = struct.unpack_from("<I", data, string_ids_off + 4 * index)
        length, pos = 0, offset
        while data[pos] & 0x80:
            length = (length << 7) | (data[pos] & 0x7F)
            pos += 1
        length = (length << 7) | data[pos]
        return data[pos + 1:pos + 1 + length].decode("utf-8", "replace")

    def type_at(index):
        descriptor_index = struct.unpack_from("<I", data, type_ids_off + 4 * index)[0]
        return string_at(descriptor_index)

    referenced = {type_at(i) for i in range(type_ids_size)}
    defined = {type_at(struct.unpack_from("<I", data, class_defs_off + 32 * i)[0])
               for i in range(class_defs_size)}
    return defined, referenced


SCOPES = ("both", "release", "debug")


def read_allowlist(path):
    """Read `<descriptor-or-prefix> [scope] <reason>` entries."""
    entries = {}
    if not path or not os.path.isfile(path):
        return entries
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 2)
            if len(parts) > 1 and parts[1] in SCOPES:
                entries[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
            else:
                entries[parts[0]] = ("both", line[len(parts[0]):].strip())
    return entries


def matches(type_name, entry):
    """A trailing /** allows an explicit package-prefix exception."""
    if entry.endswith("/**"):
        return type_name.startswith(entry[:-2])
    return type_name == entry


def dex_type_tables(dexes, blobs):
    """Return defined and referenced class names without dex descriptors."""
    defined, referenced = set(), set()
    for name in dexes:
        d, r = dex_types(blobs[name])
        defined.update(t[1:-1] for t in d if t.startswith("L") and t.endswith(";"))
        referenced.update(r)
    return defined, referenced


def check_vectors_not_stripped(names, archive):
    """Fail if aapt2 moved vector geometry to a versioned-only variant."""
    import collections
    groups = collections.defaultdict(dict)
    pattern = re.compile(r"^res/([^/]+)/([^/]+\.xml)$")
    for name in names:
        match = pattern.match(name)
        if match:
            groups[match.group(2)][match.group(1)] = name
    stripped = []
    for filename, variants in groups.items():
        if "drawable" not in variants or len(variants) < 2:
            continue
        base = archive.read(variants["drawable"])
        if b"viewportWidth" not in base and any(
                b"viewportWidth" in archive.read(path)
                for qualifier, path in variants.items() if qualifier != "drawable"):
            stripped.append(filename)
    if stripped:
        problems = fail("%d vector drawable(s) have a stripped base copy: %s" %
                        (len(stripped), ", ".join(sorted(stripped)[:8])))
        print("      (link with aapt2 --no-version-vectors so older devices retain the base)")
        return problems
    info("no stripped vector bases")
    return 0


def check_manifest_components(defined, found, manifest_path):
    if not manifest_path:
        info("no source manifest supplied; component check skipped")
        return 0
    if not found:
        return fail("%s declares no framework components" % manifest_path)
    missing = [name for _, name in found if name.replace(".", "/") not in defined]
    if missing:
        problems = fail("manifest component(s) are missing from the APK: %s" %
                        ", ".join(missing))
        print("      (R8 does not read the manifest; toolchain/manifest_keep.py generates keeps)")
        return problems
    info("%d manifest component(s) present (%s)" %
         (len(found), ", ".join(sorted({tag for tag, _ in found}))))
    return 0


def check_self_contained(defined, referenced, allowlist_path, kind, app_package):
    """Ensure project and runtime dependency types referenced by dex are packaged."""
    declared = read_allowlist(allowlist_path)
    allow = {key: reason for key, (scope, reason) in declared.items()
             if kind is None or scope in ("both", kind)}
    app_prefix = app_package.replace(".", "/").strip("/") + "/" if app_package else None
    required_prefixes = LIBRARY_PREFIXES + ((app_prefix,) if app_prefix else ())
    used = set()
    missing = []
    for descriptor in referenced:
        if not (descriptor.startswith("L") and descriptor.endswith(";")):
            continue
        name = descriptor[1:-1]
        if not name.startswith(required_prefixes) or name in defined:
            continue
        hits = [entry for entry in allow if matches(name, entry)]
        if hits:
            used.update(hits)
        else:
            missing.append(name)

    problems = 0
    if missing:
        problems += fail("%d referenced project/library type(s) are not packaged:" % len(missing))
        for name in sorted(missing)[:15]:
            print("      %s" % name)
        if len(missing) > 15:
            print("      ... and %d more" % (len(missing) - 15))
        print("      (add the missing dependency, or document a truly optional type in "
              "the project's packaging-allowlist.txt)")

    stale = sorted(set(allow) - used) if kind is not None else []
    if stale:
        problems += fail("%d packaging allowlist entry/entries are unused for this APK:" % len(stale))
        for entry in stale[:10]:
            print("      %s" % entry)
        print("      (remove stale exceptions rather than letting them hide a future missing class)")
    if not problems:
        info("%d types defined, %d referenced; project and dependency references are packaged%s" %
             (len(defined), len(referenced),
              " (%d allowed optional type(s))" % len(allow) if allow else ""))
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", nargs="?", help="APK to inspect")
    parser.add_argument("--project", default="btaudio",
                        help="project directory (flat or src/main Android layout; default: btaudio)")
    parser.add_argument("--allowlist", help="project-specific packaging allowlist")
    parser.add_argument("--min-api", type=int,
                        help="expected minSdk (defaults to the source manifest; use for an explicit override)")
    args = parser.parse_args(argv[1:])

    project = os.path.abspath(args.project)
    apk = args.apk or os.path.join(project, "build", os.path.basename(project) + ".apk")
    manifest_path = project_manifest(project)
    if not manifest_path:
        return fail("no AndroidManifest.xml under project %s" % project)
    try:
        package, components = project_manifest_info(manifest_path)
        toolchain = os.path.join(os.path.dirname(os.path.abspath(__file__)), "toolchain")
        sys.path.insert(0, toolchain)
        from project_info import values as project_values
        source_values = project_values(project)
        expected_min = args.min_api or int(source_values["min-api"])
    except (OSError, ValueError, SystemExit) as exc:
        return fail("cannot read project settings from %s: %s" % (manifest_path, exc))

    try:
        archive = zipfile.ZipFile(apk)
        bad_member = archive.testzip()
        if bad_member:
            return fail("corrupt ZIP member: %s" % bad_member)
    except (OSError, zipfile.BadZipFile) as exc:
        print("cannot read %s: %s" % (apk, exc), file=sys.stderr)
        return 2

    names = archive.namelist()
    dexes = sorted(n for n in names if re.fullmatch(r"classes(?:[1-9][0-9]*)?\.dex", n))
    if "AndroidManifest.xml" not in names:
        return fail("%s has no AndroidManifest.xml" % apk)
    if not dexes:
        return fail("%s contains no classes.dex" % apk)

    blobs = {name: archive.read(name) for name in dexes}
    try:
        defined, referenced = dex_type_tables(dexes, blobs)
    except (ValueError, IndexError, struct.error) as exc:
        return fail("cannot parse APK dex: %s" % exc)
    print("    %s: package %s, %d dex, %d entries, %.1f MB of dex" %
          (apk, package, len(dexes), len(names),
           sum(len(data) for data in blobs.values()) / 1048576.0))

    problems = 0
    metadata = apk_metadata(apk)
    apk_package = metadata_value(metadata, r"^package: name='([^']+)'")
    if apk_package and apk_package != package:
        problems += fail("APK package %s does not match project manifest package %s" %
                         (apk_package, package))
    elif apk_package:
        info("package agrees with the source manifest")

    sdk_text = metadata_value(metadata, r"^sdkVersion:'(\d+)'")
    min_sdk = int(sdk_text) if sdk_text else None
    if min_sdk is None:
        info("minSdkVersion not read (aapt2 unavailable); dex-count floor check skipped")
    else:
        if min_sdk != expected_min:
            problems += fail("APK minSdkVersion %d does not match expected project floor %d" %
                             (min_sdk, expected_min))
        if min_sdk < 21 and len(dexes) > 1:
            problems += fail("%d dex files but minSdkVersion is %d; Dalvik below API 21 loads "
                             "only classes.dex" % (len(dexes), min_sdk))
        else:
            info("minSdkVersion %d with %d dex file(s)" % (min_sdk, len(dexes)))

    # The allowlist is intentionally per-project: an optional AndroidX type in
    # one sample must not make an unrelated APK's verification pass or fail.
    allowlist = args.allowlist or os.path.join(project, "packaging-allowlist.txt")
    debuggable = metadata is not None and "application-debuggable" in metadata
    kind = "debug" if debuggable else "release" if metadata is not None else None
    problems += check_self_contained(defined, referenced, allowlist, kind, package)
    problems += check_manifest_components(defined, components, manifest_path)
    problems += check_vectors_not_stripped(names, archive)

    if problems:
        print("\033[31mAPK VERIFY FAILED\033[0m (%d problem(s))" % problems)
        return 1
    print("\033[32m    ok\033[0m APK VERIFY PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
