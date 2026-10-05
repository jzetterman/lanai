#!/usr/bin/env bats
# Tests for Lanai's lifecycle commands (plan phase 4): status_map and lanai
# status, preflight, lanai start with its dry run, runtime copy and unit,
# lanai stop and lanai force-stop. systemctl, hyprctl and ip are PATH shims;
# nothing talks to the real user manager, and the unit lands in the test's
# own ~/.config/systemd/user. QMP is the fake server in test/fixtures.
# shellcheck disable=SC2030,SC2031,SC2016,SC2034

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  RUN=$XDG_RUNTIME_DIR/lanai
  S=$XDG_STATE_HOME/lanai
  export T
  # systemctl: log every call; `show` prints $T/unit-show (default: an
  # inactive unit), or with --value the one property asked for; with
  # $T/no-manager, `show` fails like an unreachable user manager. Other
  # verbs fail when the verb is the one named in $T/systemctl-fail. `kill`
  # also logs whether the forced marker existed at that moment.
  shim systemctl 'echo "$*" >>"$T/systemctl.calls"
show=$(cat "$T/unit-show" 2>/dev/null || printf "ActiveState=inactive\nSubState=dead\nResult=success\nInvocationID=\n")
if [[ " $* " == *" show "* ]]; then
  [[ ! -e $T/no-manager ]] || exit 1
  if [[ " $* " == *" --value "* ]]; then
    for a; do [[ $prev == -p ]] && sed -n "s/^$a=//p" <<<"$show"; prev=$a; done
  else
    printf "%s\n" "$show"
  fi
  exit 0
fi
if [[ $2 == kill && -e $XDG_STATE_HOME/lanai/forced ]]; then echo forced-present >>"$T/systemctl.calls"; fi
[[ ! -f $T/systemctl-fail || $2 != "$(<"$T/systemctl-fail")" ]]'
  shim hyprctl 'echo "[{\"focused\": false, \"scale\": 1}, {\"focused\": true, \"scale\": 1.5}]"'
  echo '[{"dst":"default","gateway":"192.168.1.1","dev":"wlan0","flags":[]}]' >"$T/route.json"
  shim ip 'cat "$T/route.json"'
  export PATH=$T/shims:$PATH
}

teardown() {
  stop_bg
}

# Write the unit's `systemctl show` output: unit_show <ActiveState> [Key=Value...].
unit_show() {
  local active=$1
  shift
  printf '%s\n' "ActiveState=$active" "SubState=running" "Result=success" \
    "InvocationID=0123456789abcdef0123456789abcdef" "ExecMainStatus=0" "$@" >"$T/unit-show"
}

# A finished install at the default location, VM settings, a share, and
# finished setup and a snapshot decision for that location.
ready() {
  make_install "$HOME/.windows"
  mkdir -p "$HOME/Windows" "$S" "$XDG_CONFIG_HOME/lanai"
  echo '{"memory_gib": 8, "cores": 4}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  jq -n -c --arg l "$(realpath "$HOME/.windows")" '{location: $l, snapshot: "declined", done: true}' >"$S/setup.json"
}

# Assert that the unit was never started.
refute_started() {
  ! grep -q '^--user start' "$T/systemctl.calls" 2>/dev/null || fail "the unit was started"
}

# --- status_map: systemd's view plus Lanai's facts -> one state (spec 10) ---

# Run status_map on the fixture show output plus the given fact lines, and
# keep its JSON for field.
map() {
  run status_map < <(cat "$T/unit-show"; printf '%s\n' "$@")
  JSON=$output
}

@test "status_map: an inactive unit with a finished setup is stopped" {
  unit_show inactive
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none
  assert_success
  assert_equal "$(field state)" stopped
  assert_equal "$(field message)" "Windows is stopped."
  assert_equal "$(field next)" "start Windows"
  assert_equal "$(field notice)" null
}

@test "status_map: a forced stop last time is named, with its likely causes" {
  unit_show inactive
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiLastRun=forced
  assert_equal "$(field state)" stopped
  run field notice
  assert_output --partial "force-stopped"
  assert_output --partial "a locked Windows"
  assert_output --partial "an open Windows security screen"
  assert_output --partial "did not finish in time"
}

@test "status_map: a clean last run shows no notice" {
  unit_show inactive
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiLastRun=clean
  assert_equal "$(field notice)" null
}

