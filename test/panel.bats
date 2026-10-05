#!/usr/bin/env bats
# Panel decisions use isolated files and functions, never sockets or a VM.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
load helpers

setup() {
  # Match CLI pipeline errors without enabling nounset in Bats timeout traps.
  set -o pipefail
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  S=$(state_dir)
  RUN=$(run_dir)
  STORE=$T/storage
  mkdir -p "$S" "$RUN" "$STORE" "$HOME/Windows" "$(settings_file | xargs dirname)"
  printf '{"storage":"%s","memory_gib":8,"cores":4}\n' "$STORE" >"$(settings_file)"
  echo base >"$STORE/windows.base"
  ST=inactive RESULT=success INV=inv
  systemctl() { printf 'ActiveState=%s\nResult=%s\nInvocationID=%s\n' "$ST" "$RESULT" "$INV"; }
  layout_check() { return 0; }
  share_check() { return 0; }
  host_packages_missing() { :; }
  snapshot_list() { :; }
  guest_version_behind() { :; }
  eval "$(declare -f container_fact | sed '1s/container_fact/real_container_fact/')"
  container_fact() { echo none; }
  qmp_call() { printf '{"return":{"status":"running"}}\n'; }
  helper_alive() { return 0; }
  build_stamp_current() { return 0; }
  expected_base() { echo fixture.iso; }
  settings_seed() { echo '{"memory_gib":8,"cores":4}'; }
  export T
}

# Write setup state belonging to the fixture's storage.
state() { jq -nc --arg l "$STORE" --argjson d "$1" '$d + {location:$l}' >"$S/setup.json"; }

# Leave a stopped setup boot's evidence; a panel request is clean but incomplete.
ended() {
  printf inv >"$S/running"
  printf inv >"$S/started"
  echo '{"invocation":"inv","guest":true}' >"$S/last-shutdown"
  echo '{"setup":true}' >"$S/boot.json"
  [[ ${1:-clean} != panel ]] || echo 'inv 1' >"$S/stop-requested"
  [[ ${1:-clean} != forced ]] || : >"$S/forced"
}

# Compare the decision with the observable action/reply, not just its step.
assert_plan_agreement() {
  local plan=$1 reply=$2 action step
  case $reply in
    build) action=build; step=4 ;;
    setup-boot) action="setup-boot"; step=5 ;;
    normal-boot) action="normal-boot"; step=6 ;;
    *)
      step=$(jq -r .step <<<"$reply")
      assert_equal "$(jq -r '.reason // ""' <<<"$reply")" "$(jq -r .reason <<<"$plan")"
      case $step in
        1) action=problem ;;
        2) action=packages ;;
        3) action=snapshot ;;
        3a) action=base ;;
        5)
          if jq -e '.ok' <<<"$reply" >/dev/null; then action="setup-wait"
          elif jq -e '(.choices // [] | length) > 0' <<<"$reply" >/dev/null; then action=choices
          else action=problem; fi ;;
        6)
          if jq -e '.reason != null' <<<"$reply" >/dev/null; then action=problem
          else action=$(jq -r '.test_action // "wait"' <<<"$reply"); fi ;;
        7) action="done" ;;
      esac ;;
  esac
  assert_equal "$step" "$(jq -r .step <<<"$plan")"
  assert_equal "$action" "$(jq -r .action <<<"$plan")"
}

@test "panel: every status state has plain words and the full view" {
  local fixture_facts expected
  for expected in not-installed setup-needed stopped starting running stopping in-use version-mismatch failed; do
    case $expected in
      not-installed) fixture_facts=$'ActiveState=inactive\nLanaiInstall=none' ;;
      setup-needed) fixture_facts=$'ActiveState=inactive\nLanaiSetup=needed' ;;
      stopped) fixture_facts=$'ActiveState=inactive\nLanaiSetup=done' ;;
      starting) fixture_facts='ActiveState=activating' ;;
      running) fixture_facts=$'ActiveState=active\nLanaiSetup=done\nLanaiQmp=running\nLanaiQga=open' ;;
      stopping) fixture_facts='ActiveState=deactivating' ;;
      in-use) fixture_facts=$'ActiveState=inactive\nLanaiContainer=running' ;;
      version-mismatch) fixture_facts=$'ActiveState=active\nLanaiSetup=done\nLanaiVersion=mismatch' ;;
      failed) fixture_facts=$'ActiveState=failed\nResult=exit-code' ;;
    esac
    status_facts() { printf '%s\n' "$fixture_facts"; }
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .state <<<"$output")" "$expected"
    assert_equal "$(jq -r '[.label,.headline,.cause,.next,.notice,.warning,.busy,.buttons,.setup,.result,.settings,.snapshots,.logs] | length' <<<"$output")" 13
    refute_output --partial 'journalctl'
    refute_output --partial '—'
  done
}

@test "panel: finished setup offers both repair displays with labels and hints" {
  state '{"snapshot":"declined","done":true}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Run setup again'
  assert_equal "$(jq -c .setup.choices <<<"$output")" '["--no-window","--window"]'
  assert_equal "$(jq -r .buttons.no_window.label <<<"$output")" 'Set up in the Windows window'
  assert_equal "$(jq -r .buttons.window.label <<<"$output")" 'Set up in a basic window'
  run jq -e 'all(.buttons.no_window, .buttons.window; .show and .enable and (.hint | length > 0))' <<<"$output"
  assert_success
}

