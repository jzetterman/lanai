#!/usr/bin/env python3
"""Single-read btrfs image proof. Maps, reads and checks the same open inodes."""
import ctypes
import fcntl
import hashlib
import json
import os
import stat
import struct
import subprocess
import sys
import time

BTRFS = 0x9123683E
LAST, ENCODED, UNWRITTEN, SHARED = 1, 8, 0x800, 0x2000
ALLOWED = LAST | ENCODED | UNWRITTEN | SHARED


def open_image(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError(f"{path}: not a regular image")
    return fd


def btrfs(fd):
    buf = ctypes.create_string_buffer(256)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.fstatfs(fd, buf) != 0:
        raise OSError(ctypes.get_errno(), "cannot identify image filesystem")
    if ctypes.c_long.from_buffer(buf).value & 0xFFFFFFFF != BTRFS:
        raise ValueError("filesystem cannot make an instant copy with a provable image here; make a backup")


def image_map(fd):
    btrfs(fd)
    os.fsync(fd)
    size = os.fstat(fd).st_size
    if not size:
        raise ValueError("image is empty")
    result, start = [], 0
    while start < size:
        buf = bytearray(32 + 56 * 1024)
        struct.pack_into("=QQIIII", buf, 0, start, size - start, 1, 0, 1024, 0)
        fcntl.ioctl(fd, 0xC020660B, buf, True)
        count = struct.unpack_from("=I", buf, 20)[0]
        if count > 1024:
            raise ValueError("invalid FIEMAP batch")
        if not count:
            result.append([start, -1, size - start, 0])
            break
        for n in range(count):
            logical, physical, length, _, _, flags, _, _, _ = struct.unpack_from("=QQQQQIIII", buf, 32 + n * 56)
            if flags & ~ALLOWED or not length or logical < start:
                raise ValueError(f"unprovable FIEMAP extent (flags 0x{flags:x})")
            if logical > start:
                result.append([start, -1, logical - start, 0])
            result.append([logical, physical, length, flags & (ENCODED | UNWRITTEN)])
            start = logical + length
        if flags & LAST:
            if start < size:
                result.append([start, -1, size - start, 0])
            break
    return {"size": size, "extents": result}


def same(saved, current):
    # Same-user deliberate re-cloning/reference juggling is outside the threat
    # model. Encoded physical starts do not describe slices within an extent;
    # deliberately substituting another slice is one such excluded attack.
    if saved != current:
        raise ValueError("image changed or its shared storage does not match; proof failed")


def unchanged(path, fd):
    now, opened = os.stat(path, follow_symlinks=False), os.fstat(fd)
    if (now.st_dev, now.st_ino) != (opened.st_dev, opened.st_ino):
        raise ValueError("image path changed during proof")


def progress(phase, done=None, total=None):
    path = os.environ.get("LANAI_IMAGE_PROGRESS")
    if not path:
        return
    if done is None or total is None:
        try:
            with open(path) as previous:
                current = json.load(previous)
        except (OSError, ValueError):
            current = {}
        done = current.get("done", 0) if done is None else done
        total = current.get("total", 0) if total is None else total
    doc = {"operation": os.environ["LANAI_IMAGE_OPERATION"], "phase": phase,
           "done": done, "total": total, "pid": int(os.environ["LANAI_IMAGE_OWNER"])}
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "x", opener=lambda p, f: os.open(p, f, 0o600)) as out:
            json.dump(doc, out)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def hook(name, source, copy):
    command = os.environ.get(f"LANAI_TEST_IMAGE_{name}")
    if command:
        subprocess.run([command, source, copy], check=True)


def prove(source, copy, map_path, expected=None, adopt=False):
    src, dst = open_image(source), open_image(copy)
    try:
        progress("checking")
        saved = image_map(src)
        same(saved, image_map(dst))
        hook("AFTER_MAP", source, copy)
        digest = hashlib.sha256()
        done, first_data, last = 0, False, 0
        total = saved["size"]
        progress("hashing", 0, total)
        while done < total:
            chunk = os.read(dst, min(4 * 1024 * 1024, total - done))
            if not chunk:
                raise ValueError("image shortened while hashing")
            if done < 102400:
                first_data |= any(chunk[:102400 - done])
            digest.update(chunk)
            done += len(chunk)
            if time.monotonic() - last >= 1:
                progress("hashing", done, total)
                last = time.monotonic()
        hook("AFTER_HASH", source, copy)
        progress("checking", total, total)
        same(saved, image_map(dst))
        same(saved, image_map(src))
        unchanged(source, src)
        unchanged(copy, dst)
        if expected and digest.hexdigest() != expected:
            raise ValueError("snapshot is damaged: image does not match its manifest")
        if adopt and not first_data:
            raise ValueError("first 100 KB of data.img are all zero; dockur would treat the disk as blank")
        with open(map_path, "w", opener=lambda p, f: os.open(p, f, 0o600)) as out:
            json.dump(saved, out)
        print(f"f {total} {digest.hexdigest()} data.img")
    finally:
        os.close(src)
        os.close(dst)


