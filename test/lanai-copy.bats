#!/usr/bin/env bats
# Tests for bin/lanai-copy and lib/copy.sh (reflink_tree, tree_manifest and
# the disk lock). btrfs tests need LANAI_TEST_BTRFS_DIR; lock tests run
# QEMU under TCG with -S, so they need no KVM.
# shellcheck disable=SC2030,SC2031

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/copy.sh
  source "$REPO/lib/copy.sh"
  T=$BATS_TEST_TMPDIR
}

teardown() {
  qemu_release
  [[ -z ${B:-} ]] || rm -rf "$B"
}

# Build a fake omarchy-windows-vm storage dir at <dir>: a 1 MiB random
# data.img (NOCOW when the second argument is "nocow") and the state files.
make_storage() {
  mkdir -p "$1"
  touch "$1/data.img"
  [[ ${2:-} != nocow ]] || chattr +C "$1/data.img"
  dd if=/dev/urandom of="$1/data.img" bs=1M count=1 conv=notrunc status=none
  echo rom >"$1/windows.rom"
  echo vars >"$1/windows.vars"
  echo 02:4B:81:73:3C:96 >"$1/windows.mac"
  echo win11x64.iso >"$1/windows.base"
  echo 6.05 >"$1/windows.ver"
  : >"$1/windows.boot"
}

# Print the file attribute flags of <path> (the first lsattr field).
attrs() {
  lsattr -d -- "$1" | awk '{ print $1 }'
}

# Skip unless <dir> cannot make reflinks.
require_no_reflink() {
  printf x >"$1/probe"
  if cp --reflink=always "$1/probe" "$1/probe2" 2>/dev/null; then
    skip "$1 supports reflinks"
  fi
  rm -f "$1/probe" "$1/probe2"
}

# --- tree_manifest ---

@test "tree_manifest: lists dirs and files with size and SHA-256, sorted by path" {
  mkdir -p "$T/m/sub"
  printf 'hello\n' >"$T/m/b"
  printf '' >"$T/m/sub/a"
  run tree_manifest "$T/m"
  assert_success
  assert_output "f 6 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03 b
d - - sub
f 0 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 sub/a"
}

@test "tree_manifest: a name with spaces and a backslash is listed as is" {
  mkdir -p "$T/m"
  printf 'x' >"$T/m/a b\\c"
  run tree_manifest "$T/m"
  assert_success
  assert_output "f 1 2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881 a b\\c"
}

@test "tree_manifest: refuses a symlink" {
  mkdir -p "$T/m"
  ln -s /etc/hostname "$T/m/link"
  run tree_manifest "$T/m"
  assert_failure
  assert_output --partial "not a regular file or directory: $T/m/link"
}

@test "tree_manifest: refuses a FIFO" {
  mkdir -p "$T/m"
  mkfifo "$T/m/pipe"
  run tree_manifest "$T/m"
  assert_failure
  assert_output --partial "not a regular file or directory"
}

@test "tree_manifest: two trees differ when one file's content changes" {
  mkdir -p "$T/a" "$T/b"
  echo same >"$T/a/f"
  echo same >"$T/b/f"
  [[ $(tree_manifest "$T/a") == "$(tree_manifest "$T/b")" ]]
  echo diff >"$T/b/f"
  [[ $(tree_manifest "$T/a") != "$(tree_manifest "$T/b")" ]]
}

# --- lock_disk / unlock_disk ---

@test "lock_disk: blocks a VM from opening the disk until unlock_disk" {
  truncate -s 1M "$T/d.img"
  vm_can_open "$T/d.img"
  lock_disk "$T/d.img"
  run vm_can_open "$T/d.img"
  assert_failure
  unlock_disk
  vm_can_open "$T/d.img"
}

@test "lock_disk: fails with QEMU's reason in LANAI_LOCK_ERROR while a VM holds the disk" {
  truncate -s 1M "$T/d.img"
  qemu_hold "$T/d.img"
  if lock_disk "$T/d.img"; then fail "lock_disk took a lock a VM holds"; fi
  [[ $LANAI_LOCK_ERROR == *'Failed to get "write" lock'* ]] || fail "reason: $LANAI_LOCK_ERROR"
}

@test "lock_disk: fails on a missing image" {
  if lock_disk "$T/none.img"; then fail "locked a missing image"; fi
  [[ $LANAI_LOCK_ERROR == *"no disk image"* ]] || fail "reason: $LANAI_LOCK_ERROR"
}

@test "lock_disk: a relative name with a colon is a file, not a QEMU protocol" {
  cd "$T"
  truncate -s 1M "nbd:disk.img"
  lock_disk "nbd:disk.img"
  run vm_can_open "$T/nbd:disk.img"
  assert_failure
  unlock_disk
}

# --- reflink_tree ---

