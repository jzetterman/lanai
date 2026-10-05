#!/usr/bin/env bats
# Panel settings and detached jobs, using isolated files and a fake CLI.
load helpers

setup() {
  isolate_home
  T=$BATS_TEST_TMPDIR
  source "$REPO/lib/lanai.sh"
  mkdir -p "$XDG_CONFIG_HOME/lanai"
  printf '{"storage":"/test-copy","memory_gib":12,"cores":6,"extra":true}\n' >"$(settings_file)"
}

@test "settings: reads current sizing and preserves storage and unknown keys on save" {
  lanai_run settings
  assert_success
  assert_equal "$(field memory_gib)" 12
  assert_equal "$(field cores)" 6
  lanai_run settings 512 64
  assert_success
  run jq -c '{storage, memory_gib, cores, extra}' "$(settings_file)"
  assert_output '{"storage":"/test-copy","memory_gib":512,"cores":64,"extra":true}'
  assert_equal "$(stat -c %a "$(settings_file)")" 600
}

@test "settings: rejects invalid values with the VM's validation and leaves the file intact" {
  local before mem cores
  before=$(cat "$(settings_file)")
  for mem in 0 513 01 1.5 -1 garbage; do
    lanai_run settings "$mem" 4
    assert_failure
    assert_equal "$(field ok)" false
    run vm_args /test-copy 02:00:00:00:00:01 "$mem" 4 100 ""
    assert_failure
  done
  for cores in 0 65 01 1.5 -1 garbage; do
    lanai_run settings 12 "$cores"
    assert_failure
    run vm_args /test-copy 02:00:00:00:00:01 12 "$cores" 100 ""
    assert_failure
  done
  assert_equal "$(cat "$(settings_file)")" "$before"
  lanai_run settings 1 1
  assert_success
}

@test "settings: refuses broken JSON and symlinks rather than replacing them" {
  printf broken >"$(settings_file)"
  lanai_run settings 8 4
  assert_failure
  assert_equal "$(cat "$(settings_file)")" broken
  rm "$(settings_file)"
  printf '{}' >"$T/target"
  ln -s "$T/target" "$(settings_file)"
  lanai_run settings 8 4
  assert_failure
  assert_equal "$(cat "$T/target")" '{}'
}

@test "notice-seen: atomically clears the verdict with one JSON reply and is repeatable" {
  local s
  s=$(state_dir)
  mkdir -p "$s"
  printf 'forced\n' >"$s/last-run"
  lanai_run notice-seen
  assert_success
  assert_equal "$(field ok)" true
  assert_equal "$(wc -l <<<"$output")" 1
  assert_equal "$(cat "$s/last-run")" clean
  assert_equal "$(stat -c %a "$s/last-run")" 600
  lanai_run notice-seen
  assert_success
  assert_equal "$(cat "$s/last-run")" clean
  run find "$s" -name 'last-run.*'
  assert_output ''
}

@test "notice-seen: refuses arguments and a failed replacement leaves the verdict intact" {
  local s
  s=$(state_dir)
  mkdir -p "$s"
  printf 'forced\n' >"$s/last-run"
  lanai_run notice-seen extra
  assert_failure
  assert_equal "$(cat "$s/last-run")" forced
  shim mv 'exit 1'
  PATH=$T/shims:$PATH lanai_run notice-seen
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(wc -l <<<"$output")" 1
  assert_equal "$(cat "$s/last-run")" forced
  run find "$s" -name 'last-run.*'
  assert_output ''
}

@test "status: reports an unfinished restore without contacting a VM or install" {
  # Exercise real facts and mapping, with only external/install reads stubbed.
  systemctl() { printf 'ActiveState=inactive\n'; }
  storage_dir() { return 1; }
  setup_done() { return 1; }
  container_running() { return 1; }
  container_preparing() { return 1; }
  guest_version_behind() { return 1; }
  run lanai_main status
  assert_success
  assert_equal "$(jq -r '.restore_pending' <<<"$output")" false
  mkdir -p "$(state_dir)"
  : >"$(state_dir)/restore-in-progress"
  run lanai_main status
  assert_success
  assert_equal "$(jq -r '.restore_pending' <<<"$output")" true
  assert_equal "$(wc -l <<<"$output")" 1
}

# Override only the child CLI: no units, storage or desktop commands run.
make_job_cli() {
  LANAI_BIN=$T/cli
  mkdir -p "$LANAI_BIN"
  cat >"$LANAI_BIN/lanai" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$XDG_STATE_HOME/args"
case ${LANAI_FAKE_JOB:-ok} in
  log) echo "$2" >&2; printf '{"ok":true}\n' ;;
  failure) printf '{"ok":false,"message":"backup needed","next":"make a backup"}\n'; exit 1 ;;
  bad-json) echo broken ;;
  many-json) printf '{"ok":true}\n{"ok":true}\n' ;;
  *) printf '{"ok":true,"message":"done","next":null}\n' ;;
esac
SH
  chmod +x "$LANAI_BIN/lanai"
}

@test "ui-job: keeps only the last run's log and a rejected job cannot truncate it" {
  make_job_cli
  LANAI_FAKE_JOB=log run cmd_ui_job log-1 setup first
  assert_success
  LANAI_FAKE_JOB=log run cmd_ui_job log-2 setup second
  assert_success
  run cat "$(state_dir)/panel-job.log"
  assert_output second
  exec {JOB_FD}>"$(state_dir)/panel-job.lock"
  flock "$JOB_FD"
  LANAI_FAKE_JOB=log run cmd_ui_job log-3 setup rejected
  assert_failure
  exec {JOB_FD}>&-
  run cat "$(state_dir)/panel-job.log"
  assert_output second
}

