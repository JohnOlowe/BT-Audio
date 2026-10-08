#!/usr/bin/env python3
"""verify_apk.py -- check that a built APK still contains what the app needs.

    python3 verify_apk.py [app/build/app.apk]

Why this exists
---------------
The release build is shrunk by R8, and R8's call graph starts from the code it can
see. Android is not in that graph: the classes it instantiates (activities, services,
the accessibility service) and the methods it calls (lifecycle callbacks, onClick,
onReceive) are only reachable if the keep rules say so.

Getting that wrong does not break the build. It produces a *smaller, valid, signed
APK* that crashes or silently does nothing on a real phone - which is exactly the
class of bug that cannot be caught here, because there is no device or emulator.

It is not hypothetical: `InjectionAccessibilityService` was reduced to two static
methods by R8 (its `onServiceConnected` was dead code to R8, so the static `instance`
field looked like it could never be set, so the `dispatchGesture` call was
unreachable, so the whole injection path was deleted) - and only in the release APK.
Everything compiled, signed and "verified" happily.

So the build checks the artifact instead of trusting it:

  * required **classes**      - is the class still in the dex at all, and under its
                                original name (the framework looks them up by name)
  * required **method names** - string-table check for the calls that must survive
                                (a renamed call to a library method would be a
                                NoSuchMethodError on the device)
  * required **resources**    - the accessibility config, which carries the
                                canPerformGestures flag the whole feature hinges on
  * the **dex count against the declared minSdk** - see below

There is a second trap of the same species, and it is about old devices rather than
shrinking. Before Android 5.0 the runtime loads exactly one dex file: classes.dex. An APK
that declares minSdk < 21 and ships classes2.dex will install happily and then die with
NoClassDefFoundError the first time it touches anything in the second file - no multidex
library, no warning, just a crash on the oldest device you own. So the count is compared
against the manifest's own minSdkVersion, which is read back out of the built binary
manifest with aapt2.

Exit code 0 = the APK is intact, 1 = something was shrunk away or cannot load on the
platform it claims to support, 2 = usage/IO error.
"""

import fnmatch
import os
import struct
import subprocess
import sys
import zipfile

# Classes the framework instantiates by name from AndroidManifest.xml, plus the core
# of each subsystem. A missing one means the app is broken in a way no compiler sees.
REQUIRED_CLASSES = [
    # NOTE: framework entry points (activities/services from the manifest) are NOT
    # listed here - check_manifest_components() derives them from the manifest, so a
    # newly declared component cannot be forgotten the way SplashActivity was. This
    # list is for classes the *code* needs, which no manifest can say.

    # the protocol layer: pure Java, so if this is missing the app cannot talk at all
    "damjay/control/ghosthand/net/GhostProtocol",
    "damjay/control/ghosthand/net/FrameCodec",
    "damjay/control/ghosthand/net/Record",
    # host side
    "damjay/control/ghosthand/host/ScreenEncoder",
    "damjay/control/ghosthand/host/ClientHub",
    "damjay/control/ghosthand/host/ClientConnection",
    "damjay/control/ghosthand/host/HostController",
    "damjay/control/ghosthand/host/TouchInjector",
    # guest side
    "damjay/control/ghosthand/guest/GuestController",
    "damjay/control/ghosthand/guest/VideoDecoder",
]

# Method and field names that must appear in the dex string table. These are either
# calls into the framework (which cannot be renamed without becoming a
# NoSuchMethodError at runtime) or lifecycle methods the framework calls by name.
REQUIRED_STRINGS = [
    # MediaProjection / capture
    "getMediaProjection",
    "createVirtualDisplay",
    "startForeground",
    # MediaCodec, both directions
    "createEncoderByType",
    "createDecoderByType",
    # touch injection - the exact call R8 deleted once
    "dispatchGesture",
    "onServiceConnected",
    "onAccessibilityEvent",
    "displaySize",
    # framework callbacks implemented by our components
    "onStartCommand",
    "onConfigurationChanged",
    "onRequestPermissionsResult",
    # the guest -> host control channel
    "onGuestTouch",
    # discovery
    "discoverServices",
]

