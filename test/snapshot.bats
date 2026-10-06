#!/usr/bin/env bats
# Tests for lanai snapshot, lanai restore and lib/ficlone.py (spec 7, plan
# phase 4). Every install is a scratch folder the test builds; the only QEMU
# started is a paused TCG one on that folder's 1 MiB data.img. Tests that
# need real reflinks run under LANAI_TEST_BTRFS_DIR; the others run on any
# filesystem, with a cp shim standing in for reflinks.
# shellcheck disable=SC2030,SC2031,SC2016

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  S=$XDG_STATE_HOME/lanai
  export T
  # An inactive unit, unless a test writes $T/unit-state; with
  # $T/no-manager, `show` fails like an unreachable user manager.
  shim systemctl 'if [[ " $* " == *" show "* ]]; then
  [[ ! -e $T/no-manager ]] || exit 1
  cat "$T/unit-state" 2>/dev/null || echo inactive
fi'
  export PATH=$T/shims:$PATH
}

teardown() {
  stop_bg
  qemu_release
  if [[ -n ${B:-} ]]; then
    chmod -R u+w "$B" 2>/dev/null || true
    rm -rf "$B"
  fi
}

# Point Lanai's storage at <dir> and build an install there.
use_install() {
  make_install "$1"
  mkdir -p "$XDG_CONFIG_HOME/lanai"
  jq -n --arg s "$1" '{storage: $s}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  STORE=$1
}

# Point Lanai's storage at <dir> without building anything there.
point_at() {
  jq -n --arg s "$1" '{storage: $s}' >"$XDG_CONFIG_HOME/lanai/settings.json"
}

# A cp stand-in for filesystems without reflinks: it copies plainly. When it
# copies a data.img (a snapshot's copy) or a restore's temp file, it records
# whether a VM could open the install's disk, $STORE/data.img, at that moment
# (124: QEMU ran, so it could; anything else: the lock stopped it). With
# $T/damage set to a path pattern, it flips the first byte of a copy whose
# destination matches, keeping its size.
plain_cp() {
  export STORE
  shim cp 'args=()
reflink=0
for a; do if [[ $a == --reflink=always ]]; then reflink=1; else args+=("$a"); fi; done
src=${args[-2]} dst=${args[-1]}
if [[ -e $T/probe-lock && ( ${dst} == *.partial/* || ${dst##*/} == .lanai-restore.* ) ]]; then
  rc=0
  timeout 2 qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \
    -drive "file=$STORE/data.img,format=raw,if=none,id=d" -device virtio-scsi-pci \
    -device scsi-hd,drive=d 3>&- 2>/dev/null || rc=$?
  echo "$rc" >>"$T/vm-open"
fi
if [[ -e $T/real-reflink ]] && ((reflink)); then args=(--reflink=always "${args[@]}"); fi
if [[ -e $T/plant && ${dst##*/} == .lanai-restore.* ]]; then echo mine >"$(<"$T/plant")"; fi
/usr/bin/cp "${args[@]}" || exit
if [[ -e $T/damage ]] && [[ $dst == $(<"$T/damage") ]]; then
  printf "\\x$(printf %02x $(( ($(od -An -tu1 -N1 "$dst") + 1) % 256 )))" |
    dd of="$dst" bs=1 count=1 conv=notrunc status=none
fi'
}

# Skip the test unless $T is on a filesystem without reflinks (tmpfs or
# overlayfs, as here and in CI).
need_no_reflink() {
  local fs
  fs=$(stat -f -c %T "$T")
  [[ $fs != btrfs && $fs != xfs ]] || skip "the temp dir can reflink"
}

# Flip the first byte of <file>, keeping its size.
flip_byte() {
  local b
  b=$(od -An -tu1 -N1 "$1")
  printf '%b' "\\x$(printf %02x $(((b + 1) % 256)))" | dd of="$1" bs=1 count=1 conv=notrunc status=none
}

# Write an unfinished restore's marker: mark_restore <snapshot> <storage>.
mark_restore() {
  mkdir -p "$S"
  printf '%s\n%s\n' "$1" "$2" >"$S/restore-in-progress"
}

# Take a snapshot of the install at $STORE (on any filesystem) and set NAME
# and SNAP.
take_snapshot() {
  lanai_run snapshot
  assert_success
  NAME=$(field name) SNAP=$(field snapshot)
}

# --- refusals, on any filesystem ---

@test "snapshot and restore refuse while Lanai's VM runs, changing nothing" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  echo changed >"$B/win/windows.vars"
  local before
  before=$(tree_manifest "$B/win")
  echo active >"$T/unit-state"
  lanai_run snapshot
  assert_failure
  assert_equal "$(field message)" "Windows is running under Lanai. Shut it down first."
  lanai_run restore "$NAME"
  assert_failure
  assert_equal "$(field message)" "Windows is running under Lanai. Shut it down first."
  assert [ ! -e "$S/restore-in-progress" ]
  assert_equal "$(tree_manifest "$B/win")" "$before"
}

@test "snapshot and restore refuse while the container VM runs or prepares, changing nothing" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  echo changed >"$B/win/windows.vars"
  local before
  before=$(tree_manifest "$B/win")
  fake_proc 700 "$DOCKER_SCOPE" /usr/bin/qemu-system-x86_64
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "Docker VM is running"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "Docker VM is running"
  rm -rf "$T/proc/700"
  fake_proc 701 "$DOCKER_SCOPE" /bin/bash /run/entry.sh
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "preparing"
  lanai_run restore "$NAME"
  assert_failure
  assert [ ! -e "$S/restore-in-progress" ]
  assert_equal "$(tree_manifest "$B/win")" "$before"
}

@test "snapshot refuses when the user manager does not answer" {
  use_install "$T/win"
  plain_cp
  : >"$T/no-manager"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "cannot reach"
}

@test "snapshot refuses while any VM holds the disk" {
  use_install "$T/win"
  plain_cp
  qemu_hold "$T/win/data.img"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "lock"
  qemu_release
}

@test "snapshot and restore refuse while another start, snapshot or restore runs" {
  use_install "$T/win"
  plain_cp
  mkdir -p "$S"
  flock "$S/lock" sleep 30 3>&- &
  BG_PIDS+=("$!")
  local i
  for ((i = 0; i < 50; i++)); do
    flock -n "$S/lock" true || break
    sleep 0.05
  done
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "another Lanai start, setup, snapshot or restore is running"
  lanai_run restore 20260928T120000Z
  assert_failure
  run field message
  assert_output --partial "another Lanai"
}

