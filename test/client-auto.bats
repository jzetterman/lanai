#!/usr/bin/env bats
# Lanai's own client update (docs/plugin/client-auto-update/): the try
# record, the launch, the worker and the view. The worker runs as its own
# process through one lanai wrapper in $T/bin, which sources lib/lanai.sh and
# $T/stubs.bash. The systemd-run stub starts it with setsid, so a test stops
# it as systemd does, by signalling its process group. No real unit starts,
# and nothing builds.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329,SC2016
load helpers
load panel-fixtures

setup() {
  isolate_home
  panel_fixture_setup
  export REPO
  # $RUN as Lanai makes it (run_dir_check).
  chmod 700 "$RUN"
  mkdir -p "$T/bin" "$T/units"
  echo inactive >"$T/st"
  echo success >"$T/result"
  echo inv >"$T/inv"
  echo ok >"$T/run-mode"
  state "$CURRENT"
  auto_bin
  auto_stubs
}

teardown() {
  local f
  for f in "$T"/units/*; do
    [[ -f $f ]] || continue
    kill -KILL -- "-$(<"$f")" 2>/dev/null || true
  done
  stop_bg
}

# The stubs the test shell and every worker share. Facts come from files in
# $T, since the worker is its own process: st, result and inv (the VM unit),
# session and manager (the user manager), current (the client is current),
# no-stamp (no pinned client), behind (the guest's older driver), slow and
# fails (the build), plan-fails, write-fails (the try record), stop-at and
# false-at (the worker's seams).
auto_stubs() {
  LANAI_BIN=$T/bin
  systemctl() {
    case "$*" in
      '--user is-active --quiet graphical-session.target')
        [[ $(cat "$T/session" 2>/dev/null || echo active) == active ]] ;;
      '--user is-system-running')
        local m
        m=$(cat "$T/manager" 2>/dev/null || echo running)
        echo "$m"
        [[ $m == running ]] ;;
      *) printf 'ActiveState=%s\nResult=%s\nInvocationID=%s\n' "$(<"$T/st")" "$(<"$T/result")" "$(<"$T/inv")" ;;
    esac
  }
  layout_check() { return 0; }
  share_check() { return 0; }
  host_packages_missing() { :; }
  snapshot_list() { :; }
  container_fact() { echo none; }
  qmp_call() { printf '{"return":{"status":"running"}}\n'; }
  helper_alive() { return 0; }
  expected_base() { echo fixture.iso; }
  settings_seed() { echo '{"memory_gib":8,"cores":4}'; }
  unit_invocation() { echo inv; }
  guest_version_behind() { cat "$T/behind" 2>/dev/null || true; }
  build_stamp_current() { [[ ! -e $T/no-stamp ]]; }
  build_patches_current() { [[ -e $T/current ]]; }
  build_client() {
    echo build >>"$T/builds"
    if [[ -e $T/slow ]]; then
      touch "$T/building"
      sleep 2
    fi
    if [[ -e $T/fails ]]; then
      echo "the client did not build; see the log"
      return 1
    fi
    touch "$T/current"
    echo "$T/client"
  }
  if ! declare -F real_setup_plan >/dev/null; then
    eval "$(declare -f setup_plan | sed '1s/setup_plan/real_setup_plan/')"
  fi
  setup_plan() {
    [[ ! -e $T/plan-fails ]] || return 1
    real_setup_plan "$@"
  }
  # A full disk: every write of the try record fails.
  if ! declare -F real_auto_record_write >/dev/null; then
    eval "$(declare -f auto_record_write | sed '1s/auto_record_write/real_auto_record_write/')"
  fi
  auto_record_write() {
    [[ ! -e $T/write-fails ]] || return 1
    real_auto_record_write "$@"
  }
  # The worker's wait between its checks marks that it waits.
  ui_sleep() {
    touch "$T/waiting"
    sleep "$1"
  }
  # A stop at <step> marks it and waits to be signalled; a false at <step>
  # is an error under set -e.
  auto_step() {
    if [[ $(cat "$T/stop-at" 2>/dev/null) == "$1" ]]; then
      touch "$T/at-$1"
      sleep 30
    fi
    if [[ $(cat "$T/false-at" 2>/dev/null) == "$1" ]]; then
      echo "an error at $1" >&2
      false
    fi
  }
  # Each token whose unit (its process group) still runs.
  auto_units() {
    local f
    for f in "$T"/units/*; do
      [[ -f $f ]] || continue
      ! kill -0 "$(<"$f")" 2>/dev/null || printf '%s\n' "${f##*/}"
    done
  }
  # Log the arguments, then act by $T/run-mode: ok starts the command after
  # -- in its own process group, as a unit, with fd 3 closed; fail fails;
  # silent reports success and runs nothing.
  systemd-run() {
    local a token="" mode
    local -a cmd=()
    printf '%s\n' "$@" >>"$T/launch"
    for a; do
      [[ $a != --unit=lanai-panel-* ]] || token=${a#--unit=lanai-panel-}
    done
    while (($#)) && [[ $1 != -- ]]; do shift; done
    shift
    cmd=("$@")
    mode=$(<"$T/run-mode")
    case $mode in
      fail) return 1 ;;
      silent) return 0 ;;
    esac
    setsid bash -c '"$@"; echo "$?" >"$T/rc-$0"' "$token" "${cmd[@]}" \
      </dev/null >"$T/out-$token" 2>"$T/err-$token" 3>&- &
    echo "$!" >"$T/units/$token"
    # Return once setsid has made the group, as systemd-run returns once
    # the unit runs; before that, a wait on the group would end at once.
    local i
    for ((i = 0; i < 100; i++)); do
      kill -0 -- "-$!" 2>/dev/null && break
      sleep 0.05
    done
  }
}

# Write the one lanai wrapper the worker runs, and $T/stubs.bash. With
# $T/lanai-mode, the wrapper answers {"ok":true} (the hand path's CLI).
auto_bin() {
  {
    declare -f auto_stubs
    echo auto_stubs
  } >"$T/stubs.bash"
  cat >"$T/bin/lanai" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -e $T/lanai-mode ]]; then echo '{"ok":true}'; exit 0; fi
source "$REPO/lib/lanai.sh"
source "$T/stubs.bash"
lanai_main "$@"
SH
  chmod +x "$T/bin/lanai"
}