# Resources that have to survive the link step. These are compiled to binary XML, so
# this is a byte search and not an XML parse - and the encoding differs by file:
# aapt2 writes the manifest's string pool as UTF-16LE while attribute *names* in a
# compiled res XML stay ASCII. Both are tried, so the check cannot silently pass
# because of an encoding guess.
#
# Paths are globs because aapt2 auto-versions XML that uses a newer attribute: it splits
# res/xml/foo.xml into a base file and res/xml-v22/foo.xml, so a device that can honour
# the attribute loads the qualified copy and everyone else gets the plain one. That is
# correct behaviour and it is exactly what happened to the accessibility config when
# minSdk dropped to 19 - the base file no longer carries canPerformGestures, and the
# first version of this check called that a failure. Matching the whole family and
# requiring the symbol in *one* of them is the accurate question to ask.
#
# Note there is no "mediaProjection" here on purpose: aapt2 resolves that attribute
# value to its integer flag (0x20) during compilation, so the *string* is legitimately
# gone from the built manifest. Only values aapt2 cannot resolve stay as text.
REQUIRED_RESOURCE_STRINGS = [
    ("res/xml*/accessibility_service_config.xml", "canPerformGestures"),
    ("AndroidManifest.xml", "InjectionAccessibilityService"),
    ("AndroidManifest.xml", "android.accessibilityservice.AccessibilityService"),
    ("AndroidManifest.xml", "BIND_ACCESSIBILITY_SERVICE"),
    ("AndroidManifest.xml", ".host.ScreenCaptureService"),
]


def fail(message):
    print("\033[31m    FAIL\033[0m %s" % message)
    return 1


def info(message):
    print("    %s" % message)


