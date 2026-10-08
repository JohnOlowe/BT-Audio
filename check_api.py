#!/usr/bin/env python3
"""check_api.py -- does every framework call this app makes exist on the API it claims?

    python3 check_api.py app/build/stage/classes --min-api 19 \
        --android-jar toolchain/vendor/android-19.jar \
        [--apk app/build/app.apk] [--allowlist api-levels.txt] [--list-guarded]

Why this exists
---------------
Setting minSdkVersion is a promise, and nothing in this toolchain checks it. The Java
compiler compiles against API 34's android.jar, so `codec.getInputBuffer(i)` - a method
that does not exist below API 21 - compiles cleanly and dexes cleanly. On an Android 4.4
phone it is not a compile error and not a lint warning here; it is NoSuchMethodError, at
run time, on the device, in the one place you cannot debug.

Android Studio answers this with lint's NewApi check, which reads annotations baked into
the SDK. There is no lint here, so this does the same job from the artifact: it reads the
constant pool of every compiled class, keeps the references into android.* (and java.*),
and asks a real API 19 android.jar whether each one exists. Method and field lookups walk
the superclass and interface chain, exactly like the JVM's own resolution, so inherited
methods are not false positives.

References that name an androidx/kotlin *owner* are resolved through the bundled library
class files the same way, instead of being trusted: the compiler records the static
receiver type as the owner, so `widget.setButtonTintList(...)` on an AppCompat type shows
up as an androidx reference that the runtime then resolves up the hierarchy into the
framework - and if the framework method is newer than the app's floor, that is a device
crash no class-file check would otherwise see (this is how vc12 shipped one).

What is *not* a violation
-------------------------
Two kinds of newer-API reference are legitimate, and both must be declared in the
allowlist file with a reason and the API level they need:

  * code behind an `if (Build.VERSION.SDK_INT >= N)` check, in a class whose whole job is
    to hold that check (the AndroidX `Api21Impl` pattern - here `util/CodecCompat`),
  * code in a class that is only ever *loaded* on a newer platform: the host role
    (API 21+) or the gesture dispatcher (API 24+), which the app refuses to enter on
    older devices.

`java/lang/invoke/LambdaMetafactory` is skipped on purpose: lambdas are compiled to
`invokedynamic` and then *desugared* by D8 for old API levels. The dex is checked
separately (`--apk`) to prove that desugaring actually happened, because a lambda that
survives into a min-api-19 dex is a NoClassDefFoundError on the device.

Exit code 0 = every reference is available, 1 = something is not (or an allowlist entry
is stale), 2 = usage/IO error.
"""

import os
import struct
import sys
import zipfile

# --------------------------------------------------------------------------- JVM class

_CP_UTF8, _CP_INT, _CP_FLOAT, _CP_LONG, _CP_DOUBLE = 1, 3, 4, 5, 6
_CP_CLASS, _CP_STRING = 7, 8
_CP_FIELDREF, _CP_METHODREF, _CP_IFACEREF, _CP_NAMEANDTYPE = 9, 10, 11, 12
_CP_METHODHANDLE, _CP_METHODTYPE, _CP_DYNAMIC, _CP_INVOKEDYNAMIC = 15, 16, 17, 18
_CP_MODULE, _CP_PACKAGE = 19, 20

_TWO_U2 = (_CP_CLASS, _CP_STRING, _CP_METHODTYPE, _CP_MODULE, _CP_PACKAGE)
_TWO_U2_PLUS_TAG = (_CP_FIELDREF, _CP_METHODREF, _CP_IFACEREF, _CP_NAMEANDTYPE,
                    _CP_DYNAMIC, _CP_INVOKEDYNAMIC)


def _u2(data, i):
    return struct.unpack_from(">H", data, i)[0], i + 2


def _u4(data, i):
    return struct.unpack_from(">I", data, i)[0], i + 4


def _skip_attributes(data, i):
    count, i = _u2(data, i)
    for _ in range(count):
        _name, i = _u2(data, i)
        length, i = _u4(data, i)
        i += length
    return i


