#!/usr/bin/env bats
# The worker's time, manager and CLI are fixtures. No real unit is started.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
load helpers
setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR S=$(state_dir)
  mkdir -p "$S" "$T/bin"
  LANAI_BIN=$T/bin
  export T
  echo 100 >"$T/now"
  echo 0 >"$T/count"
  echo active >"$T/unit"
  ui_timestamp() { ui_now; }
  ui_now() { cat "$T/now"; }
  ui_sleep() {
    echo "$(( $(cat "$T/now") + $1 ))" >"$T/now"
    if [[ ${MODE:-} == step5 || ${MODE:-} == panel ]]; then
      echo inactive >"$T/unit"
      echo inv >"$S/running"; echo inv >"$S/started"
      echo '{"invocation":"inv","guest":true}' >"$S/last-shutdown"
      echo '{"setup":true}' >"$S/boot.json"
      [[ $MODE != panel ]] || echo 'inv 100' >"$S/stop-requested"
    elif [[ ${MODE:-} == stop ]]; then echo inactive >"$T/unit"; fi
  }
  unit_state() { cat "$T/unit"; }
  unit_invocation() { echo inv; }
  cat >"$LANAI_BIN/lanai" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/calls"
printf '%s\n' "$(cat "$T/now")" >>"$T/times"
n=$(cat "$T/count"); echo "$((n+1))" >"$T/count"
case ${MODE:-} in
  step5|panel) if ((n == 0)); then echo '{"ok":true,"step":"5"}'; else echo '{"ok":true,"step":"6","questions":["share","scale"]}'; fi ;;
  step6|stop) if ((n < 2)); then echo '{"ok":true,"step":"6"}'; else echo '{"ok":true,"step":"7"}'; fi ;;
  failure) echo '{"ok":false,"step":"6"}'; exit 1 ;;
  malformed) echo invalid ;;
  *) echo '{"ok":true}';;
esac
SH
  chmod +x "$LANAI_BIN/lanai"
  systemd-run() { printf '%s\n' "$@" >"$T/launch"; }
}

@test "ui job: launch is a literal systemd session unit with collect" {
  run cmd_ui_job launch setup --window
  assert_success
  run cat "$T/launch"
  assert_output --partial -- '--user'
  assert_output --partial -- '--collect'
  assert_output --partial -- '--slice=session.slice'
  assert_output --partial $'ui-job-worker\nlaunch\nsetup\n--window'
}

@test "ui job: step 5 follows clean shutdown once with bare setup and ten second spacing" {
  export MODE=step5
  run cmd_ui_job_worker token setup --window
  assert_success
  assert_equal "$(cat "$T/calls")" $'setup --window\nsetup'
  assert_equal "$(cat "$T/times")" $'100\n110'
  assert_equal "$(jq -r '.ended' "$S/panel-result-setup.json")" 110
}

@test "ui job: panel Shut down during step 5 stops following" {
  export MODE=panel
  run cmd_ui_job_worker token setup --no-window
  assert_success
  assert_equal "$(cat "$T/count")" 1
}

@test "ui job: step 6 follows ten seconds apart; stop and failure end it" {
  local mode
  for mode in step6 stop failure; do
    export MODE=$mode
    echo 100 >"$T/now"; echo 0 >"$T/count"; echo active >"$T/unit"
    rm -f "$T/times"
    run cmd_ui_job_worker token setup
    assert_success
    if [[ $mode == step6 ]]; then assert_equal "$(cat "$T/times")" $'100\n110\n120'
    else assert_equal "$(cat "$T/count")" 1; fi
  done
}

@test "ui job: final record precedes unlock and contention never overwrites it" {
  local fd
  panel_result_write setup '{"token":"owner"}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_ui_job_worker refused setup
  assert_failure
  assert_equal "$(jq -r .token "$S/panel-result-setup.json")" owner
  exec {fd}>&-
  panel_result_write() {
    if [[ $(jq -r '.ended // empty' <<<"$2") != '' ]]; then
      if flock -n "$S/panel-job.lock" true; then echo 'unlocked too soon' >&2; return 1; fi
    fi
    printf '%s\n' "$2" >"$S/panel-result-$1.json"
  }
  run cmd_ui_job_worker final snapshot
  assert_success
}

@test "ui run: records the group's outcome and current invocation, validates replies" {
  export MODE=malformed
  run cmd_ui_run token start
  assert_success
  assert_equal "$(jq -r .reply.ok "$S/panel-result-vm.json")" false
  assert_equal "$(jq -r .invocation "$S/panel-result-vm.json")" inv
  run cmd_ui_run token setup
  assert_failure
}

@test "ui job: following records are visible during waits; terminal replies never follow" {
  local mode
  eval "$(declare -f ui_sleep | sed '1s/ui_sleep/fixture_sleep/')"
  ui_sleep() {
    jq -c '{reply,ended}' "$S/panel-result-setup.json" >>"$T/during-wait"
    fixture_sleep "$1"
  }
  export MODE=step6
  run cmd_ui_job_worker token setup
  assert_success
  run jq -se 'all(.[]; .reply.ok == true and .ended == null)' "$T/during-wait"
  assert_success
  for mode in questions base "done"; do
    local reply
    case $mode in
      questions) reply='{"ok":true,"step":"6","questions":["share","scale"]}' ;;
      base) reply='{"ok":true,"step":"3a"}' ;;
      *) reply='{"ok":true,"step":"7"}' ;;
    esac
    cat >"$LANAI_BIN/lanai" <<SH
#!/usr/bin/env bash
printf '%s\n' called >>"$T/terminal-calls"
printf '%s\n' '$reply'
SH
    : >"$T/terminal-calls"
    run cmd_ui_job_worker terminal setup
    assert_success
    assert_equal "$(wc -l <"$T/terminal-calls")" 1
  done
}

@test "ui job: an invocation change and a matching stop request end step 6" {
  export MODE=step6
  unit_invocation() { if (( $(ui_now) > 100 )); then echo different; else echo inv; fi; }
  run cmd_ui_job_worker token setup
  assert_success
  assert_equal "$(cat "$T/count")" 1
  echo 100 >"$T/now"; echo 0 >"$T/count"
  unit_invocation() { echo inv; }
  echo 'inv 100' >"$S/stop-requested"
  run cmd_ui_job_worker token setup
  assert_success
  assert_equal "$(cat "$T/count")" 1
}