def declared_min_sdk(apk):
    """The APK's own minSdkVersion, or None if aapt2 is not available to read it."""
    aapt2 = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "toolchain", "vendor", "aapt2")
    if not os.path.exists(aapt2):
        return None
    try:
        out = subprocess.check_output([aapt2, "dump", "badging", apk],
                                      stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return None
    for line in out.decode("utf-8", "replace").splitlines():
        if line.startswith("sdkVersion:"):
            digits = "".join(c for c in line.split(":", 1)[1] if c.isdigit())
            return int(digits) if digits else None
    return None


# ---------------------------------------------------------------------------
# dex self-containment
# ---------------------------------------------------------------------------
#
# The bug this exists for: the first published APK called
# kotlin.jvm.internal.Intrinsics from AppCompatActivity's constructor and did not
# contain that class. R8 had said so - it warns about missing classes - but a
# `-dontwarn kotlin.**` in proguard.pro threw the warning away, the build stayed
# green, and the app died on launch with ClassNotFoundException on a real phone.
#
# R8 now fails on a missing class, and its exceptions are declared one by one in
# proguard.pro. But R8 only reports what it can reach; this check reads the finished
# dex and asks a blunter question: *every* type the APK references under a package
# that must ship inside it - androidx.*, com.google.*, kotlin.*, kotlinx.*,
# org.jetbrains.* and our own damjay.control.ghosthand.* - is it defined in the APK?
# If not, it has to be listed in packaging-allowlist.txt with a reason.
#
# Those are exactly the packages that are neither provided by the platform (android.*,
# java.*) nor optional-at-runtime by design - so a type from one of them that the dex
# names and the APK does not contain is a NoClassDefFoundError waiting for the code
# path that touches it.
APP_SPACE_PREFIXES = ("androidx/", "com/google/", "kotlin/", "kotlinx/",
                      "org/jetbrains/", "damjay/control/ghosthand/")


def dex_types(data):
    """(defined, referenced) type descriptors in one classesN.dex.

    A dex keeps every type it touches in one table (type_ids), so "referenced" is just
    that table: it covers method calls, field accesses, casts, instance creation,
    annotations and superclasses alike. "Defined" is the class_defs table - the types
    that actually live in this dex. No disassembly needed.
    """
    if data[:4] != b"dex\n":
        return set(), set()
    if struct.unpack_from("<I", data, 0x28)[0] != 0x12345678:
        return set(), set()          # reverse-endian dex: never produced here
    string_ids_size, string_ids_off = struct.unpack_from("<II", data, 0x38)
    type_ids_size, type_ids_off = struct.unpack_from("<II", data, 0x40)
    class_defs_size, class_defs_off = struct.unpack_from("<II", data, 0x60)

    def string_at(index):
        (offset,) = struct.unpack_from("<I", data, string_ids_off + 4 * index)
        # MUTF-8 length prefix, then the bytes up to NUL. Only ASCII descriptors
        # matter here, so a lenient decode is safe.
        length, pos = 0, offset
        while data[pos] & 0x80:
            length = (length << 7) | (data[pos] & 0x7F)
            pos += 1
        length = (length << 7) | data[pos]
        return data[pos + 1:pos + 1 + length].decode("utf-8", "replace")

    type_of = lambda i: string_at(struct.unpack_from("<I", data, type_ids_off + 4 * i)[0])
    referenced = {type_of(i) for i in range(type_ids_size)}
    defined = {type_of(struct.unpack_from("<I", data, class_defs_off + 32 * i)[0])
               for i in range(class_defs_size)}
    return defined, referenced


SCOPES = ("both", "release", "debug")


def read_allowlist(path):
    """{descriptor: (scope, reason)} from `<descriptor> [scope] <reason>` lines.

    The scope column is optional and defaults to `both`. `debug` marks an entry that is
    only expected in the unshrunk build, where R8 has not pruned the reference away yet;
    it is still checked for staleness there.
    """
    entries = {}
    if not os.path.exists(path):
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


def declared_debuggable(apk):
    """True/False from the manifest, or None when aapt2 cannot tell us."""
    aapt2 = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "toolchain", "vendor", "aapt2")
    if not os.path.exists(aapt2):
        return None
    try:
        out = subprocess.check_output([aapt2, "dump", "badging", apk],
                                      stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return None
    text = out.decode("utf-8", "replace")
    if "application-debuggable" in text:
        return True
    return False if "application:" in text else None


def matches(type_name, entry):
    """`androidx/window/extensions/**` matches a subtree, a bare name matches exactly."""
    if entry.endswith("**"):
        return type_name.startswith(entry[:-2])
    return type_name == entry


def dex_type_tables(dexes, blobs):
    """(defined, referenced) app-space names across every dex in the APK, stripped."""
    defined, referenced = set(), set()
    for name in dexes:
        d, r = dex_types(blobs[name])
        defined |= {t[1:-1] for t in d}       # Lfoo/Bar; -> foo/Bar, to match below
        referenced |= r
    return defined, referenced


def check_vectors_not_stripped(names, archive):
    """No vector drawable may ship with its base copy gutted by aapt2 versioning.

    With `--min-sdk-version 19` and versioning enabled, aapt2 moves a vector's API-21
    attributes (viewportWidth, fillColor, pathData) into `res/drawable-v21/` and leaves
    the base as a `<vector>` with nothing in it. On a pre-21 device AppCompat's
    VdcInflateDelegate inflates that base first, fails, and the fallback to the platform
    fails too - a Resources$NotFoundException at launch. The release APK shipped exactly
    that way: 59 of 74 drawable pairs were stripped, and the first one AppCompat probed
    (`abc_vector_test`) was the one the log named.

    The test is deliberately narrow: some `res/<qualifier>/name.xml` variant contains
    `viewportWidth` (it is a vector) while the unqualified base does not (it was
    stripped). Qualifier variants that legitimately differ - the accessibility config
    split across xml/xml-v22 - never involve viewportWidth, so they do not trip it.
    """
    import collections
    import re as _re
    groups = collections.defaultdict(dict)
    pattern = _re.compile(r"^res/([^/]+)/([^/]+\.xml)$")
    for name in names:
        match = pattern.match(name)
        if match:
            groups[match.group(2)][match.group(1)] = name
    stripped = []
    for fname, variants in groups.items():
        if "drawable" not in variants or len(variants) < 2:
            continue
        base = archive.read(variants["drawable"])
        if b"viewportWidth" in base:
            continue
        if any(b"viewportWidth" in archive.read(v)
               for q, v in variants.items() if q != "drawable"):
            stripped.append(fname)
    if stripped:
        problems = fail("%d vector drawable(s) ship a stripped base copy - aapt2 moved "
                        "their API-21 attributes to a versioned variant:" % len(stripped))
        for fname in sorted(stripped)[:8]:
            print("      res/drawable/%s" % fname)
        if len(stripped) > 8:
            print("      ... and %d more" % (len(stripped) - 8))
        print("      (pre-21 devices inflate the base file first and die with "
              "Resources$NotFoundException; pass --no-version-vectors to aapt2 link)")
        return problems
    info("no stripped vector bases (aapt2 --no-version-vectors is in effect)")
    return 0


def check_manifest_components(defined, manifest_path):
    """Every component the manifest declares must be a class inside this APK.

    Android instantiates these by name - it does not care what the dex contains beyond
    the name existing - so a missing one is a guaranteed ClassNotFoundException at
    launch, and nothing else in the pipeline sees it: R8 never reads the manifest, the
    manifest's launcher line comes from the manifest, and the dex is perfectly valid
    without the class. This shipped once, exactly that way.

    The parser is the same one toolchain/manifest_keep.py uses to generate R8's keep
    rules, deliberately: two parsers that agree are one parser with two callers, and
    two that disagree would let the generator and the gate drift apart.
    """
    if not os.path.exists(manifest_path):
        info("no manifest at %s - component check skipped" % manifest_path)
        return 0
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "toolchain"))
    from manifest_keep import components          # noqa: E402  (path set just above)
    try:
        _, found = components(open(manifest_path, encoding="utf-8").read(), manifest_path)
    except SystemExit as exc:
        return fail("cannot parse %s: %s" % (manifest_path, exc))
    if not found:
        return fail("%s declares no components at all - the parser is looking at the "
                    "wrong file" % manifest_path)
    missing = [cls for _, cls in found if cls.replace(".", "/") not in defined]
    if missing:
        problems = fail("%d manifest component(s) Android would instantiate are not in "
                        "this APK:" % len(missing))
        for cls in missing:
            print("      %s" % cls)
        print("      (R8 never reads the manifest, so it deletes classes only the "
              "framework instantiates; toolchain/manifest_keep.py keeps them - "
              "this is how the release APK shipped unable to launch)")
        return problems
    info("%d manifest components present (%s)"
         % (len(found), ", ".join(sorted({t for t, _ in found}))))
    return 0