@test "panel words: failed snapshot decision is actionable while the offer stays silent" {
  run panel_words setup '{"ok":false,"step":"3","reason":"record","message":"UNTRUSTED"}'
  assert_success
  assert_output 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue setup.'
  state '{}'
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"step":"3","reason":"record"}}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .result.setup <<<"$output")" 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue setup.'
  run panel_words setup '{"ok":false,"step":"3"}'
  assert_output ''
}

@test "setup plan: steps and acting resume agree before and after marker consumption" {
  local fixture markers planned acted
  for markers in present consumed; do
    for fixture in offer build boot clean panel forced nostart normalnostart normal "done" explicit; do
      rm -f "$S/"{running,started,forced,last-shutdown,stop-requested,boot.json}
      ST=inactive RESULT=success
      state '{"snapshot":"declined"}'
      build_stamp_current() { [[ $fixture != build ]]; }
      case $fixture in
        offer) state '{}' ;;
        clean|panel|forced|nostart) state '{"snapshot":"declined","step5":false}'; ended "$fixture"
          [[ $fixture != nostart ]] || rm "$S/started" ;;
        normal) state '{"snapshot":"declined","step5":true}' ;;
        normalnostart) state '{"snapshot":"declined","step5":true}'; echo inv >"$S/running" ;;
        done) state '{"snapshot":"declined","done":true}' ;;
        explicit) state '{"snapshot":"declined","done":true,"step5":false}' ;;
      esac
      [[ $markers != consumed ]] || record_previous_run >/dev/null
      planned=$(setup_plan "$(shared_facts)")
      # Only replace the active checks: all step selection remains real.
      setup_step6() { setup_reply true 6 waiting '' '{"test_action":"checks"}'; }
      acted=$(setup_resume auto false '' '') || true
      assert_plan_agreement "$planned" "$acted"
      [[ $fixture != explicit ]] || assert_equal "$(jq -r .finished <<<"$planned")" false
    done
  done
}

@test "setup plan: changed storage and existing snapshots overlay without writes" {
  state '{"snapshot":"declined","step5":true,"done":true}'
  jq '.location="other"' "$S/setup.json" >"$S/new"; mv "$S/new" "$S/setup.json"
  snapshot_list() { echo "$T/snapshot"; }
  local before
  before=$(cat "$S/setup.json")
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .step <<<"$output")" 5
  assert_equal "$(cat "$S/setup.json")" "$before"
}

@test "setup plan: finished ignores missing share and container but requires stamp and closed round" {
  state '{"snapshot":"declined","done":true}'
  share_check() { echo missing; return 1; }
  container_fact() { echo running; }
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .finished <<<"$output")" true
  state '{"snapshot":"declined","done":true,"round":true}'
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .step <<<"$output")" 1
}

@test "setup plan: step 6 questions retire on RESET and hide after a no answer" {
  ST=active
  state '{"snapshot":"declined","step5":true}'
  echo '{"setup":false}' >"$S/boot.json"
  : >"$RUN/step6-asked"
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -c .questions <<<"$output")" '["share","scale"]'
  event_record '{"event":"RESET"}'
  assert [ ! -e "$RUN/step6-asked" ]
  : >"$RUN/step6-asked"
  setup_back5 answers 'The answer was no.' >/dev/null
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r '.questions | length' <<<"$output")" 0
  assert_equal "$(jq -r .step <<<"$output")" 5
}

@test "panel: stopping keeps Shut down enabled and only force_stop enables Force stop" {
  status_facts() { printf 'ActiveState=active\nLanaiStopAge=%s\n' "$age"; }
  local age
  for age in 1 120; do
    run cmd_panel
    assert_equal "$(jq -r .buttons.stop.enable <<<"$output")" true
    assert_equal "$(jq -r .buttons.force_stop.show <<<"$output")" "$([[ $age == 120 ]] && echo true || echo false)"
  done
}

@test "panel: restore pending overrides stopped setup and in-use guidance" {
  local fixture_status
  for fixture_status in stopped setup-needed in-use; do
    status_facts() { printf 'ActiveState=inactive\nLanaiRestorePending=true\n';
      [[ $fixture_status != stopped ]] || echo LanaiSetup=done
      [[ $fixture_status != in-use ]] || echo LanaiContainer=running; return 0; }
    run cmd_panel
    assert_equal "$(jq -r .buttons.start.enable <<<"$output")" false
    assert_equal "$(jq -r .buttons.finish_restore.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.finish_restore.enable <<<"$output")" "$([[ $fixture_status == in-use ]] && echo false || echo true)"
  done
}

@test "panel: setup reply is ignored and forced notice comes only from last-run" {
  ended forced
  run cmd_panel
  local before=$output
  echo '{"ok":true,"step":"7"}' >"$S/setup-reply.json"
  run cmd_panel
  assert_equal "$output" "$before"
  assert_equal "$(jq -r .notice <<<"$output")" ''
  echo forced >"$S/last-run"
  run cmd_panel
  assert_output --partial 'Windows was force-stopped'
}

