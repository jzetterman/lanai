#!/usr/bin/env python3
"""ficlone.py <src> <dst>: give the existing file <dst> the data of <src>.

Lanai's restore uses it for data.img (docs/plugin/plan.md, phase 4). It
opens <dst> write-only without O_TRUNC, so the inode that holds QEMU's lock
is the one written, and the disk is never empty: when <dst> is larger it is
first cut to <src>'s size (never to zero; btrfs refuses to clone a source
that ends mid-block into a larger file), then every extent of <src> is
cloned onto it with the FICLONE ioctl. An empty <src> is refused. Both
files must be on one filesystem that supports reflinks (btrfs or XFS).
Exits 1 with the reason on failure.
"""

import fcntl
import os
import sys

# linux/fs.h: _IOW(0x94, 9, int). Python 3.12+ also names it.
FICLONE = getattr(fcntl, "FICLONE", 0x40049409)


def main(argv):
    if len(argv) != 3:
        print("usage: ficlone.py <src> <dst>", file=sys.stderr)
        return 2
    src = dst = -1
    try:
        src = os.open(argv[1], os.O_RDONLY)
        dst = os.open(argv[2], os.O_WRONLY)
        size = os.fstat(src).st_size
        if size == 0:
            print(f"ficlone.py: {argv[1]} is empty", file=sys.stderr)
            return 1
        if os.fstat(dst).st_size > size:
            os.ftruncate(dst, size)
        fcntl.ioctl(dst, FICLONE, src)
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