def check_self_contained(defined, referenced, allowlist_path, kind):
    """Every app-space type the dex references must be in the APK or declared absent.

    `kind` is "release", "debug" or None (unknown): it decides which allowlist entries
    are expected in this artifact.
    """
    declared = read_allowlist(allowlist_path)
    # Entries that apply here. With an unknown configuration every entry is a candidate
    # (coverage is the point) but staleness cannot be judged, so it is not.
    allow = {k: reason for k, (scope, reason) in declared.items()
             if kind is None or scope in ("both", kind)}
    used = set()
    missing = []
    for type_name in referenced:
        if not type_name.startswith("L"):
            continue
        name = type_name[1:-1]                      # Lfoo/Bar; -> foo/Bar
        if not name.startswith(APP_SPACE_PREFIXES):
            continue
        if name in defined:
            continue
        hits = [e for e in allow if matches(name, e)]
        if hits:
            used.update(hits)
            continue
        missing.append(name)

    problems = 0
    if missing:
        problems += fail("%d type(s) the dex references are not in the APK and are not "
                         "declared absent:" % len(missing))
        for name in sorted(missing)[:15]:
            print("      %s" % name)
        if len(missing) > 15:
            print("      ... and %d more" % (len(missing) - 15))
        print("      (a missing class is a NoClassDefFoundError on the code path that "
              "touches it; add the library, or declare it in packaging-allowlist.txt "
              "with a reason)")

    # An exemption that no longer suppresses anything is how the last one hid a real
    # missing class: it stayed while the code around it changed.
    stale = sorted(set(allow) - used) if kind is not None else []
    if stale:
        problems += fail("%d allowlist entr(y/ies) in packaging-allowlist.txt no longer "
                         "suppress anything - delete them:" % len(stale))
        for entry in stale[:10]:
            print("      %s" % entry)

    if not problems:
        info("%d types defined, %d referenced; every app-space reference is present%s"
             % (len(defined), len(referenced),
                "" if not allow else " (%d declared absent)" % len(allow)))
    return problems