# Wait up to 10 s for the unit of <token> (its process group) to end.
auto_wait() {
  local i pgid
  pgid=$(<"$T/units/$1")
  for ((i = 0; i < 100; i++)); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 0.1
  done
  fail "the worker $1 did not end"
}

# Wait up to 10 s for file <path>.
auto_file() {
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -e $1 ]] && return 0
    sleep 0.1
  done
  fail "$1 never appeared"
}

# Start a worker for <token> as its unit, then wait for it to end.
auto_run() {
  run cmd_ui_job "$1" build-client --auto
  assert_success
  auto_wait "$1"
}

# Print the try record's tries, compactly.
tries() { jq -c '.tries' "$S/client-auto.json" 2>/dev/null || echo none; }

# Print how many builds ran.
builds() { if [[ -e $T/builds ]]; then wc -l <"$T/builds"; else echo 0; fi; }

# Write a try record for patches <id> with tries <json>.
record() { jq -nc --arg p "$1" --argjson t "$2" '{patches:$p,tries:$t}' >"$S/client-auto.json"; }

# --- Phase B: the record, the launch and the worker ---

@test "auto worker: a due update records one try and builds" {
  local st id
  id=$(patches_id)
  for st in inactive active; do
    echo "$st" >"$T/st"
    rm -f "$T/current" "$T/builds" "$S/client-auto.json" "$S/panel-result-client.json"
    auto_run "auto-$st"
    assert_equal "$(builds)" 1
    assert_equal "$(jq -r .patches "$S/client-auto.json")" "$id"
    assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" "[[\"auto-$st\",\"ok\"]]"
    assert_equal "$(jq -r '.tries[0].at | type' "$S/client-auto.json")" number
    assert_equal "$(jq -r .token "$S/panel-result-client.json")" "auto-$st"
    assert_equal "$(jq -r .command "$S/panel-result-client.json")" build-client
    assert_equal "$(jq -c .args "$S/panel-result-client.json")" '["--auto"]'
    assert_equal "$(jq -r .reply.ok "$S/panel-result-client.json")" true
    assert [ -n "$(jq -r '.ended // empty' "$S/panel-result-client.json")" ]
    assert_equal "$(<"$T/rc-auto-$st")" 0
  done
}

@test "auto worker: nothing is due in each case of requirement 2" {
  local case n=0
  for case in signin old-task unfinished no-stamp behind current over session; do
    n=$((n + 1))
    state "$CURRENT"
    rm -f "$T/current" "$T/no-stamp" "$T/behind" "$T/session" "$S/client-auto.json"
    case $case in
      signin) state '{"done":true,"scale_task":2}' ;;
      old-task) state '{"done":true}' ;;
      unfinished) state '{"snapshot":"declined"}' ;;
      no-stamp) touch "$T/no-stamp" ;;
      behind) echo B7-801-g1a2b3c4d5e >"$T/behind" ;;
      current) touch "$T/current" ;;
      over) record "$(patches_id)" '[{"token":"auto-old","at":1,"outcome":"failed"}]' ;;
      session) echo inactive >"$T/session" ;;
    esac
    [[ $case == over ]] || rm -f "$S/client-auto.json"
    auto_run "auto-$n"
    assert_equal "$(<"$T/rc-auto-$n")" 0
    assert_equal "$(builds)" 0
    if [[ $case == over ]]; then
      assert_equal "$(tries)" '[{"token":"auto-old","at":1,"outcome":"failed"}]'
    else
      assert [ ! -e "$S/client-auto.json" ]
    fi
    assert [ ! -e "$S/panel-result-client.json" ]
    # A planned exit gives nothing up.
    assert [ ! -e "$RUN/client-auto-gave-up" ]
  done
}

@test "auto launch: a failed systemd-run during a logout records nothing" {
  echo fail >"$T/run-mode"
  echo inactive >"$T/session"
  run cmd_ui_job auto-a build-client --auto
  assert_failure 1
  assert [ ! -e "$S/client-auto.json" ]
  # Windows still shuts down at a logout: the session is active, the
  # manager is stopping.
  echo active >"$T/session"
  echo stopping >"$T/manager"
  run cmd_ui_job auto-b build-client --auto
  assert_failure 1
  assert [ ! -e "$S/client-auto.json" ]
  # A degraded manager still runs units, and exits 1 for it.
  echo degraded >"$T/manager"
  run cmd_ui_job auto-c build-client --auto
  assert_failure 1
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-c","launch"]]'
}

@test "auto launch: the token prefix goes with --auto" {
  run cmd_ui_job auto-a build-client
  assert_failure 2
  run cmd_ui_job panel-a build-client --auto
  assert_failure 2
  run cmd_ui_job_worker auto-a build-client
  assert_failure 2
  run cmd_ui_job_worker panel-a build-client --auto
  assert_failure 2
  # The prefix alone is not a token.
  run cmd_ui_job auto- build-client --auto
  assert_failure 2
  run cmd_ui_job_worker auto- build-client --auto
  assert_failure 2
  assert [ ! -e "$T/launch" ]
  assert [ ! -e "$S/client-auto.json" ]
  assert_equal "$(builds)" 0
}

@test "auto worker: a hold that falls between two polls is waited out" {
  local hold
  for hold in panel-job build progress; do
    rm -f "$T/current" "$T/builds" "$S/client-auto.json" "$T/held" "$T/release" "$S/image-progress.json"
    # Each holder keeps its lock until $T/release appears.
    case $hold in
      panel-job)
        flock "$S/panel-job.lock" bash -c 'touch "$1"; while [[ ! -e $2 ]]; do sleep 0.05; done' _ "$T/held" "$T/release" 3>&- & ;;
      build)
        flock "$S/build.lock" bash -c 'touch "$1"; while [[ ! -e $2 ]]; do sleep 0.05; done' _ "$T/held" "$T/release" 3>&- & ;;
      progress)
        # A command-line snapshot: the operation lock held, its progress
        # written by the holder.
        flock "$S/lock" bash -c 'jq -nc --argjson p "$$" '\''{operation:"snapshot",phase:"cloning",done:0,total:0,pid:$p}'\'' >"$2"