@test "panel records: started following ended, interruption, launch timeout and read order" {
  local fd
  panel_result_write setup '{"token":"old","command":"setup","started":1}'
  run cmd_panel
  assert_equal "$(jq -r .busy.active <<<"$output")" false
  assert_output --partial 'interrupted'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  panel_result_write setup '{"token":"old","command":"setup","started":1,"reply":{"ok":true,"step":"6"}}'
  run cmd_panel
  assert_output --partial 'Checking Windows'
  exec {fd}>&-
  # Publish the end at the lock probe; it must be read afterwards.
  flock() { panel_result_write setup '{"token":"old","command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"7"}}'; command flock "$@"; }
  run cmd_panel
  refute_output --partial 'interrupted'
  run cmd_panel --pending never "$((EPOCHSECONDS - 11))"
  assert_output --partial 'did not start'
}

@test "panel words: failures, snapshot and restore outcomes persist but waits do not" {
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":true,"step":"5"}}'
  panel_result_write vm '{"command":"start","invocation":"old","ended":1,"reply":{"ok":true,"network":false}}'
  run cmd_panel
  assert_equal "$(jq -r '.result.setup + .result.vm' <<<"$output")" ''
  panel_result_write snapshots '{"command":"snapshot","ended":1,"reply":{"ok":true,"snapshot":"/copy"}}'
  run cmd_panel
  assert_output --partial 'grows as Windows changes'
  assert_output --partial 'file manager'
  panel_result_write snapshots '{"command":"restore","ended":1,"reply":{"ok":true}}'
  run cmd_panel
  assert_equal "$(jq -r .result.snapshots <<<"$output")" 'The snapshot was restored.'
  state '{"snapshot":"declined","done":true}'
  run cmd_panel
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .result.snapshots <<<"$output")" 'The snapshot was restored.'
  panel_result_write snapshots '{"command":"restore","ended":1,"reply":{"ok":false}}'
  run cmd_panel
  assert_output --partial 'could not restore'
  state '{"snapshot":"declined","step5":false}'
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"step":"5","reason":"idd-missing"}}'
  run cmd_panel
  assert_output --partial 'display driver'
}

@test "shared facts: builtin container scan recognizes both cgroups and skips active unit" {
  container_fact() { real_container_fact; }
  fake_proc 123 "$DOCKER_SCOPE" /usr/bin/qemu-system-x86_64
  run container_fact
  assert_output running
  fake_proc 123 /docker/abcdef /bin/bash /run/entry.sh
  run container_fact
  assert_output preparing
  container_fact() { echo preparing; touch "$T/scanned"; }
  ST=active
  run shared_facts
  refute_output --partial 'LanaiContainer=preparing'
  assert [ ! -e "$T/scanned" ]
}

@test "panel words: every reason and command branch uses structured keys, never CLI prose" {
  local reason command text
  for reason in busy session settings layout missing restore share container manager active record no-media nostart incomplete guest-boot idd-missing mismatch agents answers client snapshot-unsupported invalid-reply; do
    text=$(panel_words setup "$(jq -nc --arg r "$reason" '{ok:false,step:"1",reason:$r,message:"UNTRUSTED",next:"UNTRUSTED"}')")
    assert [ -n "$text" ]
    refute [ "$text" = 'Setup could not finish. Check the setup log, then continue setup.' ]
    refute [ "$text" = UNTRUSTED ]
  done
  for command in start open stop force-stop notice-seen settings setup-host setup snapshot restore; do
    run panel_words "$command" '{"ok":false,"message":"UNTRUSTED","next":"UNTRUSTED"}'
    assert_success
    refute_output ''
    refute_output --partial UNTRUSTED
    run panel_words "$command" '{"ok":true,"step":"6"}'
    [[ $command == restore ]] || assert_output ''
  done
  run panel_words setup '{"ok":false,"step":"2","missing":["a"]}'
  assert_output ''
  run panel_words setup '{"ok":false,"step":"3"}'
  assert_output ''
}

@test "setup plan: each step and reason is detected; active setup skips container scan" {
  local fixture expected plan
  for fixture in settings layout restore share container manager packages snapshot base build setup-boot setup-wait questions checking wait "done"; do
    ST=inactive
    state '{"snapshot":"declined"}'
    echo base >"$STORE/windows.base"
    rm -f "$S/restore-in-progress" "$S/boot.json" "$RUN/step6-asked"
    share_check() { return 0; }
    host_packages_missing() { :; }
    build_stamp_current() { return 0; }
    container_fact() { echo none; }
    local fixture_facts
    fixture_facts=$(shared_facts)
    case $fixture in
      settings|layout) expected=1; fixture_facts+=$'\nLanaiProblemReason='"$fixture" ;;
      restore) expected=1; fixture_facts+=$'\nLanaiRestorePending=true' ;;
      share) expected=1; share_check() { return 1; } ;;
      container) expected=1; fixture_facts+=$'\nLanaiContainer=preparing' ;;
      manager) expected=1; fixture_facts+=$'\nActiveState=unknown' ;;
      packages) expected=2; host_packages_missing() { echo package; } ;;
      snapshot) expected=3; state '{}' ;;
      base) expected=3a; rm "$STORE/windows.base" ;;
      build) expected=4; build_stamp_current() { return 1; } ;;
      setup-boot) expected=5 ;;
      setup-wait) expected=5; fixture_facts+=$'\nActiveState=active'; echo '{"setup":true}' >"$S/boot.json" ;;
      questions|checking|wait) expected=6; state '{"snapshot":"declined","step5":true}'; fixture_facts+=$'\nActiveState=active'
        [[ $fixture != wait ]] || fixture_facts+=$'\nActiveState=activating'
        [[ $fixture != questions ]] || : >"$RUN/step6-asked" ;;
      done) expected=7; state '{"done":true}' ;;
    esac
    plan=$(setup_plan "$fixture_facts")
    assert_equal "$(jq -r .step <<<"$plan")" "$expected"
    if [[ $expected == 1 ]]; then assert_equal "$(jq -r .reason <<<"$plan")" "$fixture"; fi
  done
}

