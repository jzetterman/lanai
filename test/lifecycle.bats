#!/usr/bin/env bats
# Tests for Lanai's lifecycle commands (plan phase 4): status_map and lanai
# status, preflight, lanai start with its runtime copy and unit, lanai stop
# and lanai force-stop. systemctl and hyprctl are PATH shims; nothing talks
# to the real user manager, and the unit lands in the test's own
# ~/.config/systemd/user. QMP is the fake server in test/fixtures.
# shellcheck disable=SC2030,SC2031,SC2016

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  RUN=$XDG_RUNTIME_DIR/lanai
  S=$XDG_STATE_HOME/lanai
  BG_PIDS=()
  export T FAKE_CONF=$T/fake.conf
  # systemctl: log every call; `show` prints $T/unit-show (default: an
  # inactive unit), or with --value the ActiveState from it; other verbs
  # fail when the verb is the one named in $T/systemctl-fail.
  shim systemctl 'echo "$*" >>"$T/systemctl.calls"
show=$(cat "$T/unit-show" 2>/dev/null || printf "ActiveState=inactive\nSubState=dead\nResult=success\nInvocationID=\n")
if [[ " $* " == *" show "* ]]; then
  if [[ " $* " == *" --value "* ]]; then sed -n "s/^ActiveState=//p" <<<"$show"; else printf "%s\n" "$show"; fi
  exit 0
fi
[[ ! -f $T/systemctl-fail || $2 != "$(<"$T/systemctl-fail")" ]]'
  shim hyprctl 'echo "[{\"focused\": false, \"scale\": 1}, {\"focused\": true, \"scale\": 1.5}]"'
  export PATH=$T/shims:$PATH
}

teardown() {
  local p
  for p in "${BG_PIDS[@]}"; do
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
}

# Print field <name> of the JSON that map saved, else of the JSON in $output.
field() {
  jq -r --arg k "$1" '.[$k] | if . == null then "null" else tostring end' <<<"${JSON:-$output}"
}

# Write the unit's `systemctl show` output: unit_show <ActiveState> [Key=Value...].
unit_show() {
  local active=$1
  shift
  printf '%s\n' "ActiveState=$active" "SubState=running" "Result=success" \
    "InvocationID=0123456789abcdef0123456789abcdef" "ExecMainStatus=0" "$@" >"$T/unit-show"
}

# A finished install at the default location, a share, and finished setup.
ready() {
  make_install "$HOME/.windows"
  mkdir -p "$HOME/Windows" "$S"
  echo '{"done": true}' >"$S/setup.json"
}