@test "snapshot: without reflinks it says so, suggests a backup, and leaves nothing" {
  need_no_reflink
  use_install "$T/win"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "cannot make an instant copy"
  run field next
  assert_output --partial "backup"
  assert [ ! -e "$T/win.lanai-snapshots" ]
  assert [ ! -e "$XDG_DATA_HOME/lanai/snapshots" ]
}

@test "snapshot and restore hold the disk lock while they copy, then release it" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  : >"$T/probe-lock"
  take_snapshot
  # During the copy no VM could open the disk; afterwards one can.
  run sort -u "$T/vm-open"
  assert_output 1
  vm_can_open "$B/win/data.img" || fail "the lock outlived the snapshot"
  # The snapshot still matches its source, and names it.
  assert_equal "$(<"$SNAP/COMPLETE")" "$(tree_manifest "$B/win")"
  assert_equal "$(<"$SNAP/SOURCE")" "$B/win"
  # Restore clones and verifies temporary files under the same disk lock.
  : >"$T/vm-open"
  echo changed >"$B/win/windows.vars"
  lanai_run restore "$NAME"
  assert_success
  assert [ ! -e "$S/restore-in-progress" ]
  [[ -s $T/vm-open ]] || fail "the restore copied nothing"
  run sort -u "$T/vm-open"
  assert_output 1
  vm_can_open "$B/win/data.img" || fail "the lock outlived the restore"
}

@test "restore: the clone step's own reason reaches the user, with the next step" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  echo changed >"$B/win/windows.vars"
  local msg
  # Stand-ins for ficlone.py's refusals and its errno message.
  for msg in "ficlone.py: a and b differ in NOCOW; nothing was changed" "ficlone.py: a is empty" \
    "ficlone.py: cannot clone a onto b (No space left on device); the snapshot is intact: run lanai restore again, or restore another snapshot"; do
    shim python3 'if [[ $1 == */ficlone.py ]]; then cat "$T/clone-error" >&2; exit 1; fi
exec /usr/bin/python3 "$@"'
    printf '%s\n' "$msg" >"$T/clone-error"
    lanai_run restore "$NAME"
    assert_failure
    run field message
    # Clone failures occur before replacement, so the detail and clean refusal stay.
    msg=${msg#ficlone.py: }
    assert_output --partial "${msg%; nothing was changed}"
    assert_output --partial "Nothing was changed"
    assert [ ! -e "$S/restore-in-progress" ]
  done
}

# A sha256sum stand-in that, while $T/probe-hash exists, records whether a
# VM could open $STORE/data.img each time a file is hashed (124: it could;
# anything else: the lock stopped it), then hashes as usual.
hash_probes_the_lock() {
  export STORE
  shim sha256sum 'if [[ -e $T/probe-hash ]]; then
  rc=0
  timeout 2 qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \
    -drive "file=$STORE/data.img,format=raw,if=none,id=d" -device virtio-scsi-pci \
    -device scsi-hd,drive=d </dev/null 3>&- 2>/dev/null || rc=$?
  echo "$rc" >>"$T/hash-open"
fi
exec /usr/bin/sha256sum "$@"'
}

@test "restore: holds the disk lock while it hashes the snapshot" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  echo changed >"$B/win/windows.vars"
  hash_probes_the_lock
  : >"$T/probe-hash"
  lanai_run restore "$NAME"
  rm "$T/probe-hash"
  [[ -s $T/hash-open ]] || fail "the restore hashed nothing"
  run sort -u "$T/hash-open"
  assert_output 1
  vm_can_open "$B/win/data.img" || fail "the lock outlived the restore"
}

@test "restore: a damaged snapshot is refused under the lock, then the lock is released" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  echo changed >"$B/win/windows.vars"
  local before
  before=$(tree_manifest "$B/win")
  flip_byte "$SNAP/windows.vars"
  hash_probes_the_lock
  : >"$T/probe-hash"
  lanai_run restore "$NAME"
  rm "$T/probe-hash"
  assert_failure
  run field message
  assert_output --partial "damaged"
  run sort -u "$T/hash-open"
  assert_output 1
  vm_can_open "$B/win/data.img" || fail "the lock outlived the refusal"
  assert [ ! -e "$S/restore-in-progress" ]
  assert_equal "$(tree_manifest "$B/win")" "$before"
}

@test "snapshot: refuses a storage folder that fails the adoption checks" {
  use_install "$T/win"
  plain_cp
  rm "$T/win/windows.mac"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "windows.mac is missing or empty"
  refute_output --partial "instant copy"
}