@test "panel: setup problem guidance comes from the current plan and completed setup survives in-use" {
  share_check() { return 1; }
  run cmd_panel
  assert_output --partial 'shared Windows folder is missing'
  state '{"done":true}'
  container_fact() { echo running; }
  run cmd_panel
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .state <<<"$output")" in-use
}

@test "panel: a matching no-network result shows only during its active invocation" {
  panel_result_write vm '{"command":"start","invocation":"inv","ended":1,"reply":{"ok":true,"network":false}}'
  ST=active
  run cmd_panel
  assert_output --partial 'without a network'
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .result.vm <<<"$output")" ''
  panel_result_write vm '{"command":"start","ended":1,"reply":{"ok":false}}'
  run cmd_panel
  assert_output --partial 'could not start'
}

@test "panel: a wait after Shut down and a setup failure after restore cannot revive old guidance" {
  state '{"snapshot":"declined","step5":false}'
  ended panel
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":true,"step":"5"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  assert_equal "$(jq -r .buttons.window.show <<<"$output")" true
  rm -f "$S/"{running,started,last-shutdown,stop-requested,setup.json}
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"step":"5","reason":"mismatch"}}'
  panel_result_write snapshots '{"command":"restore","ended":2,"reply":{"ok":true}}'
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 3
  assert_equal "$(jq -r .buttons.window.show <<<"$output")" false
  assert_output --partial 'restored'
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
}

@test "panel records: newest outstanding record owns progress, pending tokens do not time out after launch" {
  local fd
  panel_result_write setup '{"token":"old","command":"setup","started":1}'
  panel_result_write snapshots '{"token":"new","command":"restore","started":2}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel --pending new 1
  assert_output --partial 'Restoring Windows'
  refute_output --partial 'did not start'
  exec {fd}>&-
}

@test "panel records: each monitor acknowledges its launch before another replaces the group record" {
  local first=monitor-first second=monitor-second at
  at=$((EPOCHSECONDS - 11))
  run cmd_panel --pending "$first" "$at"
  assert_success
  assert_equal "$(jq -r .pending_ack <<<"$output")" ''
  assert_output --partial 'did not start'
  panel_result_write setup '{"token":"monitor-first","command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"7"}}'
  run cmd_panel --pending "$first" "$at"
  assert_success
  assert_equal "$(jq -r .pending_ack <<<"$output")" "$first"
  refute_output --partial 'did not start'
  # The renderer clears this monitor's pending token on acknowledgment.
  first=$(jq -r --arg t "$first" 'if .pending_ack == $t then "" else $t end' <<<"$output")
  panel_result_write setup '{"token":"monitor-second","command":"setup","started":3,"ended":4,"reply":{"ok":true,"step":"7"}}'
  run cmd_panel --pending "$second" "$at"
  assert_success
  assert_equal "$(jq -r .pending_ack <<<"$output")" "$second"
  refute_output --partial 'did not start'
  assert_equal "$first" ''
  run cmd_panel
  assert_success
  refute_output --partial 'did not start'
  # An unrelated launch still needs its own record; no blanket acknowledgment.
  run cmd_panel --pending never "$at"
  assert_output --partial 'did not start'
}

@test "client stamp: read-only stamp check does not execute binary and pruning removes stamps with builds" {
  unset -f build_stamp_current
  # Restore just the real function, keeping all fixtures isolated.
  source "$REPO/lib/client.sh"
  local d
  d=$(client_builds)/$LG_BUILD
  mkdir -p "$d/bin"
  printf '#!/bin/bash\ntouch "%s/executed"\n' "$T" >"$d/bin/looking-glass-client"
  chmod +x "$d/bin/looking-glass-client"
  run build_stamp_current
  assert_failure
  echo "$LG_BUILD" >"$d/build-stamp"
  run build_stamp_current
  assert_success
  assert [ ! -e "$T/executed" ]
  mkdir -p "$(client_builds)/old/bin"
  : >"$(client_builds)/old/build-stamp"
  guest_version_get() { echo "$LG_BUILD"; }
  builds_prune
  assert [ ! -e "$(client_builds)/old/build-stamp" ]
  rm "$d/build-stamp"
  run build_stamp_current
  assert_failure
}

@test "panel: helper client and old-driver warnings use status details from the same read" {
  # This override is called with the gathered facts by cmd_panel.
  # shellcheck disable=SC2120
  status_facts() { printf '%s\n' "$1" 'LanaiHelpersMissing=clock' 'LanaiClient=timeout' 'LanaiDriverOld=old'; }
  run cmd_panel
  assert_output --partial 'background services stopped'
  assert_output --partial 'window did not open in time'
  assert_output --partial 'display driver needs an update'
}

