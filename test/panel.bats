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
  run panel_words setup '{"ok":false,"reason":"record","message":"UNTRUSTED"}' 3
  assert_success
  assert_output 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue without a snapshot or take a snapshot again.'
  run panel_words setup '{"ok":false,"reason":"record","message":"UNTRUSTED"}' 5
  assert_output 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue setup.'
  state '{}'
  setup_set() { return 1; }
  run setup_resume auto true '' ''
  assert_failure
  assert_equal "$(jq 'has("step")' <<<"$output")" false
  assert_equal "$(jq -r .reason <<<"$output")" record
  panel_result_write setup "$(jq -nc --argjson r "$output" '{command:"setup",ended:1,reply:$r}')"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.step <<<"$output")" 3
  assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" false
  assert_equal "$(jq -r .buttons.skip_snapshot.show <<<"$output")" true
  assert_equal "$(jq -r .buttons.setup_snapshot.show <<<"$output")" true
  assert_equal "$(jq -r .result.setup <<<"$output")" 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue without a snapshot or take a snapshot again.'
  run panel_words setup '{"ok":false,"step":"3"}'
  assert_output ''
}

@test "panel: failed existing snapshot decision stays visible at steps 4 and 5 until the next setup action" {
  state '{}'
  snapshot_list() { echo "$T/snapshot"; }
  setup_set() { return 1; }
  local step attempt
  for step in 4 5; do
    build_stamp_current() { [[ $step == 5 ]]; }
    for attempt in 1 2; do
      run setup_resume auto false '' ''
      assert_failure
      assert_equal "$(jq 'has("step")' <<<"$output")" false
      assert_equal "$(jq -r .reason <<<"$output")" record
      assert_equal "$(jq -r '.snapshot // "unset"' "$S/setup.json")" unset
      panel_result_write setup "$(jq -nc --argjson r "$output" --argjson a "$attempt" '{command:"setup",ended:$a,reply:$r}')"
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.step <<<"$output")" "$step"
      assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" true
      assert_equal "$(jq -r .result.setup <<<"$output")" 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue setup.'
    done
  done
  run cmd_panel
  assert_output --partial 'Lanai could not save the snapshot choice.'
  panel_result_write setup '{"command":"setup","ended":3,"reply":{"ok":true,"step":"5"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
}

@test "setup plan: steps and acting resume agree before and after marker consumption" {
  local fixture markers planned acted
  for markers in present consumed; do
    for fixture in offer build boot clean panel forced nostart normalnostart normal failed-setup failed-normal "done" explicit; do
      rm -f "$S/"{running,started,forced,last-shutdown,stop-requested,boot.json}
      ST=inactive RESULT=success
      state '{"snapshot":"declined"}'
      build_stamp_current() { [[ $fixture != build ]]; }
      case $fixture in
        offer) state '{}' ;;
        clean|panel|forced|nostart) state '{"snapshot":"declined","step5":false}'; ended "$fixture"
          [[ $fixture != nostart ]] || rm "$S/started" ;;
        failed-setup|failed-normal)
          ST=failed RESULT=exit-code
          state '{"snapshot":"declined","step5":false}'
          [[ $fixture != failed-normal ]] || state '{"snapshot":"declined","step5":true}'
          ended; rm "$S/last-shutdown" ;;
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
  assert_output --partial 'a real folder you own, not a link'
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
    for fixture in packages base active-setup checks questions starting wrong-boot share layout restore done-container done-share failed-setup failed-normal; do
      ST=inactive RESULT=success
      state '{"snapshot":"declined"}'
      echo base >"$STORE/windows.base"
      rm -f "$S/"{running,started,forced,last-shutdown,stop-requested,boot.json,restore-in-progress} "$RUN/step6-asked"
      share_check() { return 0; }
      layout_check() { return 0; }
      container_fact() { echo none; }
      host_packages_missing() { :; }
      setup_step6() { setup_reply true 6 waiting '' '{"test_action":"checks"}'; }
      case $fixture in
        failed-setup|failed-normal)
          ST=failed RESULT=exit-code
          state '{"snapshot":"declined","step5":false}'
          [[ $fixture != failed-normal ]] || state '{"snapshot":"declined","step5":true}'
          ended; rm "$S/last-shutdown" ;;
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
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" "In Windows, open Lanai's setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Use Shut down only if setup.cmd stops responding."
  exec {fd}>&-
}

