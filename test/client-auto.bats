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
# fails (the build), plan-fails, stop-at and false-at (the worker's seams).
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
  for case in signin old-task unfinished no-client pin-change behind current over session; do
    n=$((n + 1))
    state "$CURRENT"
    rm -f "$T/current" "$T/no-stamp" "$T/behind" "$T/session" "$S/client-auto.json"
    case $case in
      signin) state '{"done":true,"scale_task":2}' ;;
      old-task) state '{"done":true}' ;;
      unfinished) state '{"snapshot":"declined"}' ;;
      no-client | pin-change) state '{"snapshot":"declined"}'; touch "$T/no-stamp" ;;
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
  assert [ ! -e "$T/launch" ]
  assert [ ! -e "$S/client-auto.json" ]
  assert_equal "$(builds)" 0
}

@test "auto worker: a hold that falls between two polls is waited out" {
  local hold
  for hold in panel-job build progress; do
    rm -f "$T/current" "$T/builds" "$S/client-auto.json" "$T/held" "$S/image-progress.json"
    case $hold in
      panel-job)
        flock "$S/panel-job.lock" bash -c 'touch "$1"; exec sleep 2' _ "$T/held" 3>&- & ;;
      build)
        flock "$S/build.lock" bash -c 'touch "$1"; exec sleep 2' _ "$T/held" 3>&- & ;;
      progress)
        # A command-line snapshot: the operation lock held, its progress
        # written by the holder.
        flock "$S/lock" bash -c 'jq -nc --argjson p "$$" '\''{operation:"snapshot",phase:"cloning",done:0,total:0,pid:$p}'\'' >"$2"
touch "$1"; exec sleep 2' _ "$T/held" "$S/image-progress.json" 3>&- & ;;
    esac
    BG_PIDS+=("$!")
    wait_for_file "$T/held"
    run cmd_ui_job "auto-$hold" build-client --auto
    assert_success
    sleep 1
    assert [ ! -e "$S/client-auto.json" ]
    assert_equal "$(builds)" 0
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
  # It waits out a read probe of the panel view.
  rm "$S/client-auto.json"
  flock -s "$S/panel-job.lock" bash -c 'touch "$1"; exec sleep 0.5' _ "$T/held" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/held"
  run cmd_ui_job auto-c build-client --auto
  assert_failure 1
  assert_equal "$(jq -c '[.tries[] | [.token, .outcome]]' "$S/client-auto.json")" '[["auto-c","launch"]]'
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
  assert_equal "$(sha256sum <"$S/client-auto.json")" "$sum"
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