@test "panel: settings and snapshot read failures stay separate from operation outcomes" {
  printf broken >"$(settings_file)"
  run cmd_panel
  assert_output --partial 'could not read the VM settings'
  assert_output --partial 'could not read the snapshot list'
  printf '{"storage":"%s","memory_gib":8,"cores":4}\n' "$STORE" >"$(settings_file)"
  snapshot_list() { return 1; }
  run cmd_panel
  assert_output --partial 'could not read the snapshot list'
}

@test "setup plan and resume: agreement for early and active steps in both marker states" {
  local fixture marker plan acted
  for marker in present consumed; do
    for fixture in packages base active-setup checks questions starting wrong-boot share layout restore done-container done-share; do
      ST=inactive
      state '{"snapshot":"declined"}'
      echo base >"$STORE/windows.base"
      rm -f "$S/"{running,started,forced,last-shutdown,stop-requested,boot.json,restore-in-progress} "$RUN/step6-asked"
      share_check() { return 0; }
      layout_check() { return 0; }
      container_fact() { echo none; }
      host_packages_missing() { :; }
      setup_step6() { setup_reply true 6 waiting '' '{"test_action":"checks"}'; }
      case $fixture in
        packages) host_packages_missing() { echo pkg; } ;;
        base) : >"$STORE/windows.base" ;;
        active-setup) ST=active; echo '{"setup":true}' >"$S/boot.json" ;;
        checks|questions|starting) ST=active; state '{"snapshot":"declined","step5":true}';
          [[ $fixture != questions ]] || : >"$RUN/step6-asked"
          [[ $fixture != starting ]] || ST=activating ;;
        wrong-boot) ST=active ;;
        share) share_check() { return 1; } ;;
        layout) layout_check() { echo broken; return 1; } ;;
        restore) : >"$S/restore-in-progress" ;;
        done-container) state '{"done":true}'; container_fact() { echo running; } ;;
        done-share) state '{"done":true}'; share_check() { return 1; } ;;
      esac
      [[ $marker != consumed ]] || record_previous_run >/dev/null
      plan=$(setup_plan "$(shared_facts)")
      acted=$(setup_resume auto false '' '') || true
      assert_plan_agreement "$plan" "$acted"
    done
  done
}

@test "setup command: client-mode setup boot opens its selected build; window mode does not" {
  setup_resume() { echo setup-boot; }
  setup_guest() { echo '{"ok":true,"window":false}'; }
  build_select() { echo "$T/client"; }
  client_start() { printf '%s\n' "$1" >"$T/client-started"; }
  run setup_command --no-window
  assert_success
  assert_equal "$(cat "$T/client-started")" "$T/client"
  rm "$T/client-started"
  setup_guest() { echo '{"ok":true,"window":true}'; }
  run setup_command --window
  assert_success
  assert [ ! -e "$T/client-started" ]
}

@test "run verdict: reads running last and consumes step5 before deleting running" {
  state '{"snapshot":"declined","step5":false}'
  ended clean
  jq() {
    if [[ $* == *last-shutdown* ]]; then
      command jq "$@"
      rm -f "$S/running"
    else command jq "$@"; fi
  }
  run run_verdict
  assert_equal "$(command jq -r .verdict <<<"$output")" none
  assert_equal "$(command jq -r .completes_step5 <<<"$output")" false
  unset -f jq
  ended clean
  rm() {
    if [[ $* == *running* ]]; then
      [[ $(command jq -r .step5 "$S/setup.json") == true ]] || return 1
    fi
    command rm "$@"
  }
  run record_previous_run
  assert_success
  assert [ ! -e "$S/running" ]
}

@test "step6: actual questions write their marker, and a no reply has a reason and hides them" {
  ST=active
  state '{"snapshot":"declined","step5":true}'
  version_check() { echo match; }
  log_client_build() { echo "$LG_BUILD"; }
  qmp_call() { echo '{"return":[{"label":"qga0","frontend-open":true},{"label":"vdagent","frontend-open":true}]}'; }
  qga_reply() { return 0; }
  client_active() { return 0; }
  guest_version_note() { :; }
  run setup_step6 '' ''
  assert_success
  assert [ -f "$RUN/step6-asked" ]
  assert_equal "$(jq -c .questions <<<"$output")" '["share","scale"]'
  run setup_step6 no yes
  assert_failure
  assert_equal "$(jq -r .reason <<<"$output")" answers
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .questions <<<"$output")" '[]'
}

@test "vm exec: clears the questions at start before running only stubbed helpers" {
  : >"$RUN/step6-asked"
  : >"$RUN/qga-open-since"
  : >"$RUN/qga-closed-since"
  vm_plan() { echo arguments; }
  default_gateway() { echo gateway; }
  run_once() { :; }
  supervise() { :; }
  sleep() { :; }
  INVOCATION_ID=inv run vm_exec
  assert_failure
  assert [ ! -e "$RUN/step6-asked" ]
  assert [ ! -e "$RUN/qga-open-since" ]
  assert [ ! -e "$RUN/qga-closed-since" ]
}