@test "status_map: no install, setup needed, and the container, each with a cause and next step" {
  unit_show inactive
  map LanaiInstall=none LanaiSetup=needed LanaiContainer=none
  assert_equal "$(field state)" not-installed
  assert_equal "$(field next)" "install Windows with omarchy-windows-vm, then run Lanai setup"

  map LanaiInstall=present LanaiSetup=needed LanaiContainer=none
  assert_equal "$(field state)" setup-needed
  assert_equal "$(field next)" "open the Lanai panel and run setup"

  # The container wins over every other stopped state.
  map LanaiInstall=present LanaiSetup=needed LanaiContainer=running
  assert_equal "$(field state)" in-use
  run field message
  assert_output --partial "omarchy-windows-vm"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=running
  assert_equal "$(field next)" "stop it with omarchy-windows-vm stop, then start Windows here"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=preparing
  assert_equal "$(field state)" in-use
  run field message
  assert_output --partial "preparing"
}

@test "status_map: an active unit is starting until QMP reports running and the agent's port opens" {
  unit_show active
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=none
  assert_equal "$(field state)" starting
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=prelaunch
  assert_equal "$(field state)" starting
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=closed
  assert_equal "$(field state)" starting
  assert_equal "$(field next)" "wait for Windows to start"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open
  assert_equal "$(field state)" running
  assert_equal "$(field next)" "open the Windows window"
  assert_equal "$(field warning)" null
  unit_show activating
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none
  assert_equal "$(field state)" starting
}

@test "status_map: before setup is done, a booted VM is setup needed, even with an agent port open" {
  unit_show active
  local qga
  # dockur installs its own guest agent, so the port can be open already.
  for qga in closed open; do
    map LanaiInstall=present LanaiSetup=needed LanaiContainer=none LanaiQmp=running "LanaiQga=$qga"
    assert_equal "$(field state)" setup-needed
    run field message
    assert_output --partial "Windows is running"
  done
}

@test "status_map: a dead helper is a warning on the running state, naming what is lost" {
  unit_show active
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiHelpersMissing=sleep-watch,virtiofsd
  assert_equal "$(field state)" running
  run field warning
  assert_output --partial "clock sync after suspend is off"
  assert_output --partial "file sharing through ~/Windows is off"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiHelpersMissing=shutdown-watch
  assert_equal "$(field next)" "shut Windows down and start it again"
}

@test "status_map: a stop request is stopping, and after 2 minutes offers the forced stop" {
  unit_show active
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open LanaiStopAge=30
  assert_equal "$(field state)" stopping
  assert_equal "$(field force_stop)" false
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open LanaiStopAge=120
  assert_equal "$(field state)" stopping
  assert_equal "$(field force_stop)" true
  run field next
  assert_output "wait, or use Force stop below"
  unit_show deactivating
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none
  assert_equal "$(field state)" stopping
}

@test "status_map: a failed unit is failed, with the logs and the omarchy-windows-vm fallback" {
  unit_show failed "Result=exit-code" "ExecMainStatus=1"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none
  assert_equal "$(field state)" failed
  run field message
  assert_output --partial "exit-code"
  run field next
  assert_output --partial "journalctl --user -u lanai-vm"
  assert_output --partial "omarchy-windows-vm"
  assert_equal "$(field logs)" "journalctl --user -u lanai-vm"
  unit_show active
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=guest-panicked
  assert_equal "$(field state)" failed
  run field message
  assert_output --partial "guest-panicked"
}

@test "status_map: after a forced stop or a stop timeout, the failed unit shows as stopped" {
  # The notice comes from last-run only (shown once, then cleared by the
  # panel); a forced stop the next start has not recorded yet is its own
  # field.
  unit_show failed "Result=signal"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiForced=yes
  assert_equal "$(field state)" stopped
  assert_equal "$(field notice)" null
  assert_equal "$(field forced_pending)" true
  # TimeoutStopSec ran out (logout with lingering on): a forced stop.
  unit_show failed "Result=timeout"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none
  assert_equal "$(field state)" stopped
  assert_equal "$(field forced_pending)" true
  # A clean stop has nothing pending.
  unit_show inactive
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none
  assert_equal "$(field forced_pending)" false
}

@test "status_map: a version mismatch (phase 5 input) wins on a running VM" {
  unit_show active
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiVersion=mismatch
  assert_equal "$(field state)" version-mismatch
  run field next
  assert_output --partial "omarchy-windows-vm"
}

@test "status_map: an unreachable user manager is failed, not stopped" {
  printf 'ActiveState=unknown\n' >"$T/unit-show"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none
  assert_equal "$(field state)" failed
}

