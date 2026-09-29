#!/usr/bin/env bats
# Tests for lanai snapshot, lanai restore and lib/ficlone.py (spec 7, plan
# phase 4). Every install is a scratch folder the test builds; the only QEMU
# started is a paused TCG one on that folder's 1 MiB data.img. Tests that
# need real reflinks run under LANAI_TEST_BTRFS_DIR; the others run on any
# filesystem, with a cp shim standing in for reflinks where needed.
# shellcheck disable=SC2030,SC2031,SC2016

load helpers
bats_require_minimum_version 1.5.0

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  S=$XDG_STATE_HOME/lanai
  export T
  # An inactive unit, unless a test writes $T/unit-state.
  shim systemctl 'if [[ " $* " == *" show "* ]]; then cat "$T/unit-state" 2>/dev/null || echo inactive; fi'
  export PATH=$T/shims:$PATH
}

teardown() {
  qemu_release
  if [[ -n ${B:-} ]]; then
    chmod -R u+w "$B" 2>/dev/null || true
    rm -rf "$B"
  fi
}

# Run bin/lanai with bats' run, and keep its JSON for field.
lanai_run() {
  run --separate-stderr "$REPO/bin/lanai" "$@"
  JSON=$output
}

# Print field <name> of the JSON from the last lanai_run.
field() {
  jq -r --arg k "$1" '.[$k] | if . == null then "null" else tostring end' <<<"$JSON"
}

# Point Lanai's storage at <dir> and build an install there.
use_install() {
  make_install "$1"
  mkdir -p "$XDG_CONFIG_HOME/lanai"
  jq -n --arg s "$1" '{storage: $s}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  STORE=$1
}