@test "panel: warnings have no leading space and mismatch already explains the old driver" {
  state '{"done":true}'
  status_facts() { printf 'ActiveState=active\nLanaiClient=timeout\nLanaiDriverOld=old\nLanaiVersion=mismatch\nLanaiSetup=done\n'; }
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
        [[ $fixture != following ]] || expected="In Windows, open Lanai's setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Use Shut down only if setup.cmd stops responding."
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
  assert_equal "$(jq -c .setup.lines <<<"$output")" '[]'
  assert_equal "$(jq -r .next <<<"$output")" 'Install Windows with Omarchy, then continue setup.'
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

@test "panel: Continue setup is disabled for active and no-media problems at every step" {
  local reason step
  for step in 1 5 6; do
  for reason in active no-media; do
    setup_plan() { jq -nc --arg reason "$reason" --arg step "$step" '{step:$step,finished:false,action:"problem",reason:$reason,choices:[],questions:[]}'; }
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" false
  done
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

@test "panel: stopping step 6 waits for shutdown before Continue setup" {
  state '{"snapshot":"declined","step5":true}'
  ST=deactivating
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .state <<<"$output")" stopping
  assert_equal "$(jq -r .setup.step <<<"$output")" 6
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'Wait for Windows to shut down, then click Continue setup.'
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" false
}

@test "panel words: shared folder guidance explains its ownership and link rules" {
  run panel_words setup '{"ok":false,"reason":"share"}'
  assert_success
  assert_output 'Lanai needs a folder named Windows in your home folder. It must be a real folder you own, not a link. Create or fix it, then continue setup.'
}

@test "panel: missing install guidance appears only in the top block" {
  layout_check() { return 2; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .state <<<"$output")" not-installed
  assert_equal "$(jq -c .setup.lines <<<"$output")" '[]'
  assert_equal "$(jq -r .next <<<"$output")" 'Install Windows with Omarchy, then continue setup.'
}


# Durable steps, with a running worker supplied without a service or process.
setup_worker() {
  panel_records() { echo '{"held":true,"records":{"setup":{"command":"setup","started":1}}}'; }
}

@test "panel: first-time setup hides Start and Open at every step and keeps settings" {
  local step
  for step in 1 2 3 3a 4 5 6; do
    setup_plan() { jq -nc --arg step "$step" '{finished:false,step:$step,action:"problem",reason:"",choices:[],questions:[]}'; }
    for ST in inactive activating active deactivating reloading failed; do
      run cmd_panel
      assert_success
      assert_equal "$(jq -r '.buttons.start.show or .buttons.open.show' <<<"$output")" false
      assert_equal "$(jq -r .buttons.save_settings.show <<<"$output")" true
    done
  done
}

@test "panel: each setup step needs attention before its action and not while its worker runs" {
  local fixture expected
  for fixture in problem packages snapshot base build setup-boot normal-boot; do
    ST=inactive
    state '{"snapshot":"declined"}'
    echo base >"$STORE/windows.base"
    share_check() { [[ $fixture != problem ]]; }
    host_packages_missing() { [[ $fixture != packages ]] || echo package; }
    build_stamp_current() { [[ $fixture != build ]]; }
    case $fixture in
      problem) expected=1 ;;
      packages) expected=2 ;;
      snapshot) expected=3; state '{}' ;;
      base) expected=3a; rm "$STORE/windows.base" ;;
      build) expected=4 ;;
      setup-boot) expected=5 ;;
      normal-boot) expected=6; state '{"snapshot":"declined","step5":true}' ;;
    esac
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.step <<<"$output")" "$expected"
    assert_equal "$(jq -r .setup.attention <<<"$output")" true
    # Problems still need the user even while a worker winds down.
    if [[ $fixture != problem ]]; then
      setup_worker
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.attention <<<"$output")" false
      unset -f panel_records
      # Restore the real reader after the fixture worker.
      source "$REPO/lib/panel.sh"
    fi
  done
}

@test "panel: setup boot needs attention, checks wait quietly, questions and recovery need attention" {
  state '{"snapshot":"declined","step5":false}'
  ST=active
  echo '{"setup":true,"window":true}' >"$S/boot.json"
  setup_worker
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  state '{"snapshot":"declined","step5":true}'
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  client_active() { return 0; }
  for ST in active activating reloading deactivating; do
    run cmd_panel
    assert_equal "$(jq -r .setup.step <<<"$output")" 6
    assert_equal "$(jq -r .setup.attention <<<"$output")" false
  done
  ST=active
  : >"$RUN/step6-asked"
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  rm "$RUN/step6-asked"
  client_active() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" true
  client_active() { return 0; }
  panel_records() { echo '{"held":false,"records":{}}'; }
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  state '{"snapshot":"declined","step5":false}'
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .buttons.window.show <<<"$output")" true
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
}