touch "$1"; while [[ ! -e $3 ]]; do sleep 0.05; done' _ "$T/held" "$S/image-progress.json" "$T/release" 3>&- & ;;
    esac
    BG_PIDS+=("$!")
    wait_for_file "$T/held"
    run cmd_ui_job "auto-$hold" build-client --auto
    assert_success
    sleep 1
    assert [ ! -e "$S/client-auto.json" ]
    assert_equal "$(builds)" 0
    # It holds no lock while it waits: a panel job could start.
    if [[ $hold != panel-job ]]; then
      run flock -n "$S/panel-job.lock" true
      assert_success
    fi
    touch "$T/release"
    auto_wait "auto-$hold"
    assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" "[[\"auto-$hold\",\"ok\"]]"
    assert_equal "$(builds)" 1
    stop_bg
  done
}

@test "auto worker: short read probes are waited out" {
  local lock
  for lock in panel-job build; do
    rm -f "$T/current" "$T/builds" "$S/client-auto.json" "$T/held"
    flock -s "$S/$lock.lock" bash -c 'touch "$1"; exec sleep 0.5' _ "$T/held" 3>&- &
    BG_PIDS+=("$!")
    wait_for_file "$T/held"
    auto_run "auto-$lock"
    assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" "[[\"auto-$lock\",\"ok\"]]"
    assert_equal "$(builds)" 1
    stop_bg
  done
}

@test "auto launch: a failed systemd-run records one launch try" {
  echo fail >"$T/run-mode"
  run cmd_ui_job auto-a build-client --auto
  assert_failure 1
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-a","launch"]]'
  assert_equal "$(jq -r .patches "$S/client-auto.json")" "$(patches_id)"
  run cmd_ui_job auto-b build-client --auto
  assert_failure 1
  assert_equal "$(jq -c '[.tries[] | .token]' "$S/client-auto.json")" '["auto-a"]'
  # It waits for panel-job.lock, as long as another holds it.
  rm "$S/client-auto.json"
  flock "$S/panel-job.lock" bash -c 'touch "$1"; while [[ ! -e $2 ]]; do sleep 0.05; done' _ "$T/held" "$T/release" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/held"
  (cmd_ui_job auto-c build-client --auto >/dev/null) 3>&- &
  local launch=$!
  sleep 0.5
  assert [ ! -e "$S/client-auto.json" ]
  touch "$T/release"
  wait "$launch" || true
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-c","launch"]]'
}

@test "auto worker: holds build.lock while it builds" {
  echo built >"$T/stop-at"
  run cmd_ui_job auto-a build-client --auto
  assert_success
  auto_file "$T/at-built"
  # A terminal lanai build-client is refused meanwhile.
  run build_client_locked
  assert_failure 3
}

@test "auto launch: a launch whose worker never runs records nothing" {
  echo silent >"$T/run-mode"
  run cmd_ui_job auto-a build-client --auto
  assert_success
  assert [ ! -e "$S/client-auto.json" ]
  echo ok >"$T/run-mode"
  auto_run auto-b
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-b","ok"]]'
  assert_equal "$(builds)" 1
}

@test "auto worker: every error after the count records failed" {
  local case
  for case in build seam plan; do
    rm -f "$T/fails" "$T/false-at" "$T/plan-fails" "$S/client-auto.json" "$T/builds"
    case $case in
      build) touch "$T/fails" ;;
      seam) echo counted >"$T/false-at" ;;
      plan) touch "$T/plan-fails" ;;
    esac
    auto_run "auto-$case"
    assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" "[[\"auto-$case\",\"failed\"]]"
    # An error after the count is a failed try, not a give-up.
    assert [ ! -e "$RUN/client-auto-gave-up" ]
    case $case in
      build) assert_equal "$(<"$T/rc-auto-$case")" 0 ;;
      *)
        [[ $(<"$T/rc-auto-$case") != 0 ]] || fail "the $case error exited 0"
        assert_equal "$(jq -r .ok "$T/out-auto-$case")" false
        assert_equal "$(builds)" 0
        ;;
    esac
    case $case in
      seam) run cat "$S/panel-job.log"; assert_output --partial "an error at counted" ;;
      plan) run cat "$S/panel-job.log"; assert_output --partial "Lanai could not read the setup plan" ;;
    esac
    # The tries are over: a next worker builds nothing.
    rm -f "$T/fails" "$T/false-at" "$T/plan-fails" "$T/builds"
    auto_run "auto-$case-next"
    assert_equal "$(builds)" 0
    assert_equal "$(jq -r '.tries | length' "$S/client-auto.json")" 1
  done
}