@test "snapshot: flushes the whole filesystem before the rename and again after, before it reports" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  shim sync 'echo "$*" >>"$T/sync.calls"; exec /usr/bin/sync "$@"'
  take_snapshot
  local root=${SNAP%/*}
  run cat "$T/sync.calls"
  # sync -f (syncfs) also commits the cloned files; a plain sync FILE is an
  # fsync of that file only, which on XFS leaves the clones unflushed.
  assert_line "-f -- $SNAP.partial"
  assert_line "-f -- $root"
  local before after
  before=$(grep -nxF -- "-f -- $SNAP.partial" "$T/sync.calls" | cut -d: -f1)
  after=$(grep -nxF -- "-f -- $root" "$T/sync.calls" | cut -d: -f1)
  ((before < after)) || fail "the order of the syncs is wrong"
}

@test "restore: marks itself before it recreates a deleted disk, and keeps the mark when the lock fails" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  rm "$B/win/data.img"
  # The lock on the temporary inode fails before publication.
  shim qemu-io 'echo "qemu-io: Failed to get \"write\" lock" >&2; exit 1'
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "did not finish"
  assert_output --partial "run lanai restore again"
  refute_output --partial "nothing was changed"
  assert [ ! -e "$B/win/data.img" ]
  assert [ -e "$S/restore-in-progress" ]
  run preflight
  assert_failure
  assert_output --partial "a restore did not finish"
}

@test "snapshot: a copy that does not match its source is removed, and the lock released" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  echo "*.partial/windows.mac" >"$T/damage"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "nothing was kept"
  run find "$XDG_DATA_HOME/lanai/snapshots" -mindepth 1
  assert_output ""
  vm_can_open "$B/win/data.img" || fail "the lock outlived the failed snapshot"
}

@test "restore: refuses a storage folder that holds anything but an install" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  # Lanai's storage now points at a folder with someone's own files.
  mkdir -p "$T/docs/precious"
  echo keep >"$T/docs/precious/doc.txt"
  cp "$B/win/windows.vars" "$T/docs/"
  point_at "$T/docs"
  lanai_run restore "$NAME"
  assert_failure
  assert_equal "$(<"$T/docs/precious/doc.txt")" keep
  assert [ -f "$T/docs/windows.vars" ]
  assert [ ! -e "$S/restore-in-progress" ]
  # An install with one foreign file or folder is refused too, untouched.
  point_at "$B/win"
  echo mine >"$B/win/notes.txt"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "notes.txt"
  assert_equal "$(<"$B/win/notes.txt")" mine
  rm "$B/win/notes.txt"
  mkdir "$B/win/tmp"
  lanai_run restore "$NAME"
  assert_failure
  assert [ -d "$B/win/tmp" ]
}

@test "restore: refuses a symlinked data.img and a storage folder that does not exist" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  mv "$B/win/data.img" "$T/elsewhere.img"
  ln -s "$T/elsewhere.img" "$B/win/data.img"
  echo changed >"$B/win/windows.vars"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "data.img (not a regular file)"
  assert [ -L "$B/win/data.img" ]
  assert_equal "$(<"$B/win/windows.vars")" changed
  assert [ ! -e "$S/restore-in-progress" ]
  point_at "$T/gone"
  lanai_run restore "$NAME"
  assert_failure
  assert [ ! -e "$T/gone" ]
}

@test "snapshot: records its source, and another storage location never sees it" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  plain_cp
  : >"$T/real-reflink"
  take_snapshot
  use_install "$T/other"
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots | length' <<<"$JSON")" 0
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "no complete snapshot"
  # An unfinished restore of the first location does not resume on this one.
  mark_restore "$SNAP" "$B/win"
  lanai_run restore
  assert_failure
  run field message
  assert_output --partial "was for $B/win"
  assert_equal "$(tree_manifest "$T/other")" "$(tree_manifest "$SNAP" | grep -vE ' (COMPLETE|SOURCE)$')"
}

@test "restore: when the unfinished restore's snapshot is gone, another can replace it" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local before
  before=$(tree_manifest "$B/win")
  take_snapshot
  local first=$SNAP
  sleep 1
  take_snapshot
  mark_restore "$first" "$B/win"
  rm -rf "$first"
  echo changed >"$B/win/windows.vars"
  lanai_run restore
  assert_failure
  run field message
  assert_output --partial "gone or damaged"
  assert_output --partial "$S/restore-in-progress"
  lanai_run restore "$NAME"
  assert_success
  run field message
  assert_output --partial "replacing the unfinished restore"
  assert [ ! -e "$S/restore-in-progress" ]
  assert_equal "$(tree_manifest "$B/win")" "$before"
}

@test "snapshot: refuses dockur's leftovers and restore temp files, which no snapshot may hold" {
  use_install "$T/win"
  plain_cp
  local f
  for f in setup.img setup.img.tmp .lanai-restore.windows.vars; do
    echo stray >"$T/win/$f"
    lanai_run snapshot
    assert_failure
    run field message
    assert_output --partial "$f"
    assert_output --partial "delete it,"
    rm "$T/win/$f"
  done
  # Two of them: "delete them".
  echo stray >"$T/win/setup.img"
  echo stray >"$T/win/setup.img.tmp"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "setup.img, setup.img.tmp"
  assert_output --partial "delete them,"
  run bash -c 'ls -A "$1" 2>/dev/null || true' _ "$XDG_DATA_HOME/lanai/snapshots"
  assert_output ""
}

@test "snapshot: a snapshot folder that is a symlink or open to others is not used" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  mkdir -p "$B/data/lanai" "$B/elsewhere"
  ln -s "$B/elsewhere" "$B/data/lanai/snapshots"
  take_snapshot
  assert_equal "${SNAP%/*}" "$B/win.lanai-snapshots"
  run ls -A "$B/elsewhere"
  assert_output ""
  # A snapshot placed in the symlinked folder's target is not listed.
  cp -a --reflink=always "$SNAP" "$B/elsewhere/"
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots | length' <<<"$JSON")" 1
  # A group-writable folder is not trusted either.
  rm "$B/data/lanai/snapshots"
  mkdir -m 770 "$B/data/lanai/snapshots"
  cp -a --reflink=always "$SNAP" "$B/data/lanai/snapshots/"
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots[]' <<<"$JSON")" "$SNAP"
}

@test "restore: refuses an unknown snapshot, one without COMPLETE, and no name" {
  use_install "$T/win"
  lanai_run restore 20260928T120000Z
  assert_failure
  run field message
  assert_output --partial "no complete snapshot"
  mkdir -p "$XDG_DATA_HOME/lanai/snapshots/20260928T120000Z"
  cp "$T/win/windows.vars" "$XDG_DATA_HOME/lanai/snapshots/20260928T120000Z/"
  echo "$T/win" >"$XDG_DATA_HOME/lanai/snapshots/20260928T120000Z/SOURCE"
  lanai_run restore 20260928T120000Z
  assert_failure
  lanai_run restore ../../etc
  assert_failure
  lanai_run restore
  assert_failure
  run field message
  assert_output --partial "name a snapshot"
}

# --- ficlone.py ---

@test "ficlone.py: clones into an existing larger or smaller file in place" {
  btrfs_tmp
  local dst_size ino
  head -c 3M /dev/urandom >"$B/src"
  for dst_size in 5M 1M 4097; do
    head -c "$dst_size" /dev/urandom >"$B/dst"
    ino=$(stat -c %i "$B/dst")
    run python3 "$REPO/lib/ficlone.py" "$B/src" "$B/dst"
    assert_success
    assert_equal "$(sha256sum <"$B/dst")" "$(sha256sum <"$B/src")"
    assert_equal "$(stat -c %i "$B/dst")" "$ino"
  done
  # A source that ends mid-block, into a larger file.
  head -c 70001 /dev/urandom >"$B/src"
  head -c 1M /dev/urandom >"$B/dst"
  run python3 "$REPO/lib/ficlone.py" "$B/src" "$B/dst"
  assert_success
  assert_equal "$(sha256sum <"$B/dst")" "$(sha256sum <"$B/src")"
}

@test "ficlone.py: refuses an empty source, a missing or symlinked destination, and a NOCOW mismatch" {
  btrfs_tmp
  : >"$B/empty"
  head -c 1M /dev/urandom >"$B/dst"
  head -c 1M /dev/urandom >"$B/src"
  local before
  before=$(sha256sum <"$B/dst")
  run python3 "$REPO/lib/ficlone.py" "$B/empty" "$B/dst"
  assert_failure
  assert_equal "$(sha256sum <"$B/dst")" "$before"
  run python3 "$REPO/lib/ficlone.py" "$B/src" "$B/missing"
  assert_failure
  assert [ ! -e "$B/missing" ]
  ln -s "$B/dst" "$B/link"
  run python3 "$REPO/lib/ficlone.py" "$B/src" "$B/link"
  assert_failure
  assert_equal "$(sha256sum <"$B/dst")" "$before"
  : >"$B/nocow"
  chattr +C "$B/nocow"
  head -c 2M /dev/urandom >>"$B/nocow"
  before=$(sha256sum <"$B/nocow")
  run python3 "$REPO/lib/ficlone.py" "$B/src" "$B/nocow"
  assert_failure
  assert_output --partial "NOCOW"
  assert_equal "$(sha256sum <"$B/nocow")" "$before"
}

# --- snapshot and restore on btrfs ---

@test "snapshot: a verified copy in the data folder when it can reflink there" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  assert_equal "${SNAP%/*}" "$B/data/lanai/snapshots"
  [[ $NAME =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "bad name $NAME"
  assert_equal "$(<"$SNAP/COMPLETE")" "$(tree_manifest "$B/win")"
  assert_equal "$(stat -c %a "$B/data/lanai/snapshots")" 700
  run field message
  assert_output --partial "grows as Windows changes"
  assert_output --partial "rm -rf ${SNAP@Q}"
  assert_output --partial "lanai restore $NAME"
  lanai_run snapshots
  assert_success
  assert_equal "$(jq -r '.snapshots[]' <<<"$JSON")" "$SNAP"
}

@test "snapshot: falls back to a folder beside the storage location" {
  btrfs_tmp
  [[ $(stat -f -c %T "$XDG_DATA_HOME") != btrfs ]] || skip "the data folder is on btrfs too"
  use_install "$B/win"
  take_snapshot
  assert_equal "$(dirname "$SNAP")" "$B/win.lanai-snapshots"
}

@test "snapshot: only a complete snapshot counts; old partial folders are not swept" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local root=$B/data/lanai/snapshots
  mkdir -p "$root/20260101T000000Z.partial" "$root/20260102T000000Z.partial" \
    "$root/20260103T000000Z" "$root/20260104T000000Z.partial"
  # Interrupted mid-copy (no SOURCE yet), after COMPLETE but before the
  # rename, a final name with no COMPLETE, and another location's partial.
  cp "$B/win/windows.vars" "$root/20260101T000000Z.partial/"
  echo "$B/win" >"$root/20260102T000000Z.partial/SOURCE"
  tree_manifest "$B/win" >"$root/20260102T000000Z.partial/COMPLETE"
  cp "$B/win/windows.vars" "$root/20260103T000000Z/"
  echo "$B/elsewhere" >"$root/20260104T000000Z.partial/SOURCE"
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots | length' <<<"$JSON")" 0
  lanai_run restore 20260103T000000Z
  assert_failure
  take_snapshot
  assert [ -e "$root/20260101T000000Z.partial" ]
  assert [ -e "$root/20260102T000000Z.partial" ]
  assert [ -e "$root/20260104T000000Z.partial" ]
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots | length' <<<"$JSON")" 1
}

@test "snapshot: a COMPLETE whose files do not match is not a snapshot" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  echo extra >>"$SNAP/windows.vars"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "no complete snapshot"
}

# Change the install at <dir> the way a bad first boot or dockur might: new
# disk contents of another size, new variables, a missing boot marker, and
# dockur's leftover setup image.
damage() {
  head -c "$2" /dev/urandom >"$1/data.img.new"
  cat "$1/data.img.new" >"$1/data.img"
  rm "$1/data.img.new"
  echo "changed vars" >"$1/windows.vars"
  rm "$1/windows.boot"
  echo stray >"$1/setup.img"
}

@test "restore: returns the storage location to the snapshot's exact files" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local before ino size
  before=$(tree_manifest "$B/win")
  take_snapshot
  for size in 3M 256K; do
    damage "$B/win" "$size"
    ino=$(stat -c %i "$B/win/data.img")
    lanai_run restore "$NAME"
    assert_success
    assert_equal "$(tree_manifest "$B/win")" "$before"
    # The disk was cloned in place: same inode, the one QEMU's lock is on.
    assert_equal "$(stat -c %i "$B/win/data.img")" "$ino"
    assert [ ! -e "$S/restore-in-progress" ]
  done
}

@test "restore: setup starts again, with no step5 and no guest-version, even after a clean setup boot" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  # A finished setup, then a clean setup boot whose markers no start has
  # recorded yet.
  jq -n -c --arg l "$B/win" '{location: $l, snapshot: "taken", done: true}' >"$S/setup.json"
  echo B7-826-g236efcb155 >"$S/guest-version"
  echo inv-1 >"$S/running"
  echo inv-1 >"$S/started"
  echo '{"scale": 100, "setup": true}' >"$S/boot.json"
  echo '{"invocation":"inv-1","guest":true,"reason":"guest-shutdown"}' >"$S/last-shutdown"
  lanai_run restore "$NAME"
  assert_success
  assert_equal "$(field next)" "run Lanai setup"
  assert [ ! -e "$S/setup.json" ]
  assert [ ! -e "$S/guest-version" ]
  assert [ ! -e "$S/running" ]
  run setup_done
  assert_failure
}

@test "restore: after setup filled in an empty windows.base, it matches the pre-adoption hashes" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  mkdir -p "$HOME/Windows"
  shim pacman 'exit 0'
  : >"$B/win/windows.base"
  local before
  before=$(tree_manifest "$B/win")
  take_snapshot
  # Setup's step 3a, after the snapshot it finds.
  run --separate-stderr cmd_setup
  JSON=$output
  assert_equal "$(field step)" 3a
  assert_equal "$(<"$B/win/windows.base")" win11x64.iso
  lanai_run restore "$NAME"
  assert_success
  assert_equal "$(tree_manifest "$B/win")" "$before"
}

@test "restore: a refused restore keeps setup state" {
  use_install "$T/win"
  mkdir -p "$S"
  jq -n -c --arg l "$T/win" '{location: $l, done: true}' >"$S/setup.json"
  lanai_run restore 20200101T000000Z
  assert_failure
  run setup_done
  assert_success
}

@test "restore: a snapshot whose data changed is refused before anything is written" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  damage "$B/win" 2M
  local before
  before=$(tree_manifest "$B/win")
  flip_byte "$SNAP/windows.vars"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "damaged"
  assert_equal "$(tree_manifest "$B/win")" "$before"
  assert [ ! -e "$S/restore-in-progress" ]
}

@test "restore: a damaged temporary small file refuses before replacement and can retry" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  damage "$B/win" 2M
  plain_cp
  : >"$T/real-reflink"
  : >"$T/real-reflink"
  echo "$B/win/.lanai-restore.windows.vars" >"$T/damage"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "damaged"
  assert [ ! -e "$S/restore-in-progress" ]
  # Without the damage, the rerun finishes.
  rm "$T/damage"
  lanai_run restore "$NAME"
  assert_success
}

@test "restore: a file that appears while it runs is kept, and the restore does not finish" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  damage "$B/win" 2M
  plain_cp
  : >"$T/real-reflink"
  : >"$T/real-reflink"
  echo "$B/win/notes.txt" >"$T/plant"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "notes.txt"
  assert_equal "$(<"$B/win/notes.txt")" mine
  assert [ -e "$S/restore-in-progress" ]
}

@test "restore: a NOCOW mismatch or an empty snapshot disk is refused before anything changes" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  # The live disk becomes NOCOW after the snapshot: btrfs cannot clone
  # between the two.
  local before
  head -c 1M /dev/urandom >"$B/disk"
  rm "$B/win/data.img"
  : >"$B/win/data.img"
  chattr +C "$B/win/data.img"
  cat "$B/disk" >>"$B/win/data.img"
  echo changed >"$B/win/windows.vars"
  before=$(tree_manifest "$B/win")
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "NOCOW"
  assert_output --partial "Nothing was changed"
  assert_equal "$(tree_manifest "$B/win")" "$before"
  assert [ ! -e "$S/restore-in-progress" ]
  # An empty disk in a snapshot cannot be cloned. (lanai snapshot refuses
  # an empty data.img, so the test empties the snapshot's copy and its
  # manifest to match.)
  use_install "$B/win2"
  sleep 1
  take_snapshot
  : >"$SNAP/data.img"
  snapshot_manifest "$SNAP" >"$SNAP/COMPLETE"
  echo changed >"$B/win2/windows.vars"
  before=$(tree_manifest "$B/win2")
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "empty"
  assert_equal "$(tree_manifest "$B/win2")" "$before"
  assert [ ! -e "$S/restore-in-progress" ]
}

@test "restore: puts back a disk that dockur deleted" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local before
  before=$(tree_manifest "$B/win")
  take_snapshot
  rm "$B/win/data.img" "$B/win/windows.rom"
  lanai_run restore "$NAME"
  assert_success
  assert_equal "$(tree_manifest "$B/win")" "$before"
}

@test "restore: resumes after an interruption at each replacement step" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local before n i f
  local -a order
  before=$(tree_manifest "$B/win")
  take_snapshot
  # Resume accepts interruptions left by either restore order, including old versions.
  mapfile -t order < <(find "$SNAP" -mindepth 1 -maxdepth 1 ! -name COMPLETE ! -name SOURCE \
    ! -name data.img -printf '%P\n' | LC_ALL=C sort)
  order+=(data.img)
  for ((n = 0; n <= ${#order[@]}; n++)); do
    # The state a restore leaves when it stops after n replacements: the
    # first n files are the snapshot's, the rest still damaged, a temp file
    # of the next step left over, and the marker still there.
    damage "$B/win" 2M
    for ((i = 0; i < n; i++)); do
      f=${order[i]}
      rm -f "$B/win/$f"
      cp --reflink=always "$SNAP/$f" "$B/win/$f"
    done
    ((n == ${#order[@]})) || echo partial >"$B/win/.lanai-restore.${order[n]}"
    mark_restore "$SNAP" "$B/win"
    # lanai start refuses meanwhile (plan: resumable restore).
    run preflight
    assert_failure
    assert_output --partial "a restore did not finish"
    # Rerun without a name: it resumes the same snapshot.
    lanai_run restore
    assert_success
    assert_equal "$(tree_manifest "$B/win")" "$before"
    assert [ ! -e "$S/restore-in-progress" ]
  done
}

@test "restore: an unfinished restore refuses another snapshot and a new snapshot" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  mark_restore "$SNAP" "$B/win"
  lanai_run restore 20200101T000000Z
  assert_failure
  run field message
  assert_output --partial "did not finish"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "did not finish"
  lanai_run restore "$NAME"
  assert_success
}

# Phase B hooks run inside the helper with its image descriptors still open.
# Every mutation restores size and mtime; only shared storage proves the bytes.
proof_mode() {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  rm "$B/win/data.img"
  : >"$B/win/data.img"
  case $1 in
    normal) chattr +m "$B/win/data.img" ;;
    nocow) chattr +C "$B/win/data.img" ;;
    compressed|mixed) chattr +c "$B/win/data.img" ;;
  esac
  if [[ $1 == normal || $1 == nocow ]]; then
    head -c 2M /dev/urandom >>"$B/win/data.img"
  else
    # Compressible nonzero blocks, followed by a plain random region for mixed.
    python3 -c 'import sys; sys.stdout.buffer.write(b"X" * 2097152)' >>"$B/win/data.img"
    [[ $1 != mixed ]] || head -c 1M /dev/urandom >>"$B/win/data.img"
  fi
  fallocate -z -o 524288 -l 262144 "$B/win/data.img"
  sync -f "$B/win"
  local counts
  counts=$(python3 "$REPO/docs/plugin/proof-kit/count-image-extents.py" --json "$B/win/data.img")
  assert [ "$(jq '.classes.unwritten // 0' <<<"$counts")" -gt 0 ]
  case $1 in
    normal|nocow) assert_equal "$(jq '.classes.encoded // 0' <<<"$counts")" 0 ;;
    compressed) assert [ "$(jq '.classes.encoded // 0' <<<"$counts")" -gt 0 ] ;;
    mixed)
      assert [ "$(jq '.classes.encoded // 0' <<<"$counts")" -gt 0 ]
      assert [ "$(jq '.classes.plain // 0' <<<"$counts")" -gt 0 ] ;;
  esac
  [[ $1 != nocow ]] || has_nocow "$B/win/data.img"
}

mutation_hook() {
  cat >"$T/mutate" <<'PY'
#!/usr/bin/env python3
import os
import sys
path = sys.argv[int(os.environ.get("MUTATE_FILE", "2"))]
st = os.stat(path)
with open(path, "r+b") as f:
    f.seek(int(os.environ.get("MUTATE_OFFSET", "0")))
    f.write(b"changed block" * 256)
    f.flush()
    os.fsync(f.fileno())
os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
PY
  chmod +x "$T/mutate"
}

proof_mutations() {
  proof_mode "$1"
  mutation_hook
  local hook offset target
  for hook in LANAI_TEST_IMAGE_AFTER_MAP LANAI_TEST_IMAGE_AFTER_HASH; do
    for offset in 0 524288; do
      for target in 1 2; do
        export MUTATE_FILE=$target MUTATE_OFFSET=$offset
        export "$hook=$T/mutate"
        lanai_run snapshot
        assert_failure
        assert_output --partial "nothing was kept"
        assert [ ! -e "$S/image-progress.json" ]
        unset "$hook"
        sleep 1
      done
    done
  done
  take_snapshot
  for hook in LANAI_TEST_IMAGE_AFTER_MAP LANAI_TEST_IMAGE_AFTER_HASH LANAI_TEST_IMAGE_AFTER_INSTALL; do
    for offset in 0 524288; do
      export MUTATE_FILE=2 MUTATE_OFFSET=$offset
      export "$hook=$T/mutate"
      lanai_run restore "$NAME"
      assert_failure
      assert_output --partial "changed"
      unset "$hook"
      if [[ $hook == LANAI_TEST_IMAGE_AFTER_INSTALL ]]; then
        assert [ -e "$S/restore-in-progress" ]
      else
        assert [ ! -e "$S/restore-in-progress" ]
      fi
      lanai_run restore "$NAME"
      assert_success
    done
  done
}

@test "proof: normal btrfs mutations reject snapshot and restore including unwritten blocks" { proof_mutations normal; }
@test "proof: NOCOW btrfs mutations reject snapshot and restore including unwritten blocks" { proof_mutations nocow; }
@test "proof: compressed btrfs mutations reject snapshot and restore including unwritten blocks" { proof_mutations compressed; }
@test "proof: mixed btrfs mutations reject snapshot and restore including unwritten blocks" { proof_mutations mixed; }

@test "proof: a plain copy is never accepted as a successful proof" {
  proof_mode normal
  cp --reflink=never "$B/win/data.img" "$B/plain.img"
  run python3 "$REPO/lib/image-proof.py" prove "$B/win/data.img" "$B/plain.img" "$B/map.json" adopt
  assert_failure
  assert_output --partial "shared storage does not match"
}

@test "proof: sparse maps pass and an unsupported image creates no partial folder" {
  proof_mode normal
  truncate -s 8M "$B/win/data.img"
  take_snapshot
  lanai_run restore "$NAME"
  assert_success
  use_install "$T/win"
  lanai_run snapshot
  assert_failure
  assert_equal "$(field reason)" snapshot-unsupported
  assert [ ! -e "$T/win.lanai-snapshots" ]
}

@test "proof: snapshot mutations after cloning are caught even when the hashed clone matches COMPLETE" {
  local mode hook offset
  for mode in normal nocow compressed mixed; do
    proof_mode "$mode"
    take_snapshot
    reflink_file "$SNAP/data.img" "$B/pristine.img"
    mutation_hook
    for hook in LANAI_TEST_IMAGE_AFTER_MAP LANAI_TEST_IMAGE_AFTER_HASH; do
      for offset in 0 524288; do
        export MUTATE_FILE=1 MUTATE_OFFSET=$offset
        export "$hook=$T/mutate"
        lanai_run restore "$NAME"
        assert_failure
        assert_output --partial "changed"
        assert [ ! -e "$S/restore-in-progress" ]
        unset "$hook"
        rm "$SNAP/data.img"
        reflink_file "$B/pristine.img" "$SNAP/data.img"
      done
    done
    rm -rf "$B"
    B=''
  done
}

@test "proof: deleted disk is locked and verified boot files exist before the one image read" {
  proof_mode normal
  take_snapshot
  rm "$B/win/data.img" "$B/win/windows.boot"
  cat >"$T/deleted-hook" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -f ${2%/*}/windows.boot && -f ${2%/*}/windows.rom ]]
# A mock container's installation check sees an existing install; a fixture
# QEMU uses its ordinary disk-open path and must fail on the locked inode.
if timeout 2 qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \
  -drive "file=$2,format=raw,if=none,id=d" -device virtio-scsi-pci -device scsi-hd,drive=d \
  </dev/null 3>&- 2>"$T/deleted-lock"; then exit 1; fi
grep -q 'Failed to get.*lock' "$T/deleted-lock"
: >"$T/deleted-probed"
SH
  chmod +x "$T/deleted-hook"
  export LANAI_TEST_IMAGE_AFTER_MAP=$T/deleted-hook
  lanai_run restore "$NAME"
  assert_success
  assert [ -f "$T/deleted-probed" ]
  assert [ ! -e "$S/restore-in-progress" ]
}

@test "proof: no-replace publication preserves a contender's disk inode and keeps recovery blocked" {
  proof_mode normal
  take_snapshot
  rm "$B/win/data.img"
  shim python3 'if [[ $2 == publish ]]; then
  echo contender >"${@: -1}"
  stat -c %i "${@: -1}" >"$T/contender-inode"
fi
exec /usr/bin/python3 "$@"'
  lanai_run restore "$NAME"
  assert_failure
  assert_output --partial "File exists"
  assert_equal "$(stat -c %i "$B/win/data.img")" "$(<"$T/contender-inode")"
  assert_equal "$(<"$B/win/data.img")" contender
  assert [ -e "$S/restore-in-progress" ]
}

@test "proof: resume discards a stale temporary inode with the wrong NOCOW attribute" {
  proof_mode nocow
  take_snapshot
  mark_restore "$SNAP" "$B/win"
  : >"$B/win/.lanai-restore.data.img"
  chattr -C "$B/win/.lanai-restore.data.img"
  echo stale >"$B/win/.lanai-restore.data.img"
  lanai_run restore
  assert_success
  has_nocow "$B/win/data.img"
  assert [ ! -e "$B/win/.lanai-restore.data.img" ]
}

@test "proof: existing destination extent classes do not gate an otherwise provable restore" {
  proof_mode normal
  take_snapshot
  # A tiny inline destination is unprovable by itself, but is wholly replaced.
  rm "$B/win/data.img"
  printf short >"$B/win/data.img"
  sync -f "$B/win"
  run python3 "$REPO/lib/image-proof.py" gate "$B/win/data.img"
  assert_failure
  assert_output --partial "unprovable"
  local ino
  ino=$(stat -c %i "$B/win/data.img")
  lanai_run restore "$NAME"
  assert_success
  assert_equal "$(stat -c %i "$B/win/data.img")" "$ino"
}

@test "proof: gate refusals and FIEMAP errors create neither a marker nor a partial snapshot" {
  proof_mode normal
  take_snapshot
  # Simulate an ioctl error, not a successful proof, through the actual CLI.
  shim python3 'if [[ $1 == */image-proof.py && $2 == gate ]]; then
  echo "image-proof: FIEMAP ioctl failed" >&2; exit 1