@test "panel: interrupted setup always offers Continue setup, including the snapshot offer" {
  panel_result_write setup '{"token":"lost","command":"setup","started":1}'
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 3
  assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" true
}

@test "snapshot: unsupported filesystem replies have a reason for the panel backup advice" {
  snapshot_create() { echo unavailable; return 3; }
  run cmd_snapshot
  assert_failure
  assert_equal "$(jq -r .reason <<<"$output")" snapshot-unsupported
  run panel_words snapshot "$output"
  assert_output --partial 'Make a backup'
}

@test "shared facts: status and setup resume each gather once and setup does not rescan active containers" {
  eval "$(declare -f shared_facts | sed '1s/shared_facts/original_shared_facts/')"
  shared_facts() { echo read >>"$T/fact-reads"; original_shared_facts; }
  ST=active
  state '{"snapshot":"declined","step5":true}'
  setup_step6() { setup_wait waiting; }
  container_fact() { touch "$T/container-scanned"; echo running; }
  run status_facts
  assert_success
  assert_equal "$(wc -l <"$T/fact-reads")" 1
  run setup_resume auto false '' ''
  assert_success
  assert_equal "$(wc -l <"$T/fact-reads")" 2
  assert [ ! -e "$T/container-scanned" ]
}

@test "shared facts: value-only unit state lets an empty base resume after an existing snapshot" {
  systemctl() { echo inactive; }
  snapshot_list() { echo "$T/snapshot"; }
  state '{}'
  : >"$STORE/windows.base"
  local facts before
  before=$(cat "$S/setup.json")
  facts=$(shared_facts)
  run setup_plan "$facts"
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 3a
  assert_equal "$(cat "$S/setup.json")" "$before"
  run setup_resume auto false '' ''
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 3a
  assert_equal "$(cat "$STORE/windows.base")" fixture.iso
  assert_equal "$(jq -r .snapshot "$S/setup.json")" taken
  systemctl() { return 1; }
  run shared_facts
  assert_output --partial 'ActiveState=unknown'
}

@test "setup resume: running another location or without setup media asks for shutdown" {
  ST=active
  local fixture before
  for fixture in other-location no-media; do
    state '{"snapshot":"declined"}'
    [[ $fixture != other-location ]] || echo '{"location":"elsewhere","snapshot":"declined","step5":true}' >"$S/setup.json"
    before=$(cat "$S/setup.json")
    run setup_resume auto false '' ''
    assert_failure
    assert_equal "$(jq -r .reason <<<"$output")" "$([[ $fixture == other-location ]] && echo active || echo no-media)"
    assert_equal "$(jq -r .next <<<"$output")" 'shut Windows down, then run setup again'
    assert_equal "$(cat "$S/setup.json")" "$before"
  done
}

@test "client stamp: an installed unstamped client takes a quick build check before setup continues" {
  source "$REPO/lib/client.sh"
  # Sourcing lib/client.sh again replaces setup()'s package stub with the real
  # check, which depends on the host's packages (CI lacks them).
  host_packages_missing() { :; }
  local d
  d=$(client_builds)/$LG_BUILD
  mkdir -p "$d/bin"
  printf '#!/bin/bash\necho "00:00:00.000 [I] main.c:4303 | main | Looking Glass (%s)" >&2\n' "$LG_BUILD" >"$d/bin/looking-glass-client"
  chmod +x "$d/bin/looking-glass-client"
  state '{"snapshot":"declined"}'
  run setup_plan "$(shared_facts)"
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 4
  # Keep timeout/the executable in a fresh shell, outside Bats' trap state.
  # All paths still come from isolate_home, including HOME and TMPDIR.
  # shellcheck disable=SC2016
  run --separate-stderr bash -c '
    set -euo pipefail
    source "$1/lib/lanai.sh"
    fetch_verified() { echo "unexpected download" >&2; return 1; }
    build_client
  ' _ "$REPO"
  assert_success
  assert_output "$d/bin/looking-glass-client"
  assert_equal "$(cat "$d/build-stamp")" "$LG_BUILD"
  run setup_plan "$(shared_facts)"
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 5
}

@test "panel records: a launch at the lock probe is read as started and running" {
  exec {PANEL_RACE_FD}>"$S/panel-job.lock"
  flock() {
    panel_result_write setup '{"token":"racing-launch","command":"setup","started":1}'
    command flock "$PANEL_RACE_FD"
    return 1
  }
  run cmd_panel --pending racing-launch 1
  assert_success
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  refute_output --partial interrupted
  refute_output --partial 'did not start'
  exec {PANEL_RACE_FD}>&-
}

@test "panel: its reads leave durable files unchanged, never running a client" {
  state '{"snapshot":"declined","step5":false}'
  ended clean
  echo '{"step":"7"}' >"$S/setup-reply.json"
  local before after
  before=$(find "$S" "$RUN" "$STORE" -type f -exec sha256sum {} + | sort)
  client_version() { touch "$T/client-ran"; return 1; }
  run cmd_panel
  assert_success
  after=$(find "$S" "$RUN" "$STORE" -type f -exec sha256sum {} + | sort)
  assert_equal "$before" "$after"
  assert [ ! -e "$T/client-ran" ]
}