@test "auto worker: a stop by a signal leaves a stop" {
  local signal step i
  for signal in TERM KILL; do
    for step in counted published built; do
      rm -f "$T/current" "$T/builds" "$S/client-auto.json" "$T/at-$step"
      echo "$step" >"$T/stop-at"
      run cmd_ui_job "auto-$signal-$step" build-client --auto
      assert_success
      auto_file "$T/at-$step"
      # Published: the client record names Lanai's own update, with no
      # reply yet.
      if [[ $step == published ]]; then
        assert_equal "$(jq -c '[.args, has("reply")]' "$S/panel-result-client.json")" '[["--auto"],false]'
      fi
      kill "-$signal" -- "-$(<"$T/units/auto-$signal-$step")"
      for ((i = 0; i < 20; i++)); do
        kill -0 -- "-$(<"$T/units/auto-$signal-$step")" 2>/dev/null || break
        sleep 0.1
      done
      ((i < 20)) || fail "the worker outlived SIG$signal at $step by 2 s"
      assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" "[[\"auto-$signal-$step\",null]]"
      # The lock went with the group: a next worker gets it at once.
      rm -f "$T/stop-at"
      run flock -w 1 "$S/panel-job.lock" true
      assert_success
    done
  done
  # A reboot after a stop at counted: a fresh runtime folder, the first
  # entry null and its group gone. A second try runs and builds.
  rm -f "$T/current" "$T/builds" "$S/client-auto.json" "$T"/at-*
  echo counted >"$T/stop-at"
  run cmd_ui_job auto-r1 build-client --auto
  auto_file "$T/at-counted"
  kill -TERM -- "-$(<"$T/units/auto-r1")"
  auto_wait auto-r1
  rm -f "$T/stop-at"
  rm -rf "$RUN"
  mkdir -m 700 "$RUN"
  auto_run auto-r2
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-r1",null],["auto-r2","ok"]]'
  assert_equal "$(builds)" 1
  # Two stops end the tries: a third worker builds nothing.
  rm -f "$T/current" "$T/builds" "$S/client-auto.json"
  for i in 1 2; do
    rm -f "$T/at-counted"
    echo counted >"$T/stop-at"
    run cmd_ui_job "auto-s$i" build-client --auto
    auto_file "$T/at-counted"
    kill -TERM -- "-$(<"$T/units/auto-s$i")"
    auto_wait "auto-s$i"
  done
  rm -f "$T/stop-at"
  auto_run auto-s3
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-s1",null],["auto-s2",null]]'
  assert_equal "$(builds)" 0
  # A stop while the build runs, not at a seam.
  rm -f "$T/current" "$T/builds" "$S/client-auto.json"
  touch "$T/slow"
  run cmd_ui_job auto-b1 build-client --auto
  auto_file "$T/building"
  kill -TERM -- "-$(<"$T/units/auto-b1")"
  for ((i = 0; i < 20; i++)); do
    kill -0 -- "-$(<"$T/units/auto-b1")" 2>/dev/null || break
    sleep 0.1
  done
  ((i < 20)) || fail "the worker outlived SIGTERM in its build by 2 s"
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-b1",null]]'
}

@test "auto worker: a stop while a command fails is a stop, not a failure" {
  local case
  # mv and sync block, then fail at the stop: without the TERM trap, the
  # failed command would read as an error and write "failed".
  shim mv 'if [[ -e $T/mv-block && ${!#} == */panel-result-client.json ]]; then rm "$T/mv-block"; touch "$T/at-mv"; exec sleep 30; fi
exec /usr/bin/mv "$@"'
  shim sync 'if [[ -e $T/sync-block && -e $T/current && ${!#} == */client-auto.json.* ]]; then rm "$T/sync-block"; touch "$T/at-sync"; exec sleep 30; fi
exec /usr/bin/sync "$@"'
  export PATH=$T/shims:$PATH
  for case in mv sync; do
    rm -f "$T/current" "$T/builds" "$S/client-auto.json" "$T/at-$case"
    touch "$T/$case-block"
    run cmd_ui_job "auto-$case" build-client --auto
    assert_success
    auto_file "$T/at-$case"
    kill -TERM -- "-$(<"$T/units/auto-$case")"
    auto_wait "auto-$case"
    assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" "[[\"auto-$case\",null]]"
    # mv blocks at the client record, before the build; sync blocks at the
    # ok outcome's write, after it.
    if [[ $case == mv ]]; then assert_equal "$(builds)" 0; else assert_equal "$(builds)" 1; fi
  done
}

@test "auto_units: lists the tokens of running automatic units only" {
  # The real auto_units, with systemctl answering list-units.
  # shellcheck source-path=SCRIPTDIR source=../lib/ui.sh
  source "$REPO/lib/ui.sh"
  systemctl() {
    printf '%s\n' "$@" >"$T/list-args"
    printf '%s\n' \
      'lanai-panel-auto-1-2.service loaded active running Lanai panel operation' \
      'lanai-panel-auto-3-4.service loaded deactivating stop-sigterm Lanai panel operation' \
      'lanai-panel-panel-x.service loaded active running Lanai panel operation' \
      'lanai-panel-auto-x.service.bak loaded active running Lanai panel operation' \
      'lanai-panel-auto-x.socket loaded active listening Lanai panel operation'
  }
  run auto_units
  assert_success
  assert_output $'auto-1-2\nauto-3-4'
  run cat "$T/list-args"
  assert_line -- --user
  assert_line list-units
  assert_line -- --state=activating,active,reloading,deactivating
  assert_line 'lanai-panel-auto-*'
}

@test "auto worker: a failure keeps its outcome after a stop at the end" {
  touch "$T/fails"
  echo recorded >"$T/stop-at"
  run cmd_ui_job auto-a build-client --auto
  auto_file "$T/at-recorded"
  kill -KILL -- "-$(<"$T/units/auto-a")"
  auto_wait auto-a
  assert_equal "$(jq -r 'has("reply")' "$S/panel-result-client.json")" false
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-a","failed"]]'
}

@test "auto worker: a cut-off try that installed the client leaves it current" {
  echo built >"$T/stop-at"
  run cmd_ui_job auto-a build-client --auto
  auto_file "$T/at-built"
  kill -KILL -- "-$(<"$T/units/auto-a")"
  auto_wait auto-a
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-a",null]]'
  build_patches_current
  rm -f "$T/stop-at"
  auto_run auto-b
  assert_equal "$(<"$T/rc-auto-b")" 0
  assert_equal "$(builds)" 1
  assert_equal "$(jq -r '.tries | length' "$S/client-auto.json")" 1
}

@test "auto worker: a changed patch set gets new tries" {
  record older '[{"token":"auto-old","at":1,"outcome":"failed"}]'
  auto_run auto-a
  assert_equal "$(jq -r .patches "$S/client-auto.json")" "$(patches_id)"
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-a","ok"]]'
  assert_equal "$(builds)" 1
}

@test "auto worker: a record file with two JSON values counts as empty" {
  record "$(patches_id)" '[{"token":"auto-old","at":1,"outcome":"failed"}]'
  cat "$S/client-auto.json" "$S/client-auto.json" >"$T/two"
  mv "$T/two" "$S/client-auto.json"
  auto_run auto-a
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-a","ok"]]'
  assert_equal "$(builds)" 1
}

@test "auto worker: builds Lanai did not start leave the record alone" {
  local sum
  record "$(patches_id)" '[{"token":"auto-old","at":1,"outcome":null}]'
  sum=$(sha256sum <"$S/client-auto.json")
  touch "$T/lanai-mode"
  run cmd_ui_job_worker t build-client
  assert_success
  assert_equal "$(jq -r .reply.ok "$S/panel-result-client.json")" true
  run cmd_build_client
  assert_success
  # A hand launch that systemd-run refuses.
  echo fail >"$T/run-mode"
  run cmd_ui_job panel-h build-client
  assert_failure 1
  assert_equal "$(sha256sum <"$S/client-auto.json")" "$sum"
}

@test "auto worker: an error after the outcome keeps the outcome" {
  echo recorded >"$T/false-at"
  auto_run auto-a
  [[ $(<"$T/rc-auto-a") != 0 ]] || fail "the error exited 0"
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-a","ok"]]'
}

@test "auto worker: a try entry that is not an object counts as an empty record" {
  record "$(patches_id)" '["x","y"]'
  auto_run auto-a
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-a","ok"]]'
}

@test "auto worker: removes a temporary record file a stop left" {
  : >"$S/client-auto.json.Ab12Cd"
  auto_run auto-a
  assert [ ! -e "$S/client-auto.json.Ab12Cd" ]
}

@test "auto_record_write: the folder is synced after the move" {
  shim sync 'echo "sync $*" >>"$T/order"; exec /usr/bin/sync "$@"'
  shim mv 'echo "mv $*" >>"$T/order"; exec /usr/bin/mv "$@"'
  export PATH=$T/shims:$PATH
  auto_record_write '{"patches":"p","tries":[]}'
  run cat "$T/order"
  assert_line --index 0 --regexp "^sync -- $S/client-auto.json\..{6}$"
  assert_line --index 1 --regexp "^mv -f -- $S/client-auto.json\..{6} $S/client-auto.json$"
  assert_line --index 2 "sync -- $S"
}

@test "auto worker: two launches at once record one try" {
  touch "$T/slow"
  run cmd_ui_job auto-a build-client --auto
  assert_success
  run cmd_ui_job auto-b build-client --auto
  assert_success
  auto_wait auto-a
  auto_wait auto-b
  assert_equal "$(builds)" 1
  assert_equal "$(jq -r '.tries | length' "$S/client-auto.json")" 1
  assert_equal "$(jq -r '.tries[0].outcome' "$S/client-auto.json")" ok
  assert_equal "$(<"$T/rc-auto-a")" 0
  assert_equal "$(<"$T/rc-auto-b")" 0
  run jq -r .token "$S/panel-result-client.json"
  assert_output --regexp '^auto-[ab]$'
  assert_equal "$(jq -r .reply.ok "$S/panel-result-client.json")" true
}

# --- Phase C: the view ---

W_WAIT='When the current job ends, Lanai updates the Windows window. Updating changes nothing in Windows.'
W_RUN='Lanai is updating the Windows window. This can take several minutes and changes nothing in Windows. You can start and use Windows during the update.'
W_REOPEN='The Windows window is updated. To use the update, close the Windows window and open it again.'
RESIZE_NEW='After the computer wakes from sleep, the mouse may reach only part of Windows. Windows may also start at, or change to, the wrong size. To fix both, click Update the Windows window in More actions. Updating changes nothing in Windows.'
AUTO_FAILED='Lanai could not update the Windows window by itself. The Windows window build log (build-client.log) or the Jobs log says why.'
AUTO_LAUNCH='Lanai could not start its update of the Windows window. The Jobs log says why.'
AUTO_GAVE_UP='Lanai could not start its update of the Windows window.'
AUTO_STOPPED="Lanai's update of the Windows window stopped twice before it finished, for example when you logged out or restarted the computer."

# The view's tests list the automatic units from $T/units-list.
view_setup() { auto_units() { cat "$T/units-list" 2>/dev/null || true; }; }

# Print field <filter> of the last view.
view() { jq -r "$1" <<<"$output"; }

# Every text a person reads in the view, except hidden buttons' labels.
view_words() { jq -r '[.warning, .busy.line, .cause, .next, .headline, (.result | .[]), (.setup.lines[]?)] | join("\n")' <<<"$output"; }

# Hold lock <name> in the background: hold <name> [exclusive|shared].
hold() {
  local mode=()
  [[ ${2:-exclusive} == exclusive ]] || mode=(-s)
  rm -f "$T/held-$1"
  flock "${mode[@]}" "$S/$1" bash -c 'touch "$1"; exec sleep 30' _ "$T/held-$1" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/held-$1"
}

# Let Windows read as running, with no window open, while $T/st says active.
running_facts() {
  declare -F real_status_facts >/dev/null ||
    eval "$(declare -f status_facts | sed '1s/status_facts/real_status_facts/')"
  status_facts() {
    if [[ $(<"$T/st") == active ]]; then printf 'ActiveState=active\nLanaiSetup=done\nLanaiQmp=running\nLanaiQga=open\n'
    else real_status_facts "$@"; fi
  }
}

# A command-line snapshot: the operation lock held, its progress written.
cli_snapshot() {
  rm -f "$T/held-cli"
  flock "$S/lock" bash -c 'jq -nc --argjson p "$$" '\''{operation:"snapshot",phase:"cloning",done:0,total:0,pid:$p}'\'' >"$2"
touch "$1"; exec sleep 30' _ "$T/held-cli" "$S/image-progress.json" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/held-cli"
}

@test "view: an old client asks for an update, with Windows stopped and running" {
  local st
  view_setup
  running_facts
  for st in inactive active; do
    echo "$st" >"$T/st"
    run cmd_panel
    assert_success
    assert_equal "$(view .state)" "$([[ $st == active ]] && echo running || echo stopped)"
    assert_equal "$(view .auto_update.launch)" true
    assert_equal "$(view .auto_update.key)" "$(patches_id):0"
    assert_equal "$(view .warning)" "$W_RUN"
    assert_equal "$(view .bar.mode)" busy
    assert_equal "$(view .busy.line)" ''
    assert_equal "$(view .result.client)" ''
    assert_equal "$(view .buttons.update_client.show)" false
    run view_words
    refute_output --partial 'Update the Windows window'
    refute_output --partial 'when it finishes'
  done
}

@test "view: no ask in each case of requirement 2" {
  local case
  view_setup
  for case in signin old-task unfinished no-stamp behind current over session; do
    state "$CURRENT"
    rm -f "$T/current" "$T/no-stamp" "$T/behind" "$T/session" "$S/client-auto.json"
    case $case in
      signin) state '{"done":true,"scale_task":2}' ;;
      old-task) state '{"done":true}' ;;
      unfinished) state '{"snapshot":"declined"}' ;;
      no-stamp) touch "$T/no-stamp" ;;
      behind) echo B7-801-g1a2b3c4d5e >"$T/behind" ;;
      current) touch "$T/current" ;;
      over) record "$(patches_id)" '[{"token":"auto-old","at":1,"outcome":"failed"}]' ;;
      session) echo inactive >"$T/session" ;;
    esac
    run cmd_panel
    assert_success
    assert_equal "$(view .auto_update.launch)" false
    case $case in
      signin | old-task)
        run view .warning
        assert_output --partial 'Run setup again'
        ;;
    esac
  done
}

