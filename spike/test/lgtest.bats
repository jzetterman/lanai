#!/usr/bin/env bats
# Tests for the lgtest functions that guard the live disk or produce a decision number.

bats_load_library bats-support
bats_load_library bats-assert

setup() {
  # shellcheck source=../lgtest
  source "$BATS_TEST_DIRNAME/../lgtest"
  FIX=$BATS_TEST_DIRNAME/fixtures
  # Temp dirs live in spike/work so they sit on the repo's btrfs filesystem.
  mkdir -p "$BATS_TEST_DIRNAME/../work/test-tmp"
  T=$(mktemp -d "$BATS_TEST_DIRNAME/../work/test-tmp/t.XXXXXX")
}

teardown() {
  rm -rf "$T"
}

teardown_file() {
  rmdir "$BATS_TEST_DIRNAME/../work/test-tmp" 2>/dev/null || true
}

# Skip a test unless its temp dir is on btrfs.
require_btrfs() {
  [[ $(stat -f -c %T "$T") == btrfs ]] || skip "needs btrfs"
}

# --- verify_sha256 ---

@test "verify_sha256: matching sum passes and keeps the file" {
  printf 'hello\n' >"$T/f"
  run verify_sha256 "$T/f" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  assert_success
  assert [ -f "$T/f" ]
}

@test "verify_sha256: mismatch deletes the file and fails" {
  printf 'tampered\n' >"$T/f"
  run verify_sha256 "$T/f" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  assert_failure
  assert_output --partial "SHA-256 mismatch"
  assert [ ! -e "$T/f" ]
}

# --- host_busy_seconds ---

@test "host_busy_seconds: sums user, nice, system, irq and softirq of a real cpu line" {
  # (34220712 + 709189 + 8097477 + 1512962 + 1236383) ticks / 100 per second.
  # Idle, iowait, steal and the guest columns are left out.
  [[ $(getconf CLK_TCK) == 100 ]] || skip "fixture math assumes CLK_TCK=100"
  LGTEST_STAT=$FIX/stat run host_busy_seconds
  assert_success
  assert_output "457767.23"
}

# --- baseline_median ---

@test "baseline_median: odd count gives the middle value" {
  printf '60,30\n60,10\n60,20\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_success
  assert_output "20.00"
}

@test "baseline_median: even count gives the mean of the middle two" {
  printf '60,40\n60,10\n60,21\n60,5\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_success
  assert_output "15.50"
}

@test "baseline_median: rows of other lengths are ignored" {
  printf '1800,900\n60,12\n30,1\n60,14\n1800,950\n60,13\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_success
  assert_output "13.00"
}

@test "baseline_median: no rows of that length fails" {
  printf '1800,900\n30,1\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_failure
  assert_output --partial "no 60 s baseline"
}

@test "baseline_median: a missing file fails" {
  run baseline_median "$T/none.csv" 60
  assert_failure
}

# --- qemu_cmdlines ---

@test "qemu_cmdlines: finds bare and full-path QEMU, ignores a shell that mentions it" {
  # One argument per line, a blank line after each process. The fixture also
  # holds a shell whose arguments name QEMU and a kernel thread (empty cmdline).
  LGTEST_PROC=$FIX/proc-qemu run qemu_cmdlines
  assert_success
  assert_output "qemu-system-x86_64
-name
Windows,process=windows
-m
16G

/usr/bin/qemu-system-x86_64
-name
spike
-m
16G"
}

@test "qemu_cmdlines: prints nothing when no QEMU runs" {
  LGTEST_PROC=$FIX/proc-none run qemu_cmdlines
  assert_success
  assert_output ""
}

# --- disk_locked ---

# Print a file's filesystem device the way /proc/locks writes it (%02x:%02x).
locks_dev() {
  local d maj min
  d=$(findmnt -no MAJ:MIN -T "$1")
  IFS=: read -r maj min <<<"${d//[[:space:]]/}"
  printf '%02x:%02x' "$maj" "$min"
}

# Write a /proc/locks fixture with one OFD lock line on <dev>:<inode>, among
# unrelated real-format lines.
write_locks() {
  {
    echo "1: POSIX  ADVISORY  WRITE 3372069 00:1d:32123 1073741826 1073742335"
    echo "2: OFDLCK ADVISORY  READ -1 $1 100 101"
    echo "3: FLOCK  ADVISORY  WRITE 2211 00:19:998 0 EOF"
  } >"$T/locks"
}

@test "disk_locked: a lock on the image's device and inode is found" {
  touch "$T/data.img"
  write_locks "$(locks_dev "$T/data.img"):$(stat -c %i "$T/data.img")"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_success
}