@test "setup follow: a step 6 stop after the worker check cannot boot Windows" {
  state '{"snapshot":"declined","step5":true}'
  ST=active
  unit_state() { echo "$ST"; }
  unit_invocation() { echo "$INV"; }
  ui_sleep() { :; }
  ui_now() { echo 110; }
  systemctl() { [[ $* == '--user is-active --quiet graphical-session.target' ]]; }
  ui_setup_next '{"ok":true,"step":"6"}' inv 100
  # The unit exits between the worker deciding and setup taking its lock.
  ST=inactive
  boot_vm() { touch "$T/booted"; echo '{"ok":true}'; }
  client_start() { touch "$T/client-started"; }
  run setup_command --follow 6 inv
  assert_success
  assert_equal "$(jq -r .follow_stopped <<<"$output")" true
  assert [ ! -e "$T/booted" ]
  assert [ ! -e "$T/client-started" ]
}

@test "setup follow: locked checks reject changed invocations and panel stop requests" {
  local fixture before
  for fixture in invocation stop consumed step5-panel; do
    rm -f "$S/"{running,started,last-shutdown,stop-requested}
    state '{"snapshot":"declined","step5":true}'
    ST=active INV=inv
    case $fixture in
      invocation) INV=other ;;
      stop) echo 'inv 1' >"$S/stop-requested" ;;
      consumed) ST=inactive ;;
      step5-panel) ST=inactive; ended panel ;;
    esac
    before=$(cat "$S/setup.json")
    run setup_command --follow "$([[ $fixture == consumed || $fixture == step5-panel ]] && echo 5 || echo 6)" inv
    assert_success
    assert_equal "$(jq -r .follow_stopped <<<"$output")" true
    assert_equal "$(cat "$S/setup.json")" "$before"
    [[ $fixture != step5-panel ]] || assert [ -f "$S/running" ]
  done
}

@test "setup follow: matching locked step 5 completion advances and active step 6 checks" {
  state '{"snapshot":"declined","step5":false}'
  ended clean
  run setup_resume auto false '' '' 5 inv
  assert_success
  assert_output normal-boot
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  ST=active
  echo '{"setup":false}' >"$S/boot.json"
  setup_step6() { setup_reply true 6 checked '' '{"questions":["share","scale"]}'; }
  run setup_command --follow 6 inv
  assert_success
  assert_equal "$(jq -c .questions <<<"$output")" '["share","scale"]'
}

@test "panel records: two concurrent readers without a worker both report no job" {
  : >"$S/panel-job.lock"
  # Pause reader one after it takes the real probe lock, before record reads.
  flock() {
    command flock "$@" || return
    : >"$T/reader-ready"
    local i
    for ((i=0; i<100; i++)); do
      [[ ! -e $T/reader-release ]] || return 0
      sleep 0.05
    done
    return 1
  }
  (panel_records >"$T/reader-one") 3>&- &
  local reader=$!
  wait_for_file "$T/reader-ready"
  unset -f flock
  panel_records >"$T/reader-two"
  : >"$T/reader-release"
  wait "$reader"
  assert_equal "$(jq -r .held "$T/reader-one")" false
  assert_equal "$(jq -r .held "$T/reader-two")" false
}

@test "panel: finished setup can run again only while Windows is off" {
  state '{"snapshot":"declined","done":true}'
  ST=active
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" false
  assert_equal "$(jq -r .buttons.continue_setup.hint <<<"$output")" 'Shut Windows down to run setup again.'
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" true
  assert_equal "$(jq -r .buttons.continue_setup.hint <<<"$output")" ''
}

@test "panel: setup results follow their step, keep stepless failures and suppress repeated reasons" {
  state '{"snapshot":"declined","step5":false}'
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"step":"5","reason":"incomplete"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"reason":"busy"}}'
  state '{}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" 'Lanai is busy with another task. Try again in a moment.'
  panel_result_write setup '{"command":"setup","ended":2,"reply":{"ok":true,"step":"3a"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
}

@test "panel: interruption words match the group operation" {
  local command group expected
  for command in snapshot restore setup; do
    group=$(panel_group "$command")
    panel_result_write "$group" "$(jq -nc --arg c "$command" '{command:$c,started:1}')"
    run cmd_panel
    case $command in
      snapshot) expected='The snapshot did not finish. Try again.' ;;
      restore) expected='The restore did not finish. Finish the unfinished restore before starting Windows.' ;;
      setup) expected='Setup was interrupted. Continue setup to try again.' ;;
    esac
    assert_equal "$(jq -r --arg g "$group" '.result[$g]' <<<"$output")" "$expected"
  done
}

@test "panel: step 5 waits name the automatic shutdown and subsequent checks" {
  local fd
  ST=active
  state '{"snapshot":"declined"}'
  echo '{"setup":true}' >"$S/boot.json"
  panel_result_write setup '{"command":"setup","started":1,"reply":{"ok":true,"step":"5"}}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_equal "$(jq -r .busy.line <<<"$output")" 'Waiting for Windows to finish setup. You can close this panel.'
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" "In Windows, open Lanai's setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Don't use Shut down here during this step."
  exec {fd}>&-
}

@test "panel: warnings have no leading space and mismatch already explains the old driver" {
  status_facts() { printf 'ActiveState=active\nLanaiClient=timeout\nLanaiDriverOld=old\nLanaiVersion=mismatch\n'; }
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" 'The Windows window did not open in time. Try Open window again.'
}