def parse_class(data, with_refs=True):
    """Minimal class-file reader: names, hierarchy, members, and constant-pool refs."""
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("not a class file")
    i = 8
    cp_count, i = _u2(data, i)
    cp = [None] * cp_count
    k = 1
    while k < cp_count:
        tag = data[i]
        i += 1
        if tag == _CP_UTF8:
            length, i = _u2(data, i)
            cp[k] = ("utf8", data[i:i + length].decode("utf-8", "replace"))
            i += length
        elif tag in (_CP_INT, _CP_FLOAT):
            cp[k] = (tag, _u4(data, i)[0])
            i += 4
        elif tag in (_CP_LONG, _CP_DOUBLE):
            cp[k] = (tag, 0)
            i += 8
            k += 1                      # longs and doubles take two constant-pool slots
        elif tag in _TWO_U2:
            a, i = _u2(data, i)
            cp[k] = (tag, a)
        elif tag in _TWO_U2_PLUS_TAG:
            a, i = _u2(data, i)
            b, i = _u2(data, i)
            cp[k] = (tag, a, b)
        elif tag == _CP_METHODHANDLE:
            i += 1
            a, i = _u2(data, i)
            cp[k] = (tag, a)
        else:
            raise ValueError("unknown constant pool tag %d" % tag)
        k += 1

    def utf8(idx):
        return cp[idx][1]

    def class_name(idx):
        return utf8(cp[idx][1])

    _access, i = _u2(data, i)
    _this, i = _u2(data, i)
    this_class = class_name(_this)
    super_index, i = _u2(data, i)
    super_class = class_name(super_index) if super_index else None
    iface_count, i = _u2(data, i)
    interfaces = []
    for _ in range(iface_count):
        idx, i = _u2(data, i)
        interfaces.append(class_name(idx))

    fields = set()
    field_count, i = _u2(data, i)
    for _ in range(field_count):
        _acc, i = _u2(data, i)
        name_idx, i = _u2(data, i)
        desc_idx, i = _u2(data, i)
        fields.add((utf8(name_idx), utf8(desc_idx)))
        i = _skip_attributes(data, i)

    methods = set()
    method_count, i = _u2(data, i)
    for _ in range(method_count):
        _acc, i = _u2(data, i)
        name_idx, i = _u2(data, i)
        desc_idx, i = _u2(data, i)
        methods.add((utf8(name_idx), utf8(desc_idx)))
        i = _skip_attributes(data, i)

    refs = {"types": set(), "methods": set(), "fields": set()}
    if with_refs:
        for entry in cp:
            if entry is None:
                continue
            tag = entry[0]
            if tag == _CP_CLASS:
                # entry[1] is the Utf8 index of the name, not another Class entry
                refs["types"].add(utf8(entry[1]))
            elif tag == _CP_FIELDREF or tag == _CP_METHODREF or tag == _CP_IFACEREF:
                owner = class_name(entry[1])
                nat = cp[entry[2]]
                name, desc = utf8(nat[1]), utf8(nat[2])
                key = (owner, name, desc)
                refs["fields" if tag == _CP_FIELDREF else "methods"].add(key)

    return {
        "name": this_class,
        "super": super_class,
        "interfaces": interfaces,
        "fields": fields,
        "methods": methods,
        "refs": refs,
    }


# ------------------------------------------------------------------- reference symbols

class Platform(object):
    """The reference android.jar, parsed on demand and cached."""

    def __init__(self, path, label):
        self.zip = zipfile.ZipFile(path)
        self.label = label
        self.cache = {}
        self._entries = set(self.zip.namelist())

    def symbols(self, class_name):
        """Members of a class as declared in the reference jar, or None if absent."""
        if class_name in self.cache:
            return self.cache[class_name]
        entry = class_name + ".class"
        info = None
        if entry in self._entries:
            try:
                info = parse_class(self.zip.read(entry), with_refs=False)
            except (ValueError, struct.error, IndexError):
                info = None
        self.cache[class_name] = info
        return info

    def has_class(self, class_name):
        return self.symbols(class_name) is not None

    def has_member(self, class_name, name, descriptor, kind):
        """Resolves like the JVM: the member may be declared in a supertype."""
        pending = [class_name]
        seen = set()
        while pending:
            current = pending.pop()
            if current is None or current in seen:
                continue
            seen.add(current)
            info = self.symbols(current)
            if info is None:
                return None             # the *class* is missing; reported separately
            members = info["methods"] if kind == "method" else info["fields"]
            if (name, descriptor) in members:
                return True
            pending.append(info.get("super"))
            pending.extend(info.get("interfaces") or [])
        return False


# ------------------------------------------------------------------------ the app side

IGNORED_PREFIXES = (
    "damjay/",            # our own classes (and R)
    "androidx/",          # libraries that declare their own minSdk (all of ours say 14)
    "kotlin/",
)

# A class file that contains a lambda mentions java.lang.invoke.* in its constant pool:
# that is the bootstrap method the compiler emitted, not something the app calls. D8
# rewrites those to synthetic classes for old API levels, which is why the whole package
# is skipped here and *proved* separately on the dex (check_dex below) - if the
# rewrite did not happen, the dex still has invoke-custom and that check fails.
DESUGARING_PACKAGE = "java/lang/invoke/"


