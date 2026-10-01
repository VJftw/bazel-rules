#!/usr/bin/env python3
"""Extracts a single named file out of a macOS `.pkg` installer's `Payload`.

Used only for fetching the Darwin Hugo toolchain (see extensions.bzl) -
Hugo's `darwin-universal` release switched from a plain `.tar.gz` to a `.pkg`
installer as of v0.160.0, which Bazel's own `download_and_extract` can't
unpack (it only understands zip/tar, not Apple's XAR container format).

Two extraction paths, tried in order:

1. `pkgutil --expand-full` - macOS's own, built-in tool. Zero extra
   dependencies on a real Mac, which is the common case for actually
   fetching (and running) a Darwin toolchain.
2. A pure-Python XAR container parser (this module ships no dependency on
   the `xar` binary at all - `xar!` header + zlib-compressed TOC XML +
   heap are all stdlib-parseable) that extracts the raw `Payload` member,
   gunzips it (also stdlib), and shells out to `cpio -i` (near-universal on
   Linux/macOS, unlike `xar`) for the final unpack. Used when fetching the
   Darwin toolchain from a non-Mac machine (e.g. Linux, for remote
   execution / cross-fetching), where `pkgutil` doesn't exist.

Either way, only the one requested file (`--member`) is extracted, not the
whole payload - Hugo's `.pkg` payload is just the single binary anyway
(plus a macOS AppleDouble `._<name>` resource-fork sidecar file, ignored).
"""
import argparse
import gzip
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib


def _extract_via_pkgutil(pkg_path, member, out_path):
    if not shutil.which("pkgutil"):
        return False
    with tempfile.TemporaryDirectory() as d:
        expand_dir = os.path.join(d, "expanded")
        subprocess.run(["pkgutil", "--expand-full", pkg_path, expand_dir], check=True)
        found = None
        for root, _dirs, files in os.walk(expand_dir):
            if member in files:
                found = os.path.join(root, member)
                break
        if found is None:
            sys.exit("pkgutil expanded %s but %s wasn't in it" % (pkg_path, member))
        shutil.copyfile(found, out_path)
    return True


def _xar_toc(data):
    """Parses a `.pkg`'s XAR header + TOC. Returns (toc_root, heap_start)."""
    magic, header_size, _version, toc_comp_len, toc_uncomp_len, _cksum_alg = struct.unpack(">4sHHQQI", data[:28])
    if magic != b"xar!":
        sys.exit("Not a XAR file (bad magic): %r" % magic)
    toc_xml = zlib.decompress(data[header_size:header_size + toc_comp_len])
    if len(toc_xml) != toc_uncomp_len:
        sys.exit("XAR TOC length mismatch: got %d, header says %d" % (len(toc_xml), toc_uncomp_len))
    heap_start = header_size + toc_comp_len
    return ET.fromstring(toc_xml), heap_start


def _xar_member_bytes(data, toc_root, heap_start, name):
    for f in toc_root.find("toc").iter("file"):
        if f.find("name").text != name:
            continue
        d = f.find("data")
        offset = int(d.find("offset").text)
        length = int(d.find("length").text)
        raw = data[heap_start + offset:heap_start + offset + length]
        encoding = d.find("encoding")
        style = encoding.get("style") if encoding is not None else None
        if style == "application/x-gzip":
            return gzip.decompress(raw)
        return raw  # "application/octet-stream" - stored as-is in the heap.
    sys.exit("No %s member in XAR TOC" % name)


def _extract_via_pure_python(pkg_path, member, out_path):
    if not shutil.which("cpio"):
        sys.exit(
            "Fetching the Darwin Hugo toolchain from a non-Mac machine needs "
            "either `pkgutil` (macOS's own tool) or `cpio` on PATH to unpack "
            "the .pkg installer's Payload - neither was found."
        )
    data = open(pkg_path, "rb").read()
    toc_root, heap_start = _xar_toc(data)
    payload = _xar_member_bytes(data, toc_root, heap_start, "Payload")
    # Hugo's Payload is itself gzip-compressed (its own content format, on
    # top of - and independent of - whatever XAR-level encoding the TOC
    # above already reported/handled), wrapping a "pre-SVR4/odc" cpio
    # archive - verified empirically against a real Hugo release.
    cpio_bytes = gzip.decompress(payload)
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["cpio", "-id", "--quiet"], input=cpio_bytes, cwd=d, check=True)
        found = None
        for root, _dirs, files in os.walk(d):
            if member in files:
                found = os.path.join(root, member)
                break
        if found is None:
            sys.exit("cpio extracted %s's Payload but %s wasn't in it" % (pkg_path, member))
        shutil.copyfile(found, out_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pkg", required=True)
    parser.add_argument("--member", required=True, help="Filename to extract from the Payload, e.g. 'hugo'.")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    if not _extract_via_pkgutil(args.pkg, args.member, args.out):
        _extract_via_pure_python(args.pkg, args.member, args.out)

    os.chmod(args.out, 0o755)


if __name__ == "__main__":
    main()