@test "panel: failures, interrupted work and failed launches need attention, pending launches do not" {
  state '{"snapshot":"declined","step5":true}'
  ST=active
  client_active() { return 0; }
  setup_worker
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" false
  panel_records() { echo '{"held":true,"records":{"setup":{"command":"setup","started":1,"reply":{"ok":false,"step":"6","reason":"client"}}}}'; }
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  source "$REPO/lib/panel.sh"
  panel_result_write setup '{"command":"setup","started":1}'
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  rm "$S/panel-result-setup.json"
  run cmd_panel --pending missing "$EPOCHSECONDS"
  assert_equal "$(jq -r .setup.attention <<<"$output")" false
  run cmd_panel --pending missing "$((EPOCHSECONDS - 11))"
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
}

@test "panel: reopen follows the unfinished running boot, never a basic window or shutdown" {
  local boot client window
  for boot in setup checks normal finished; do
    case $boot in
      setup) state '{"snapshot":"declined","step5":false}'; echo '{"setup":true}' >"$S/boot.json" ;;
      checks) state '{"snapshot":"declined","step5":true}'; echo '{"setup":false}' >"$S/boot.json" ;;
      normal) state '{"snapshot":"declined"}'; echo '{"setup":false}' >"$S/boot.json" ;;
      finished) state '{"snapshot":"declined","done":true}'; echo '{"setup":false}' >"$S/boot.json" ;;
    esac
    for ST in inactive active activating reloading deactivating; do
      for client in closed running; do
        client_active() { [[ $client == running ]]; }
        for window in false true; do
          jq --argjson w "$window" '.window=$w' "$S/boot.json" >"$S/new"; mv "$S/new" "$S/boot.json"
          run cmd_panel
          assert_success
          local expected=false
          if [[ $boot != finished && $ST == active && $client == closed && $window == false ]]; then expected=true; fi
          if [[ $(jq -r .buttons.reopen_window.show <<<"$output") != "$expected" ]]; then echo "$boot / $ST / $client / $window" >&3; fi
          assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" "$expected"
          assert_equal "$(jq -r .buttons.reopen_window.enable <<<"$output")" "$expected"
          assert_equal "$(jq -r .buttons.reopen_window.label <<<"$output")" 'Reopen the Windows window'
        done
      done
    done
  done
}

@test "panel: step 6 rollback keeps Reopen available when its normal boot's client closes" {
  local reason client
  ST=active
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  for reason in answers agents; do
    state '{"snapshot":"declined","step5":true}'
    : >"$RUN/step6-asked"
    setup_back5 "$reason" 'The final check failed.' >/dev/null
    for client in running closed; do
      client_active() { [[ $client == running ]]; }
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.step <<<"$output")" 5
      assert_equal "$(jq -r '.setup.questions | length' <<<"$output")" 0
      assert_output --partial 'Shut Windows down, then continue setup to attach the setup drive.'
      assert_equal "$(jq -r '.buttons.start.show or .buttons.open.show or .buttons.continue_setup.enable' <<<"$output")" false
      assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" "$([[ $client == closed ]] && echo true || echo false)"
      assert_equal "$(jq -r .buttons.reopen_window.enable <<<"$output")" "$([[ $client == closed ]] && echo true || echo false)"
    done
  done
}

@test "panel: rollback shutdown clears setup attention despite its reason, failure reply and failed launch" {
  local reason shutdown reply
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  client_active() { return 1; }
  for reason in guest-boot idd-missing mismatch agents answers; do
    ST=active
    state '{"snapshot":"declined","step5":true}'
    reply=$(setup_back5 "$reason" 'The final check failed.')
    panel_result_write setup "$(jq -nc --argjson r "$reply" '{command:"setup",ended:1,reply:$r}')"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.attention <<<"$output")" true
    for shutdown in deactivating requested guest; do
      ST=active
      qmp_call() { printf '{"return":{"status":"running"}}\n'; }
      case $shutdown in
        deactivating) ST=deactivating ;;
        requested) printf 'inv %s\n' "$EPOCHSECONDS" >"$S/stop-requested" ;;
        guest) qmp_call() { printf '{"return":{"status":"shutdown"}}\n'; } ;;
      esac
      run cmd_panel --pending missing "$((EPOCHSECONDS - 11))"
      assert_success
      assert_equal "$(jq -r .state <<<"$output")" stopping
      assert_equal "$(jq -r .setup.step <<<"$output")" 5
      assert_output --partial 'Shut Windows down, then continue setup to attach the setup drive.'
      assert [ -n "$(jq -r .result.setup <<<"$output")" ]
      assert [ -n "$(jq -r .result.launch <<<"$output")" ]
      assert_equal "$(jq -r .setup.attention <<<"$output")" false
      assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" false
      rm -f "$S/stop-requested"
    done
    qmp_call() { printf '{"return":{"status":"running"}}\n'; }
  done
}

