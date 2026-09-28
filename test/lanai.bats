#!/usr/bin/env bats
# Tests for bin/lanai and lib/lanai.sh.
# shellcheck disable=SC2030,SC2031

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
}

teardown() {
  qemu_release
  [[ -z ${B:-} ]] || rm -rf "$B"
}

# Assert that $output is exactly one line holding one JSON object.
assert_one_json() {
  assert_equal "$(wc -l <<<"$output")" 1
  jq -e 'type == "object"' <<<"$output" >/dev/null || fail "not a JSON object: $output"
}

# Print field <name> of the JSON in $output.
field() {
  jq -r --arg k "$1" '.[$k] | if . == null then "null" else tostring end' <<<"$output"
}

# --- bin/lanai: one JSON object on every path ---

@test "lanai help: one JSON object listing the commands" {
  run "$REPO/bin/lanai" help
  assert_success
  assert_one_json
  assert_equal "$(field ok)" true
  run jq -r '.commands | index("version") != null' <<<"$output"
  assert_output true
}

@test "lanai with no command is help" {
  run "$REPO/bin/lanai"
  assert_success
  assert_one_json
  run jq -r '.commands | length > 0' <<<"$output"
  assert_output true
}

@test "lanai version: matches manifest.json" {
  run "$REPO/bin/lanai" version
  assert_success
  assert_one_json
  assert_equal "$(field version)" "$(jq -r .version "$REPO/manifest.json")"
}

@test "lanai: an unknown command is one JSON error that names it" {
  run "$REPO/bin/lanai" frobnicate
  assert_failure 2
  assert_one_json
  assert_equal "$(field ok)" false
  assert_equal "$(field message)" "unknown command: frobnicate"
  assert_equal "$(field next)" "run lanai help"
}

@test "lanai: a command name that is not a plain word is refused" {
  local bad
  for bad in 'x;true' '../x' 'Help' '-v'; do
    run "$REPO/bin/lanai" "$bad"
    assert_failure 2
    assert_one_json
    assert_equal "$(field ok)" false
  done
}

@test "lanai: a command that fails part way still prints one JSON error" {
  # A command defined only for this test fails under set -e.
  run bash -c 'set -euo pipefail; source "$1"; cmd_boom() { echo "detail" >&2; false; }; lanai_main boom' _ "$REPO/lib/lanai.sh"
  assert_failure
  # stderr keeps its detail; stdout's last line is the JSON.
  output=$(tail -n1 <<<"$output")
  assert_one_json
  assert_equal "$(field ok)" false
  assert_equal "$(field state)" null
  [[ $(field message) == *"exit 1"* ]]
}

@test "lanai: a command that already answered prints nothing more when it fails" {
  run bash -c 'set -euo pipefail; source "$1"; cmd_half() { emit true "" done ""; false; }; lanai_main half 2>/dev/null' _ "$REPO/lib/lanai.sh"
  assert_failure
  assert_one_json
  assert_equal "$(field message)" "done"
}

@test "lanai: with jq failing, the fallback is still one JSON object" {
  mkdir "$T/shims"
  printf '#!/bin/sh\nexit 1\n' >"$T/shims/jq"
  chmod +x "$T/shims/jq"
  PATH=$T/shims:$PATH run "$REPO/bin/lanai" version
  assert_failure
  # Checked with the real jq.
  assert_one_json
  assert_equal "$(field ok)" false
}

@test "emit: strings are JSON-escaped and details are merged" {
  run emit false "stopped" $'a "quoted"\nline' "" '{"extra":[1,2]}'
  assert_success
  assert_one_json
  assert_equal "$(field message)" $'a "quoted"\nline'
  assert_equal "$(field next)" null
  assert_equal "$(field extra)" "[1,2]"
}

# --- verify_sha256 (from the spike) ---

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

# --- qemu_cmdlines (from the spike) ---

@test "qemu_cmdlines: finds bare and full-path QEMU, ignores a shell that mentions it" {
  LANAI_PROC=$FIX/proc-qemu run qemu_cmdlines
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
  LANAI_PROC=$FIX/proc-none run qemu_cmdlines
  assert_success
  assert_output ""
}

# --- disk_locked (from the spike) ---

# Print a file's filesystem device the way /proc/locks writes it (%02x:%02x).
locks_dev() {
  local maj min
  IFS=: read -r maj min <<<"$(mount_dev "$1")"
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
  LANAI_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_success
}

@test "disk_locked: no lock line for the image" {
  touch "$T/data.img"
  write_locks "00:1d:1"
  LANAI_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: same inode on another device does not match" {
  touch "$T/data.img"
  local dev other=fe:01
  dev=$(locks_dev "$T/data.img")
  [[ $dev != "$other" ]] || other=fe:02
  write_locks "$other:$(stat -c %i "$T/data.img")"
  LANAI_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: an inode that extends the image's inode does not match" {
  touch "$T/data.img"
  local ino
  ino=$(stat -c %i "$T/data.img")
  write_locks "$(locks_dev "$T/data.img"):${ino}4"
  LANAI_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: an inode that is a prefix of the image's inode does not match" {
  touch "$T/data.img"
  local ino
  ino=$(stat -c %i "$T/data.img")
  [[ ${#ino} -gt 1 ]] || skip "inode too short to truncate"
  write_locks "$(locks_dev "$T/data.img"):${ino%?}"
  LANAI_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: an unreadable locks file means cannot tell" {
  touch "$T/data.img"
  LANAI_LOCKS=$T/missing run disk_locked "$T/data.img"
  assert_failure 2
}

@test "disk_locked: a running VM's lock on btrfs shows in the real /proc/locks" {
  btrfs_tmp
  unset LANAI_LOCKS
  truncate -s 1M "$B/data.img"
  run disk_locked "$B/data.img"
  assert_failure 1
  qemu_hold "$B/data.img"
  run disk_locked "$B/data.img"
  assert_success
  qemu_release
  run disk_locked "$B/data.img"
  assert_failure 1
}