@test "reflink_tree: copies nested dirs and files as shared extents, keeping modes" {
  btrfs_tmp
  make_storage "$B/src"
  mkdir "$B/src/sub" "$B/dst"
  echo nested >"$B/src/sub/f"
  chmod 600 "$B/src/windows.vars"
  chmod 750 "$B/src"
  run reflink_tree "$B/src" "$B/dst"
  assert_success
  [[ $(tree_manifest "$B/src") == "$(tree_manifest "$B/dst")" ]]
  assert_equal "$(stat -c %a "$B/dst/windows.vars")" 600
  assert_equal "$(stat -c %a "$B/dst")" 750
  run filefrag -v "$B/dst/data.img"
  assert_output --partial "shared"
}

@test "reflink_tree: mirrors NOCOW both ways" {
  btrfs_tmp
  make_storage "$B/nocow" nocow
  make_storage "$B/cow"
  # New files in this folder inherit NOCOW, so a COW source needs it removed.
  mkdir "$B/nocow-copy" "$B/cow-copy"
  chattr +C "$B/cow-copy"
  reflink_tree "$B/nocow" "$B/nocow-copy"
  reflink_tree "$B/cow" "$B/cow-copy"
  [[ $(attrs "$B/nocow-copy/data.img") == *C* ]]
  [[ $(attrs "$B/cow-copy/data.img") != *C* ]]
  cmp "$B/cow/data.img" "$B/cow-copy/data.img"
}

@test "reflink_tree: refuses a destination that is not an empty folder, and leaves it alone" {
  btrfs_tmp
  make_storage "$B/src"
  mkdir "$B/dst"
  echo keep >"$B/dst/marker"
  run reflink_tree "$B/src" "$B/dst"
  assert_failure
  assert_output --partial "not an empty folder"
  assert_equal "$(cat "$B/dst/marker")" keep
  assert [ ! -e "$B/dst/data.img" ]
  run reflink_tree "$B/src" "$B/none"
  assert_failure
  assert [ ! -e "$B/none" ]
}

@test "reflink_tree: refuses a symlink in the source" {
  btrfs_tmp
  make_storage "$B/src"
  mkdir "$B/dst"
  ln -s /etc/hostname "$B/src/link"
  run reflink_tree "$B/src" "$B/dst"
  assert_failure
  assert_output --partial "not a regular file or directory: $B/src/link"
}

@test "reflink_tree: fails with a clear reason where reflinks are impossible" {
  mkdir -p "$T/fs/dst"
  require_no_reflink "$T/fs"
  make_storage "$T/fs/src"
  run reflink_tree "$T/fs/src" "$T/fs/dst"
  assert_failure
  assert_output --partial "same btrfs or XFS filesystem"
}

# --- bin/lanai-copy ---

@test "lanai-copy: wrong argument count prints usage" {
  run "$REPO/bin/lanai-copy" only-one
  assert_failure 2
  assert_output --partial "usage: lanai-copy <src> <dst>"
}

@test "lanai-copy: refuses an existing destination" {
  make_storage "$T/src"
  mkdir "$T/dst"
  echo keep >"$T/dst/marker"
  run "$REPO/bin/lanai-copy" "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "already exists"
  assert_equal "$(cat "$T/dst/marker")" keep
}

@test "lanai-copy: refuses a source without data.img" {
  make_storage "$T/src"
  rm "$T/src/data.img"
  run "$REPO/bin/lanai-copy" "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "no data.img"
  assert [ ! -e "$T/dst" ]
}

@test "lanai-copy: refuses a destination inside the source" {
  make_storage "$T/src"
  run "$REPO/bin/lanai-copy" "$T/src" "$T/src/copy"
  assert_failure
  assert_output --partial "inside"
  assert [ ! -e "$T/src/copy" ]
  assert [ ! -e "$T/src/copy.partial" ]
}

@test "lanai-copy: refuses while a VM holds the source disk" {
  make_storage "$T/src"
  qemu_hold "$T/src/data.img"
  run "$REPO/bin/lanai-copy" "$T/src" "$T/dst"
  assert_failure
  # One message: the reason and the next step.
  assert_equal "${#lines[@]}" 1
  assert_output --partial 'Failed to get "write" lock'
  assert_output --partial "stop the VM that uses $T/src, then try again"
  assert [ ! -e "$T/dst" ]
  assert [ ! -e "$T/dst.partial" ]
}

@test "lanai-copy: makes a verified reflink copy and releases the lock" {
  btrfs_tmp
  make_storage "$B/src" nocow
  local before
  before=$(tree_manifest "$B/src")
  run "$REPO/bin/lanai-copy" "$B/src" "$B/dst"
  assert_success
  assert_output --partial "verified"
  assert_equal "$(tree_manifest "$B/dst")" "$before"
  assert_equal "$(tree_manifest "$B/src")" "$before"
  [[ $(attrs "$B/dst/data.img") == *C* ]]
  run filefrag -v "$B/dst/data.img"
  assert_output --partial "shared"
  assert [ ! -e "$B/dst.partial" ]
  vm_can_open "$B/src/data.img"
}