# A cp stand-in for filesystems without reflinks: it copies plainly. When it
# copies a data.img (a snapshot's copy) or a restore's temp file, it records
# whether a VM could open the install's disk, $STORE/data.img, at that moment
# (124: QEMU ran, so it could; anything else: the lock stopped it).
plain_cp_that_probes_the_lock() {
  export STORE
  shim cp 'args=()
for a; do [[ $a == --reflink=always ]] || args+=("$a"); done
src=${args[-2]} dst=${args[-1]}
if [[ ${src##*/} == data.img || ${dst##*/} == .lanai-restore.* ]]; then
  rc=0
  timeout 2 qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \
    -drive "file=$STORE/data.img,format=raw,if=none,id=d" -device virtio-scsi-pci \
    -device scsi-hd,drive=d 3>&- 2>/dev/null || rc=$?
  echo "$rc" >>"$T/vm-open"
fi
exec /usr/bin/cp "${args[@]}"'
}

# --- refusals, on any filesystem ---

@test "lanai snapshot and restore refuse while Lanai's VM runs" {
  use_install "$T/win"
  echo active >"$T/unit-state"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "running under Lanai"
  lanai_run restore 20260928T120000Z
  assert_failure
}

@test "lanai snapshot and restore refuse while the container VM runs or prepares" {
  use_install "$T/win"
  local scope=/system.slice/docker-4f1c2d3e4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff.scope
  fake_proc 700 "$scope" /usr/bin/qemu-system-x86_64
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "Docker VM is running"
  rm -rf "$T/proc/700"
  fake_proc 701 "$scope" /bin/bash /run/entry.sh
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "preparing"
}

@test "lanai snapshot refuses while any VM holds the disk" {
  use_install "$T/win"
  plain_cp_that_probes_the_lock
  qemu_hold "$T/win/data.img"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "lock"
  qemu_release
}

@test "lanai snapshot: without reflinks it says so, suggests a backup, and leaves nothing" {
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

@test "lanai snapshot and restore hold the disk lock while they copy, then release it" {
  use_install "$T/win"
  plain_cp_that_probes_the_lock
  lanai_run snapshot
  assert_success
  local name
  name=$(field name)
  # During the copy no VM could open the disk; afterwards one can.
  assert_equal "$(<"$T/vm-open")" 1
  vm_can_open "$T/win/data.img" || fail "the lock outlived the snapshot"
  # The snapshot still matches its source.
  assert_equal "$(<"$(field snapshot)/COMPLETE")" "$(tree_manifest "$T/win")"
  # Restore: the non-disk files go first, under the lock; FICLONE needs a
  # reflink filesystem, so on tmpfs the restore stops there, unfinished.
  : >"$T/vm-open"
  echo changed >"$T/win/windows.vars"
  lanai_run restore "$name"
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

@test "lanai restore: refuses an unknown snapshot, and one without a valid COMPLETE" {
  use_install "$T/win"
  lanai_run restore 20260928T120000Z
  assert_failure
  run field message
  assert_output --partial "no complete snapshot"
  mkdir -p "$XDG_DATA_HOME/lanai/snapshots/20260928T120000Z"
  cp "$T/win/windows.vars" "$XDG_DATA_HOME/lanai/snapshots/20260928T120000Z/"
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

@test "ficlone.py: refuses an empty source and a missing destination, changing nothing" {
  btrfs_tmp
  : >"$B/empty"
  head -c 1M /dev/urandom >"$B/dst"
  local before
  before=$(sha256sum <"$B/dst")
  run python3 "$REPO/lib/ficlone.py" "$B/empty" "$B/dst"
  assert_failure
  assert_equal "$(sha256sum <"$B/dst")" "$before"
  run python3 "$REPO/lib/ficlone.py" "$B/dst" "$B/missing"
  assert_failure
  assert [ ! -e "$B/missing" ]
}

# --- snapshot and restore on btrfs ---

@test "lanai snapshot: a verified copy in the data folder when it can reflink there" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  lanai_run snapshot
  assert_success
  local snap
  snap=$(field snapshot)
  assert_equal "${snap%/*}" "$B/data/lanai/snapshots"
  [[ ${snap##*/} =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "bad name ${snap##*/}"
  assert_equal "$(<"$snap/COMPLETE")" "$(tree_manifest "$B/win")"
  run field message
  assert_output --partial "grows as Windows changes"
  assert_output --partial "rm -rf $snap"
  assert_output --partial "lanai restore ${snap##*/}"
  lanai_run snapshots
  assert_success
  assert_equal "$(jq -r '.snapshots[]' <<<"$output")" "$snap"
}

@test "lanai snapshot: falls back to a folder beside the storage location" {
  btrfs_tmp
  [[ $(stat -f -c %T "$XDG_DATA_HOME") != btrfs ]] || skip "the data folder is on btrfs too"
  use_install "$B/win"
  lanai_run snapshot
  assert_success
  assert_equal "$(dirname "$(field snapshot)")" "$B/win.lanai-snapshots"
}

@test "lanai snapshot: only a complete snapshot counts, and leftovers are removed" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local root=$B/data/lanai/snapshots
  mkdir -p "$root/20260101T000000Z.partial" "$root/20260102T000000Z.partial" "$root/20260103T000000Z"
  # Interrupted before COMPLETE, after COMPLETE but before the rename, and a
  # final name with no COMPLETE at all.
  cp "$B/win/windows.vars" "$root/20260101T000000Z.partial/"
  tree_manifest "$B/win" >"$root/20260102T000000Z.partial/COMPLETE"
  cp "$B/win/windows.vars" "$root/20260103T000000Z/"
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots | length' <<<"$output")" 0
  lanai_run restore 20260103T000000Z
  assert_failure
  lanai_run snapshot
  assert_success
  assert [ ! -e "$root/20260101T000000Z.partial" ]
  assert [ ! -e "$root/20260102T000000Z.partial" ]
  lanai_run snapshots
  assert_equal "$(jq -r '.snapshots | length' <<<"$output")" 1
}

@test "lanai snapshot: a COMPLETE whose files do not match is not a snapshot" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  lanai_run snapshot
  local snap
  snap=$(field snapshot)
  echo extra >>"$snap/windows.vars"
  lanai_run restore "${snap##*/}"
  assert_failure
  run field message
  assert_output --partial "no complete snapshot"
}

# Change the install at <dir> the way a bad first boot or dockur might: new
# disk contents of another size, new variables, a missing boot marker, and
# extra files and folders.
damage() {
  head -c "$2" /dev/urandom >"$1/data.img.new"
  cat "$1/data.img.new" >"$1/data.img"
  rm "$1/data.img.new"
  echo "changed vars" >"$1/windows.vars"
  rm "$1/windows.boot"
  echo stray >"$1/custom.iso"
  mkdir -p "$1/tmp/sub"
  echo x >"$1/tmp/sub/f"
}

@test "lanai restore: returns the storage location to the snapshot's exact files" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local before ino size
  before=$(tree_manifest "$B/win")
  lanai_run snapshot
  local name
  name=$(field name)
  for size in 3M 256K; do
    damage "$B/win" "$size"
    ino=$(stat -c %i "$B/win/data.img")
    lanai_run restore "$name"
    assert_success
    assert_equal "$(tree_manifest "$B/win")" "$before"
    # The disk was cloned in place: same inode, the one QEMU's lock is on.
    assert_equal "$(stat -c %i "$B/win/data.img")" "$ino"
    assert [ ! -e "$S/restore-in-progress" ]
  done
}

@test "lanai restore: puts back a disk that dockur deleted" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local before
  before=$(tree_manifest "$B/win")
  lanai_run snapshot
  local name
  name=$(field name)
  rm "$B/win/data.img" "$B/win/windows.rom"
  lanai_run restore "$name"
  assert_success
  assert_equal "$(tree_manifest "$B/win")" "$before"
}

@test "lanai restore: resumes after an interruption at each replacement step" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  local before name snap n i f
  local -a order
  before=$(tree_manifest "$B/win")
  lanai_run snapshot
  name=$(field name)
  snap=$(field snapshot)
  # Restore order: every other file by name, then data.img last.
  mapfile -t order < <(find "$snap" -mindepth 1 -maxdepth 1 ! -name COMPLETE ! -name data.img -printf '%P\n' |
    LC_ALL=C sort)
  order+=(data.img)
  for ((n = 0; n <= ${#order[@]}; n++)); do
    # The state a restore leaves when it stops after n replacements: the
    # first n files are the snapshot's, the rest still damaged, a temp file
    # of the next step left over, and the marker still there.
    damage "$B/win" 2M
    for ((i = 0; i < n; i++)); do
      f=${order[i]}
      rm -f "$B/win/$f"
      cp --reflink=always "$snap/$f" "$B/win/$f"
    done
    ((n == ${#order[@]})) || echo partial >"$B/win/.lanai-restore.${order[n]}"
    mkdir -p "$S"
    printf '%s\n' "$snap" >"$S/restore-in-progress"
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

@test "lanai restore: an unfinished restore refuses another snapshot and a new snapshot" {
  btrfs_tmp
  export XDG_DATA_HOME=$B/data
  use_install "$B/win"
  lanai_run snapshot
  local snap
  snap=$(field snapshot)
  mkdir -p "$S"
  printf '%s\n' "$snap" >"$S/restore-in-progress"
  lanai_run restore 20200101T000000Z
  assert_failure
  run field message
  assert_output --partial "did not finish"
  lanai_run snapshot
  assert_failure
  run field message
  assert_output --partial "did not finish"
  lanai_run restore "${snap##*/}"
  assert_success
}