def publish(source, destination):
    # Atomic no-replace publication keeps any contender's inode untouched.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renameat2(-100, os.fsencode(source), -100, os.fsencode(destination), 1):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def activity(lock_path, progress_path):
    """Read-only lock ownership: external flock's short-lived PID is irrelevant."""
    try:
        lock = os.stat(lock_path)
        # btrfs /proc/locks uses the mount device, not stat's subvolume device.
        device = subprocess.check_output(["findmnt", "-no", "MAJ:MIN", "-T", lock_path], text=True).splitlines()[0]
        major, minor = map(int, device.strip().split(":"))
        identity = f"{major:02x}:{minor:02x}:{lock.st_ino}"
        with open("/proc/locks") as records:
            held = any("FLOCK" in line.split() and identity in line.split() for line in records)
        with open(progress_path) as record:
            doc = json.load(record)
        if not isinstance(doc, dict):
            return None
        if (type(doc.get("pid")) is not int or doc["pid"] <= 0 or
                doc.get("operation") not in ("snapshot", "restore") or
                doc.get("phase") not in ("cloning", "checking", "hashing", "replacing", "finishing") or
                any(type(doc.get(k)) is not int or doc[k] < 0 for k in ("done", "total")) or
                doc["done"] > doc["total"]):
            return None
        proc = f'/proc/{doc["pid"]}'
        with open(f"{proc}/stat") as state:
            if state.read().rsplit(")", 1)[1].strip()[0] in "ZX":
                return None
        owns = False
        for name in os.listdir(f"{proc}/fd"):
            try:
                entry = os.stat(f"{proc}/fd/{name}")
                matches = (entry.st_dev, entry.st_ino) == (lock.st_dev, lock.st_ino)
                owns |= matches
                if matches and not held:
                    # PID namespaces can hide /proc/locks entries whose external
                    # flock creator exited (fdinfo reports pid 0). The open file's
                    # kernel FLOCK record is the same read-only proof of holding.
                    with open(f"{proc}/fdinfo/{name}") as info:
                        held |= any("FLOCK" in line.split() and identity in line.split() for line in info)
            except OSError:
                continue
        if not owns or not held:
            return None
        percent = min(99, doc["done"] * 99 // doc["total"]) if doc["total"] else 0
        verb = "Taking snapshot" if doc["operation"] == "snapshot" else "Restoring Windows"
        labels = {"cloning": "making instant copy", "checking": "checking shared storage",
                  "hashing": "reading image", "replacing": "replacing the disk", "finishing": "finishing and saving"}
        return {"label": f'{verb}: {labels[doc["phase"]]}', "percent": percent}
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError):
        return None


def main(args):
    action = args[0]
    if action == "activity":
        print(json.dumps(activity(*args[1:])))
    elif action == "progress":
        if args[1] == "cloning":
            progress(args[1], 0, 0)
        else:
            progress(args[1])
    elif action == "publish":
        publish(*args[1:])
    elif action in ("gate", "filesystem"):
        fd = open_image(args[1])
        try:
            btrfs(fd)
            if action == "gate":
                image_map(fd)
        finally:
            os.close(fd)
    elif action == "prove":
        prove(*args[1:4], expected=args[4] if len(args) > 4 and args[4] != "adopt" else None,
              adopt=args[-1] == "adopt")
    elif action == "final":
        source, destination, map_path = args[1:]
        hook("AFTER_INSTALL", source, destination)
        fd = open_image(destination)
        try:
            with open(map_path) as saved:
                same(json.load(saved), image_map(fd))
            unchanged(destination, fd)
        finally:
            os.close(fd)
    else:
        raise ValueError("unknown image-proof operation")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"image-proof: {error}", file=sys.stderr)
        sys.exit(1)