def app_classes(classes_dir):
    for root, _dirs, files in os.walk(classes_dir):
        for name in sorted(files):
            if name.endswith(".class"):
                yield os.path.join(root, name)


# Compiled library classes are indexed here on first use: owner references that
# name an androidx/kotlin class have to be resolved THROUGH that class file, not
# trusted, because ECJ records the static receiver type as the reference owner -
# so `((AppCompatRadioButton) x).setButtonTintList(...)` is an androidx-owned
# reference in the class file that resolves to a FRAMEWORK method at runtime.
_LIB_INDEX = None       # entry name (androidx/foo/Bar.class) -> jar that holds it
_LIB_CACHE = {}         # class name -> parsed info (or None when unreadable)


def _lib_index():
    global _LIB_INDEX
    if _LIB_INDEX is None:
        _LIB_INDEX = {}
        base = os.path.dirname(os.path.abspath(__file__))
        vendor = os.path.join(base, "toolchain", "vendor")
        if not os.path.isdir(vendor):
            vendor = os.path.join(base, "vendor")
        if os.path.isdir(vendor):
            jars = []
            for dirpath, _, files in os.walk(vendor):
                for filename in files:
                    if filename.endswith(".jar"):
                        jars.append(os.path.join(dirpath, filename))
            for jar in sorted(jars):
                try:
                    zf = zipfile.ZipFile(jar)
                except (OSError, zipfile.BadZipFile):
                    continue
                for entry in zf.namelist():
                    if entry.endswith(".class") and entry not in _LIB_INDEX:
                        _LIB_INDEX[entry] = (jar, entry)
    return _LIB_INDEX


def lib_class(class_name):
    """Parsed class file of a bundled library class, or None if we cannot read it."""
    if class_name in _LIB_CACHE:
        return _LIB_CACHE[class_name]
    info = None
    hit = _lib_index().get(class_name + ".class")
    if hit:
        jar, entry = hit
        try:
            with zipfile.ZipFile(jar) as zf:
                info = parse_class(zf.read(entry), with_refs=False)
        except (OSError, ValueError, struct.error, IndexError, KeyError):
            info = None
    _LIB_CACHE[class_name] = info
    return info


def is_platform_reference(owner):
    if owner.startswith("["):                       # array type
        return False
    if owner.startswith(IGNORED_PREFIXES):
        return False
    return owner.startswith("android/") or owner.startswith("java/") \
        or owner.startswith("javax/") or owner.startswith("org/xml") \
        or owner.startswith("org/json") or owner.startswith("org/apache/http")


def load_allowlist(path):
    """Lines: <symbol-pattern> <min-api> <reason...>; '#' comments and blanks ignored."""
    entries = []
    if not path or not os.path.exists(path):
        return entries
    with open(path) as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 2)
            if len(parts) < 2:
                print("api-levels.txt:%d: expected '<symbol> <min-api> <reason>'" % number,
                      file=sys.stderr)
                continue
            try:
                min_api = int(parts[1])
            except ValueError:
                print("api-levels.txt:%d: min-api '%s' is not a number" % (number, parts[1]),
                      file=sys.stderr)
                continue
            entries.append({"pattern": parts[0], "min_api": min_api,
                            "reason": parts[2] if len(parts) > 2 else "", "line": number})
    return entries


def allowlist_match(entries, candidates):
    for entry in entries:
        for candidate in candidates:
            if entry["pattern"] == candidate:
                return entry
            if entry["pattern"].endswith("#*") and candidate.startswith(
                    entry["pattern"][:-1]):
                return entry
            if "#" not in entry["pattern"] and candidate.split("#", 1)[0] == entry["pattern"]:
                return entry
    return None


def short(class_name):
    """damjay/control/ghosthand/guest/VideoDecoder$1 -> guest/VideoDecoder$1"""
    prefix = "damjay/control/ghosthand/"
    return class_name[len(prefix):] if class_name.startswith(prefix) else class_name


# ------------------------------------------------------------------------ dex sanity

def dex_map_types(data):
    """The item types present in a dex file's map_list (to spot invoke-custom)."""
    if len(data) < 0x40 or data[:4] != b"dex\n":
        return None
    map_off = struct.unpack_from("<I", data, 0x34)[0]
    if map_off == 0 or map_off >= len(data):
        return set()
    size = struct.unpack_from("<I", data, map_off)[0]
    types = set()
    for index in range(size):
        offset = map_off + 4 + index * 12
        if offset + 12 > len(data):
            break
        item_type = struct.unpack_from("<H", data, offset)[0]
        types.add(item_type)
    return types