@test "panel: Snapshots hide only for unfinished setup with an active unit" {
  local finished expected
  snapshot_list() { echo "$T/snapshot"; }
  for finished in false true; do
    state "{\"snapshot\":\"declined\",\"done\":$finished}"
    for ST in inactive failed activating active reloading deactivating; do
      run cmd_panel
      assert_success
      expected=true
      if [[ $finished == false && $ST != inactive && $ST != failed ]]; then expected=false; fi
      assert_equal "$(jq -r .snapshots.show <<<"$output")" "$expected"
      assert_equal "$(jq -r .buttons.take_snapshot.show <<<"$output")" "$expected"
      assert_equal "$(jq -r .buttons.restore_snapshot.show <<<"$output")" "$expected"
      assert_equal "$(jq -r .buttons.restore_confirm.show <<<"$output")" "$expected"
    done
  done
  # A working install with a pending update keeps Snapshots on ordinary boots.
  state '{"snapshot":"declined","done":true}'
  build_stamp_current() { return 1; }
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  for ST in activating active reloading deactivating; do
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.finished <<<"$output")" false
    assert_equal "$(jq -r .snapshots.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.take_snapshot.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.restore_snapshot.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.restore_confirm.show <<<"$output")" true
  done
  state '{"snapshot":"declined"}'
  status_facts() { printf 'ActiveState=%s\nLanaiRestorePending=true\n' "$ST"; }
  for ST in active inactive; do
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .buttons.finish_restore.show <<<"$output")" "$([[ $ST == inactive ]] && echo true || echo false)"
  done
}

@test "panel: setup boot Shut down carries its second click and finished controls stay unchanged" {
  local boot finished
  for finished in false true; do
    state "{\"snapshot\":\"declined\",\"done\":$finished}"
    for boot in true false; do
      echo "{\"setup\":$boot}" >"$S/boot.json"
      for ST in inactive active activating reloading deactivating; do
        run cmd_panel
        assert_success
        local expected=false
        if [[ $finished == false && $boot == true && $ST != inactive && $ST != deactivating ]]; then expected=true; fi
        assert_equal "$(jq -r .buttons.stop.confirm <<<"$output")" "$expected"
        assert_equal "$(jq -r .buttons.stop_confirm.show <<<"$output")" "$expected"
        assert_equal "$(jq -r .buttons.stop_confirm.hint <<<"$output")" "Shutting down now stops setup. You'll choose how to continue."
        if [[ $finished == true ]]; then
          assert_equal "$(jq -r .setup.attention <<<"$output")" false
          assert_equal "$(jq -r .buttons.start.show <<<"$output")" "$([[ $ST == inactive ]] && echo true || echo false)"
          assert_equal "$(jq -r .buttons.open.show <<<"$output")" "$([[ $ST == inactive ]] && echo false || echo true)"
          assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Run setup again'
        fi
      done
    done
  done
}

@test "panel: working installs keep Start and Open beside each pending update step" {
  local pending
  client_active() { return 1; }
  qmp_call() { printf '{"return":{"status":"running"}}\n{"return":[{"label":"qga0","frontend-open":true}]}\n'; }
  for pending in stamp driver rerun; do
    state '{"snapshot":"declined","done":true}'
    build_stamp_current() { [[ $pending != stamp ]]; }
    guest_version_behind() { [[ $pending != driver ]] || echo old; }
    [[ $pending != rerun ]] || state '{"snapshot":"declined","done":true,"round":true,"step5":false}'
    for ST in inactive active; do
      echo '{"setup":false,"step6":true,"window":false}' >"$S/boot.json"
      [[ $pending != rerun ]] || echo '{"setup":false,"window":false}' >"$S/boot.json"
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.show <<<"$output")" true
      assert_equal "$(jq -r .setup.step <<<"$output")" "$([[ $pending == stamp ]] && echo 4 || echo 5)"
      assert_equal "$(jq -r '.buttons.start.show and .buttons.start.enable' <<<"$output")" "$([[ $ST == inactive ]] && echo true || echo false)"
      assert_equal "$(jq -r '.buttons.open.show and .buttons.open.enable' <<<"$output")" "$([[ $ST == active ]] && echo true || echo false)"
      assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" false
      assert_equal "$(jq -r .cause <<<"$output")" "$([[ $ST == inactive ]] && echo 'Windows is ready to start.' || echo 'Windows is available.')"
      assert_equal "$(jq -r .next <<<"$output")" "$([[ $ST == inactive ]] && echo 'Click Start Windows.' || echo 'Click Open window.')"
    done
  done
}

