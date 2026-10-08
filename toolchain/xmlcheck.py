#!/usr/bin/env python3
"""xmlcheck.py -- offline linter for Android XML (manifest + resources).

aapt2 is the authoritative compiler, but it is blunt: it fails at the first
error, and it will not tell you that `@string/app_nam` is a typo when the whole
link step is what you were trying to avoid.  This runs *before* aapt2 as a fast
pre-flight pass, using nothing but the standard library:

  * XML is well-formed (with line numbers when it is not)
  * AndroidManifest.xml: package / uses-sdk / application / launcher activity,
    android:exported present where API 31+ demands it, duplicate activity names
  * resource files: duplicate <string>/<color>/... names, empty values
  * `@type/name` and `@+id/name` references resolve to something that exists
    (add --extra-res DIR for library resources, e.g. AndroidX AAR res/ dirs)

Usage:
    python3 xmlcheck.py PROJECT_DIR [PROJECT_DIR ...] [--extra-res DIR ...]
    python3 xmlcheck.py --json PROJECT_DIR
Exit code: 0 clean, 1 problems found, 2 bad usage.
"""

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

ANDROID_NS = "http://schemas.android.com/apk/res/android"
A = "{%s}" % ANDROID_NS
REF_RE = re.compile(r"@(\+?)([A-Za-z_][A-Za-z0-9_]*)/([A-Za-z0-9_.]+)")
# values/<name>.xml -> resource type is the tag name, e.g. <string>, <color>
VALUE_DIR_RE = re.compile(r"^values(-[A-Za-z]{2,3}(-r[A-Z]{2})?)?$")
COMPONENT_TAGS = ("activity", "activity-alias", "service", "receiver", "provider")
# "<type>" or "<type>-<qualifier>-<qualifier>...": drawable-v24, mipmap-hdpi,
# values-night, layout-land-sw600dp, drawable-en-xhdpi. Only the first segment is
# the resource type; the rest are configuration qualifiers.
RES_DIR_RE = re.compile(r"^([a-z]+)(?:-.+)?$")
# Non-XML files define resources too: ic_launcher.webp in mipmap-hdpi is exactly as
# real as a drawable XML, so it has to satisfy @mipmap/ic_launcher references.
BINARY_RES_EXTS = (".9.png", ".png", ".webp", ".jpg", ".jpeg", ".gif",
                   ".ttf", ".otf", ".mp3", ".wav", ".ogg", ".mp4", ".webm")
# values tags whose resource type is not the tag name.
VALUE_TAG_ALIASES = {"string-array": "array", "integer-array": "array",
                     "array": "array", "declare-styleable": "styleable"}
FILE_RES_TYPES = ("drawable", "layout", "mipmap", "anim", "menu", "xml",
                  "raw", "color", "font", "navigation", "transition", "values")


class Problem(object):
    def __init__(self, path, line, level, message):
        self.path, self.line, self.level, self.message = path, line, level, message

    def __str__(self):
        loc = "%s:%s" % (self.path, self.line) if self.line else self.path
        colour = "\033[31m" if self.level == "error" else "\033[33m"
        return "%s%s: %s\033[0m %s" % (colour, loc, self.level, self.message)


def parse(path, problems):
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        return ET.fromstring(raw)
    except ET.ParseError as exc:
        line = exc.position[0] if getattr(exc, "position", None) else None
        problems.append(Problem(path, line, "error", "malformed XML: %s" % exc))
    except OSError as exc:
        problems.append(Problem(path, None, "error", "cannot read: %s" % exc))
    return None


def find_res_dirs(root_dir):
    """res/ for a flat project, src/main/res/ for the Gradle layout."""
    candidates = [os.path.join(root_dir, "res"),
                  os.path.join(root_dir, "src", "main", "res"),
                  os.path.join(root_dir, "src", "res")]
    return [d for d in candidates if os.path.isdir(d)]


