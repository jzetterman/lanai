#!/usr/bin/env python3
"""Count successful traced reads of install files, including every child."""
import json
import os
import re
import sys

READS = {"read", "pread64", "readv", "preadv", "preadv2"}
OTHER_IO = {"mmap", "mmap2", "sendfile", "sendfile64", "splice", "copy_file_range"}
SMALL = {"windows.base", "windows.boot", "windows.mac", "windows.rom", "windows.vars", "windows.ver", "SOURCE", "COMPLETE"}


def measure(trace):
    counts = {"image": 0, "small": 0}
    pending = {}
    for line in trace:
        resumed = re.match(r"^(\d+)\s+<\.\.\. (\w+) resumed>(.*)", line)
        if resumed:
            key = (resumed[1], resumed[2])
            line = pending.pop(key, "") + resumed[3]
        elif "<unfinished ...>" in line:
            begin = re.match(r"^(\d+)\s+(\w+)\(", line)
            if begin:
                pending[(begin[1], begin[2])] = line.split("<unfinished ...>")[0]
            continue
        call = re.search(r"\b(\w+)\(.*", line)
        if not call:
            continue
        names = {os.path.basename(p.removesuffix(" (deleted)")).removeprefix(".lanai-restore.") for p in re.findall(r"<(/[^>]*)>", line)}
        names &= SMALL | {"data.img"}
        if not names:
            continue
        syscall = call[1]
        if syscall in OTHER_IO:
            raise ValueError(f"uncounted image/file IO: {line.strip()}")
        result = re.search(r"= (\d+)(?:\s|$)", line)
        if not result:
            continue
        if syscall in READS:
            counts["image" if "data.img" in names else "small"] += int(result[1])
    return counts


if __name__ == "__main__":
    with open(sys.argv[1]) as trace:
        counts = measure(trace)
    print(json.dumps(counts))
    if counts["image"] != int(sys.argv[2]):
        sys.exit("image read budget failed (expected exactly one logical image size)")
    allowance = 4 * int(sys.argv[3]) + (int(sys.argv[4]) + 1) * 65536
    if counts["small"] > allowance:
        sys.exit(f"small-file read budget failed (allowance {allowance})")
