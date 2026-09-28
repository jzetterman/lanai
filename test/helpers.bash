# Shared setup for Lanai's bats tests. Load with `load helpers`.
# shellcheck shell=bash
# The globals set here (REPO, FIX, B, QEMU_PID) are read by the test files.
# shellcheck disable=SC2034

bats_load_library bats-support
bats_load_library bats-assert

REPO=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
FIX=$BATS_TEST_DIRNAME/fixtures

# Point HOME and every XDG_* path at fresh temp dirs, so no test can reach the
# real ~/.windows, settings or runtime dir. Other XDG_* variables are unset.
isolate_home() {
  local v
  for v in $(compgen -e XDG_); do unset "$v"; done
  export HOME=$BATS_TEST_TMPDIR/home
  export XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share
  export XDG_STATE_HOME=$HOME/.local/state XDG_CACHE_HOME=$HOME/.cache
  export XDG_RUNTIME_DIR=$BATS_TEST_TMPDIR/run
  export XDG_CONFIG_DIRS=$BATS_TEST_TMPDIR/etc-xdg XDG_DATA_DIRS=$BATS_TEST_TMPDIR/share
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
  mkdir -m 700 "$XDG_RUNTIME_DIR"
}

# Set B to a new temp dir under LANAI_TEST_BTRFS_DIR. Skips the test when
# that variable is unset or does not point at btrfs. Call it directly, not in
# $(...), or the skip is lost.
btrfs_tmp() {
  [[ -n ${LANAI_TEST_BTRFS_DIR:-} ]] || skip "LANAI_TEST_BTRFS_DIR is unset"
  mkdir -p "$LANAI_TEST_BTRFS_DIR"
  [[ $(stat -f -c %T "$LANAI_TEST_BTRFS_DIR") == btrfs ]] || skip "LANAI_TEST_BTRFS_DIR is not on btrfs"
  B=$(mktemp -d "$LANAI_TEST_BTRFS_DIR/t.XXXXXX")
}

# Start a paused QEMU (TCG, no guest code runs) that opens <img> as a disk
# the way a VM does, and wait until it holds the image lock. Sets QEMU_PID.
qemu_hold() {
  local img=$1 ino i
  ino=$(stat -c %i -- "$img")
  qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \
    -drive "file=$img,format=raw,if=none,id=d" -device virtio-scsi-pci \
    -device scsi-hd,drive=d 3>&- &
  QEMU_PID=$!
  for ((i = 0; i < 50; i++)); do
    grep -q ":$ino " /proc/locks && return 0
    sleep 0.1
  done
  fail "QEMU did not lock $img"
}

# Return 0 when a VM could open <img> now: a paused QEMU runs for 2 s without
# failing on the image lock. Return 1 when QEMU cannot get the lock.
vm_can_open() {
  local rc=0
  timeout 2 qemu-system-x86_64 -S -nodefaults -display none -machine q35,accel=tcg \
    -drive "file=$1,format=raw,if=none,id=d" -device virtio-scsi-pci \
    -device scsi-hd,drive=d 3>&- 2>/dev/null || rc=$?
  ((rc == 124))
}