@test "view: a job, a client build or a command-line snapshot makes it wait" {
  view_setup
  panel_result_write snapshots '{"token":"t","command":"snapshot","args":[],"started":5}'
  hold panel-job.lock
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view .warning)" "$W_WAIT"
  run view_words
  refute_output --partial 'Update the Windows window'
  stop_bg
  rm "$S/panel-result-snapshots.json"
  hold build.lock
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view .warning)" "$W_WAIT"
  stop_bg
  cli_snapshot
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view .warning)" "$W_WAIT"
  assert_equal "$(view .progress.operation)" snapshot
  stop_bg
  run cmd_panel --pending panel-x "$EPOCHSECONDS"
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view .warning)" "$W_WAIT"
  # The hold ends: the view asks.
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" true
  assert_equal "$(view .warning)" "$W_RUN"
}

@test "view: a launch in flight is not launched again" {
  view_setup
  echo auto-x >"$T/units-list"
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .bar.mode)" busy
  # Its unit ended before it counted a try: ask again, with the same key.
  : >"$T/units-list"
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" true
  assert_equal "$(view .auto_update.key)" "$(patches_id):0"
  assert_equal "$(view .bar.mode)" busy
}

@test "view: a running update shows busy, W_RUN, and Start and Open" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-r","at":1,"outcome":null}]'
  echo auto-r >"$T/units-list"
  panel_result_write client '{"token":"auto-r","command":"build-client","args":["--auto"],"invocation":"inv","started":2}'
  hold panel-job.lock
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .bar.mode)" busy
  assert_equal "$(view .busy.line)" ''
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view '.buttons.start.show and .buttons.start.enable')" true
  assert_equal "$(view .right_click)" start
  assert_equal "$(view .buttons.update_client.show)" false
  # Windows running, with no window open.
  running_facts
  echo active >"$T/st"
  run cmd_panel
  assert_equal "$(view .state)" running
  assert_equal "$(view '.buttons.open.show and .buttons.open.enable')" true
  assert_equal "$(view .right_click)" open
  # With a command-line snapshot's progress too: both show.
  cli_snapshot
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .progress.operation)" snapshot
  stop_bg
  # The launching check: nothing held, no entry.
  echo inactive >"$T/st"
  rm "$S/client-auto.json" "$S/panel-result-client.json"
  : >"$T/units-list"
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .bar.mode)" busy
  assert_equal "$(view '.buttons.start.show and .buttons.start.enable')" true
  assert_equal "$(view .right_click)" start
  # A hand update after the tries end.
  record "$(patches_id)" '[{"token":"auto-old","at":1,"outcome":"failed"}]'
  panel_result_write client '{"token":"panel-h","command":"build-client","args":[],"invocation":"inv","started":2}'
  hold panel-job.lock
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view '.buttons.start.show and .buttons.start.enable')" true
  assert_equal "$(view .right_click)" start
  assert_equal "$(view '[.buttons.update_client.show, .buttons.update_client.enable] | tostring')" '[true,false]'
}

