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
