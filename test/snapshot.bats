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
if [[ -e $T/probe-lock && ( ${src##*/} == data.img || ${dst##*/} == .lanai-restore.* ) ]]; then
  rc=0
  timeout 2 qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \
    -drive "file=$STORE/data.img,format=raw,if=none,id=d" -device virtio-scsi-pci \
    -device scsi-hd,drive=d 3>&- 2>/dev/null || rc=$?
  echo "$rc" >>"$T/vm-open"
fi
if [[ -e $T/real-reflink ]] && ((reflink)); then args=(--reflink=always "${args[@]}"); fi
/usr/bin/cp "${args[@]}" || exit
if [[ -e $T/damage ]] && [[ $dst == $(<"$T/damage") ]]; then
  printf "\\x$(printf %02x $(( ($(od -An -tu1 -N1 "$dst") + 1) % 256 )))" |
    dd of="$dst" bs=1 count=1 conv=notrunc status=none
fi'
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
  use_install "$T/win"
  plain_cp
  take_snapshot
  echo changed >"$T/win/windows.vars"
  local before
  before=$(tree_manifest "$T/win")
  echo active >"$T/unit-state"
  lanai_run snapshot
  assert_failure
  assert_equal "$(field message)" "Windows is running under Lanai. Shut it down first."
  lanai_run restore "$NAME"
  assert_failure
  assert_equal "$(field message)" "Windows is running under Lanai. Shut it down first."
  assert [ ! -e "$S/restore-in-progress" ]
  assert_equal "$(tree_manifest "$T/win")" "$before"
}

@test "snapshot and restore refuse while the container VM runs or prepares, changing nothing" {
  use_install "$T/win"
  plain_cp
  take_snapshot
  echo changed >"$T/win/windows.vars"
  local before scope=/system.slice/docker-4f1c2d3e4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff.scope
  before=$(tree_manifest "$T/win")
  fake_proc 700 "$scope" /usr/bin/qemu-system-x86_64
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "Docker VM is running"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "Docker VM is running"
  rm -rf "$T/proc/700"
  fake_proc 701 "$scope" /bin/bash /run/entry.sh
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "preparing"
  lanai_run restore "$NAME"
  assert_failure
  assert [ ! -e "$S/restore-in-progress" ]
  assert_equal "$(tree_manifest "$T/win")" "$before"
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
  assert_output --partial "another Lanai start, snapshot or restore is running"
  lanai_run restore 20260928T120000Z
  assert_failure
  run field message
  assert_output --partial "another Lanai"
}

@test "snapshot: without reflinks it says so, suggests a backup, and leaves nothing" {
  use_install "$T/win"
  [[ $(stat -f -c %T "$T") != btrfs && $(stat -f -c %T "$T") != xfs ]] || skip "the temp dir can reflink"
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
  use_install "$T/win"
  plain_cp
  : >"$T/probe-lock"
  take_snapshot
  # During the copy no VM could open the disk; afterwards one can.
  assert_equal "$(<"$T/vm-open")" 1
  vm_can_open "$T/win/data.img" || fail "the lock outlived the snapshot"
  # The snapshot still matches its source, and names it.
  assert_equal "$(<"$SNAP/COMPLETE")" "$(tree_manifest "$T/win")"
  assert_equal "$(<"$SNAP/SOURCE")" "$T/win"
  # Restore: the other files go first, under the lock; FICLONE needs a
  # reflink filesystem, so on tmpfs the restore stops there, unfinished.
  : >"$T/vm-open"
  echo changed >"$T/win/windows.vars"
  lanai_run restore "$NAME"
  if [[ $(stat -f -c %T "$T") != btrfs && $(stat -f -c %T "$T") != xfs ]]; then
    assert_failure
    run field message
    assert_output --partial "run lanai restore again"
    assert [ -e "$S/restore-in-progress" ]
  fi
  [[ -s $T/vm-open ]] || fail "the restore copied nothing"
  run sort -u "$T/vm-open"
  assert_output 1
  vm_can_open "$T/win/data.img" || fail "the lock outlived the restore"
}

@test "snapshot: a copy that does not match its source is removed, and the lock released" {
  use_install "$T/win"
  plain_cp
  echo "*.partial/windows.mac" >"$T/damage"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "nothing was kept"
  run find "$XDG_DATA_HOME/lanai/snapshots" -mindepth 1
  assert_output ""
  vm_can_open "$T/win/data.img" || fail "the lock outlived the failed snapshot"
}

@test "restore: refuses a storage folder that holds anything but an install" {
  use_install "$T/win"
  plain_cp
  take_snapshot
  # Lanai's storage now points at a folder with someone's own files.
  mkdir -p "$T/docs/precious"
  echo keep >"$T/docs/precious/doc.txt"
  cp "$T/win/windows.vars" "$T/docs/"
  point_at "$T/docs"
  lanai_run restore "$NAME"
  assert_failure
  assert_equal "$(<"$T/docs/precious/doc.txt")" keep
  assert [ -f "$T/docs/windows.vars" ]
  assert [ ! -e "$S/restore-in-progress" ]
  # An install with one foreign file or folder is refused too, untouched.
  point_at "$T/win"
  echo mine >"$T/win/notes.txt"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "notes.txt"
  assert_equal "$(<"$T/win/notes.txt")" mine
  rm "$T/win/notes.txt"
  mkdir "$T/win/tmp"
  lanai_run restore "$NAME"
  assert_failure
  assert [ -d "$T/win/tmp" ]
}

@test "restore: refuses a symlinked data.img and a storage folder that does not exist" {
  use_install "$T/win"
  plain_cp
  take_snapshot
  mv "$T/win/data.img" "$T/elsewhere.img"
  ln -s "$T/elsewhere.img" "$T/win/data.img"
  echo changed >"$T/win/windows.vars"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "data.img (not a regular file)"
  assert [ -L "$T/win/data.img" ]
  assert_equal "$(<"$T/win/windows.vars")" changed
  assert [ ! -e "$S/restore-in-progress" ]
  point_at "$T/gone"
  lanai_run restore "$NAME"
  assert_failure
  assert [ ! -e "$T/gone" ]
}

@test "snapshot: records its source, and another storage location never sees it" {
  use_install "$T/win"
  plain_cp
  take_snapshot
  use_install "$T/other"
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots | length' <<<"$JSON")" 0
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "no complete snapshot"
  # An unfinished restore of the first location does not resume on this one.
  mark_restore "$SNAP" "$T/win"
  lanai_run restore
  assert_failure
  run field message
  assert_output --partial "was for $T/win"
  assert_equal "$(tree_manifest "$T/other")" "$(tree_manifest "$SNAP" | grep -vE ' (COMPLETE|SOURCE)$')"
}

@test "restore: when the unfinished restore's snapshot is gone, another can replace it" {
  use_install "$T/win"
  plain_cp
  take_snapshot
  local first=$SNAP
  sleep 1
  take_snapshot
  mark_restore "$first" "$T/win"
  rm -rf "$first"
  lanai_run restore
  assert_failure
  run field message
  assert_output --partial "gone or damaged"
  assert_output --partial "$S/restore-in-progress"
  # On tmpfs the clone step fails, but the marker now names the new snapshot.
  lanai_run restore "$NAME"
  assert_equal "$(head -n1 "$S/restore-in-progress" 2>/dev/null || echo "$SNAP")" "$SNAP"
  run field message
  if [[ $(field ok) == true ]]; then assert_output --partial "replacing the unfinished restore"; fi
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

@test "snapshot: only a complete snapshot counts; this location's leftovers are removed" {
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
  assert [ ! -e "$root/20260101T000000Z.partial" ]
  assert [ ! -e "$root/20260102T000000Z.partial" ]
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

@test "restore: a result that does not match the snapshot keeps the marker, and start refuses" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  take_snapshot
  damage "$B/win" 2M
  plain_cp
  : >"$T/real-reflink"
  echo "$B/win/.lanai-restore.windows.vars" >"$T/damage"
  lanai_run restore "$NAME"
  assert_failure
  run field message
  assert_output --partial "run lanai restore again"
  assert [ -e "$S/restore-in-progress" ]
  run preflight
  assert_failure
  assert_output --partial "a restore did not finish"
  # Without the damage, the rerun finishes.
  rm "$T/damage"
  lanai_run restore
  assert_success
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
  # Restore order: every other file by name, then data.img last.
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