def collect_resources(root_dir, extra_res_dirs=()):
    """{resource_type: {name: (file, line)}} for every resource in the project.

    extra_res_dirs are *library* resource directories (AndroidX AARs). They are
    indexed so that `@style/Theme.Material3...` resolves, but the project's own
    definitions win and library files are never reported as duplicates.
    """
    found = {}
    for res_dir in find_res_dirs(root_dir):
        found = _scan_res_dir(res_dir, found)
    for res_dir in extra_res_dirs:
        if os.path.isdir(res_dir):
            found = _scan_res_dir(res_dir, found, override=False)
    return found


def _scan_res_dir(res_dir, found, override=True):
    for dirpath, _dirs, files in os.walk(res_dir):
        rel = os.path.relpath(dirpath, res_dir)
        leaf = rel.split(os.sep)[0]
        if leaf == ".":
            continue

        # Split "drawable-v24" into type "drawable" + qualifiers.
        m = RES_DIR_RE.match(leaf)
        if not m:
            continue
        is_values = VALUE_DIR_RE.match(leaf) is not None

        for name in sorted(files):
            path = os.path.join(dirpath, name)

            if is_values:
                if not name.endswith(".xml"):
                    continue
                tree = ET.parse(path) if _wellformed(path) else None
                if tree is None:
                    continue
                for child in tree.getroot():
                    if not isinstance(child.tag, str):
                        continue
                    resname = child.get(A + "name") or child.get("name")
                    if not resname:
                        continue
                    # <item type="string" name="x"> carries its type explicitly.
                    if child.tag in ("item", "public"):
                        rtype = child.get("type")
                    else:
                        rtype = VALUE_TAG_ALIASES.get(child.tag, child.tag)
                    if rtype and rtype not in ("public", "overlayable", "macro",
                                               "staging-public-group", "resources"):
                        _add(found, rtype, resname, path, override)
                continue

            # File-based resources: the file name (minus its extension) is the
            # resource name and the directory's first segment is the type.
            typ = m.group(1)
            if typ not in FILE_RES_TYPES:
                continue
            if name.endswith(".xml"):
                base = name[:-4]
            else:
                base = _strip_binary_ext(name)
                if base is None:
                    continue
            _add(found, typ, base, path, override)
    return found


def _add(found, rtype, name, path, override):
    """Register one resource; library passes may not clobber project entries."""
    bucket = found.setdefault(rtype, {})
    if override or name not in bucket:
        bucket[name] = (path, 0)


def _strip_binary_ext(name):
    """ic_launcher.webp -> ic_launcher; None if this is not a resource file."""
    lowered = name.lower()
    for ext in BINARY_RES_EXTS:
        if lowered.endswith(ext):
            return name[: -len(ext)]
    return None


def _wellformed(path):
    try:
        ET.parse(path)
        return True
    except ET.ParseError:
        return False


def check_xml_files(root_dir, problems):
    """Well-formedness of every XML file in the project."""
    count = 0
    skip = {".git", "build", "vendor", "node_modules", ".gradle", "out", ".idea"}

    def walk(d):
        nonlocal count
        for dirpath, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if x not in skip]
            for name in files:
                if name.endswith(".xml"):
                    count += 1
                    parse(os.path.join(dirpath, name), problems)

    walk(root_dir)
    return count