def main(argv):
    apk = argv[1] if len(argv) > 1 else "app/build/app.apk"
    try:
        archive = zipfile.ZipFile(apk)
    except (OSError, zipfile.BadZipFile) as exc:
        print("cannot read %s: %s" % (apk, exc), file=sys.stderr)
        return 2

    names = archive.namelist()
    dexes = sorted(n for n in names if n.endswith(".dex"))
    if not dexes:
        return fail("%s contains no classes.dex" % apk)

    dex_bytes = b"".join(archive.read(n) for n in dexes)
    print("    %s: %d dex, %d entries, %.1f MB of dex"
          % (apk, len(dexes), len(names), len(dex_bytes) / 1048576.0))

    problems = 0

    missing_classes = [c for c in REQUIRED_CLASSES
                       if ("L%s;" % c).encode() not in dex_bytes]
    if missing_classes:
        for c in missing_classes:
            problems += fail("class shrunk away or renamed: %s" % c)
        print("    (fix: a -keep rule in app/proguard.pro for each class above)")

    missing_strings = [s for s in REQUIRED_STRINGS if s.encode() not in dex_bytes]
    if missing_strings:
        for s in missing_strings:
            problems += fail("no reference to '%s' anywhere in the dex" % s)
        print("    (fix: a -keep rule covering the class that makes this call -"
              " R8 deletes the caller when it cannot see the callee as reachable)")

    # ------------------------------------------------------------------ dex count
    #
    # Dalvik (API < 21) loads classes.dex and nothing else. A min-api-19 APK with a
    # classes2.dex is therefore broken on exactly the devices it claims to support,
    # and nothing else in the toolchain notices: the dex is valid, the signature is
    # valid, the manifest is valid.
    min_sdk = declared_min_sdk(apk)
    if min_sdk is None:
        info("minSdkVersion not read (no aapt2 in toolchain/vendor) - "
             "dex count not checked against it")
    elif min_sdk < 21 and len(dexes) > 1:
        problems += fail("%d dex files but minSdkVersion is %d: Android < 5.0 loads only "
                         "classes.dex, so everything in %s would be missing at runtime"
                         % (len(dexes), min_sdk, ", ".join(dexes[1:])))
        print("    (fix: this configuration must fit in one dex - shrink it (R8), or "
              "declare minSdk 21+ so the platform loads the extra files natively)")
    else:
        info("minSdkVersion %d, %d dex file(s) - %s"
             % (min_sdk, len(dexes),
                "loadable on any supported device" if len(dexes) == 1
                else "needs native multidex (API 21+), which this build declares"))

    # ------------------------------------------------- dex self-containment
    blobs = {name: archive.read(name) for name in dexes}
    defined, referenced = dex_type_tables(dexes, blobs)
    debuggable = declared_debuggable(apk)
    problems += check_self_contained(
        defined, referenced,
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "packaging-allowlist.txt"),
        None if debuggable is None else ("debug" if debuggable else "release"))

    # ------------------------------------------------- vector base files
    problems += check_vectors_not_stripped(names, archive)

    # ------------------------------------------------- manifest components
    problems += check_manifest_components(
        defined,
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "app", "src", "main", "AndroidManifest.xml"))

    for pattern, needle in REQUIRED_RESOURCE_STRINGS:
        entries = [n for n in names if fnmatch.fnmatch(n, pattern)]
        if not entries:
            problems += fail("no entry in the APK matches %s" % pattern)
            continue
        ascii_needle = needle.encode()
        utf16_needle = needle.encode("utf-16-le")
        found = [n for n in entries
                 if ascii_needle in archive.read(n) or utf16_needle in archive.read(n)]
        if not found:
            problems += fail("%s no longer contains '%s' in any variant (%s)"
                             % (pattern, needle, ", ".join(entries)))
        elif len(entries) > 1:
            info("%s: '%s' present in %s - aapt2 version-qualified this resource, "
                 "which is how a newer attribute legally survives a low minSdk "
                 "(older devices load %s)"
                 % (pattern, needle, ", ".join(sorted(found)),
                    ", ".join(sorted(set(entries) - set(found))) or "nothing"))

    if problems:
        print("\033[31mAPK VERIFY FAILED\033[0m  (%d problem(s)) - do not install or "
              "publish this build" % problems)
        return 1

    print("\033[32m    ok\033[0m  APK VERIFY PASSED  (%d classes, %d call strings, "
          "%d resources present, dex self-contained)"
          % (len(REQUIRED_CLASSES), len(REQUIRED_STRINGS),
             len(REQUIRED_RESOURCE_STRINGS)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
