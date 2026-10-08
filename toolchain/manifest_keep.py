#!/usr/bin/env python3
"""manifest_keep.py -- the R8 keep rules AGP would have generated for the manifest.

Why this exists
---------------
R8 shrinks from the entry points it is told about: your classes, your libraries, your
proguard rules. It never reads AndroidManifest.xml - so the activities, services and
receivers that *the framework* will instantiate by name look to R8 like ordinary unused
classes, and it deletes them. The crash this produces is exact and delayed:

    ClassNotFoundException: Didn't find class "...SplashActivity" on launch

The Android Gradle Plugin solves this by generating keep rules from the merged manifest
for every component. This toolchain has no AGP, so this script does it instead: it reads
the manifest, resolves each android:name against the package, and emits one -keep rule
per component, run at dex time by toolchain/lib.sh.

Why generating beats listing
----------------------------
This file replaces a hand-written block in app/proguard.pro that opened with "keep them
in sync with the manifest". The splash activity was added to the manifest and not to the
list; R8 deleted it; the release APK shipped unable to launch (the debug APK, unshrunk,
was fine, which is how it survived one device). A generated rule cannot be forgotten
when a component is added - and verify_apk.py checks the *finished APK* against the
manifest, so even bypassing this script gets caught.

Usage:
    python3 toolchain/manifest_keep.py [MANIFEST] [--out FILE]

With no arguments it uses the app's manifest and prints the rules to stdout. --out
writes them to a file instead (that is how toolchain/lib.sh uses it, as a second
--pg-conf for R8). Exits 1 if the manifest has no <package> or no components
(because both mean the parser is looking at the wrong file).
"""

import re
import sys
import os

# Component tags whose android:name names a *class Android instantiates*. Deliberately
# excludes activity-alias (its android:name is a component alias, not a class) and
# everything inside intent-filter (action/category names are not classes either).
COMPONENT_TAGS = ("activity", "service", "receiver", "provider", "application")

TAG_RE = re.compile(r"<(%s)\b([^>]*?)/?>" % "|".join(COMPONENT_TAGS), re.S)
NAME_RE = re.compile(r'android:name\s*=\s*"([^"]+)"')
PACKAGE_RE = re.compile(r'\bpackage\s*=\s*"([^"]+)"')


def resolve(name, package):
    """Android's component-name rules: '.Foo', 'Foo' and 'a.b.Foo' all mean one thing."""
    if name.startswith("."):
        return package + name
    if "." not in name:
        return package + "." + name
    return name


def components(manifest_text, where="the manifest"):
    """[(tag, fully-qualified class name), ...] for every framework-instantiated component.

    Shared with verify_apk.py on purpose: the generator and the checker must parse
    identically, or they can both be wrong in the same direction and the gate sees
    nothing.
    """
    pkg = PACKAGE_RE.search(manifest_text)
    if not pkg:
        raise SystemExit("%s has no package= attribute - is this an AndroidManifest.xml?" % where)
    package = pkg.group(1)
    found = []
    for tag, attrs in TAG_RE.findall(manifest_text):
        name = NAME_RE.search(attrs)
        if name:
            found.append((tag, resolve(name.group(1), package)))
    return package, found


def rules_for(found):
    """The keep rules for a component list.

    Both the class and its nested classes ($*) are kept whole. Nested classes matter:
    the accessibility service's gesture path lives in an inner Api24 class and in an
    anonymous callback, and R8 - treating a framework-instantiated class as possibly
    dead - will prune members and nested classes it cannot see being used. Keeping
    components whole is exactly what the Android runtime assumes anyway.
    """
    lines = [
        "# Generated from AndroidManifest.xml by toolchain/manifest_keep.py.",
        "# Do not edit: adding a component to the manifest adds its rules here.",
    ]
    for tag, cls in found:
        lines.append("")
        lines.append("# %s declared in the manifest" % tag)
        lines.append("-keep class %s { *; }" % cls)
        lines.append("-keep class %s$* { *; }" % cls)
    return "\n".join(lines) + "\n"


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    default_manifest = os.path.join(here, "..", "app", "src", "main", "AndroidManifest.xml")
    manifest, out = default_manifest, None
    args = list(argv[1:])
    while args:
        arg = args.pop(0)
        if arg == "--out":
            if not args:
                print("--out needs a file", file=sys.stderr)
                return 2
            out = args.pop(0)
        else:
            manifest = arg

    try:
        text = open(manifest, encoding="utf-8").read()
    except OSError as exc:
        print("cannot read %s: %s" % (manifest, exc), file=sys.stderr)
        return 2

    _, found = components(text, manifest)
    if not found:
        print("%s declares no components - refusing to write an empty rule set "
              "(the parser is probably looking at the wrong file)" % manifest, file=sys.stderr)
        return 1

    text_rules = rules_for(found)
    if out:
        with open(out, "w", encoding="utf-8") as handle:
            handle.write(text_rules)
        print("    manifest keep rules: %d component(s) -> %s"
              % (len(found), out))
    else:
        sys.stdout.write(text_rules)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