def check_manifest(root_dir, problems, res_index):
    manifest = os.path.join(root_dir, "AndroidManifest.xml")
    if not os.path.isfile(manifest):
        # src/main/AndroidManifest.xml is the Gradle layout
        alt = os.path.join(root_dir, "src", "main", "AndroidManifest.xml")
        if os.path.isfile(alt):
            manifest = alt
        else:
            problems.append(Problem(root_dir, None, "error", "no AndroidManifest.xml"))
            return None
    root = parse(manifest, problems)
    if root is None:
        return None
    if root.tag != "manifest":
        problems.append(Problem(manifest, 0, "error",
                                "root element is <%s>, expected <manifest>" % root.tag))
        return manifest

    package = root.get("package") or ""
    if not package:
        problems.append(Problem(manifest, 0, "error", '<manifest> has no package="..."'))
    elif not re.match(r"^[a-zA-Z]\w*(\.[a-zA-Z]\w*)+$", package):
        problems.append(Problem(manifest, 0, "error",
                                'package="%s" is not a valid Java package' % package))
    if not root.get(A + "versionCode") and not root.get("versionCode"):
        problems.append(Problem(manifest, 0, "warn", 'no android:versionCode'))

    uses_sdk = root.find("uses-sdk")
    min_sdk, target_sdk = 1, 1
    if uses_sdk is None:
        problems.append(Problem(manifest, 0, "warn", "no <uses-sdk> (defaults to minSdk 1)"))
    else:
        min_sdk = int(uses_sdk.get(A + "minSdkVersion") or 1)
        target_sdk = int(uses_sdk.get(A + "targetSdkVersion") or min_sdk)
        if min_sdk > target_sdk:
            problems.append(Problem(manifest, 0, "error",
                                    "minSdkVersion %d > targetSdkVersion %d" % (min_sdk, target_sdk)))

    app = root.find("application")
    if app is None:
        problems.append(Problem(manifest, 0, "error", "no <application> element"))
        return manifest
    if not (app.get(A + "label") or root.get(A + "label")):
        problems.append(Problem(manifest, 0, "warn", "<application> has no android:label"))

    seen = {}
    launchers = 0
    for tag in COMPONENT_TAGS:
        for comp in app.iter(tag):
            name = comp.get(A + "name") or comp.get("name") or "?"
            if name in seen:
                problems.append(Problem(manifest, 0, "error",
                                        "duplicate <%s android:name=%r>" % (tag, name)))
            seen[name] = tag
            exported = comp.get(A + "exported")
            has_filter = comp.find("intent-filter") is not None
            is_launcher = False
            for f in comp.findall("intent-filter"):
                actions = [a.get(A + "name") for a in f.findall("action")]
                cats = [c.get(A + "name") for c in f.findall("category")]
                if "android.intent.action.MAIN" in actions and \
                   "android.intent.category.LAUNCHER" in cats:
                    is_launcher = True
            launchers += is_launcher
            # Since targetSdk 31 every component with an intent filter must say
            # android:exported explicitly, the installer rejects the APK otherwise.
            if target_sdk >= 31 and has_filter and exported is None:
                problems.append(Problem(manifest, 0, "error",
                                        "<%s %s> needs android:exported (targetSdk %d)"
                                        % (tag, name, target_sdk)))
            if (exported == "true" or has_filter) and package:
                if is_launcher and exported == "false":
                    problems.append(Problem(manifest, 0, "error",
                                            "launcher activity %s is android:exported=\"false\"" % name))
    if launchers == 0:
        problems.append(Problem(manifest, 0, "warn",
                                "no MAIN/LAUNCHER activity: nothing will show in the app drawer"))
    return manifest


def check_refs(root_dir, problems, res_index):
    """Every @type/name reference should resolve to a resource or a file."""
    for dirpath, dirs, files in os.walk(root_dir):
        dirs[:] = [d for d in dirs if d not in {".git", "build", "vendor", "node_modules"}]
        for name in files:
            if not name.endswith(".xml"):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
            except OSError:
                continue
            if "@android:" in text:
                # "@android:style/Foo" -> "@android/style/Foo": still matches the
                # reference regex, and the "android" type is skipped below.
                text = text.replace("@android:", "@android/")
            for match in REF_RE.finditer(text):
                plus, rtype, rname = match.groups()
                if rtype == "android":          # framework resource, fine
                    continue
                if plus:                        # @+id/foo *defines* it
                    continue
                if rname == "*android*" or rtype in ("id",) and rname.startswith("android"):
                    continue
                known = res_index.get(rtype, {})
                if rname not in known and rtype not in ("id",):
                    problems.append(Problem(
                        path, text[:match.start()].count("\n") + 1, "error",
                        "@%s/%s is not defined anywhere in res/ (or is a typo)"
                        % (rtype, rname)))
                elif rname not in known and rtype == "id":
                    # @id/foo must exist as @+id/foo somewhere
                    if ("@+id/%s" % rname) not in text and not _id_defined(root_dir, rname):
                        problems.append(Problem(
                            path, text[:match.start()].count("\n") + 1, "error",
                            "@id/%s is never declared with @+id/%s" % (rname, rname)))


