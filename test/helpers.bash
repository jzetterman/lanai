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
# the way a VM does. -daemonize returns only once QEMU has set up its
# devices, so the disk's locks are all held on return. Sets QEMU_PID.
qemu_hold() {
  local img=$1 pidfile=$BATS_TEST_TMPDIR/qemu-hold.pid
  qemu-system-x86_64 -S -daemonize -pidfile "$pidfile" -nodefaults -display none \
    -machine q35,accel=tcg -drive "file=$img,format=raw,if=none,id=d" \
    -device virtio-scsi-pci -device scsi-hd,drive=d 3>&- ||
    fail "QEMU could not open $img"
  QEMU_PID=$(<"$pidfile")
}

# Stop the QEMU from qemu_hold and wait until it has exited.
qemu_release() {
  local i
  [[ -n ${QEMU_PID:-} ]] || return 0
  kill "$QEMU_PID" 2>/dev/null || true
  for ((i = 0; i < 100; i++)); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.05
  done
  QEMU_PID=""
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
