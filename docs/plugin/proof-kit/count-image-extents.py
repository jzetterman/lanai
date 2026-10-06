#!/usr/bin/env python3
"""count-image-extents.py <image>: count a disk image's extent classes.

A read-only check for phase B of the scale, progress and clicks amendment
(docs/plugin/plan.md). It reads the file's extent map with the FIEMAP ioctl and
never reads image data, syncs or writes. It prints the filesystem, the NOCOW
attribute, and the extent count and bytes for each flag combination, then
whether every extent falls in a class Lanai can prove (plain, encoded,
unwritten). John runs it on his rehearsal copy with the VM stopped and records
the output in docs/plugin/proofs.md. Agents never run it on ~/.windows.
"""

import collections
import ctypes
import fcntl
import json
import os
import struct
import sys
import time

FS_IOC_FIEMAP = 0xC020660B
FS_IOC_GETFLAGS = 0x80086601
FS_NOCOW_FL = 0x00800000
BTRFS_MAGIC = 0x9123683E
BATCH = 512
HEADER = struct.Struct("=QQIIII")  # struct fiemap
EXTENT = struct.Struct("=QQQQQIIII")  # struct fiemap_extent

FLAGS = {
    0x1: "last", 0x2: "unknown", 0x4: "delalloc", 0x8: "encoded",
    0x80: "encrypted", 0x100: "not-aligned", 0x200: "inline", 0x400: "tail",
    0x800: "unwritten", 0x1000: "merged", 0x2000: "shared",
}
# Flags that say nothing about how the data is stored.
IGNORED = 0x1 | 0x2000


def fs_type(path):
    """Return statfs's f_type (os.statvfs has none)."""
    libc = ctypes.CDLL(None, use_errno=True)
    buf = ctypes.create_string_buffer(256)
    if libc.statfs(os.fsencode(path), buf) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), path)
    return struct.unpack_from("=q", buf.raw)[0]


def nocow(fd):
    try:
        buf = fcntl.ioctl(fd, FS_IOC_GETFLAGS, b"\0" * 8)
    except OSError:
        return None
    return bool(struct.unpack("l", buf)[0] & FS_NOCOW_FL)


def extents(fd):
    """Yield (logical, physical, length, flags) for the whole file."""
    start = 0
    while True:
        req = bytearray(HEADER.size + BATCH * EXTENT.size)
        HEADER.pack_into(req, 0, start, 2**64 - 1 - start, 0, 0, BATCH, 0)
        fcntl.ioctl(fd, FS_IOC_FIEMAP, req)
        mapped = HEADER.unpack_from(req, 0)[3]
        if mapped == 0:
            return
        for i in range(mapped):
            e = EXTENT.unpack_from(req, HEADER.size + i * EXTENT.size)
            yield e[0], e[1], e[2], e[5]
            start = e[0] + e[2]
            if e[5] & 0x1:
                return


def name(flags):
    shown = [n for bit, n in FLAGS.items() if flags & bit and not bit & IGNORED]
    other = flags & ~sum(FLAGS)
    if other:
        shown.append(hex(other))
    return "+".join(shown) or "plain"


def main(argv):
    as_json = len(argv) == 3 and argv[1] == "--json"
    if as_json:
        argv = [argv[0], argv[2]]
    if len(argv) != 2:
        print("usage: count-image-extents.py <image>", file=sys.stderr)
        return 2
    fd = os.open(argv[1], os.O_RDONLY | os.O_NOFOLLOW)
    try:
        kind = fs_type(argv[1])
        size = os.fstat(fd).st_size
        counts = collections.Counter()
        sizes = collections.Counter()
        shared = 0
        started = time.monotonic()
        for _, _, length, flags in extents(fd):
            key = name(flags)
            counts[key] += 1
            sizes[key] += length
            shared += length if flags & 0x2000 else 0
        elapsed = time.monotonic() - started
        if as_json:
            print(json.dumps({"size": size, "classes": dict(counts), "bytes": dict(sizes),
                              "nocow": nocow(fd), "map_seconds": elapsed}))
            return 0
        print(f"map time: {elapsed:.6f} seconds")
        print(f"file: {argv[1]}")
        print(f"filesystem: {'btrfs' if kind == BTRFS_MAGIC else hex(kind)}")
        print(f"nocow: {nocow(fd)}")
        print(f"size: {size} bytes")
        print(f"shared: {shared} bytes")
        print(f"{'class':<24}{'extents':>12}{'bytes':>20}")
        for key in sorted(counts):
            print(f"{key:<24}{counts[key]:>12}{sizes[key]:>20}")
        bad = [k for k in counts if k != "plain" and
               any(n not in ("encoded", "unwritten") for n in k.split("+"))]
        print("provable classes only: " + ("no (" + ", ".join(bad) + ")" if bad else "yes"))
    finally:
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