@test "ui-job: carries literal arguments and publishes its completion" {
  make_job_cli
  # Literal shell metacharacters must reach the CLI untouched.
  # shellcheck disable=SC2016
  run cmd_ui_job token-1 restore 'snapshot with spaces;$(false)'
  assert_success
  run cmd_ui_job_status
  assert_success
  assert_equal "$(jq -r '.active' <<<"$output")" false
  assert_equal "$(jq -r '.token' <<<"$output")" token-1
  assert_equal "$(jq -r '.reply.ok' <<<"$output")" true
  run cat "$XDG_STATE_HOME/args"
  assert_output $'restore\nsnapshot with spaces;$(false)'
}

@test "ui-job: publishes CLI failures and rejects malformed output" {
  make_job_cli
  LANAI_FAKE_JOB=failure run cmd_ui_job token-2 snapshot
  assert_success
  run cmd_ui_job_status
  assert_equal "$(jq -r '.reply.ok' <<<"$output")" false
  assert_equal "$(jq -r '.reply.next' <<<"$output")" 'make a backup'
  LANAI_FAKE_JOB=bad-json run cmd_ui_job token-3 setup
  assert_success
  run cmd_ui_job_status
  assert_equal "$(jq -r '.reply.ok' <<<"$output")" false
}

@test "ui-job: forwards the panel's snapshot and display setup flags" {
  make_job_cli
  local flag
  for flag in --no-snapshot --window --no-window; do
    run cmd_ui_job token-flags setup "$flag"
    assert_success
    run cmd_ui_job_status
    assert_success
    assert_equal "$(jq -c '.args' <<<"$output")" "[\"$flag\"]"
    assert_equal "$(jq -r '.reply.ok' <<<"$output")" true
    run cat "$XDG_STATE_HOME/args"
    assert_output "$(printf 'setup\n%s' "$flag")"
  done
}

@test "ui-job: forwards both final setup answers from the panel" {
  make_job_cli
  run cmd_ui_job token-answers setup --share-ok yes --scale-ok yes
  assert_success
  run cmd_ui_job_status
  assert_success
  assert_equal "$(jq -c '.args' <<<"$output")" '["--share-ok","yes","--scale-ok","yes"]'
  assert_equal "$(jq -r '.reply.ok' <<<"$output")" true
  run cat "$XDG_STATE_HOME/args"
  assert_output $'setup\n--share-ok\nyes\n--scale-ok\nyes'
}

@test "ui-job-status: preserves completion published between the read and lock" {
  mkdir -p "$(state_dir)"
  panel_job_write '{"token":"racing","command":"setup","active":true}'
  # Finish at the lock attempt, after the poll has read the active marker.
  flock() {
    panel_job_write '{"token":"racing","command":"setup","active":false,"reply":{"ok":true,"message":"done"}}'
    command flock "$@"
  }
  run cmd_ui_job_status
  assert_success
  assert_equal "$(jq -r '.active' <<<"$output")" false
  assert_equal "$(jq -r '.token' <<<"$output")" racing
  assert_equal "$(jq -r '.reply.ok' <<<"$output")" true
  assert_equal "$(jq -r '.reply.message' <<<"$output")" 'done'
}

@test "ui-job: refuses concurrent jobs and recovers an interrupted job" {
  make_job_cli
  mkdir -p "$(state_dir)"
  exec {JOB_FD}>"$(state_dir)/panel-job.lock"
  flock "$JOB_FD"
  run cmd_ui_job token-4 setup
  assert_failure
  assert [ ! -e "$XDG_STATE_HOME/args" ]
  exec {JOB_FD}>&-
  printf '{"token":"old","command":"setup","active":true}' >"$(state_dir)/panel-job.json"
  run cmd_ui_job_status
  assert_success
  assert_equal "$(jq -r '.active' <<<"$output")" false
  assert_equal "$(jq -r '.reply.ok' <<<"$output")" false
}

@test "ui-job: accepts only the three long operations" {
  make_job_cli
  run cmd_ui_job token-5 start
  assert_failure
  assert [ ! -e "$XDG_STATE_HOME/args" ]
}

@test "ui-job commands: CLI emits exactly one JSON object, including its EXIT trap" {
  lanai_run ui-job-status
  assert_success
  assert_equal "$(wc -l <<<"$output")" 1
  make_job_cli
  run bash -c 'source "$1"; LANAI_BIN=$2; lanai_main ui-job token-cli snapshot' _ "$REPO/lib/lanai.sh" "$LANAI_BIN"
  assert_success
  assert_equal "$(wc -l <<<"$output")" 1
  lanai_run ui-job-status
  assert_success
  assert_equal "$(wc -l <<<"$output")" 1
  assert_equal "$(field active)" false
}

@test "ui-job: multiple JSON objects become a recoverable failure, never a broken marker" {
  make_job_cli
  LANAI_FAKE_JOB=many-json run cmd_ui_job token-6 setup
  assert_success
  run cmd_ui_job_status
  assert_success
  assert_equal "$(jq -r '.active' <<<"$output")" false
  assert_equal "$(jq -r '.reply.ok' <<<"$output")" false
}