fi
exec /usr/bin/python3 "$@"'
  lanai_run restore "$NAME"
  assert_failure
  assert_output --partial "FIEMAP ioctl failed"
  assert [ ! -e "$S/restore-in-progress" ]
  lanai_run snapshot
  assert_failure
  run find "${SNAP%/*}" -name '*.partial'
  assert_output ""
}

@test "proof: snapshot root fallback occurs only for EXDEV and EINVAL and removes partial folders" {
  proof_mode normal
  local rc
  for rc in 3 1; do
    export CLONE_RC=$rc
    shim python3 'if [[ $1 == */ficlone.py && $2 == --new && ${@: -1} == "$XDG_DATA_HOME"/* ]]; then
  echo "clone errno fixture" >&2; exit "$CLONE_RC"
fi
exec /usr/bin/python3 "$@"'
    lanai_run snapshot
    if ((rc == 3)); then
      assert_success
      assert_equal "$(dirname "$(field snapshot)")" "$B/win.lanai-snapshots"
    else
      assert_failure
      assert_output --partial "nothing was kept"
    fi
    run find "$B/data/lanai/snapshots" -mindepth 1
    assert_output ""
  done
}

@test "proof: a NOCOW image falls back to the root beside storage when the data folder cannot hold NOCOW" {
  [[ -d /dev/shm && $(stat -f -c %T /dev/shm) == tmpfs ]] || skip "needs a tmpfs /dev/shm"
  proof_mode nocow
  XDG_DATA_HOME=$(mktemp -d /dev/shm/lanai-test.XXXXXX)
  export XDG_DATA_HOME
  lanai_run snapshot
  local data=$XDG_DATA_HOME
  rm -rf -- "$data"
  assert_success
  assert_equal "$(dirname "$(field snapshot)")" "$B/win.lanai-snapshots"
}