@test "view: a worker that decides counts as launching" {
  view_setup
  hold panel-job.lock
  hold build.lock
  echo auto-new >"$T/units-list"
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .busy.line)" ''
  assert_equal "$(view '.buttons.start.show and .buttons.start.enable')" true
  # The start of a second try: the first try's client record is stale.
  record "$(patches_id)" '[{"token":"auto-old","at":1,"outcome":null}]'
  panel_result_write client '{"token":"auto-old","command":"build-client","args":["--auto"],"invocation":"inv","started":2}'
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .busy.line)" ''
  assert_equal "$(view '.buttons.start.show and .buttons.start.enable')" true
  # The same locks with no automatic unit: a hold.
  : >"$T/units-list"
  run cmd_panel
  assert_equal "$(view .warning)" "$W_WAIT"
}

@test "view: a terminal build after the tries end counts as an update by hand" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-old","at":1,"outcome":"failed"}]'
  panel_result_write client '{"token":"auto-old","command":"build-client","args":["--auto"],"invocation":"inv","started":1.5,"ended":3,"reply":{"ok":false}}'
  hold build.lock
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .bar.mode)" busy
  assert_equal "$(view .busy.line)" ''
  assert_equal "$(view .result.client)" ''
  # With an automatic unit in flight, the build lock may be that worker's:
  # not an update by hand.
  echo auto-new >"$T/units-list"
  run cmd_panel
  assert_equal "$(view .warning)" "$RESIZE_NEW"
  # The build ends between the records' probe and the units' read: not an
  # update by hand.
  stop_bg
  : >"$T/units-list"
  touch "$T/probe-once"
  lock_held() {
    [[ $1 == */build.lock && -e $T/probe-once ]] || return 1
    rm "$T/probe-once"
  }
  run cmd_panel
  assert_equal "$(view .warning)" "$RESIZE_NEW"
}

@test "view: a terminal build is a hold while tries are left, and nothing outside the update case" {
  view_setup
  hold build.lock
  run cmd_panel
  assert_equal "$(view .warning)" "$W_WAIT"
  # A quick-path lanai build-client on a current client, or a command-line
  # setup at step 4.
  touch "$T/current"
  run cmd_panel
  assert_equal "$(view .warning)" ''
  [[ $(view .bar.mode) != busy ]] || fail "a quick-path build shows busy"
  rm "$T/current"
  state '{"snapshot":"declined"}'
  run cmd_panel
  [[ $(view .bar.mode) != busy ]] || fail "a command-line setup's build shows busy"
  run view_words
  refute_output --partial "$W_RUN"
  refute_output --partial "$W_WAIT"
}