@test "panel: logs name the journal and omit an unavailable client path" {
  run_dir() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .logs.vm <<<"$output")" 'Windows VM log: in your user journal, under lanai-vm'
  run jq -e '.logs | has("client") | not' <<<"$output"
  assert_success
}

@test "panel: setup wait guidance requires the held setup job, not just an active VM" {
  local fixture fd expected step
  for step in 5 6; do
    for fixture in cli failed-client failed-check retired-questions interrupted other-job following; do
      ST=active
      rm -f "$S/panel-result-setup.json" "$S/panel-result-snapshots.json" "$RUN/step6-asked"
      state '{"snapshot":"declined","step5":true}'
      if [[ $step == 5 ]]; then echo '{"setup":true}' >"$S/boot.json"
      else echo '{"setup":false}' >"$S/boot.json"; fi
      case $fixture in
        failed-client) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,ended:2,reply:{ok:false,step:$step,reason:"client"}}')" ;;
        failed-check) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,ended:2,reply:{ok:false,step:$step}}')" ;;
        retired-questions) panel_result_write setup '{"command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"6","questions":["share","scale"]}}' ;;
        interrupted) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,reply:{ok:true,step:$step}}')" ;;
        other-job) panel_result_write snapshots '{"command":"snapshot","started":3}'; exec {fd}>"$S/panel-job.lock"; flock "$fd" ;;
        following) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,reply:{ok:true,step:$step}}')"; exec {fd}>"$S/panel-job.lock"; flock "$fd" ;;
      esac
      run cmd_panel
      assert_success
      if [[ $step == 5 ]]; then
        expected="In Windows, open Lanai's setup drive and run setup.cmd. Then click Continue setup so Lanai can restart Windows and check it when setup.cmd finishes."
        [[ $fixture != following ]] || expected="In Windows, open Lanai's setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Don't use Shut down here during this step."
      else
        expected='Click Continue setup so Lanai can check Windows.'
        [[ $fixture != following ]] || expected='Windows is starting or being checked.'
      fi
      assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" "$expected"
      if [[ $fixture == other-job || $fixture == following ]]; then exec {fd}>&-; fi
    done
  done
}

@test "shared facts: no install has its own reason and setup words" {
  layout_check() { return 2; }
  local facts plan
  facts=$(shared_facts)
  assert [ "$facts" != '' ]
  assert_equal "$(sed -n 's/^LanaiProblemReason=//p' <<<"$facts")" missing
  plan=$(setup_plan "$facts")
  assert_equal "$(jq -r .reason <<<"$plan")" missing
  run setup_resume auto false '' ''
  assert_failure
  assert_equal "$(jq -r .reason <<<"$output")" missing
  run cmd_panel
  assert_success
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'No Windows install was found. Install Windows with Omarchy, then continue setup.'
}

@test "panel: logs and reply guidance use the same names" {
  run cmd_panel
  assert_equal "$(jq -r .logs.client <<<"$output")" "Windows window log: $RUN/client.log"
  assert_equal "$(jq -r .logs.job <<<"$output")" "Setup, snapshot and restore log: $S/panel-job.log"
  assert_equal "$(jq -r .logs.command <<<"$output")" "Button actions log: $S/panel-run.log"
  run panel_words setup '{"ok":false,"reason":"client"}'
  assert_output 'The Windows window could not open. Check the Windows window log and try again.'
  run panel_words setup '{"ok":false}'
  assert_output 'Setup could not finish. Check the setup log, then continue setup.'
  run panel_words snapshot '{"ok":false}'
  assert_output 'Lanai could not take the snapshot. Check the snapshot log and try again.'
  run panel_words restore '{"ok":false}'
  assert_output 'Lanai could not restore the snapshot. Check the restore log before trying again.'
  run cmd_panel --pending never "$((EPOCHSECONDS - 11))"
  assert_equal "$(jq -r .result.launch <<<"$output")" 'The operation did not start. Check the setup, snapshot and restore log, then try again.'
}

@test "panel: repair prompt and named restore labels come from the backend" {
  state '{"snapshot":"declined","done":true}'
  snapshot_list() { printf '%s\n' "$T/holiday" "$T/school"; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.again_line <<<"$output")" 'Choose how Windows should show during setup.'
  assert_equal "$(jq -r .buttons.cancel.label <<<"$output")" Cancel
  assert_equal "$(jq -r '.buttons.restore_snapshot.labels.holiday' <<<"$output")" 'Restore snapshot holiday'
  assert_equal "$(jq -r '.buttons.restore_confirm.labels.holiday' <<<"$output")" 'Restore holiday and replace Windows'
  assert_equal "$(jq -r '.buttons.restore_confirm.labels.school' <<<"$output")" 'Restore school and replace Windows'
}

@test "panel: Continue setup is disabled for step 5 active and no-media problems" {
  local reason
  for reason in active no-media; do
    setup_plan() { jq -nc --arg reason "$reason" '{step:"5",finished:false,action:"problem",reason:$reason,choices:[],questions:[]}'; }
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" false
  done
}

@test "panel: stopped step 6 without a setup worker asks for Continue setup" {
  state '{"snapshot":"declined","step5":true}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.step <<<"$output")" 6
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'Click Continue setup so Lanai can check Windows.'
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" true
}
