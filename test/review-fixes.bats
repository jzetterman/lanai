#!/usr/bin/env bats
# Regression cases use scratch installs and mocked copy/proof failures only.
# They never establish a successful image proof or start a VM.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329,SC2016
load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  S=$(state_dir)
  STORE=$T/storage
  mkdir -p "$S" "$(dirname "$(settings_file)")"
  make_install "$STORE"
  printf '{"storage":"%s"}\n' "$STORE" >"$(settings_file)"
  systemctl() { echo ActiveState=inactive; }
  container_fact() { echo none; }
  snapshot_blocked() { return 1; }
  lock_disk() { :; }
  unlock_disk() { :; }
  export T
}

teardown() { stop_bg; }

@test "review fixes: setup's own operation lock still detects a blank disk" {
  truncate -s 0 "$STORE/data.img"
  truncate -s 1M "$STORE/data.img"
  lanai_flock
  # This namespace hides exited flock creators. Supply the same kernel record
  # through awk to cover hosts where the bare operation lock stays visible.
  local dev maj min ino
  dev=$(mount_dev "$S/lock")
  IFS=: read -r maj min <<<"$dev"
  ino=$(stat -c %i "$S/lock")
  printf '1: FLOCK ADVISORY WRITE 0 %02x:%02x:%s 0 EOF\n' "$maj" "$min" "$ino" >"$T/visible-locks"
  shim awk 'args=("$@"); if [[ ${args[-1]} == /proc/locks ]]; then args[-1]=$T/visible-locks; fi
exec /usr/bin/awk "${args[@]}"'
  export PATH=$T/shims:$PATH
  run shared_facts
  assert_success
  assert_output --partial 'first 100 KB of data.img are all zero'
  assert_output --partial 'LanaiProblemReason=layout'
  exec {LANAI_FLOCK_FD}>&-
  run setup_resume auto false '' ''
  assert_failure
  assert_equal "$(jq -r .step <<<"$output")" 1
  assert_equal "$(jq -r .reason <<<"$output")" layout
}

@test "review fixes: live snapshot and restore owners skip the panel image read" {
  truncate -s 0 "$STORE/data.img"
  truncate -s 1M "$STORE/data.img"
  local op
  lanai_flock
  for op in snapshot restore; do
    jq -nc --arg op "$op" --argjson pid "$BASHPID" \
      '{operation:$op,phase:"hashing",done:0,total:1048576,pid:$pid}' >"$S/image-progress.json"
    run shared_facts
    assert_success
    refute_output --partial 'first 100 KB'
    assert_output --partial 'LanaiProblemReason='
  done
}

# Mock the proof only to reach later failure paths without an image read.
mock_proof() {
  shim python3 'if [[ $1 == */image-proof.py ]]; then
  case $2 in
    progress) exit 0 ;;
    gate|filesystem) [[ ! -e $T/gate-error ]] || { cat "$T/gate-error" >&2; exit 1; }; exit 0 ;;
    prove) [[ ! -e $T/proof-error ]] || { cat "$T/proof-error" >&2; exit 1; }; echo "f 1048576 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa data.img"; exit 0 ;;
  esac
elif [[ $1 == */ficlone.py ]]; then
  [[ ! -e $T/clone-error ]] || exit "$(cat "$T/clone-error")"
  /usr/bin/cp -- "${@: -2:1}" "${@: -1}"; exit
fi
exec /usr/bin/python3 "$@"'
  export PATH=$T/shims:$PATH
  reflink_file() { cp -- "$1" "$2"; }
}

@test "review fixes: small-file failure after prove reports the check rather than its manifest" {
  mock_proof
  small_manifest() { echo 'small file read failed' >&2; return 1; }
  run image_operation snapshot snapshot_create
  assert_failure
  assert_output --partial 'small-file check failed'
  refute_output --partial 'f 1048576'
  refute_output --partial 'aaaaaaaaaaaaaaaa'
}

@test "review fixes: gate and proof errors have plain reasons and detailed stderr" {
  mock_proof
  echo 'image-proof: unprovable FIEMAP extent (flags 0x201)' >"$T/gate-error"
  run --separate-stderr image_operation snapshot snapshot_create
  assert_failure 3
  refute_output --partial 'image-proof:'
  refute_output --partial 'flags 0x'
  assert_output --partial 'cannot verify'
  [[ $stderr == *'flags 0x201'* ]]
}

@test "review fixes: restore gate refusal puts backup advice only in next" {
  snapshot_find() { echo "$T/snapshot"; }
  mkdir "$T/snapshot"
  cp "$STORE/data.img" "$T/snapshot/data.img"
  snapshot_valid() { return 0; }
  mock_proof
  echo 'image-proof: filesystem cannot make an instant copy with a provable image here; make a backup' >"$T/gate-error"
  run --separate-stderr cmd_restore 20260101T000000Z
  assert_failure
  refute_output --partial 'image-proof:'
  assert_equal "$(jq -r '.message | contains("backup")' <<<"$output")" false
  assert_equal "$(jq -r '.next | contains("backup")' <<<"$output")" true
}

