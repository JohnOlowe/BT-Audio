#!/usr/bin/env python3
"""zipalign.py -- pure-Python reimplementation of Android's zipalign for APKs.

Why: the SDK's `zipalign` is a build-tools binary, and build-tools cannot be
downloaded in this sandbox (dl.google.com / maven.google.com are blocked; the
Linux ARM64 `zipalign`s found on GitHub are Android/bionic ELFs that will not
run on glibc).  The algorithm is small and fully specified, so we do it
ourselves: rewrite the zip so the data of every entry starts on a 4-byte
boundary (and .so entries on a 4096-byte page boundary with -p), without
recompressing anything.

Usage:
    python3 zipalign.py -f 4 in.apk out.apk
    python3 zipalign.py -f -p 4 in.apk out.apk
    python3 zipalign.py -c -v in.apk          # check only

Exit codes: 0 ok, 1 check failed, 2 usage/IO error.
"""

import argparse
import os
import re
import struct
import sys

LFH_SIG = b"PK\x03\x04"
CDH_SIG = b"PK\x01\x02"
EOCD_SIG = b"PK\x05\x06"
LFH_LEN = 30
CDH_LEN = 46
# Extra-field id Android's zipalign uses for alignment padding.
ZIPALIGN_EXTRA_ID = 0xD935
PAGE = 4096


def _u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def _u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


class Entry(object):
    __slots__ = ("name", "flag", "method", "mtime", "mdate", "crc", "csize",
                 "usize", "l_extra", "c_extra", "comment", "ext_attrs", "off",
                 "raw", "data_off", "new_off")


def read_zip(path):
    """Parse a zip by walking the central directory. Returns (entries, comment)."""
    with open(path, "rb") as fh:
        blob = fh.read()

    eocd = blob.rfind(EOCD_SIG)
    if eocd < 0:
        raise ValueError("not a zip file (no EOCD)")
    if _u16(blob, eocd + 8) or _u16(blob, eocd + 10) or _u32(blob, eocd + 12) != 0xFFFFFFFF:
        pass  # multi-disk / zip64 are not used by APKs; values are read below
    cd_count = _u16(blob, eocd + 10)
    cd_off = _u32(blob, eocd + 16)
    comment = blob[eocd + 22: eocd + 22 + _u16(blob, eocd + 20)]

    entries = []
    pos = cd_off
    for _ in range(cd_count):
        if blob[pos:pos + 4] != CDH_SIG:
            raise ValueError("bad central directory entry at %d" % pos)
        e = Entry()
        e.flag = _u16(blob, pos + 8)
        e.method = _u16(blob, pos + 10)
        e.mtime = _u16(blob, pos + 12)
        e.mdate = _u16(blob, pos + 14)
        e.crc = _u32(blob, pos + 16)
        e.csize = _u32(blob, pos + 20)
        e.usize = _u32(blob, pos + 24)
        nlen = _u16(blob, pos + 28)
        elen = _u16(blob, pos + 30)
        clen = _u16(blob, pos + 32)
        e.ext_attrs = _u32(blob, pos + 38)
        e.off = _u32(blob, pos + 42)
        e.name = blob[pos + CDH_LEN: pos + CDH_LEN + nlen].decode("utf-8", "replace")
        e.c_extra = blob[pos + CDH_LEN + nlen: pos + CDH_LEN + nlen + elen]
        e.comment = blob[pos + CDH_LEN + nlen + elen:
                         pos + CDH_LEN + nlen + elen + clen]

        lh = e.off
        if blob[lh:lh + 4] != LFH_SIG:
            raise ValueError("bad local header for %s" % e.name)
        l_nlen = _u16(blob, lh + 26)
        l_elen = _u16(blob, lh + 28)
        e.l_extra = blob[lh + LFH_LEN + l_nlen: lh + LFH_LEN + l_nlen + l_elen]
        e.data_off = lh + LFH_LEN + l_nlen + l_elen
        e.raw = blob[e.data_off: e.data_off + e.csize]
        if len(e.raw) != e.csize:
            raise ValueError("truncated entry %s" % e.name)
        entries.append(e)
        pos += CDH_LEN + nlen + elen + clen
    return entries, comment


def _extra_with_padding(extra, pad):
    """Return `extra` grown by `pad` bytes, kept structurally valid."""
    if pad <= 0:
        return extra
    if pad < 4:
        return extra + b"\x00" * pad          # not enough room for a field header
    return extra + struct.pack("<HH", ZIPALIGN_EXTRA_ID, pad - 4) + b"\x00" * (pad - 4)