_CALL_SITE_ID, _METHOD_HANDLE = 0x0007, 0x0008


def check_dex(apk, min_api, problems):
    """A min-api-19 dex must not contain invoke-custom: lambdas have to be desugared."""
    with zipfile.ZipFile(apk) as archive:
        dexes = sorted(n for n in archive.namelist() if n.endswith(".dex"))
        total = 0
        for name in dexes:
            types = dex_map_types(archive.read(name))
            if types is None:
                continue
            if _CALL_SITE_ID in types or _METHOD_HANDLE in types:
                total += 1
        if total and min_api < 26:
            problems.append(
                "%d dex file(s) still contain invoke-custom / method handles, but "
                "minSdk is %d: D8 desugars lambdas below API 26, so something survived "
                "desugaring and will fail with NoClassDefFoundError on old devices"
                % (total, min_api))
        elif not total:
            print("    ok  no invoke-custom in the dex - lambdas were desugared for "
                  "API %d" % min_api)


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2

    classes_dir = argv[1]
    min_api = 19
    android_jar = None
    apk = None
    allowlist_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "api-levels.txt")
    list_guarded = False

    index = 2
    while index < len(argv):
        option = argv[index]
        if option == "--min-api":
            min_api = int(argv[index + 1]); index += 2
        elif option == "--android-jar":
            android_jar = argv[index + 1]; index += 2
        elif option == "--apk":
            apk = argv[index + 1]; index += 2
        elif option == "--allowlist":
            allowlist_path = argv[index + 1]; index += 2
        elif option == "--list-guarded":
            list_guarded = True; index += 1
        else:
            print("unknown option: %s" % option, file=sys.stderr)
            return 2

    if not android_jar or not os.path.exists(android_jar):
        print("need a reference platform jar: --android-jar toolchain/vendor/"
              "android-%d.jar" % min_api, file=sys.stderr)
        print("(toolchain/setup.sh fetches it for any API level)", file=sys.stderr)
        return 2

    platform = Platform(android_jar, os.path.basename(android_jar))
    allowlist = load_allowlist(allowlist_path)
    print("    checking %s at API %d against %s"
          % (classes_dir, min_api, os.path.basename(android_jar)))

    problems = []
    guarded = {}
    stale = {entry["line"]: entry for entry in allowlist}
    checked = skipped = 0

    # Two passes: every class is parsed first, because resolving a call on one of our
    # own types means walking our own hierarchy (see resolve_through_our_classes).
    parsed = []
    app = {}
    for path in app_classes(classes_dir):
        try:
            info = parse_class(open(path, "rb").read())
        except (ValueError, struct.error, IndexError) as exc:
            problems.append("%s: unreadable class file (%s)" % (path, exc))
            continue
        parsed.append(info)
        app[info["name"]] = info

    def resolve_through_our_classes(owner, name, descriptor, kind):
        """A call on one of our types may resolve into a framework superclass.

        `service.dispatchGesture(...)` on our AccessibilityService subclass is recorded
        in the bytecode as a call on *our* class, and the JVM resolves it by searching
        the hierarchy - so if the only thing that can provide it is an android.* class,
        that class had better have it. Skipping every reference whose owner is ours
        would hide exactly the calls this tool exists to find.

        The search is exhaustive across the whole class graph (supers AND
        interfaces, breadth-first): a platform class that LACKS the member does not
        end the search, because a sibling branch (or a deeper superclass) may still
        provide it - stopping early produced false alarms on interface branches.
        A platform class that HAS it wins immediately; the verdict at exhaustion is
        "absent" only when some platform branch said so and nothing was unreadable
        (unreadable library or runtime-generated class = cannot disprove = silent).
        """
        pending = [owner]
        seen = set()
        absent_at = None
        uncertain = False
        while pending:
            current = pending.pop(0)
            if current is None or current in seen:
                continue
            seen.add(current)
            if current.startswith("damjay/"):
                info = app.get(current)
                if info is None:
                    uncertain = True                 # generated at runtime; nothing to say
                    continue
                members = info["methods"] if kind == "method" else info["fields"]
                if (name, descriptor) in members:
                    return True, None               # our own method: fine
                pending.append(info.get("super"))
                pending.extend(info.get("interfaces") or [])
            elif current.startswith("androidx/") or current.startswith("kotlin/"):
                # Only the library's OWN declarations are its promise. A framework
                # method merely inherited into it (the ECJ static-receiver-ref quirk
                # above) is a runtime dependency on the platform: keep walking - to
                # the library's own members (fine), its supers (maybe still library),
                # or the framework (checked against the real android-19 jar).
                info = lib_class(current)
                if info is None:
                    uncertain = True                # unreadable: cannot disprove
                    continue
                members = info["methods"] if kind == "method" else info["fields"]
                if (name, descriptor) in members:
                    return True, None
                pending.append(info.get("super"))
                pending.extend(info.get("interfaces") or [])
            elif is_platform_reference(current):
                # The platform class is the real API dependency; if it supplies the
                # member (walking its own supers, like the JVM), we are done. If not,
                # remember it as evidence of absence but keep exploring - another
                # branch of the graph may still prove the member exists.
                has = platform.has_member(current, name, descriptor, kind)
                if has:
                    return True, None
                if has is None:
                    uncertain = True                # class missing from the jar
                elif absent_at is None:
                    absent_at = current
            else:
                uncertain = True
        if absent_at is not None and not uncertain:
            return False, absent_at
        return None, None

    for info in parsed:
        owner = info["name"]

        reports = []
        for referenced in sorted(info["refs"]["types"]):
            if is_platform_reference(referenced) and not platform.has_class(referenced):
                reports.append((referenced, None, None, "type", None))
        for referenced, name, descriptor in sorted(info["refs"]["methods"]):
            if is_platform_reference(referenced):
                result, platform_owner = platform.has_member(
                    referenced, name, descriptor, "method"), None
            else:
                result, platform_owner = resolve_through_our_classes(
                    referenced, name, descriptor, "method")
            if result is False:
                reports.append((platform_owner or referenced, name, descriptor, "method",
                                referenced))
        for referenced, name, descriptor in sorted(info["refs"]["fields"]):
            if is_platform_reference(referenced):
                result, platform_owner = platform.has_member(
                    referenced, name, descriptor, "field"), None
            else:
                result, platform_owner = resolve_through_our_classes(
                    referenced, name, descriptor, "field")
            if result is False:
                reports.append((platform_owner or referenced, name, descriptor, "field",
                                referenced))

        for referenced, name, descriptor, kind, called_on in reports:
            if kind == "type":
                candidates = [referenced]
                text = "%s" % referenced
            else:
                candidates = ["%s#%s(%s)" % (referenced, name, descriptor),
                              "%s#%s" % (referenced, name)]
                text = "%s#%s" % (referenced, name)
                if called_on and called_on != referenced:
                    # an inherited framework method called through our subclass
                    text += " (called on %s)" % short(called_on)
                    candidates.append("%s#%s" % (short(called_on), name))
            checked += 1
            if referenced.startswith(DESUGARING_PACKAGE):
                skipped += 1
                continue
            entry = allowlist_match(allowlist, candidates)
            if entry:
                guarded.setdefault(entry["line"], []).append(short(owner))
                stale.pop(entry["line"], None)
            else:
                problems.append("%s is not in %s (used by %s) [%s]"
                                % (text, os.path.basename(android_jar), short(owner),
                                   kind))

    # An allowlist entry that nothing references any more is a stale promise: the guard
    # it documents has gone, and the next reader would trust it.
    for line, entry in sorted(stale.items()):
        problems.append("api-levels.txt:%d: '%s' is no longer referenced by any class - "
                        "delete the exemption" % (line, entry["pattern"]))

    if list_guarded or guarded:
        print("    guarded exemptions in use (%d):" % len(guarded))
        by_pattern = {entry["line"]: entry for entry in allowlist}
        for line in sorted(guarded):
            entry = by_pattern[line]
            print("      api %2d  %-58s  <- %s"
                  % (entry["min_api"], entry["pattern"],
                     ", ".join(sorted(set(guarded[line]))[:3])))
        for entry in allowlist:
            if entry["min_api"] <= min_api:
                print("      note: api-levels.txt:%d declares API %d, which is not newer "
                      "than the minimum %d - it is dead weight"
                      % (entry["line"], entry["min_api"], min_api))

    if apk:
        check_dex(apk, min_api, problems)

    if problems:
        print()
        for problem in problems:
            print("    \033[31mFAIL\033[0m %s" % problem)
        print("\n\033[31mAPI CHECK FAILED\033[0m  (%d problem(s)) - these would throw "
              "NoSuchMethodError / NoClassDefFoundError on API %d"
              % (len(problems), min_api))
        return 1

    print("    \033[32mok\033[0m  API CHECK PASSED  (every framework reference exists on "
          "API %d; %d newer symbols exempted in api-levels.txt, %d lambda/desugaring "
          "references ignored)"
          % (min_api, len(guarded), skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