@test "lanai-copy: a VM cannot open the source while the copy is verified" {
  btrfs_tmp
  make_storage "$B/src"
  # A sha256sum shim tries to start a VM on the source once, mid-run.
  mkdir "$T/shims"
  cat >"$T/shims/sha256sum" <<EOF
#!/usr/bin/env bash
if [[ ! -e $T/probed ]]; then
  : >"$T/probed"
  rc=0
  timeout 2 qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \\
    -drive "file=$B/src/data.img,format=raw,if=none,id=d" -device virtio-scsi-pci \\
    -device scsi-hd,drive=d </dev/null 3>&- 2>"$T/probe.err" || rc=\$?
  echo "\$rc" >"$T/probe.rc"
fi
exec $(command -v sha256sum) "\$@"
EOF
  chmod +x "$T/shims/sha256sum"
  PATH=$T/shims:$PATH run "$REPO/bin/lanai-copy" "$B/src" "$B/dst"
  assert_success
  assert_equal "$(cat "$T/probe.rc")" 1
  run cat "$T/probe.err"
  assert_output --partial 'Failed to get shared "write" lock'
}

@test "lanai-copy: a copy that does not match fails, leaves nothing and releases the lock" {
  btrfs_tmp
  make_storage "$B/src"
  # A cp shim damages the copied MAC file after a successful clone.
  mkdir "$T/shims"
  cat >"$T/shims/cp" <<EOF
#!/usr/bin/env bash
$(command -v cp) "\$@" || exit
last=\${!#}
[[ \$last != *.partial/windows.mac ]] || echo x >>"\$last"
EOF
  chmod +x "$T/shims/cp"
  PATH=$T/shims:$PATH run "$REPO/bin/lanai-copy" "$B/src" "$B/dst"
  assert_failure
  assert_output --partial "does not match"
  assert [ ! -e "$B/dst" ]
  assert [ ! -e "$B/dst.partial" ]
  vm_can_open "$B/src/data.img"
}

@test "lanai-copy: an existing dst.partial is refused and left alone" {
  make_storage "$T/src"
  mkdir "$T/dst.partial"
  echo keep >"$T/dst.partial/marker"
  run "$REPO/bin/lanai-copy" "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "$T/dst.partial already exists"
  assert_equal "$(cat "$T/dst.partial/marker")" keep
  assert [ ! -e "$T/dst" ]
}

@test "lanai-copy: a source named like the work folder is refused and kept" {
  make_storage "$T/win.partial"
  local before
  before=$(tree_manifest "$T/win.partial")
  run "$REPO/bin/lanai-copy" "$T/win.partial" "$T/win"
  assert_failure
  assert_equal "$(tree_manifest "$T/win.partial")" "$before"
  assert [ ! -e "$T/win" ]
}

@test "lanai-copy: a source inside the work folder is refused and kept" {
  make_storage "$T/foo.partial/win"
  local before
  before=$(tree_manifest "$T/foo.partial")
  run "$REPO/bin/lanai-copy" "$T/foo.partial/win" "$T/foo"
  assert_failure
  assert_equal "$(tree_manifest "$T/foo.partial")" "$before"
  assert [ ! -e "$T/foo" ]
}

@test "lanai-copy: a symlink to the work folder is refused and its target kept" {
  make_storage "$T/real"
  ln -s "$T/real" "$T/dst.partial"
  run "$REPO/bin/lanai-copy" "$T/real" "$T/dst"
  assert_failure
  assert [ -f "$T/real/data.img" ]
  assert [ -L "$T/dst.partial" ]
}

@test "lanai-copy: copies through a symlinked source folder" {
  btrfs_tmp
  make_storage "$B/real"
  ln -s "$B/real" "$B/link"
  run "$REPO/bin/lanai-copy" "$B/link" "$B/dst"
  assert_success
  assert [ -d "$B/dst" ]
  assert [ ! -L "$B/dst" ]
  assert_equal "$(tree_manifest "$B/dst")" "$(tree_manifest "$B/real")"
}

@test "lanai-copy: a missing source is refused" {
  run "$REPO/bin/lanai-copy" "$T/none" "$T/dst"
  assert_failure
  assert_output --partial "$T/none is not a folder"
}

@test "lanai-copy: fails cleanly where reflinks are impossible" {
  mkdir -p "$T/fs"
  require_no_reflink "$T/fs"
  make_storage "$T/fs/src"
  run "$REPO/bin/lanai-copy" "$T/fs/src" "$T/fs/dst"
  assert_failure
  assert_output --partial "same btrfs or XFS filesystem"
  assert [ ! -e "$T/fs/dst" ]
  assert [ ! -e "$T/fs/dst.partial" ]
  vm_can_open "$T/fs/src/data.img"
}