@test "panel: completing final checks restores the daily controls in the same boot" {
  ST=active
  state '{"snapshot":"declined","done":true}'
  echo '{"setup":false,"step6":true,"window":false}' >"$S/boot.json"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .buttons.open.show <<<"$output")" true
}

@test "panel: working installs hide daily controls only during setup or final check boots" {
  local boot
  state '{"snapshot":"declined","done":true,"round":true,"step5":true}'
  for boot in setup step6; do
    echo "{\"$boot\":true,\"window\":false}" >"$S/boot.json"
    for ST in activating active reloading deactivating; do
      run cmd_panel
      assert_success
      assert_equal "$(jq -r '.buttons.start.show or .buttons.open.show' <<<"$output")" false
    done
    ST=inactive
    run cmd_panel
    assert_equal "$(jq -r '.buttons.start.show and .buttons.start.enable' <<<"$output")" true
    assert_equal "$(jq -r .cause <<<"$output")" 'Windows is ready to start.'
  done
  echo '{"location":"elsewhere","done":true}' >"$S/setup.json"
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .buttons.start.show <<<"$output")" false
  refute_output --partial 'Windows is ready to start.'
}

@test "panel: hidden Start has setup guidance even when status says stopped" {
  status_map() { echo '{"state":"stopped","active":false,"setup_done":false,"window":false,"force_stop":false,"restore_pending":false}'; }
  run cmd_panel
  assert_equal "$(jq -r .buttons.start.show <<<"$output")" false
  assert_equal "$(jq -r .cause <<<"$output")" 'Lanai setup has not finished for this Windows install.'
  assert_equal "$(jq -r .next <<<"$output")" 'Follow the Setup section below.'
}

@test "panel: client timeout guidance follows the available window control" {
  local boot client
  ST=active
  status_facts() { printf '%s\n' "$1" 'LanaiClient=timeout' 'LanaiQmp=running' 'LanaiQga=open' 'LanaiSetup=done'; }
  for boot in client basic; do
    state '{"snapshot":"declined","step5":false}'
    echo "{\"setup\":true,\"window\":$([[ $boot == basic ]] && echo true || echo false)}" >"$S/boot.json"
    for client in closed running; do
      client_active() { [[ $client == running ]]; }
      run cmd_panel
      assert_success
      local advice='Check the Windows window log, then shut down and continue setup.'
      if [[ $boot == client && $client == closed ]]; then advice='Try Reopen the Windows window in Setup.'; fi
      assert_equal "$(jq -r .warning <<<"$output")" "The Windows window did not open in time. $advice"
    done
  done
  state '{"snapshot":"declined","done":true,"round":true}'
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" 'The Windows window did not open in time. Try Open window again.'
}

@test "panel: an existing shutdown request never asks for another confirmation" {
  local request
  state '{"snapshot":"declined"}'
  echo '{"setup":true}' >"$S/boot.json"
  for request in current activating old stopping guest; do
    ST=active
    qmp_call() { echo '{"return":{"status":"running"}}'; }
    rm -f "$S/stop-requested"
    case $request in
      current) echo "inv $EPOCHSECONDS" >"$S/stop-requested" ;;
      activating) ST=activating; echo "inv $EPOCHSECONDS" >"$S/stop-requested" ;;
      old) echo "other $EPOCHSECONDS" >"$S/stop-requested" ;;
      stopping) ST=deactivating ;;
      guest) qmp_call() { echo '{"return":{"status":"shutdown"}}'; } ;;
    esac
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .buttons.stop.confirm <<<"$output")" "$([[ $request == old ]] && echo true || echo false)"
    assert_equal "$(jq -r .buttons.stop_confirm.show <<<"$output")" "$([[ $request == old ]] && echo true || echo false)"
    assert_equal "$(jq -r .buttons.stop.enable <<<"$output")" true
  done
}