@test "view: a successful second try never shows stopped" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":null}]'
  # The try ends right after the view lists its unit.
  auto_units() {
    echo auto-a
    record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":"ok"}]'
    touch "$T/current"
  }
  run cmd_panel
  assert_equal "$(view .layout)" daily
  [[ $(view .bar.mode) != failed ]] || fail "the view shows a failure"
  assert_equal "$(view .result.client)" ''
  run view_words
  refute_output --partial 'Windows window'
  # An ok last try while the client is still old, with the tries over: the
  # failed kind.
  view_setup
  rm "$T/current"
  record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":null},{"token":"auto-b","at":2,"outcome":"ok"}]'
  run cmd_panel
  assert_equal "$(view .result.client)" "$AUTO_FAILED"
}

@test "view: another job's lock never makes a dead try look running" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":null}]'
  panel_result_write snapshots '{"token":"t","command":"snapshot","args":[],"started":5}'
  hold panel-job.lock
  run cmd_panel
  assert_equal "$(view .auto_update.key)" "$(patches_id):1"
  assert_equal "$(view .warning)" "$W_WAIT"
  # Another automatic unit runs (a second bar item's worker waiting): the
  # dead try still reads as a stop, since liveness is per token.
  echo auto-new >"$T/units-list"
  run cmd_panel
  assert_equal "$(view .auto_update.key)" "$(patches_id):1"
  assert_equal "$(view .warning)" "$W_WAIT"
}

@test "view: a stop with a try left shows no failure and asks again" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":null}]'
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" true
  assert_equal "$(view .auto_update.key)" "$(patches_id):1"
  assert_equal "$(view .warning)" "$W_RUN"
  assert_equal "$(view .result.client)" ''
  assert_equal "$(view .bar.mode)" busy
  assert_equal "$(view .layout)" daily
}

# Check the failed state after the tries end, with words <words>.
assert_auto_failed() {
  run cmd_panel
  assert_success
  assert_equal "$(view .bar.mode)" failed
  assert_equal "$(view .layout)" failed
  assert_equal "$(view .result.client)" "$1"
  assert_equal "$(view .warning)" "$RESIZE_NEW"
  assert_equal "$(view '[.buttons.update_client.show, .buttons.update_client.enable] | tostring')" '[true,true]'
  assert_equal "$(view .auto_update.launch)" false
}

@test "view: after the tries end, every bar item fails until a hand update or a current client" {
  local tries words
  view_setup
  running_facts
  for tries in '[{"token":"auto-a","at":1,"outcome":"failed"}]' \
    '[{"token":"auto-a","at":1,"outcome":"launch"}]' \
    '[{"token":"auto-a","at":1,"outcome":null},{"token":"auto-b","at":2,"outcome":null}]'; do
    case $tries in
      *failed*) words=$AUTO_FAILED ;;
      *launch*) words=$AUTO_LAUNCH ;;
      *) words=$AUTO_STOPPED ;;
    esac
    echo inactive >"$T/st"
    echo inv >"$T/inv"
    record "$(patches_id)" "$tries"
    panel_result_write client '{"token":"auto-a","command":"build-client","args":["--auto"],"invocation":"inv","started":1.5,"ended":3,"reply":{"ok":false}}'
    assert_auto_failed "$words"
    # A reload, Windows started, a reboot, and no client record.
    assert_auto_failed "$words"
    echo active >"$T/st"
    echo inv2 >"$T/inv"
    assert_auto_failed "$words"
    assert_equal "$(view .state)" running
    rm -rf "$RUN"
    mkdir -m 700 "$RUN"
    assert_auto_failed "$words"
    rm "$S/panel-result-client.json"
    assert_auto_failed "$words"
  done
  # A hand update started after the last try, running: no failure.
  echo inactive >"$T/st"
  panel_result_write client '{"token":"panel-h","command":"build-client","args":[],"invocation":"inv2","started":5}'
  hold panel-job.lock
  run cmd_panel
  [[ $(view .bar.mode) != failed ]] || fail "a hand update still shows the failure"
  assert_equal "$(view .warning)" "$W_RUN"
  stop_bg
  # The same record failed: today's hand words.
  panel_result_write client '{"token":"panel-h","command":"build-client","args":[],"invocation":"inv2","started":5,"ended":6,"reply":{"ok":false}}'
  run cmd_panel
  assert_equal "$(view .result.client)" 'The Windows window could not be updated. Check the Windows window build log (build-client.log), then try again.'
  # A hand record from before the tries does not end the failure state.
  panel_result_write client '{"token":"panel-h","command":"build-client","args":[],"invocation":"inv2","started":0.5,"ended":0.7,"reply":{"ok":false}}'
  assert_auto_failed "$AUTO_STOPPED"
  # A current client ends it.
  touch "$T/current"
  run cmd_panel
  [[ $(view .bar.mode) != failed ]] || fail "a current client still shows the failure"
  assert_equal "$(view .buttons.update_client.show)" false
  assert_equal "$(view .result.client)" ''
  assert_equal "$(view .warning)" ''
}

@test "view: a worker that fails before it counts a try ends the tries until a reboot" {
  view_setup
  # A full disk: the worker cannot count its try, and exits with an error.
  touch "$T/write-fails"
  auto_run auto-a
  [[ $(<"$T/rc-auto-a") != 0 ]] || fail "the worker exited 0"
  assert [ ! -e "$S/client-auto.json" ]
  assert_equal "$(builds)" 0
  rm "$T/write-fails"
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view .result.client)" "$AUTO_GAVE_UP"
  assert_equal "$(view .warning)" "$RESIZE_NEW"
  assert_equal "$(view '[.buttons.update_client.show, .buttons.update_client.enable] | tostring')" '[true,true]'
  # Nothing stays busy: snapshots and Run setup again are available.
  assert_equal "$(view .busy.active)" false
  assert_equal "$(view .buttons.take_snapshot.enable)" true
  assert_equal "$(view .bar.mode)" failed
  # A hand update after it ends the failure state.
  panel_result_write client "$(jq -nc --argjson s "$(ui_timestamp)" '{token:"panel-h",command:"build-client",args:[],invocation:"inv",started:$s}')"
  hold panel-job.lock
  run cmd_panel
  assert_equal "$(view .warning)" "$W_RUN"
  [[ $(view .bar.mode) != failed ]] || fail "a hand update still shows the failure"
  stop_bg
  # The same hand update failed: its own words, not the gave-up words.
  jq -c '. + {ended:(.started + 1),reply:{ok:false}}' "$S/panel-result-client.json" >"$T/hand"
  panel_result_write client "$(<"$T/hand")"
  run cmd_panel
  assert_equal "$(view .result.client)" "The Windows window could not be updated. Check the Windows window build log (build-client.log), then try again."
  rm "$S/panel-result-client.json"
  # A changed patch set asks again.
  printf '1 older\n' >"$RUN/client-auto-gave-up"
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" true
  # A reboot empties the runtime folder.
  printf '1 %s\n' "$(patches_id)" >"$RUN/client-auto-gave-up"
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  rm -rf "$RUN"
  mkdir -m 700 "$RUN"
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" true
}