# --- status_facts ---

@test "status_facts: a helper is missing when its pid is dead, a zombie, or outside the unit" {
  unit_show active
  mkdir -m 700 "$RUN"
  local unit_cg=/user.slice/user-1000.slice/user@1000.service/session.slice/lanai-vm.service
  fake_proc 501 "$unit_cg" bash
  fake_proc 502 "$unit_cg" bash
  fake_proc 503 /user.slice/user-1000.slice/session-2.scope bash
  fake_proc 504 "$unit_cg" bash
  echo '504 (bash) Z 1 504 504 0 -1' >"$T/proc/504/stat"
  echo 501 >"$RUN/virtiofsd.pid"
  echo 502 >"$RUN/shutdown-watch.pid"
  echo 503 >"$RUN/sleep-watch.pid"
  echo 999 >"$RUN/event-log.pid"
  run status_facts
  assert_success
  local missing
  missing=$(sed -n 's/^LanaiHelpersMissing=//p' <<<"$output" | tr ',' '\n' | sort | paste -sd,)
  assert_equal "$missing" "event-log,sleep-watch"
  echo 504 >"$RUN/virtiofsd.pid"
  run status_facts
  missing=$(sed -n 's/^LanaiHelpersMissing=//p' <<<"$output" | tr ',' '\n' | sort | paste -sd,)
  assert_equal "$missing" "event-log,sleep-watch,virtiofsd"
}

@test "status_facts: a stop request counts only for the running invocation" {
  unit_show active
  mkdir -p "$S"
  echo "someoldinvocation $((EPOCHSECONDS - 500))" >"$S/stop-requested"
  run status_facts
  refute_line --partial LanaiStopAge=
  echo "0123456789abcdef0123456789abcdef $((EPOCHSECONDS - 130))" >"$S/stop-requested"
  run status_facts
  assert_line --regexp '^LanaiStopAge=1[23][0-9]$'
}

@test "lanai status: a running VM, read through systemd, /proc and QMP" {
  ready
  unit_show active
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  lanai_run status
  assert_success
  assert_equal "$(field state)" running
  assert_equal "$(field ok)" true
  unit_show inactive
  lanai_run status
  assert_equal "$(field state)" stopped
}

@test "lanai status: no install at the storage location is not installed" {
  ready
  rm -rf "$HOME/.windows"
  lanai_run status
  assert_success
  assert_equal "$(field state)" not-installed
}

@test "lanai status: the guest agent's port closed means starting; a panicked guest is failed" {
  ready
  unit_show active
  conf FAKE_QMP_QGA=false
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  lanai_run status
  assert_equal "$(field state)" starting
  conf FAKE_QMP_STATUS=guest-panicked
  lanai_run status
  assert_equal "$(field state)" failed
  run field message
  assert_output --partial "guest-panicked"
}

# --- preflight and boot_vm's dry run, through every path that starts the unit ---

# Run each entry point that boots the VM: lanai start, and boot_vm true
# (the setup boot of lanai setup-guest and lanai setup, phase 6). Each
# must refuse with a message containing <text> and must not start the unit.
assert_both_refuse() {
  lanai_run start
  assert_failure
  assert_equal "$(field ok)" false
  run field message
  assert_output --partial "$1"
  WAYLAND_DISPLAY=wayland-0 run --separate-stderr boot_vm true
  assert_failure
  JSON=$output
  assert_equal "$(field ok)" false
  run field message
  assert_output --partial "$1"
  refute_started
}

@test "preflight: refuses while Lanai's VM runs, and keeps that run's markers" {
  ready
  unit_show active
  echo live-run >"$S/running"
  assert_both_refuse "already running"
  assert_equal "$(<"$S/running")" live-run
  unit_show deactivating
  assert_both_refuse "still shutting down; try again in a moment"
  assert_equal "$(<"$S/running")" live-run
}

@test "preflight: refuses when the user manager does not answer, and keeps the markers" {
  ready
  : >"$T/no-manager"
  echo live-run >"$S/running"
  assert_both_refuse "cannot reach the systemd user manager"
  assert_equal "$(<"$S/running")" live-run
}

@test "preflight: refuses while a restore is unfinished" {
  ready
  printf '/some/snapshot\n%s\n' "$HOME/.windows" >"$S/restore-in-progress"
  assert_both_refuse "a restore did not finish: run lanai restore again"
}

