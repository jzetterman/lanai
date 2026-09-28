# Copy helpers shared by bin/lanai-copy and Lanai's snapshot and restore.
# Source this file; it defines functions only.
# shellcheck shell=bash

# Print one line per entry under <dir>, sorted by path: "d - - <path>" for a
# directory and "f <size> <sha256> <path>" for a regular file. Two trees hold
# the same files and data when their manifests are equal. Fails on a symlink,
# a special file or a name with a newline.
tree_manifest() (
  set -o pipefail
  dir=$1
  [[ -d $dir ]] || {
    echo "lanai: not a directory: $dir" >&2
    exit 1
  }
  find "$dir" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z |
    while IFS= read -r -d '' p; do
      f=$dir/$p
      if [[ $p == *$'\n'* ]]; then
        echo "lanai: file name with a newline in $dir" >&2
        exit 1
      elif [[ -L $f || ! (-d $f || -f $f) ]]; then
        echo "lanai: not a regular file or directory: $f" >&2
        exit 1
      elif [[ -d $f ]]; then
        printf 'd - - %s\n' "$p"
      else
        # Hash stdin, so sha256sum never escapes the name.
        sum=$(sha256sum <"$f") || exit 1
        printf 'f %s %s %s\n' "$(stat -c %s -- "$f")" "${sum%% *}" "$p"
      fi
    done
)

# Return 0 when <path> has the NOCOW (C) attribute. Filesystems without
# attributes count as not NOCOW.
has_nocow() {
  local a
  a=$(lsattr -d -- "$1" 2>/dev/null) || return 1
  [[ ${a%% *} == *C* ]]
}

# Copy the tree <src> into <dst>, an empty folder the caller made (so the
# caller knows the folder is its own and may remove it on failure). Each file
# is cloned with cp --reflink=always, so the copy shares its data blocks with
# the source and costs no space. btrfs refuses to clone between a NOCOW and a
# COW file, so each file is created empty and given the source's NOCOW
# attribute (or has an inherited one removed) before the clone. Modes and
# file times are kept; <dst> gets <src>'s mode. Fails on a symlink or special
# file, and when the two are not on one filesystem that supports reflinks.
reflink_tree() (
  set -o pipefail
  src=$1 dst=$2
  [[ -d $src && ! -L $src ]] || {
    echo "lanai: not a directory: $src" >&2
    exit 1
  }
  if [[ ! -d $dst || -L $dst ]] || [[ -n $(find "$dst" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo "lanai: $dst is not an empty folder" >&2
    exit 1
  fi
  chmod --reference="$src" -- "$dst" || exit 1
  find "$src" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z |
    while IFS= read -r -d '' p; do
      s=$src/$p d=$dst/$p
      if [[ -L $s || ! (-d $s || -f $s) ]]; then
        echo "lanai: not a regular file or directory: $s" >&2
        exit 1
      elif [[ -d $s ]]; then
        mkdir -- "$d" && chmod --reference="$s" -- "$d" || exit 1
        continue
      fi
      : >"$d" || exit 1
      if has_nocow "$s"; then
        chattr +C -- "$d" || exit 1
      elif has_nocow "$d"; then
        chattr -C -- "$d" || exit 1
      fi
      cp --reflink=always --preserve=mode,timestamps -- "$s" "$d" || {
        echo "lanai: cannot reflink $s: source and destination must be on the same btrfs or XFS filesystem" >&2
        exit 1
      }
    done
)

# Take QEMU's write lock on the raw image <img> by holding `qemu-io -f raw`
# open read-write with no commands. While held, no VM can open the image.
# While a VM holds it, this fails and sets LANAI_LOCK_ERROR to qemu-io's
# reason (the caller words the message). The lock lasts until unlock_disk or
# until this shell exits (qemu-io then reads end of input). `qemu-io -r`
# would take only a shared read lock and block nothing. One lock at a time.
lock_disk() {
  local img prompt="" rest="" out=""
  LANAI_LOCK_ERROR=""
  # An absolute path, so QEMU never reads a "proto:" prefix in the name.
  if [[ ! -f $1 ]] || ! img=$(realpath -e -- "$1"); then
    LANAI_LOCK_ERROR="no disk image at $1"
    return 1
  fi
  coproc LANAI_LOCK { exec qemu-io -f raw -- "$img" 2>&1; }
  # A copy of the output end: bash closes the coproc's own fds as soon as
  # it exits, which on failure can be before its message is read. If it is
  # already gone, there is nothing to read.
  if [[ -n ${LANAI_LOCK[0]:-} ]]; then
    { exec {out}<&"${LANAI_LOCK[0]}"; } 2>/dev/null || out=""
  fi
  if [[ -n $out ]]; then
    # qemu-io prints its prompt once the image is open; an error ends it.
    IFS= read -r -t 30 -N 9 prompt <&"$out" || true
    if [[ $prompt == "qemu-io> " ]]; then
      exec {out}<&-
      return 0
    fi
    rest=$(timeout 5 cat <&"$out") || true
    exec {out}<&-
  fi
  wait "$LANAI_LOCK_PID" 2>/dev/null || true
  # qemu-io's first line holds the reason.
  rest=$prompt$rest
  LANAI_LOCK_ERROR=${rest%%$'\n'*}
  LANAI_LOCK_ERROR=${LANAI_LOCK_ERROR#qemu-io: }
  LANAI_LOCK_ERROR=${LANAI_LOCK_ERROR:-qemu-io exited without a reason}
  return 1
}

# Release the lock taken by lock_disk and wait for qemu-io to exit.
unlock_disk() {
  local pid=${LANAI_LOCK_PID:-} fd=${LANAI_LOCK[1]:-}
  [[ -n $pid ]] || return 0
  [[ -z $fd ]] || exec {fd}>&-
  wait "$pid" 2>/dev/null || true
}