@test "setup command: a Reopen in either boot gap keeps setup successful" {
  local boot running
  build_select() { echo "$T/selected"; }
  pinned_client() { echo "$T/pinned"; }
  client_start() { echo "$1" >"$T/client-started"; [[ $running == false ]]; }
  for boot in setup-boot normal-boot; do
    setup_resume() { echo "$boot"; }
    setup_guest() { echo '{"ok":true,"window":false}'; }
    boot_vm() { echo '{"ok":true,"window":false}'; }
    for running in true false; do
      rm -f "$T/client-started"
      client_active() { [[ $running == true ]]; }
      run setup_command
      assert_success
      assert_equal "$(jq -r .step <<<"$output")" "$([[ $boot == setup-boot ]] && echo 5 || echo 6)"
      if [[ $running == true ]]; then
        assert [ ! -e "$T/client-started" ]
      else
        assert_equal "$(cat "$T/client-started")" "$T/$([[ $boot == setup-boot ]] && echo selected || echo pinned)"
      fi
    done
  done
}

@test "setup command: Reopen while selecting the client does not fail the setup boot" {
  setup_resume() { echo setup-boot; }
  setup_guest() { echo '{"ok":true,"window":false}'; }
  build_select() { touch "$T/client-open"; echo "$T/selected"; }
  client_active() { [[ -e $T/client-open ]]; }
  client_start() { touch "$T/client-started"; return 1; }
  run setup_command
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 5
  assert [ ! -e "$T/client-started" ]
}

@test "boot mode: final checks are recorded and an ordinary start clears the flag" {
  state '{"snapshot":"declined","done":true,"round":true,"step5":true}'
  lanai_flock() { return 0; }
  preflight() { return 0; }
  vm_plan() { return 0; }
  runtime_refresh() { return 0; }
  host_scale() { echo 100; }
  default_gateway() { echo gateway; }
  local checks
  for checks in true false; do
    run boot_vm false auto "$checks"
    assert_success
    assert_equal "$(jq -r '.step6 // false' "$S/boot.json")" "$checks"
  done
}

@test "panel: automatic setup startup waits quietly until Windows can show its setup drive" {
  state '{"snapshot":"declined","step5":false}'
  echo '{"setup":true,"window":true}' >"$S/boot.json"
  setup_worker
  for ST in activating active; do
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.attention <<<"$output")" "$([[ $ST == activating ]] && echo false || echo true)"
  done
}

@test "panel progress: external flock owner advances without a job record and blocks controls" {
  local fd pid=$BASHPID
  exec {fd}>"$S/lock"
  flock -n "$fd"
  # flock exits; the live owner retains its open descriptor and lock.
  jq -nc --argjson p "$pid" '{operation:"snapshot",phase:"hashing",done:25,total:100,pid:$p}' >"$S/image-progress.json"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r '.progress.percent' <<<"$output")" 24
  assert_equal "$(jq -r '.busy.active' <<<"$output")" true
  assert_equal "$(jq -r '.buttons.take_snapshot.enable' <<<"$output")" false
  assert_equal "$(jq -r '.progress.label' <<<"$output")" "Taking snapshot: reading image"
  jq '.done=100' "$S/image-progress.json" >"$S/next.json"
  mv "$S/next.json" "$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress.percent' <<<"$output")" 99
  exec {fd}>&-
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
}

@test "panel progress: dead owners, unrelated open files, wrong lock inodes and malformed records are ignored" {
  local fd pid=$BASHPID
  exec {fd}>"$S/other-lock"
  flock -n "$fd"
  : >"$S/lock"
  jq -nc --argjson p "$pid" '{operation:"restore",phase:"checking",done:0,total:0,pid:$p}' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  exec {fd}>&-
  exec {fd}>"$S/lock"
  # An open descriptor without a FLOCK does not suffice.
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  flock -n "$fd"
  jq '.pid=2147483647' "$S/image-progress.json" >"$S/next.json"
  mv "$S/next.json" "$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  # A live owner which has no descriptor to this lock also fails.
  (exec {fd}>&-; sleep 30) &
  local live=$!
  BG_PIDS+=("$live")
  jq -nc --argjson p "$live" '{operation:"restore",phase:"checking",done:0,total:0,pid:$p}' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  echo '{broken' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  exec {fd}>&-
  kill "$live"
  wait "$live" || true
}
