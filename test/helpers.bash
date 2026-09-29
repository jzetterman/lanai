# Shared setup for Lanai's bats tests. Load with `load helpers`.
# shellcheck shell=bash
# The globals set here (REPO, FIX, B, QEMU_PID) are read by the test files.
# shellcheck disable=SC2034,SC2154

bats_load_library bats-support
bats_load_library bats-assert
bats_require_minimum_version 1.5.0

REPO=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
FIX=$BATS_TEST_DIRNAME/fixtures

# Run bin/lanai with bats' run (stdout only in $output; stderr apart), and
# keep its JSON for field.
lanai_run() {
  run --separate-stderr "$REPO/bin/lanai" "$@"
  JSON=$output
}

# Print field <name> of the JSON in $JSON, or "null".
field() {
  jq -r --arg k "$1" '.[$k] | if . == null then "null" else tostring end' <<<"$JSON"
}

# Set the fake servers' knobs (KEY=value lines, test/fixtures/fake-*) for
# their next connection.
conf() {
  printf '%s\n' "$@" >"$FAKE_CONF"
}

# Serve <socket> with the fake server <script> (one run per connection) in
# the background, and wait until the socket exists.
serve() {
  local i
  mkdir -p "$(dirname "$1")"
  socat "UNIX-LISTEN:$1,fork" "EXEC:$2" >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  for ((i = 0; i < 100; i++)); do
    [[ -S $1 ]] && return 0
    sleep 0.05
  done
  fail "the fake server did not create $1"
}

# Stop every background job in BG_PIDS: its direct children, its process
# group when it leads one (setsid), and itself. Call it from teardown.
stop_bg() {
  local p
  for p in "${BG_PIDS[@]}"; do
    pkill -P "$p" 2>/dev/null || true
    kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true
  done
  for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
  BG_PIDS=()
}

# Point HOME, every XDG_* path, TMPDIR and Lanai's overrides at fresh temp
# paths, so no test can reach the real ~/.windows, compose file, settings,
# /proc processes or runtime dir. Other XDG_* variables are unset. A test that
# needs the real /proc or /proc/locks unsets LANAI_PROC or LANAI_LOCKS itself.
isolate_home() {
  local v
  for v in $(compgen -e XDG_); do unset "$v"; done
  export HOME=$BATS_TEST_TMPDIR/home
  export XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share
  export XDG_STATE_HOME=$HOME/.local/state XDG_CACHE_HOME=$HOME/.cache
  export XDG_RUNTIME_DIR=$BATS_TEST_TMPDIR/run
  export XDG_CONFIG_DIRS=$BATS_TEST_TMPDIR/etc-xdg XDG_DATA_DIRS=$BATS_TEST_TMPDIR/share
  export TMPDIR=$BATS_TEST_TMPDIR/tmp
  export OMARCHY_WINDOWS_DIR=$BATS_TEST_TMPDIR/var-lib-omarchy-windows
  export LANAI_PROC=$BATS_TEST_TMPDIR/proc LANAI_LOCKS=$BATS_TEST_TMPDIR/locks
  export FAKE_CONF=$BATS_TEST_TMPDIR/fake.conf
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
    "$TMPDIR" "$LANAI_PROC"
  : >"$LANAI_LOCKS"
  mkdir -m 700 "$XDG_RUNTIME_DIR"
  BG_PIDS=() JSON=""
}

# Put an executable shim <name> with body <script> in $T/shims, which tests
# put first on PATH.
shim() {
  mkdir -p "$T/shims"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/shims/$1"
  chmod +x "$T/shims/$1"
}

# Write a fake /proc entry: fake_proc <pid> <cgroup path> <argv...>. Its
# stat says the process is sleeping (S); a test may rewrite it.
fake_proc() {
  local pid=$1 cg=$2
  shift 2
  mkdir -p "$T/proc/$pid"
  printf '%s\0' "$@" >"$T/proc/$pid/cmdline"
  printf '0::%s\n' "$cg" >"$T/proc/$pid/cgroup"
  printf '%s (bash) S 1 %s %s 0 -1\n' "$pid" "$pid" "$pid" >"$T/proc/$pid/stat"
}

# Build a finished omarchy-windows-vm install at <dir>: a 1 MiB data.img with
# data in its first bytes, firmware, variables, MAC, boot marker, base, ver.
make_install() {
  mkdir -p "$1"
  truncate -s 1M "$1/data.img"
  printf 'LANAI' | dd of="$1/data.img" conv=notrunc status=none
  echo rom >"$1/windows.rom"
  echo vars >"$1/windows.vars"
  echo 02:4B:81:73:3C:96 >"$1/windows.mac"
  : >"$1/windows.boot"
  echo win11x64.iso >"$1/windows.base"
  echo 6.05 >"$1/windows.ver"
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