def _id_defined(root_dir, name):
    needle = "@+id/%s" % name
    for dirpath, dirs, files in os.walk(root_dir):
        dirs[:] = [d for d in dirs if d not in {".git", "build", "vendor", "node_modules"}]
        for f in files:
            if f.endswith(".xml"):
                try:
                    with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                        if needle in fh.read():
                            return True
                except OSError:
                    pass
    return False


def check_values(root_dir, problems):
    for res_dir in find_res_dirs(root_dir):
        _check_values_dir(res_dir, problems)


def _check_values_dir(res_dir, problems):
    for dirpath, _dirs, files in os.walk(res_dir):
        leaf = os.path.basename(dirpath)
        if not VALUE_DIR_RE.match(leaf):
            continue
        for name in sorted(files):
            if not name.endswith(".xml"):
                continue
            path = os.path.join(dirpath, name)
            root = parse(path, problems)
            if root is None:
                continue
            seen = {}
            for child in root:
                if not isinstance(child.tag, str):
                    continue
                rname = child.get("name")
                if rname is None:
                    problems.append(Problem(path, 0, "warn",
                                            "<%s> without a name attribute" % child.tag))
                    continue
                key = (child.tag, rname)
                if key in seen:
                    problems.append(Problem(path, 0, "error",
                                            "duplicate <%s name=%r>" % (child.tag, rname)))
                seen[key] = True
                value = "".join(child.itertext()).strip()
                if child.tag in ("string", "color", "dimen") and not value:
                    problems.append(Problem(path, 0, "warn",
                                            "<%s name=%r> is empty" % (child.tag, rname)))
                if child.tag == "string" and "'" in value and '"' not in value:
                    problems.append(Problem(path, 0, "warn",
                                            "<string name=%r> contains an unescaped apostrophe" % rname))


def run(root_dirs, as_json=False, extra_res_dirs=()):
    all_problems = []
    for root_dir in root_dirs:
        if not os.path.isdir(root_dir):
            all_problems.append(Problem(root_dir, None, "error", "not a directory"))
            continue
        problems = []
        n_xml = check_xml_files(root_dir, problems)
        res_index = collect_resources(root_dir, extra_res_dirs)
        check_values(root_dir, problems)
        check_manifest(root_dir, problems, res_index)
        check_refs(root_dir, problems, res_index)
        problems.insert(0, Problem(root_dir, None, "info",
                                   "%d XML file(s), %d resource type(s): %s"
                                   % (n_xml, len(res_index),
                                      ", ".join(sorted(res_index)) or "-")))
        all_problems.extend(problems)

    if as_json:
        print(json.dumps([{"path": p.path, "line": p.line, "level": p.level,
                           "message": p.message} for p in all_problems], indent=2))
    else:
        for p in all_problems:
            if p.level == "info":
                print("\033[36m%s: %s\033[0m" % (p.path, p.message))
            else:
                print(p)
    errors = sum(1 for p in all_problems if p.level == "error")
    warns = sum(1 for p in all_problems if p.level == "warn")
    if not as_json:
        print("\nxmlcheck: %d error(s), %d warning(s)" % (errors, warns))
    return 1 if errors else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Android XML/manifest linter")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--extra-res", action="append", default=[], metavar="DIR",
                    help="library res/ directory to index for reference checks "
                         "(repeatable; used for AndroidX AARs)")
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args(argv)
    return run(a.dirs, a.json, a.extra_res)


if __name__ == "__main__":
    sys.exit(main())