# Serve <socket> with the fake QMP server in the background.
serve_qmp() {
  local i
  mkdir -p "$(dirname "$1")"
  socat "UNIX-LISTEN:$1,fork" "EXEC:$FIX/fake-qmp" >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  for ((i = 0; i < 100; i++)); do
    [[ -S $1 ]] && return 0
    sleep 0.05
  done
  fail "no socket $1"
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

@test "status_map: before guest setup installs the agent, a booted VM is setup needed" {
  unit_show active
  map LanaiInstall=present LanaiSetup=needed LanaiContainer=none LanaiQmp=running LanaiQga=closed
  assert_equal "$(field state)" setup-needed
  run field message
  assert_output --partial "Windows is running"
}

@test "status_map: a dead helper is a warning on the running state, naming what is lost" {
  unit_show active
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiHelpersMissing=sleep-watcher,virtiofsd
  assert_equal "$(field state)" running
  run field warning
  assert_output --partial "clock sync after suspend is off"
  assert_output --partial "file sharing through ~/Windows is off"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiHelpersMissing=inhibitor
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
  assert_output --partial "forced stop"
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
  unit_show active
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=guest-panicked
  assert_equal "$(field state)" failed
  run field message
  assert_output --partial "guest-panicked"
}

@test "status_map: after a forced stop the failed unit shows as stopped" {
  unit_show failed "Result=signal"
  map LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiForced=yes
  assert_equal "$(field state)" stopped
  run field notice
  assert_output --partial "force-stopped"
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

@test "status_facts: a helper is missing when its pid is dead or outside the unit" {
  unit_show active
  mkdir -m 700 "$RUN"
  local unit_cg=/user.slice/user-1000.slice/user@1000.service/session.slice/lanai-vm.service
  fake_proc 501 "$unit_cg" bash
  fake_proc 502 "$unit_cg" bash
  fake_proc 503 /user.slice/user-1000.slice/session-2.scope bash
  echo 501 >"$RUN/virtiofsd.pid"
  echo 502 >"$RUN/inhibitor.pid"
  echo 503 >"$RUN/sleep-watcher.pid"
  echo 999 >"$RUN/event-logger.pid"
  run status_facts
  assert_success
  local missing
  missing=$(sed -n 's/^LanaiHelpersMissing=//p' <<<"$output" | tr ',' '\n' | sort | paste -sd,)
  assert_equal "$missing" "event-logger,sleep-watcher"
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
  serve_qmp "$RUN/qmp-cli.sock"
  run "$REPO/bin/lanai" status
  assert_success
  assert_equal "$(field state)" running
  assert_equal "$(field ok)" true
  # One QMP session with both queries, then a disconnect.
  unit_show inactive
  run "$REPO/bin/lanai" status
  assert_equal "$(field state)" stopped
}

@test "lanai status: the guest agent's port closed means starting" {
  ready
  unit_show active
  conf_qmp FAKE_QMP_QGA=false
  serve_qmp "$RUN/qmp-cli.sock"
  run "$REPO/bin/lanai" status
  assert_equal "$(field state)" starting
}

# Set the fake QMP server's knobs.
conf_qmp() {
  printf '%s\n' "$@" >"$FAKE_CONF"
}

# --- preflight, through every path that starts the unit ---

# Run each entry point that boots the VM: lanai start, and boot_vm 1 (the
# setup boots of lanai setup-guest and setup's step 6, phase 6). Each must
# refuse with a message containing <text> and must not start the unit.
assert_both_refuse() {
  run "$REPO/bin/lanai" start
  assert_failure
  assert_equal "$(field ok)" false
  run field message
  assert_output --partial "$1"
  run boot_vm 1
  assert_failure
  assert_equal "$(jq -r .ok <<<"$output")" false
  assert_output --partial "$1"
  ! grep -q '^--user start' "$T/systemctl.calls" 2>/dev/null || fail "the unit was started"
}

@test "preflight: refuses while Lanai's VM runs, and keeps that run's markers" {
  ready
  unit_show active
  echo live-run >"$S/running"
  assert_both_refuse "already running"
  assert_equal "$(<"$S/running")" live-run
  unit_show deactivating
  assert_both_refuse "already running"
}

@test "preflight: refuses while a restore is unfinished" {
  ready
  echo /some/snapshot >"$S/restore-in-progress"
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
  local scope=/system.slice/docker-4f1c2d3e4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff.scope
  fake_proc 700 "$scope" /usr/bin/qemu-system-x86_64 -name windows
  assert_both_refuse "a Docker VM is running (possibly omarchy-windows-vm)"
  rm -rf "$T/proc/700"
  fake_proc 701 "$scope" /bin/bash /run/entry.sh
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
  rm "$HOME/.windows/windows.boot"
  run "$REPO/bin/lanai" start
  assert_failure
  assert_equal "$(<"$S/last-run")" forced
  assert [ ! -e "$S/running" ]
}

# --- lanai start ---

@test "lanai start: refuses while setup is incomplete" {
  ready
  rm "$S/setup.json"
  run "$REPO/bin/lanai" start
  assert_failure
  assert_equal "$(field state)" setup-needed
  echo '{"done": false}' >"$S/setup.json"
  run "$REPO/bin/lanai" start
  assert_failure
  ! grep -q '^--user start' "$T/systemctl.calls" 2>/dev/null || fail "the unit was started"
}

@test "lanai start: installs the runtime copy and unit, records the scale, starts the unit" {
  ready
  run "$REPO/bin/lanai" start
  assert_success
  assert_equal "$(field state)" starting
  local rt=$XDG_DATA_HOME/lanai/runtime/$LANAI_VERSION
  assert [ -x "$rt/bin/lanai-vm-exec" ]
  assert [ -f "$rt/lib/vm.sh" ]
  assert [ -f "$rt/lib/dockur-6.05.args" ]
  local unit=$XDG_CONFIG_HOME/systemd/user/lanai-vm.service
  run cat "$unit"
  assert_line "ExecStart=$rt/bin/lanai-vm-exec"
  assert_line "ExecStop=$rt/bin/lanai-vm-stop"
  assert_line "Environment=XDG_CONFIG_HOME=$XDG_CONFIG_HOME XDG_STATE_HOME=$XDG_STATE_HOME XDG_DATA_HOME=$XDG_DATA_HOME XDG_CACHE_HOME=$XDG_CACHE_HOME"
  assert_line "PartOf=graphical-session.target"
  assert_line "Slice=session.slice"
  assert_line "TimeoutStopSec=2min"
  refute_output --partial "[Install]"
  # The focused monitor is at 150%.
  assert_equal "$(jq -c . "$S/boot.json")" '{"scale":150,"setup":false}'
  run cat "$T/systemctl.calls"
  assert_line "--user daemon-reload"
  assert_line "--user start lanai-vm.service"
}

@test "lanai start: the runtime copy is refreshed only when the version changes" {
  ready
  run "$REPO/bin/lanai" start
  assert_success
  : >"$T/systemctl.calls"
  run "$REPO/bin/lanai" start
  assert_success
  run grep -c daemon-reload "$T/systemctl.calls"
  assert_output 0
  # A new version: a new copy, the unit points at it, systemd reloads, and
  # the old copy goes.
  : >"$T/systemctl.calls"
  LANAI_VERSION=9.9.9 run boot_vm 0
  assert_success
  assert [ -d "$XDG_DATA_HOME/lanai/runtime/9.9.9/bin" ]
  assert [ ! -e "$XDG_DATA_HOME/lanai/runtime/$LANAI_VERSION" ]
  grep -q "^ExecStart=$XDG_DATA_HOME/lanai/runtime/9.9.9/bin/lanai-vm-exec$" \
    "$XDG_CONFIG_HOME/systemd/user/lanai-vm.service" || fail "the unit still points at the old copy"
  run grep -c daemon-reload "$T/systemctl.calls"
  assert_output 1
}

@test "lanai start: reports a forced stop from the last run, once" {
  ready
  echo run-1 >"$S/running"
  printf '{"invocation":"run-1","guest":true,"reason":"guest-shutdown"}\n' >"$S/last-shutdown"
  : >"$S/forced"
  run "$REPO/bin/lanai" start
  assert_success
  assert_equal "$(field last_run)" forced
}

@test "lanai start: a failed systemctl start is reported as failed" {
  ready
  echo start >"$T/systemctl-fail"
  run "$REPO/bin/lanai" start
  assert_failure
  assert_equal "$(field state)" failed
  run field next
  assert_output --partial "journalctl --user -u lanai-vm"
}

@test "lanai start: without Hyprland the scale falls back to 100%" {
  ready
  shim hyprctl 'exit 1'
  run "$REPO/bin/lanai" start
  assert_success
  assert_equal "$(jq -r .scale "$S/boot.json")" 100
}

@test "boot_vm 1: the setup boot records setup mode, without the setup check" {
  ready
  rm "$S/setup.json"
  run boot_vm 1
  assert_success
  assert_equal "$(jq -r .setup "$S/boot.json")" true
}

# --- lanai stop and force-stop ---

@test "lanai stop: sends system_powerdown on the CLI socket and records the request" {
  ready
  unit_show active
  export FAKE_QMP_LOG=$T/qmp.log
  serve_qmp "$RUN/qmp-cli.sock"
  run "$REPO/bin/lanai" stop
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
  run "$REPO/bin/lanai" stop
  assert_success
  assert_equal "$(<"$S/stop-requested")" "0123456789abcdef0123456789abcdef 1000"
}

@test "lanai stop: refuses when Windows is not running or QMP does not answer" {
  ready
  run "$REPO/bin/lanai" stop
  assert_failure
  run field message
  assert_output --partial "not running"
  unit_show active
  run "$REPO/bin/lanai" stop
  assert_failure
  assert [ ! -e "$S/stop-requested" ]
}

@test "lanai force-stop: refuses without --confirm" {
  ready
  unit_show active
  run "$REPO/bin/lanai" force-stop
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
  run "$REPO/bin/lanai" force-stop --confirm
  assert_success
  assert [ -e "$S/forced" ]
  run cat "$T/systemctl.calls"
  assert_line "--user kill --signal=SIGKILL lanai-vm.service"
}

@test "lanai force-stop --confirm: does nothing when Windows is not running" {
  ready
  run "$REPO/bin/lanai" force-stop --confirm
  assert_failure
  assert [ ! -e "$S/forced" ]
  ! grep -q -- '--user kill' "$T/systemctl.calls" || fail "killed a stopped unit"
}

@test "lanai force-stop --confirm: a failed kill leaves no forced marker" {
  ready
  unit_show active
  echo kill >"$T/systemctl-fail"
  run "$REPO/bin/lanai" force-stop --confirm
  assert_failure
  assert [ ! -e "$S/forced" ]
}