@test "preflight: refuses on a failed adoption check, and with no install" {
  ready
  rm "$HOME/.windows/windows.boot"
  assert_both_refuse "windows.boot is missing"
  rm -rf "$HOME/.windows"
  assert_both_refuse "No Windows install"
}

@test "preflight: refuses a disk smaller than the container's DISK_SIZE" {
  ready
  mkdir -p "$OMARCHY_WINDOWS_DIR"
  printf 'services:\n  windows:\n    environment:\n      VERSION: "11"\n      DISK_SIZE: "64G"\n' \
    >"$OMARCHY_WINDOWS_DIR/docker-compose.yml"
  assert_both_refuse "smaller than DISK_SIZE"
}

@test "preflight: refuses without a usable ~/Windows share" {
  ready
  rmdir "$HOME/Windows"
  assert_both_refuse "does not exist"
  ln -s /tmp "$HOME/Windows"
  assert_both_refuse "symlink"
}

@test "preflight: refuses while the container VM runs or prepares" {
  ready
  fake_proc 700 "$DOCKER_SCOPE" /usr/bin/qemu-system-x86_64 -name windows
  assert_both_refuse "a Docker VM is running (possibly omarchy-windows-vm)"
  rm -rf "$T/proc/700"
  fake_proc 701 "$DOCKER_SCOPE" /bin/bash /run/entry.sh
  assert_both_refuse "preparing a VM"
}

@test "preflight: refuses while another process holds the disk's lock" {
  ready
  local maj min
  IFS=: read -r maj min <<<"$(mount_dev "$HOME/.windows/data.img")"
  printf '1: OFDLCK ADVISORY  WRITE -1 %02x:%02x:%s 100 101\n' "$maj" "$min" \
    "$(stat -c %i "$HOME/.windows/data.img")" >"$LANAI_LOCKS"
  assert_both_refuse "holds the Windows disk"
  LANAI_LOCKS=$T/no-such-file
  assert_both_refuse "cannot tell"
}

@test "preflight: turns the last run into a verdict even when it refuses" {
  ready
  echo crashed-run >"$S/running"
  echo crashed-run >"$S/started"
  rm "$HOME/.windows/windows.boot"
  lanai_run start
  assert_failure
  assert_equal "$(<"$S/last-run")" forced
  assert [ ! -e "$S/running" ]
}

@test "boot_vm: lanai-vm-exec's own checks refuse here, with their reason, before the unit starts" {
  ready
  echo '{"memory_gib": "8,share=off", "cores": 4}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  assert_both_refuse "memory must be a whole number"
  echo '{"memory_gib": 8, "cores": 4}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  echo 'not-a-mac' >"$HOME/.windows/windows.mac"
  assert_both_refuse "MAC address"
  echo 02:4B:81:73:3C:96 >"$HOME/.windows/windows.mac"
  mkdir -p "$RUN"
  chmod 755 "$RUN"
  assert_both_refuse "0700"
}

@test "boot_vm: another start, snapshot or restore holding the lock refuses" {
  ready
  flock "$S/lock" sleep 30 3>&- &
  BG_PIDS+=("$!")
  local i
  for ((i = 0; i < 50; i++)); do
    flock -n "$S/lock" true || break
    sleep 0.05
  done
  assert_both_refuse "another Lanai start, setup, snapshot or restore is running"
}

# --- lanai start ---

@test "lanai start: refuses while setup is incomplete" {
  ready
  rm "$S/setup.json"
  lanai_run start
  assert_failure
  assert_equal "$(field state)" setup-needed
  echo '{"done": false}' >"$S/setup.json"
  lanai_run start
  assert_failure
  refute_started
}

@test "lanai start: installs the runtime copy and unit, records the scale, starts the unit" {
  ready
  lanai_run start
  assert_success
  assert_equal "$(field state)" starting
  assert_equal "$(field network)" true
  local rt
  rt=$XDG_DATA_HOME/lanai/runtime/$(runtime_revision)
  assert [ -x "$rt/bin/lanai-vm-exec" ]
  assert [ -f "$rt/lib/vm.sh" ]
  assert [ -f "$rt/lib/dockur-6.05.args" ]
  assert [ ! -e "$rt/systemd" ]
  local unit=$XDG_CONFIG_HOME/systemd/user/lanai-vm.service
  run cat "$unit"
  assert_line "ExecStart=$rt/bin/lanai-vm-exec"
  assert_line "ExecStop=$rt/bin/lanai-vm-stop"
  assert_line "Environment=XDG_CONFIG_HOME=$XDG_CONFIG_HOME XDG_STATE_HOME=$XDG_STATE_HOME XDG_DATA_HOME=$XDG_DATA_HOME"
  assert_line "PartOf=graphical-session.target"
  assert_line "Slice=session.slice"
  assert_line "TimeoutStopSec=2min"
  refute_output --partial "[Install]"
  # The focused monitor is at 150%.
  assert_equal "$(jq -c . "$S/boot.json")" '{"scale":150,"setup":false,"window":false}'
  run cat "$T/systemctl.calls"
  assert_line "--user daemon-reload"
  assert_line "--user start lanai-vm.service"
}