@test "review fixes: stale partial sweep matches SOURCE and runs under the lock" {
  local root d
  root=$(data_dir)/snapshots
  mkdir -p "$root"
  for d in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do mkdir "$root/$d.partial"; done
  echo "$STORE" >"$root/20260101T000000Z.partial/SOURCE"
  echo elsewhere >"$root/20260102T000000Z.partial/SOURCE"
  mock_proof
  echo 3 >"$T/clone-error"
  lanai_flock
  run image_operation snapshot snapshot_create
  assert_failure
  assert [ ! -e "$root/20260101T000000Z.partial" ]
  assert [ -e "$root/20260102T000000Z.partial" ]
  assert [ -e "$root/20260103T000000Z.partial" ]
}

@test "review fixes: failed root attempts remove newly created empty snapshot roots" {
  mock_proof
  echo 3 >"$T/clone-error"
  lanai_flock
  run image_operation snapshot snapshot_create
  assert_failure 3
  assert [ ! -e "$(data_dir)/snapshots" ]
  assert [ ! -e "$STORE.lanai-snapshots" ]
}

@test "review fixes: SOURCE is recorded and flushed before cloning can pin extents" {
  mock_proof
  shim sync 'printf "%s\n" "$*" >>"$T/sync.calls"'
  shim python3 'if [[ $1 == */ficlone.py ]]; then
  part=${@: -1}; part=${part%/*}
  [[ $(cat "$part/SOURCE") == "$T/storage" ]] || exit 1
  grep -qxF -- "-- $part/SOURCE" "$T/sync.calls" || exit 1
  grep -qxF -- "-- $part" "$T/sync.calls" || exit 1
  exit 3
elif [[ $1 == */image-proof.py ]]; then exit 0; fi
exec /usr/bin/python3 "$@"'
  lanai_flock
  run image_operation snapshot snapshot_create
  assert_failure 3
  assert_output --partial 'cannot make an instant copy'
}

@test "review fixes: dead image map owners are swept and live owners are kept" {
  mock_proof
  echo 3 >"$T/clone-error"
  : >"$S/image-map.2147483647.json"
  : >"$S/image-map.$BASHPID.json"
  : >"$S/image-map.unknown.json"
  lanai_flock
  run image_operation snapshot snapshot_create
  assert_failure
  assert [ ! -e "$S/image-map.2147483647.json" ]
  assert [ -e "$S/image-map.$BASHPID.json" ]
  assert [ -e "$S/image-map.unknown.json" ]
}

@test "review fixes: snapshot validation rejects duplicate manifest names without a separate name cache" {
  local snap record
  snap=$(data_dir)/snapshots/20260101T000000Z
  mkdir -p "$snap"
  cp "$STORE/"* "$snap/"
  echo "$STORE" >"$snap/SOURCE"
  tree_manifest "$STORE" >"$snap/COMPLETE"
  run snapshot_valid "$snap" "$STORE"
  assert_success
  record=$(head -n 1 "$snap/COMPLETE")
  printf '%s\n' "$record" >>"$snap/COMPLETE"
  run snapshot_valid "$snap" "$STORE"
  assert_failure
}

@test "review fixes: proof errors keep details off the user's reason" {
  mock_proof
  echo 'image-proof: unprovable FIEMAP extent (flags 0x201)' >"$T/proof-error"
  run --separate-stderr image_operation snapshot snapshot_create
  assert_failure 1
  assert_output --partial 'cannot verify'
  refute_output --partial 'image-proof:'
  refute_output --partial 'flags 0x'
  [[ $stderr == *'flags 0x201'* ]]
}

@test "review fixes: restore reuses parsed small-file hashes without rereading COMPLETE" {
  local snap
  snap=$(data_dir)/snapshots/20260101T000000Z
  mkdir -p "$snap"
  cp "$STORE/"* "$snap/"
  echo "$STORE" >"$snap/SOURCE"
  tree_manifest "$STORE" >"$snap/COMPLETE"
  mock_proof
  echo 'image-proof: image changed during verification' >"$T/proof-error"
  shim awk '[[ ${@: -1} != */COMPLETE ]] || : >"$T/complete-reread"
exec /usr/bin/awk "$@"'
  lanai_flock
  run image_operation restore snapshot_restore 20260101T000000Z
  assert_failure
  assert_output --partial 'image changed during verification'
  assert [ ! -e "$T/complete-reread" ]
}