@test "disk_locked: no lock line for the image" {
  touch "$T/data.img"
  write_locks "00:1d:1"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: same inode on another device does not match" {
  touch "$T/data.img"
  local dev other=fe:01
  dev=$(locks_dev "$T/data.img")
  [[ $dev != "$other" ]] || other=fe:02
  write_locks "$other:$(stat -c %i "$T/data.img")"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: an inode that extends the image's inode does not match" {
  touch "$T/data.img"
  local ino
  ino=$(stat -c %i "$T/data.img")
  write_locks "$(locks_dev "$T/data.img"):${ino}4"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: an inode that is a prefix of the image's inode does not match" {
  touch "$T/data.img"
  local ino
  ino=$(stat -c %i "$T/data.img")
  [[ ${#ino} -gt 1 ]] || skip "inode too short to truncate"
  write_locks "$(locks_dev "$T/data.img"):${ino%?}"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: live flock on btrfs shows in the real /proc/locks" {
  require_btrfs
  touch "$T/data.img"
  run disk_locked "$T/data.img"
  assert_failure 1
  exec {fd}<"$T/data.img"
  flock -s "$fd"
  run disk_locked "$T/data.img"
  exec {fd}<&-
  assert_success
  run disk_locked "$T/data.img"
  assert_failure 1
}

# --- prepare_copy ---

# Build a fake dockur storage dir at <dir>: a 1 MiB data.img (NOCOW when the
# second argument is "nocow") plus the firmware and MAC files.
make_src() {
  mkdir -p "$1"
  touch "$1/data.img"
  [[ ${2:-} != nocow ]] || chattr +C "$1/data.img"
  dd if=/dev/urandom of="$1/data.img" bs=1M count=1 conv=notrunc,fsync status=none
  echo rom >"$1/windows.rom"
  echo vars >"$1/windows.vars"
  echo 02:4B:81:73:3C:96 >"$1/windows.mac"
}

# Point the QEMU and lock checks at quiet fixtures.
quiet_host() {
  export LGTEST_PROC=$FIX/proc-none
  : >"$T/nolocks"
  export LGTEST_LOCKS=$T/nolocks
}

@test "prepare_copy: refuses while a QEMU process runs" {
  make_src "$T/src"
  quiet_host
  LGTEST_PROC=$FIX/proc-qemu run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "QEMU process is running"
  assert [ ! -e "$T/dst" ]
  assert [ ! -e "$T/dst.tmp" ]
}

@test "prepare_copy: refuses while the source disk is locked" {
  make_src "$T/src"
  quiet_host
  write_locks "$(locks_dev "$T/src/data.img"):$(stat -c %i "$T/src/data.img")"
  LGTEST_LOCKS=$T/locks run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "is locked"
  refute_output --partial "QEMU process"
  assert [ ! -e "$T/dst" ]
}

@test "prepare_copy: refuses when the destination exists" {
  make_src "$T/src"
  quiet_host
  mkdir "$T/dst"
  echo keep >"$T/dst/marker"
  run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "already exists"
  assert [ "$(cat "$T/dst/marker")" = keep ]
}

@test "prepare_copy: NOCOW source gives a NOCOW reflink copy on btrfs" {
  require_btrfs
  make_src "$T/src" nocow
  quiet_host
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  [[ $(lsattr "$T/dst/data.img" | awk '{print $1}') == *C* ]]
  run filefrag -v "$T/dst/data.img"
  assert_output --partial "shared"
  cmp "$T/src/data.img" "$T/dst/data.img"
  cmp "$T/src/windows.rom" "$T/dst/windows.rom"
  cmp "$T/src/windows.vars" "$T/dst/windows.vars"
  cmp "$T/src/windows.mac" "$T/dst/windows.mac"
  assert [ ! -e "$T/dst.tmp" ]
}

@test "prepare_copy: COW source gives a copy without the C flag" {
  require_btrfs
  make_src "$T/src"
  quiet_host
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  [[ $(lsattr "$T/dst/data.img" | awk '{print $1}') != *C* ]]
}

@test "prepare_copy: a failed copy leaves no dst and no dst.tmp; a rerun succeeds" {
  require_btrfs
  make_src "$T/src" nocow
  quiet_host
  rm "$T/src/windows.mac"
  run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert [ ! -e "$T/dst" ]
  assert [ ! -e "$T/dst.tmp" ]
  echo 02:4B:81:73:3C:96 >"$T/src/windows.mac"
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  cmp "$T/src/data.img" "$T/dst/data.img"
}

@test "prepare_copy: a stale dst.tmp is deleted before copying" {
  require_btrfs
  make_src "$T/src" nocow
  quiet_host
  mkdir "$T/dst.tmp"
  echo junk >"$T/dst.tmp/junk"
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  assert [ ! -e "$T/dst/junk" ]
  assert [ ! -e "$T/dst.tmp" ]
}