@test "lanai start: without a default route Windows starts, and says it has no network" {
  ready
  echo '[]' >"$T/route.json"
  lanai_run start
  assert_success
  assert_equal "$(field network)" false
  run field message
  assert_output --partial "without a network"
}

@test "lanai start: the runtime copy is reused for unchanged content and refreshed for a new version" {
  ready
  lanai_run start
  assert_success
  : >"$T/systemctl.calls"
  lanai_run start
  assert_success
  run grep -c daemon-reload "$T/systemctl.calls"
  assert_output 0
  # A new version: a new copy, the unit points at it, systemd reloads, and
  # the old copy goes.
  : >"$T/systemctl.calls"
  local old_rt new_rt
  old_rt=$XDG_DATA_HOME/lanai/runtime/$(runtime_revision)
  new_rt=$XDG_DATA_HOME/lanai/runtime/$(LANAI_VERSION=9.9.9 runtime_revision)
  LANAI_VERSION=9.9.9 run boot_vm false
  assert_success
  assert [ -d "$new_rt/bin" ]
  assert [ ! -e "$old_rt" ]
  grep -q "^ExecStart=$new_rt/bin/lanai-vm-exec$" \
    "$XDG_CONFIG_HOME/systemd/user/lanai-vm.service" || fail "the unit still points at the old copy"
  run grep -c daemon-reload "$T/systemctl.calls"
  assert_output 1
}

@test "lanai start: a data folder the unit file cannot hold stops the start, with no unit" {
  ready
  local bad
  for bad in "$HOME/my data" "$HOME/100%"; do
    export XDG_DATA_HOME=$bad
    mkdir -p "$bad"
    : >"$T/systemctl.calls"
    lanai_run start
    assert_failure
    assert [ ! -e "$XDG_CONFIG_HOME/systemd/user/lanai-vm.service" ]
    ! grep -qE -- '--user (daemon-reload|start)' "$T/systemctl.calls" || fail "systemd was touched"
  done
}

@test "lanai start: a failed runtime copy stops the start and is repaired next time" {
  ready
  shim cp 'for a; do [[ $a != */bin ]] || exit 1; done; exec /usr/bin/cp "$@"'
  lanai_run start
  assert_failure
  run field message
  assert_output --partial "runtime copy"
  assert [ ! -e "$XDG_DATA_HOME/lanai/runtime/$(runtime_revision)" ]
  refute_started
  rm "$T/shims/cp"
  lanai_run start
  assert_success
  assert [ -x "$XDG_DATA_HOME/lanai/runtime/$(runtime_revision)/bin/lanai-vm-exec" ]
}

@test "lanai start: reports a forced stop from the last run, once" {
  ready
  echo run-1 >"$S/running"
  echo run-1 >"$S/started"
  printf '{"invocation":"run-1","guest":true,"reason":"guest-shutdown"}\n' >"$S/last-shutdown"
  : >"$S/forced"
  lanai_run start
  assert_success
  assert_equal "$(field last_run)" forced
}

@test "lanai start: a failed systemctl start is reported as failed" {
  ready
  echo start >"$T/systemctl-fail"
  lanai_run start
  assert_failure
  assert_equal "$(field state)" failed
  run field next
  assert_output --partial "journalctl --user -u lanai-vm"
}

@test "lanai start: without Hyprland the scale falls back to 100%" {
  ready
  shim hyprctl 'exit 1'
  lanai_run start
  assert_success
  assert_equal "$(jq -r .scale "$S/boot.json")" 100
}

@test "boot_vm true: a snapshot decision allows setup mode before setup is done" {
  ready
  setup_patch '{"done": null}'
  local snapshot
  for snapshot in taken declined; do
    setup_set snapshot "\"$snapshot\""
    WAYLAND_DISPLAY=wayland-0 run boot_vm true
    assert_success
    assert_equal "$(jq -r .setup "$S/boot.json")" true
  done
}