def write_aligned(entries, comment, out_path, alignment=4, page_align=False):
    out = bytearray()
    cd = bytearray()
    for e in entries:
        name = e.name.encode("utf-8")
        align = PAGE if (page_align and e.name.endswith(".so")) else alignment
        header_len = LFH_LEN + len(name) + len(e.l_extra)
        pad = (-(len(out) + header_len)) % align
        extra = _extra_with_padding(e.l_extra, pad)
        e.new_off = len(out)
        e.data_off = len(out) + LFH_LEN + len(name) + len(extra)

        out += LFH_SIG
        out += struct.pack("<HHHHHIIIHH", 20, e.flag, e.method, e.mtime, e.mdate,
                           e.crc, e.csize, e.usize, len(name), len(extra))
        out += name
        out += extra
        out += e.raw

        hdr = bytearray(CDH_LEN)
        struct.pack_into("<IHHHHHHIII", hdr, 0, 0x02014B50, 20, 20, e.flag,
                         e.method, e.mtime, e.mdate, e.crc, e.csize, e.usize)
        struct.pack_into("<HHHHHII", hdr, 28, len(name), len(e.c_extra),
                         len(e.comment), 0, 0, e.ext_attrs, e.new_off)
        cd += hdr + name + e.c_extra + e.comment

    cd_off = len(out)
    out += cd
    out += EOCD_SIG
    out += struct.pack("<HHHHIIH", 0, 0, len(entries), len(entries),
                       len(cd), cd_off, len(comment))
    out += comment
    with open(out_path, "wb") as fh:
        fh.write(out)
    return out_path


def check(path, alignment=4, page_align=False, ignore=None):
    """`ignore` is a compiled regex; matching entries are skipped.

    apksigner's v1 (JAR) signatures are written after alignment, so META-INF/*
    is always unaligned -- callers pass ignore=re.compile('^META-INF/') when
    checking a signed APK.
    """
    entries, _ = read_zip(path)
    bad = []
    for e in entries:
        if ignore and ignore.search(e.name):
            continue
        align = PAGE if (page_align and e.name.endswith(".so")) else alignment
        if e.data_off % align:
            bad.append((e.name, e.data_off % align, align))
    return entries, bad


def main(argv=None):
    ap = argparse.ArgumentParser(description="pure-Python zipalign for APKs")
    ap.add_argument("-f", "--force", action="store_true", help="overwrite output")
    ap.add_argument("-p", "--page-align-shared-libs", action="store_true")
    ap.add_argument("-c", "--check", action="store_true", help="check only")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("-a", "--alignment", type=int, default=None,
                    help="alignment in bytes (default 4, Android's own default)")
    ap.add_argument("--ignore-regex", default=None,
                    help="skip entries matching this regex when checking "
                         "(e.g. '^META-INF/' for v1-signed APKs)")
    # NOTE: the positional list is collected from parse_known_args() below.
    # argparse cannot mix `nargs="+"` positionals with options placed between
    # them ("unrecognized arguments"), and Android's own CLI is
    # `zipalign -f [-p] 4 in.apk out.apk`, which does exactly that.
    ap.add_argument("paths", nargs="*", metavar="[ALIGNMENT] IN [OUT]",
                    help="Android-compatible: a leading bare number is taken as "
                         "the alignment, then the input file, then the output")
    a, unknown = ap.parse_known_args(argv)
    bad = [u for u in unknown if u.startswith("-")]
    if bad:
        ap.error("unrecognized arguments: %s" % " ".join(bad))
    paths = list(a.paths) + list(unknown)
    align = a.alignment if a.alignment else 4
    if paths[0].isdigit():          # `zipalign -f 4 in.apk out.apk`
        align = int(paths.pop(0))
    if not paths:
        ap.error("missing input file")
    infile = paths[0]
    outfile = paths[1] if len(paths) > 1 else None
    if len(paths) > 2:
        ap.error("too many arguments: %s" % " ".join(paths[2:]))

    big = 4 * 1024
    if align not in (1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, big):
        print("zipalign: alignment must be a power of two <= %d" % big, file=sys.stderr)
        return 2

    ignore = re.compile(a.ignore_regex) if a.ignore_regex else None

    try:
        if a.check:
            entries, bad = check(infile, align, a.page_align_shared_libs, ignore)
            if bad:
                print("%s: BAD - %d unaligned entr%s" %
                      (infile, len(bad), "y" if len(bad) == 1 else "ies"))
                for name, off, al in bad[:10]:
                    print("   %s: offset %% %d = %d" % (name, al, off))
                return 1
            print("%s: OK (%d entries, alignment=%d%s)" %
                  (infile, len(entries), align,
                   ", page-aligned .so" if a.page_align_shared_libs else ""))
            if a.verbose:
                for e in entries:
                    if ignore and ignore.search(e.name):
                        continue
                    print("   %-34s off=%8d  off%%%d=%d  stored=%s" %
                          (e.name, e.data_off, align, e.data_off % align,
                           e.method == 0))
            return 0

        if not outfile:
            ap.error("outfile required unless -c is used")
        if os.path.exists(outfile) and not a.force:
            print("refusing to overwrite %s (use -f)" % outfile, file=sys.stderr)
            return 2
        entries, comment = read_zip(infile)
        write_aligned(entries, comment, outfile, align, a.page_align_shared_libs)
        _, bad = check(outfile, align, a.page_align_shared_libs, ignore)
        if bad:
            print("internal error: output still unaligned", file=sys.stderr)
            return 1
        print("aligned %d entries -> %s" % (len(entries), outfile))
        return 0
    except (ValueError, OSError) as exc:
        print("zipalign: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