@test "view: a worker that cannot read the patches gives up, and the view stops asking" {
  view_setup
  mkdir "$T/patches"
  cp "$LANAI_PATCHES"/* "$T/patches/"
  export LANAI_PATCHES=$T/patches
  chmod 000 "$(find "$T/patches" -name '*.patch' -print -quit)"
  auto_run auto-a
  [[ $(<"$T/rc-auto-a") != 0 ]] || fail "the worker exited 0"
  assert [ -e "$RUN/client-auto-gave-up" ]
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  assert_equal "$(view .result.client)" "$AUTO_GAVE_UP"
  assert_equal "$(view '[.buttons.update_client.show, .buttons.update_client.enable] | tostring')" '[true,true]'
}

@test "auto worker: a stop by a signal before the count marks nothing" {
  # The worker waits for a client build, sleeping between its checks.
  hold build.lock
  run cmd_ui_job auto-a build-client --auto
  assert_success
  auto_file "$T/waiting"
  kill -TERM -- "-$(<"$T/units/auto-a")"
  auto_wait auto-a
  assert [ ! -e "$RUN/client-auto-gave-up" ]
  assert [ ! -e "$S/client-auto.json" ]
}

@test "view: a failed try stopped at its end shows failed, not stopped" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":"failed"}]'
  panel_result_write client '{"token":"auto-a","command":"build-client","args":["--auto"],"invocation":"inv","started":2}'
  run cmd_panel
  assert_equal "$(view .result.client)" "$AUTO_FAILED"
}

@test "view: the button starts an update by hand after the tries end" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":"failed"}]'
  run cmd_panel
  assert_equal "$(view .buttons.update_client.enable)" true
}

@test "view: a cut-off try that installed the client shows neither failure nor button" {
  view_setup
  record "$(patches_id)" '[{"token":"auto-a","at":1,"outcome":null}]'
  touch "$T/current"
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" false
  [[ $(view .bar.mode) != failed ]] || fail "the view shows a failure"
  assert_equal "$(view .buttons.update_client.show)" false
  assert_equal "$(view .result.client)" ''
}

@test "view: a changed patch set asks again" {
  view_setup
  record older '[{"token":"auto-a","at":1,"outcome":"failed"}]'
  run cmd_panel
  assert_equal "$(view .auto_update.launch)" true
  assert_equal "$(view .auto_update.key)" "$(patches_id):0"
  [[ $(view .bar.mode) != failed ]] || fail "the view shows a failure"
}

@test "view: two bar items' launches show no failure" {
  touch "$T/slow"
  run cmd_ui_job auto-a build-client --auto
  run cmd_ui_job auto-b build-client --auto
  auto_wait auto-a
  auto_wait auto-b
  view_setup
  run cmd_panel
  assert_success
  [[ $(view .bar.mode) != failed ]] || fail "the view shows a failure"
  assert_equal "$(view .result.client)" ''
  assert_equal "$(view .result.launch)" ''
}

@test "view: close and reopen only for a window older than the install" {
  local id bin args
  view_setup
  # The real client checks, on an installed client with current stamps.
  # shellcheck source-path=SCRIPTDIR source=../lib/client.sh
  source "$REPO/lib/client.sh"
  fake_build "$LG_BUILD"
  write_client_stamps
  bin=$(client_builds)/$LG_BUILD/bin/looking-glass-client
  id=$(stat -c %d:%i "$bin")
  echo active >"$T/st"
  client_active() { return 0; }
  client_main_pid() { echo 4242; }
  client_exe() { echo "0:1 /old/lanai/looking-glass/B7/bin/looking-glass-client"; }
  run cmd_panel
  assert_equal "$(view .warning)" "$W_REOPEN"
  [[ $(view .bar.mode) != failed && $(view .bar.mode) != busy ]] || fail "the reopen words change the bar"
  assert_equal "$(view .auto_update.launch)" false
  client_exe() { echo "$id $bin"; }
  run cmd_panel
  assert_equal "$(view .warning)" ''
  client_exe() { echo "$id $bin (deleted)"; }
  run cmd_panel
  assert_equal "$(view .warning)" "$W_REOPEN"
  # A window that is still opening runs lanai-client-exec, a bash script.
  client_exe() { echo "0:1 /usr/bin/bash"; }
  run cmd_panel
  assert_equal "$(view .warning)" ''
  client_exe() { echo "0:1 /old/bin/looking-glass-client"; }
  client_active() { return 1; }
  run cmd_panel
  assert_equal "$(view .warning)" ''
  client_active() { return 0; }
  echo inactive >"$T/st"
  run cmd_panel
  assert_equal "$(view .warning)" ''
  # The plan unfinished for another reason, and the patches not current.
  echo active >"$T/st"
  state '{"snapshot":"declined"}'
  echo stale >"$(client_builds)/$LG_BUILD/build-patches"
  run cmd_panel
  [[ $(view .warning) != *"$W_REOPEN"* ]] || fail "an unfinished plan shows the reopen words"
  state "$CURRENT"
  write_client_stamps
  # A successful update with no window shows nothing.
  client_active() { return 1; }
  for args in '[]' '["--auto"]'; do
    panel_result_write client "$(jq -nc --argjson a "$args" '{token:"t",command:"build-client",args:$a,invocation:"inv",started:1,ended:2,reply:{ok:true}}')"
    run cmd_panel
    assert_equal "$(view .warning)" ''
    assert_equal "$(view .result.client)" ''
  done
}