# --- lanai stop and force-stop ---

@test "lanai stop: sends system_powerdown on the CLI socket and records the request" {
  ready
  unit_show active
  export FAKE_QMP_LOG=$T/qmp.log
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  lanai_run stop
  assert_success
  assert_equal "$(field state)" stopping
  grep -q '"execute":"system_powerdown"' "$T/qmp.log" || fail "no system_powerdown"
  local inv at
  read -r inv at <"$S/stop-requested"
  assert_equal "$inv" 0123456789abcdef0123456789abcdef
  ((EPOCHSECONDS - at <= 5)) || fail "request time $at is not now"
  # It never stops the unit through systemd (spec 16).
  ! grep -qE -- '--user (stop|kill)' "$T/systemctl.calls" || fail "used systemctl to stop"
  # A second stop keeps the first request's time, so the 2 minutes run on.
  echo "0123456789abcdef0123456789abcdef 1000" >"$S/stop-requested"
  lanai_run stop
  assert_success
  assert_equal "$(<"$S/stop-requested")" "0123456789abcdef0123456789abcdef 1000"
}

@test "lanai stop: refuses when Windows is not running, is starting, or QMP does not answer" {
  ready
  lanai_run stop
  assert_failure
  run field message
  assert_output --partial "not running"
  unit_show activating
  lanai_run stop
  assert_failure
  unit_show active
  lanai_run stop
  assert_failure
  assert [ ! -e "$S/stop-requested" ]
}

@test "lanai force-stop: refuses without --confirm" {
  ready
  unit_show active
  lanai_run force-stop
  assert_failure
  assert_equal "$(field ok)" false
  run field message
  assert_output --partial "--confirm"
  assert [ ! -e "$S/forced" ]
  ! grep -q -- '--user kill' "$T/systemctl.calls" 2>/dev/null || fail "killed without confirmation"
}

@test "lanai force-stop --confirm: writes the forced marker, then SIGKILLs the unit" {
  ready
  unit_show active
  lanai_run force-stop --confirm
  assert_success
  assert [ -e "$S/forced" ]
  run cat "$T/systemctl.calls"
  assert_line "--user kill --signal=SIGKILL lanai-vm.service"
  # The marker was already there when the kill went out.
  assert_line forced-present
}

@test "lanai force-stop --confirm: does nothing when Windows is not running" {
  ready
  lanai_run force-stop --confirm
  assert_failure
  assert [ ! -e "$S/forced" ]
  ! grep -q -- '--user kill' "$T/systemctl.calls" || fail "killed a stopped unit"
}

@test "lanai force-stop --confirm: a failed kill leaves no forced marker" {
  ready
  unit_show active
  echo kill >"$T/systemctl-fail"
  lanai_run force-stop --confirm
  assert_failure
  assert [ ! -e "$S/forced" ]
}

@test "runtime refresh: code changes replace a legacy copy without a version bump" {
  # Copy only the runtime sources and unit template; never edit the checkout.
  mkdir -p "$T/plugin" "$(data_dir)/runtime/$LANAI_VERSION/bin"
  cp -R "$REPO/bin" "$REPO/lib" "$REPO/systemd" "$T/plugin/"
  LANAI_LIB=$T/plugin/lib
  echo legacy >"$(data_dir)/runtime/$LANAI_VERSION/bin/lanai-vm-helper"
  run runtime_refresh
  assert_success
  local first second
  first=$(runtime_revision)
  assert [ ! -e "$(data_dir)/runtime/$LANAI_VERSION" ]
  printf '\n# updated RESET handler\n' >>"$LANAI_LIB/vm.sh"
  printf '\n# updated start cleanup\n' >>"$T/plugin/bin/lanai-vm-exec"
  second=$(runtime_revision)
  refute [ "$first" = "$second" ]
  : >"$T/systemctl.calls"
  run runtime_refresh
  assert_success
  assert [ ! -e "$(data_dir)/runtime/$first" ]
  cmp "$LANAI_LIB/vm.sh" "$(data_dir)/runtime/$second/lib/vm.sh"
  cmp "$T/plugin/bin/lanai-vm-exec" "$(data_dir)/runtime/$second/bin/lanai-vm-exec"
  run cat "$XDG_CONFIG_HOME/systemd/user/$LANAI_UNIT"
  assert_line "ExecStart=$(data_dir)/runtime/$second/bin/lanai-vm-exec"
  run grep -c daemon-reload "$T/systemctl.calls"
  assert_output 1
}
