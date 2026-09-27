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