@test "restore: a staged small file swapped for a symlink during the image hash is refused" {
  proof_mode normal
  take_snapshot
  echo live >"$B/win/windows.vars"
  local before
  before=$(sha256sum <"$B/win/windows.vars")
  cat >"$T/link-small" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
temp=${2%/*}/.lanai-restore.windows.vars
rm -f "$temp"
ln -s "${1%/*}/windows.vars" "$temp"
SH
  chmod +x "$T/link-small"
  export LANAI_TEST_IMAGE_AFTER_HASH=$T/link-small
  lanai_run restore "$NAME"
  assert_failure
  assert_output --partial "windows.vars"
  assert [ ! -L "$B/win/windows.vars" ]
  assert_equal "$(sha256sum <"$B/win/windows.vars")" "$before"
  assert [ -e "$S/restore-in-progress" ]
  unset LANAI_TEST_IMAGE_AFTER_HASH
  # Lanai never removes a link it did not make; the user moves it out first.
  lanai_run restore
  assert_failure
  assert_output --partial ".lanai-restore.windows.vars (not a regular file)"
  rm "$B/win/.lanai-restore.windows.vars"
  lanai_run restore
  assert_success
  assert [ ! -L "$B/win/windows.vars" ]
  assert [ ! -e "$S/restore-in-progress" ]
}

@test "proof: each small temporary file is hashed before any rename" {
  proof_mode normal
  take_snapshot
  plain_cp
  : >"$T/real-reflink"
  local name before
  before=$(tree_manifest "$B/win")
  for name in windows.base windows.mac windows.rom windows.vars windows.ver; do
    echo "$B/win/.lanai-restore.$name" >"$T/damage"
    lanai_run restore "$NAME"
    assert_failure
    assert_output --partial "damaged"
    assert_equal "$(tree_manifest "$B/win")" "$before"
    assert [ ! -e "$S/restore-in-progress" ]
  done
}

# Mutate a staged small file at either image hook, preserving its length.
# Older deleted-disk restores have already renamed it; recreate the temp in
# that case to expose their missing final verification too.
small_temp_changes_during_image_hash() {
  local deleted=$1 name before hook
  proof_mode normal
  echo boot >"$B/win/windows.boot"
  take_snapshot
  cat >"$T/change-small" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
temp=${2%/*}/.lanai-restore.$MUTATE_SMALL
[[ -f $temp ]] || cp --reflink=always "${1%/*}/$MUTATE_SMALL" "$temp"
stat -c %s "$temp" >"$T/small-size-before"
printf Z | dd of="$temp" bs=1 count=1 conv=notrunc status=none
stat -c %s "$temp" >"$T/small-size-after"
SH
  chmod +x "$T/change-small"
  for hook in LANAI_TEST_IMAGE_AFTER_MAP LANAI_TEST_IMAGE_AFTER_HASH; do
    for name in windows.base windows.boot windows.mac windows.rom windows.vars windows.ver; do
      if $deleted; then
        rm -f "$B/win/data.img"
        before=$(sha256sum <"$SNAP/$name")
      else
        echo live >"$B/win/$name"
        before=$(sha256sum <"$B/win/$name")
      fi
      export MUTATE_SMALL=$name
      export "$hook=$T/change-small"
      lanai_run restore "$NAME"
      assert_failure
      assert_output --partial "restore did not finish"
      assert_output --partial "$name"
      assert_output --partial "does not match its manifest"
      assert_equal "$(<"$T/small-size-before")" "$(<"$T/small-size-after")"
      assert_equal "$(sha256sum <"$B/win/$name")" "$before"
      assert [ -e "$S/restore-in-progress" ]
      unset "$hook"
      lanai_run restore
      assert_success
      assert [ ! -e "$S/restore-in-progress" ]
    done
  done
}

@test "restore: existing disk refuses small temps changed during the image hash" {
  small_temp_changes_during_image_hash false
}

@test "restore: deleted disk refuses small temps changed during the image hash" {
  small_temp_changes_during_image_hash true
}

@test "proof: interruption keeps the restore marker and removes operation progress" {
  proof_mode normal
  take_snapshot
  cat >"$T/interrupt" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
kill -TERM "$LANAI_IMAGE_OWNER"
SH
  chmod +x "$T/interrupt"
  export LANAI_TEST_IMAGE_AFTER_MAP=$T/interrupt
  lanai_run restore "$NAME"
  assert_failure
  assert [ -e "$S/restore-in-progress" ]
  assert [ ! -e "$S/image-progress.json" ]
  unset LANAI_TEST_IMAGE_AFTER_MAP
  lanai_run restore
  assert_success
}

@test "proof: strace single image read budget includes concurrent panel polls for CLI snapshot and restore" {
  if ! command -v strace >/dev/null; then
    [[ ${LANAI_REQUIRE_BTRFS:-0} != 1 ]] || fail "CI requires strace for the image read budget"
    skip "strace unavailable; CI requires the measurement"
  fi
  proof_mode normal
  export TRACE_REPO=$REPO
  cat >"$T/hold-map" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: >"$T/map-ready"
for ((n=0;n<300;n++)); do
  [[ ! -f $T/map-release ]] || exit 0
  sleep 0.1
done
exit 1
SH
  chmod +x "$T/hold-map"
  cat >"$T/trace-operation" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$TRACE_REPO/bin/lanai" "$@" >"$T/traced-reply" &
job=$!
for ((n=0;n<300;n++)); do
  [[ ! -f $T/map-ready ]] || break
  sleep 0.1
done
[[ -f $T/map-ready ]]
for ((p=0;p<3;p++)); do
  "$TRACE_REPO/bin/lanai" panel >"$T/poll.$p"
  jq -e '.busy.active and .progress != null' "$T/poll.$p" >/dev/null
done
: >"$T/map-release"
wait "$job"
SH
  local image_size small operation counts
  image_size=$(stat -c %s "$B/win/data.img")
  small=$(find "$B/win" -type f ! -name data.img -printf '%s\n' | awk '{s+=$1} END {print s}')
  export LANAI_TEST_IMAGE_AFTER_MAP=$T/hold-map
  for operation in snapshot restore; do
    rm -f "$T/map-ready" "$T/map-release"
    if [[ $operation == snapshot ]]; then
      run strace -f -yy -o "$T/reads.trace" -e trace=read,pread64,readv,preadv,preadv2,mmap,sendfile,splice,copy_file_range \
        bash "$T/trace-operation" snapshot
      assert_success
      NAME=$(jq -r .name "$T/traced-reply")
    else
      run strace -f -yy -o "$T/reads.trace" -e trace=read,pread64,readv,preadv,preadv2,mmap,sendfile,splice,copy_file_range \
        bash "$T/trace-operation" restore "$NAME"
      assert_success
    fi
    run python3 "$REPO/test/fixtures/image-read-budget.py" "$T/reads.trace" "$image_size" "$small" 3
    assert_success
    counts=$output
    printf '# %s bytes read: %s\n' "$operation" "$counts" >&3
    assert [ ! -e "$S/image-progress.json" ]
  done
}

@test "proof: replacing the read path after its map refuses completion" {
  proof_mode normal
  cat >"$T/replace" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cp --reflink=always "$2" "$2.changed"
mv -f -T "$2.changed" "$2"
SH
  chmod +x "$T/replace"
  export LANAI_TEST_IMAGE_AFTER_MAP=$T/replace
  lanai_run snapshot
  assert_failure
  assert_output --partial "path changed"
  assert_output --partial "nothing was kept"
}

@test "proof: FIEMAP pagination covers more than one batch and preserves sparse holes" {
  proof_mode normal
  python3 - "$B/win/data.img" <<'PY'
import os
import sys
with open(sys.argv[1], "wb") as f:
    for n in range(1100):
        f.seek(n * 8192)
        f.write(b"a" * 4096)
    f.flush()
    os.fsync(f.fileno())
PY
  local counts
  counts=$(python3 "$REPO/docs/plugin/proof-kit/count-image-extents.py" --json "$B/win/data.img")
  assert [ "$(jq '.classes.plain' <<<"$counts")" -gt 1024 ]
  take_snapshot
  lanai_run restore "$NAME"
  assert_success
}

@test "proof: interrupted snapshot removes its partial folder and progress" {
  proof_mode normal
  cat >"$T/interrupt-snapshot" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
kill -TERM "$LANAI_IMAGE_OWNER"
SH
  chmod +x "$T/interrupt-snapshot"
  export LANAI_TEST_IMAGE_AFTER_MAP=$T/interrupt-snapshot
  lanai_run snapshot
  assert_failure
  assert [ ! -e "$S/image-progress.json" ]
  run find "$B/data/lanai/snapshots" -mindepth 1
  assert_output ""
}
