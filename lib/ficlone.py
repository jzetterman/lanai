#!/usr/bin/env python3
"""ficlone.py <src> <dst>: give the existing file <dst> the data of <src>.

Lanai's restore uses it for data.img (docs/plugin/plan.md, phase 4). It
opens <dst> write-only without O_TRUNC, and never through a symlink, so the
inode that holds QEMU's lock is the one written. The disk is never empty:
when <dst> is larger it is first cut to <src>'s size (never to zero; btrfs
refuses to clone a source that ends mid-block into a larger file), then
every extent of <src> is cloned onto it with the FICLONE ioctl. Before any
change it refuses an empty <src>, and two files whose NOCOW attributes
differ (btrfs cannot clone between them, so the clone would fail after the
cut). Both files must be on one filesystem that supports reflinks (btrfs or
XFS). Exits 1 with the reason on failure.
"""

import fcntl
import os
import struct
import sys

# linux/fs.h: FICLONE is _IOW(0x94, 9, int); FS_IOC_GETFLAGS is
# _IOR('f', 1, long); FS_NOCOW_FL is the C attribute. Python 3.12+ also
# names FICLONE.
FICLONE = getattr(fcntl, "FICLONE", 0x40049409)
FS_IOC_GETFLAGS = 0x80086601
FS_NOCOW_FL = 0x00800000


def nocow(fd):
    """Return the file's NOCOW flag, or None when the filesystem has none."""
    try:
        buf = fcntl.ioctl(fd, FS_IOC_GETFLAGS, b"\0" * 8)
    except OSError:
        return None
    return bool(struct.unpack("l", buf)[0] & FS_NOCOW_FL)


def main(argv):
    if len(argv) != 3:
        print("usage: ficlone.py <src> <dst>", file=sys.stderr)
        return 2
    src = dst = -1
    try:
        src = os.open(argv[1], os.O_RDONLY | os.O_NOFOLLOW)
        dst = os.open(argv[2], os.O_WRONLY | os.O_NOFOLLOW)
        size = os.fstat(src).st_size
        if size == 0:
            print(f"ficlone.py: {argv[1]} is empty", file=sys.stderr)
            return 1
        if nocow(src) != nocow(dst):
            print(f"ficlone.py: {argv[1]} and {argv[2]} differ in NOCOW; nothing was changed",
                  file=sys.stderr)
            return 1
        cut = os.fstat(dst).st_size > size
        if cut:
            os.ftruncate(dst, size)
        try:
            fcntl.ioctl(dst, FICLONE, src)
        except OSError as err:
            shortened = ", after it was shortened to the snapshot's size" if cut else ""
            print(f"ficlone.py: cannot clone {argv[1]} onto {argv[2]} ({err.strerror}){shortened}; "
                  "the snapshot is intact: run lanai restore again, or restore another snapshot",
                  file=sys.stderr)
            return 1
        os.fsync(dst)
    except OSError as err:
        print(f"ficlone.py: {err}", file=sys.stderr)
        return 1
    finally:
        for fd in (src, dst):
            if fd >= 0:
                os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
