#!/usr/bin/env bats
# Tests for the Looking Glass client and host setup (plan phase 5):
# version_check and its normalization, build_select, lanai-client-exec's QMP
# wait (against test/fixtures/fake-qmp), lanai open, lanai build-client with
# a small local tarball and a stubbed cmake, and lanai setup-host. systemctl,
# systemd-run, hyprctl, curl, cmake, pacman, sudo and omarchy are PATH shims:
# nothing talks to the real user manager, opens a real window, downloads,
# builds or installs anything.
# shellcheck disable=SC2030,SC2031,SC2016,SC2034,SC2329

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  RUN=$XDG_RUNTIME_DIR/lanai
  S=$XDG_STATE_HOME/lanai
  LOGS=$FIX/client-logs
  LGDIR=$XDG_DATA_HOME/lanai/looking-glass
  export T
  # systemctl: log every call. `show` answers from $T/show-<unit> (default:
  # inactive), all of it or, with --value, the one property asked for.
  shim systemctl 'echo "$*" >>"$T/systemctl.calls"
unit=""
for a; do [[ $a != *.service ]] || unit=$a; done
show=$(cat "$T/show-$unit" 2>/dev/null || printf "ActiveState=inactive\nSubState=dead\nResult=success\nInvocationID=\nMainPID=0\n")
if [[ " $* " == *" show "* ]]; then
  if [[ " $* " == *" --value "* ]]; then
    for a; do [[ ${prev:-} == -p ]] && sed -n "s/^$a=//p" <<<"$show"; prev=$a; done
  else
    printf "%s\n" "$show"
  fi
fi
exit 0'
  # systemd-run: log its arguments; with $T/systemd-run-fails it fails, and
  # with $T/race too, the client unit shows as started by someone else.
  shim systemd-run 'printf "%s\n" "$@" >"$T/systemd-run.args"
[[ -e $T/systemd-run-fails ]] || exit 0
[[ ! -e $T/race ]] || printf "ActiveState=active\nMainPID=77\n" >"$T/show-lanai-client.service"
exit 1'
  shim hyprctl 'echo "$*" >>"$T/hyprctl.calls"; echo ok'
  export PATH=$T/shims:$PATH
}

teardown() {
  stop_bg
}

# Write the `systemctl show` output of <unit>: unit_is <unit> <ActiveState> [Key=Value...].
unit_is() {
  local unit=$1 active=$2
  shift 2
  printf '%s\n' "ActiveState=$active" "SubState=running" "Result=success" \
    "InvocationID=0123456789abcdef0123456789abcdef" "ExecMainStatus=0" "$@" >"$T/show-$unit"
}

# Print client log <file> as lanai-client-exec leaves it: its start line
# (<age> seconds ago, default 5), then the client's output.
started_log() {
  echo "lanai: client started at $((EPOCHSECONDS - ${2:-5}))"
  cat "$1"
}

# --- version normalization ---

@test "client build readers: the binary and log report the same first build, or none" {
  fake_build "$LG_BUILD"
  local bin=$LGDIR/$LG_BUILD/bin/looking-glass-client
  "$bin" --help >"$T/client.log" 2>&1
  started_log "$LOGS/other-build.log" >>"$T/client.log"
  run client_version "$bin"
  assert_success
  assert_output "$LG_BUILD"
  run log_client_build "$T/client.log"
  assert_success
  assert_output "$LG_BUILD"
  printf '#!/usr/bin/env bash\necho no-build\n' >"$bin"
  run client_version "$bin"
  assert_failure
  assert_output ""
  echo no-build >"$T/client.log"
  run log_client_build "$T/client.log"
  assert_success
  assert_output ""
}

@test "lg_version_key: splits a build into tag, count and hash, with or without git's g" {
  run lg_version_key B7-826-236efcb1
  assert_output "B7 826 236efcb1"
  run lg_version_key B7-826-g236efcb155
  assert_output "B7 826 236efcb155"
  # A tag may hold dashes; the hash is lower-cased.
  run lg_version_key B7-rc1-12-gABCDEF12
  assert_output "B7-rc1 12 abcdef12"
  local bad
  for bad in "" unknown B7 B7-826 B7-826-g12345 B7-x-236efcb1 "B7-826-236efcb1 extra" B7-826-236efcbz; do
    run lg_version_key "$bad"
    assert_failure
  done
}

@test "lg_same_build: the client's build and the IDD's git describe name match; others do not" {
  lg_same_build B7-826-236efcb1 B7-826-g236efcb155
  lg_same_build B7-826-g236efcb155 B7-826-236efcb1
  run lg_same_build B7-826-236efcb1 B7-825-g236efcb155
  assert_failure
  run lg_same_build B7-826-236efcb1 B6-826-g236efcb155
  assert_failure
  run lg_same_build B7-826-236efcb1 B7-826-g236efcb255
  assert_failure
  run lg_same_build B7-826-236efcb1 unknown
  assert_failure
}

# --- version_check on client logs (fixtures trimmed from spike/work/client-*.log) ---

@test "version_check: the spike's log, client and IDD from one build, is a match" {
  run version_check "$LOGS/match.log"
  assert_success
  assert_output "match B7-826-g236efcb155"
}

@test "version_check: an IDD from another build is a mismatch, and names its version" {
  run version_check "$LOGS/other-build.log"
  assert_output "mismatch B7-801-g1a2b3c4d5e"
}

@test "version_check: an Incompatible line is a hard mismatch; a later guest session wins" {
  run version_check "$LOGS/incompatible.log"
  assert_output "mismatch"
  sed -n '7,$p' "$LOGS/match.log" >"$T/fixed.log"
  cat "$LOGS/incompatible.log" "$T/fixed.log" >"$T/log"
  run version_check "$T/log"
  assert_output "match B7-826-g236efcb155"
  # The client's other wording for the same problem.
  { head -n 6 "$LOGS/incompatible.log"
    echo "00:00:00.212 [E]              main.c:2808 | reportBadVersion               | The transport is not compatible with this client"
  } >"$T/log"
  run version_check "$T/log"
  assert_output "mismatch"
}

@test "version_check: the transport unavailable for 30 s means the IDD is missing" {
  local now=1000000
  # Lanai's first line gives the client's start; the log's own times count
  # from it. The line is at 0.211 s.
  { echo "lanai: client started at $((now - 20))"; cat "$LOGS/waiting.log"; } >"$T/log"
  run version_check "$T/log" "$now"
  assert_output "waiting"
  { echo "lanai: client started at $((now - 31))"; cat "$LOGS/waiting.log"; } >"$T/log"
  run version_check "$T/log" "$now"
  assert_output "idd-missing"
  # A line logged late in a long run counts from its own time.
  { echo "lanai: client started at $((now - 100))"; cat "$LOGS/waiting.log"
    echo "00:01:30.000 [I]              main.c:3961 | lg_run                         | The transport source is not available"
  } >"$T/log"
  run version_check "$T/log" "$now"
  assert_output "waiting"
  # Without Lanai's start line nothing can be timed.
  run version_check "$LOGS/waiting.log" "$now"
  assert_output "waiting"
  # The guest answering after the wait ends it.
  { echo "lanai: client started at $((now - 600))"; cat "$LOGS/match.log"; } >"$T/log"
  run version_check "$T/log" "$now"
  assert_output "match B7-826-g236efcb155"
}

@test "version_check: no log, an empty log or a log without events is unknown" {
  run version_check "$T/none.log"
  assert_output "unknown"
  : >"$T/empty.log"
  run version_check "$T/empty.log"
  assert_output "unknown"
  # The EGL renderer's "Version :" line is not the guest's, nor is a
  # "Version  :" line outside a Guest Information block.
  head -n 6 "$LOGS/match.log" >"$T/log"
  echo "00:00:00.300 [I]              main.c:4017 | lg_run                         | Version  : B7-826-g236efcb155" >>"$T/log"
  run version_check "$T/log"
  assert_output "unknown"
}

@test "version_check: the start line counts only as the log's first line" {
  local now=1000000
  # A guest version string with a newline can put text at the start of a
  # log line; an older start there must not make the wait look long.
  { echo "lanai: client started at $((now - 10))"; cat "$LOGS/waiting.log"
    echo "lanai: client started at $((now - 500))"; } >"$T/log"
  run version_check "$T/log" "$now"
  assert_output "waiting"
  { cat "$LOGS/waiting.log"; echo "lanai: client started at $((now - 500))"; } >"$T/log"
  run version_check "$T/log" "$now"
  assert_output "waiting"
}

@test "version_check: a guest version the client cannot tell is a mismatch" {
  sed 's/Version  : B7-826-g236efcb155/Version  : unknown/' "$LOGS/match.log" >"$T/log"
  run version_check "$T/log"
  assert_output "mismatch unknown"
}

# --- guest version record and build_select (req 8) ---

@test "build_select: no record picks the pinned build" {
  fake_build "$LG_BUILD"
  fake_build B7-801-1a2b3c4d
  run build_select
  assert_success
  assert_output "$LGDIR/$LG_BUILD/bin/looking-glass-client"
}

@test "build_select: a recorded guest version picks the build that matches it" {
  fake_build "$LG_BUILD"
  fake_build B7-801-1a2b3c4d
  guest_version_set B7-801-g1a2b3c4d5e
  run build_select
  assert_output "$LGDIR/B7-801-1a2b3c4d/bin/looking-glass-client"
}

@test "build_select: no build matches the record, so the pinned build" {
  fake_build "$LG_BUILD"
  fake_build B7-801-1a2b3c4d
  guest_version_set B7-700-g9999999999
  run build_select
  assert_output "$LGDIR/$LG_BUILD/bin/looking-glass-client"
  # A matching folder without a client binary does not count.
  mkdir -p "$LGDIR/B7-700-99999999"
  run build_select
  assert_output "$LGDIR/$LG_BUILD/bin/looking-glass-client"
}

@test "build_select: after setup-guest records the pin, the pinned build again" {
  fake_build "$LG_BUILD"
  fake_build B7-801-1a2b3c4d
  guest_version_set B7-801-g1a2b3c4d5e
  # What lanai setup-guest writes when it succeeds (phase 6).
  guest_version_set "$LG_BUILD"
  assert_equal "$(cat "$S/guest-version")" "$LG_BUILD"
  run build_select
  assert_output "$LGDIR/$LG_BUILD/bin/looking-glass-client"
}

@test "build_select: fails when no usable build is installed" {
  run build_select
  assert_failure
  guest_version_set B7-801-g1a2b3c4d5e
  fake_build B7-802-1a2b3c4d
  run build_select
  assert_failure
}

@test "guest_version_set: refuses anything that is not a version name" {
  run guest_version_set $'B7-826-g236efcb155\nrm'
  assert_failure
  run guest_version_set "../x"
  assert_failure
  run guest_version_set unknown
  assert_failure
  run guest_version_set B7
  assert_failure
  assert [ ! -e "$S/guest-version" ]
}

# --- lanai-client-exec: wait for QEMU's reply on qmp-cli.sock, then exec ---

# A stand-in client: records its arguments and prints the version line like
# the real client. With $T/probe-qmp it first asks QMP itself, which on a
# one-client server works only if the wrapper closed its connection.
fake_client() {
  cat >"$T/fake-client" <<'EOF'
#!/usr/bin/env bash
if [[ -e $T/probe-qmp ]]; then
  source "$REPO/lib/lanai.sh"
  if qmp_call "$XDG_RUNTIME_DIR/lanai/qmp-cli.sock" '{"execute":"query-status"}' >/dev/null; then
    echo free >"$T/client.qmp"
  fi
fi
printf '%s\n' "$@" >"$T/client.args"
echo "00:00:00.000 [I]              main.c:4303 | main                           | Looking Glass (B7-826-236efcb1)"
EOF
  chmod +x "$T/fake-client"
  export REPO
}

@test "lanai-client-exec: waits for a status reply, closes QMP, then execs the client with its flags" {
  mkdir -m 700 "$RUN"
  echo "an old client's log" >"$RUN/client.log"
  fake_client
  export FAKE_QMP_LOG=$T/qmp.log
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  run timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_success
  # The handshake: capabilities, then query-status.
  assert_equal "$(sed -n 1p "$T/qmp.log")" '{"execute":"qmp_capabilities","id":1}'
  assert_equal "$(sed -n 2p "$T/qmp.log")" '{"execute":"query-status","id":2}'
  run cat "$T/client.args"
  assert_output -- "-f
$RUN/ivshmem
spice:host=$RUN/spice.sock
spice:port=0
win:setGuestRes=yes
wayland:warpSupport=no"
  # A fresh log: Lanai's start line, then the client's own output.
  run cat "$RUN/client.log"
  assert_line --index 0 --regexp '^lanai: client started at [0-9]+$'
  assert_line --index 1 --partial "Looking Glass (B7-826-236efcb1)"
  refute_output --partial "an old client"
}

@test "lanai-client-exec: on a one-client socket, a try without a status leaks nothing" {
  mkdir -m 700 "$RUN"
  fake_client
  touch "$T/probe-qmp"
  export FAKE_QMP_LOG=$T/qmp.log
  # The first connection gets no status; once query-status has arrived,
  # later connections get a real answer. A connection left open would block
  # every later one, as in QEMU.
  conf FAKE_QMP_MODE=nostatus
  serve_one "$RUN/qmp-cli.sock"
  (
    until grep -q query-status "$T/qmp.log" 2>/dev/null; do sleep 0.05; done
    : >"$FAKE_CONF"
  ) 3>&- &
  BG_PIDS+=("$!")
  LANAI_CLIENT_WAIT=8 run timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_success
  assert [ -e "$T/client.args" ]
  # The client itself could reach QMP: the wrapper closed its connection.
  assert_equal "$(cat "$T/client.qmp")" free
}

@test "lanai-client-exec: retries while the socket is missing, then starts" {
  mkdir -m 700 "$RUN"
  fake_client
  export FAKE_QMP_LOG=$T/qmp.log
  timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client" >"$T/out" 2>&1 &
  local pid=$!
  BG_PIDS+=("$pid")
  sleep 1.5
  assert [ ! -e "$T/client.args" ]
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  wait "$pid" || fail "lanai-client-exec failed: $(cat "$T/out")"
  assert [ -e "$T/client.args" ]
}

@test "lanai-client-exec: the greeting alone does not count; it times out with a message" {
  mkdir -m 700 "$RUN"
  fake_client
  export FAKE_QMP_LOG=$T/qmp.log FAKE_QMP_MODE=silent
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  local start=$SECONDS
  LANAI_CLIENT_WAIT=4 run --separate-stderr timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_failure
  (((SECONDS - start) <= 9)) || fail "took $((SECONDS - start)) s"
  assert [ ! -e "$T/client.args" ]
  # Each try is its own short connection (2 s), so there were several.
  (($(grep -c qmp_capabilities "$T/qmp.log") >= 2)) || fail "only one try: $(cat "$T/qmp.log")"
  [[ $stderr == *"QEMU did not answer"* ]] || fail "no message: $stderr"
  # status reads the message from the log, which holds only this try.
  run cat "$RUN/client.log"
  assert_output --regexp '^lanai: QEMU did not answer'
}

@test "lanai-client-exec: a reply without a status does not count" {
  mkdir -m 700 "$RUN"
  fake_client
  export FAKE_QMP_LOG=$T/qmp.log FAKE_QMP_MODE=nostatus
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  LANAI_CLIENT_WAIT=2 run timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_failure
  grep -q query-status "$T/qmp.log" || fail "query-status was never sent"
  assert [ ! -e "$T/client.args" ]
}

@test "lanai-client-exec: refuses a runtime folder with the wrong mode, and leaves its log alone" {
  mkdir -m 755 "$RUN"
  echo sentinel >"$RUN/client.log"
  fake_client
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  run --separate-stderr timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_failure
  [[ $stderr == *"0700"* ]] || fail "no reason: $stderr"
  assert [ ! -e "$T/client.args" ]
  assert_equal "$(cat "$RUN/client.log")" sentinel
}

@test "lanai-client-exec: a missing client stops it before the wait, and the log is untouched" {
  mkdir -m 700 "$RUN"
  echo sentinel >"$RUN/client.log"
  export FAKE_QMP_LOG=$T/qmp.log
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  run --separate-stderr timeout 20 "$REPO/bin/lanai-client-exec" "$T/no-such-client"
  assert_failure
  [[ $stderr == *"no Looking Glass client"* ]] || fail "no reason: $stderr"
  assert_equal "$(cat "$RUN/client.log")" sentinel
  assert [ ! -e "$T/qmp.log" ]
}

@test "lanai-client-exec: a timeout writes its message only into a sound runtime folder" {
  fake_client
  # No $RUN at all: a timeout never creates it.
  LANAI_CLIENT_WAIT=1 run timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_failure
  assert [ ! -e "$RUN" ]
  # A $RUN with the wrong mode: the log is not written through it.
  mkdir -m 755 "$RUN"
  echo sentinel >"$RUN/client.log"
  LANAI_CLIENT_WAIT=1 run timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_failure
  assert_equal "$(cat "$RUN/client.log")" sentinel
  # A sound $RUN gets the message.
  chmod 700 "$RUN"
  LANAI_CLIENT_WAIT=1 run timeout 20 "$REPO/bin/lanai-client-exec" "$T/fake-client"
  assert_failure
  run cat "$RUN/client.log"
  assert_output --regexp '^lanai: QEMU did not answer'
}

# --- lanai open ---

@test "lanai open: refuses while Windows is not running" {
  fake_build "$LG_BUILD"
  lanai_run open
  assert_failure
  assert_equal "$(field message)" "Windows is not running."
  assert [ ! -e "$T/systemd-run.args" ]
}

@test "lanai open: starts the client unit with the selected build and returns at once" {
  fake_build "$LG_BUILD"
  unit_is lanai-vm.service active
  export WAYLAND_DISPLAY=wayland-7
  lanai_run open
  assert_success
  assert_equal "$(field ok)" true
  run cat "$T/systemd-run.args"
  assert_equal "${lines[0]}" --user
  assert_equal "${lines[1]}" --collect
  assert_line -- --unit=lanai-client
  # Stopping the VM unit stops the client too (without ever starting the
  # VM), and no path is expanded as a variable.
  assert_line -- --property=PartOf=lanai-vm.service
  # Out of app.slice, where oomd kills under memory pressure.
  assert_line -- --slice=session.slice
  refute_line --partial Requires=
  refute_line --partial BindsTo=
  assert_line -- --expand-environment=no
  assert_line -- --setenv=WAYLAND_DISPLAY=wayland-7
  assert_line -- "--setenv=XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
  # The wrapper and the client come last, after --.
  local n=${#lines[@]}
  assert_equal "${lines[n - 3]}" --
  assert_equal "${lines[n - 2]}" "$REPO/bin/lanai-client-exec"
  assert_equal "${lines[n - 1]}" "$LGDIR/$LG_BUILD/bin/looking-glass-client"
}

@test "lanai open: focuses the running client instead of starting a second one" {
  fake_build "$LG_BUILD"
  unit_is lanai-vm.service active
  unit_is lanai-client.service active MainPID=4242
  lanai_run open
  assert_success
  assert [ ! -e "$T/systemd-run.args" ]
  run cat "$T/hyprctl.calls"
  assert_output "dispatch focuswindow pid:4242"
}

@test "lanai open: records the guest version from the last client log, then picks its build" {
  fake_build "$LG_BUILD"
  fake_build B7-801-1a2b3c4d
  unit_is lanai-vm.service active
  mkdir -m 700 "$RUN"
  started_log "$LOGS/other-build.log" >"$RUN/client.log"
  lanai_run open
  assert_success
  assert_equal "$(cat "$S/guest-version")" B7-801-g1a2b3c4d5e
  run tail -n 1 "$T/systemd-run.args"
  assert_output "$LGDIR/B7-801-1a2b3c4d/bin/looking-glass-client"
}

@test "lanai open: without a client build it says to build one" {
  unit_is lanai-vm.service active
  lanai_run open
  assert_failure
  run field next
  assert_output --partial "build-client"
  assert [ ! -e "$T/systemd-run.args" ]
}

@test "lanai open: a failed systemd-run is reported" {
  fake_build "$LG_BUILD"
  unit_is lanai-vm.service active
  touch "$T/systemd-run-fails"
  lanai_run open
  assert_failure
  run field next
  assert_output --partial "journalctl --user -u lanai-client"
}

@test "lanai open: when a second open started the client meanwhile, it focuses that one" {
  fake_build "$LG_BUILD"
  unit_is lanai-vm.service active
  # systemd-run fails because the unit exists: another open won the race.
  touch "$T/systemd-run-fails" "$T/race"
  lanai_run open
  assert_success
  run cat "$T/hyprctl.calls"
  assert_output "dispatch focuswindow pid:77"
}

# --- status: the version check wired into status_facts and status_map ---

@test "status_facts: reads the client log for the version, and records the guest's" {
  unit_is lanai-vm.service active
  mkdir -m 700 "$RUN"
  started_log "$LOGS/match.log" >"$RUN/client.log"
  run status_facts
  assert_line LanaiVersion=match
  refute_line --partial LanaiClient=
  assert_equal "$(cat "$S/guest-version")" B7-826-g236efcb155
  cp "$LOGS/incompatible.log" "$RUN/client.log"
  run status_facts
  assert_line LanaiVersion=mismatch
  echo "lanai: QEMU did not answer on qmp-cli.sock within 60 s; the Windows window did not open" >"$RUN/client.log"
  run status_facts
  assert_line LanaiClient=timeout
  # While a second open waits, the old timeout is not shown.
  unit_is lanai-client.service active
  run status_facts
  refute_line --partial LanaiClient=
}

@test "status_facts and open: a client log older than the record does not undo it" {
  fake_build "$LG_BUILD"
  fake_build B7-801-1a2b3c4d
  unit_is lanai-vm.service active
  mkdir -m 700 "$RUN"
  # This run's client saw the old driver; then setup-guest recorded the pin
  # (phase 6).
  started_log "$LOGS/other-build.log" 60 >"$RUN/client.log"
  guest_version_set "$LG_BUILD"
  run status_facts
  refute_line --partial LanaiDriverOld=
  assert_equal "$(cat "$S/guest-version")" "$LG_BUILD"
  lanai_run open
  assert_success
  assert_equal "$(cat "$S/guest-version")" "$LG_BUILD"
  run tail -n 1 "$T/systemd-run.args"
  assert_output "$LGDIR/$LG_BUILD/bin/looking-glass-client"
  # A client started after the record does record what it sees.
  touch -d '-120 seconds' "$S/guest-version"
  run status_facts
  assert_equal "$(cat "$S/guest-version")" B7-801-g1a2b3c4d5e
  # A log without Lanai's start line is not trusted for the record.
  guest_version_set "$LG_BUILD"
  touch -d '-120 seconds' "$S/guest-version"
  cp "$LOGS/other-build.log" "$RUN/client.log"
  run status_facts
  assert_equal "$(cat "$S/guest-version")" "$LG_BUILD"
}

@test "status_facts: a missing IDD counts only while the client runs" {
  unit_is lanai-vm.service active
  mkdir -m 700 "$RUN"
  { echo "lanai: client started at $((EPOCHSECONDS - 120))"; cat "$LOGS/waiting.log"; } >"$RUN/client.log"
  # The user closed a black window while Windows booted: the log is stale.
  run status_facts
  assert_line LanaiVersion=unknown
  unit_is lanai-client.service active
  run status_facts
  assert_line LanaiVersion=idd-missing
}

@test "status_facts: a guest driver from another build than the pin is named" {
  unit_is lanai-vm.service active
  mkdir -m 700 "$RUN"
  # The old client build matches the old driver, so the window works, but
  # the pin moved on (req 8).
  sed "1s/.*/00:00:00.000 [I]              main.c:4303 | main                           | Looking Glass (B7-801-1a2b3c4d)/" \
    "$LOGS/other-build.log" >"$T/old.log"
  started_log "$T/old.log" >"$RUN/client.log"
  run status_facts
  assert_line LanaiVersion=match
  assert_line LanaiDriverOld=B7-801-g1a2b3c4d5e
  # Recorded, it shows while Windows is stopped too.
  unit_is lanai-vm.service inactive
  run status_facts
  assert_line LanaiDriverOld=B7-801-g1a2b3c4d5e
  guest_version_set B7-826-g236efcb155
  run status_facts
  refute_line --partial LanaiDriverOld=
}

# Run status_map on the active VM unit plus the given fact lines, and keep
# its JSON for field.
smap() {
  unit_is lanai-vm.service active
  run status_map < <(cat "$T/show-lanai-vm.service"; printf '%s\n' "$@")
  JSON=$output
}

@test "status_map: a mismatch does not hide a stop in progress or a QEMU error" {
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiStopAge=150 LanaiVersion=mismatch
  assert_equal "$(field state)" stopping
  assert_equal "$(field force_stop)" true
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=guest-panicked \
    LanaiVersion=mismatch
  assert_equal "$(field state)" failed
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiVersion=mismatch
  assert_equal "$(field state)" version-mismatch
}

@test "status_map: a driver from another build than the pin is a warning with the fix" {
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running LanaiQga=open \
    LanaiVersion=match LanaiDriverOld=B7-801-g1a2b3c4d5e
  assert_equal "$(field state)" running
  run field warning
  assert_output --partial "B7-801-g1a2b3c4d5e"
  assert_output --partial "run Lanai setup again"
  unit_is lanai-vm.service inactive
  run status_map < <(cat "$T/show-lanai-vm.service"
    printf '%s\n' LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiDriverOld=B7-801-g1a2b3c4d5e)
  JSON=$output
  assert_equal "$(field state)" stopped
  run field warning
  assert_output --partial "run Lanai setup again"
}

@test "status_map: an IDD that never answered is failed on a booted VM, with the client log" {
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running \
    LanaiQga=open LanaiVersion=idd-missing
  assert_equal "$(field state)" failed
  assert_equal "$(field logs)" "$RUN/client.log"
  run field next
  assert_output --partial "omarchy-windows-vm"
  # While Windows still boots it is only starting.
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running \
    LanaiQga=closed LanaiVersion=idd-missing
  assert_equal "$(field state)" starting
}

@test "status_map: a client that gave up waiting is a warning, and a match changes nothing" {
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running \
    LanaiQga=open LanaiVersion=match LanaiClient=timeout
  assert_equal "$(field state)" running
  run field warning
  assert_output --partial "did not open"
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running \
    LanaiQga=open LanaiVersion=match
  assert_equal "$(field state)" running
  assert_equal "$(field warning)" null
}

@test "status_map: under a version mismatch the old-driver warning is not repeated" {
  smap LanaiInstall=present LanaiSetup=done LanaiContainer=none LanaiQmp=running \
    LanaiQga=open LanaiVersion=mismatch LanaiDriverOld=B7-801-g1a2b3c4d5e
  assert_equal "$(field state)" version-mismatch
  assert_equal "$(field warning)" null
}

# --- lanai build-client (spec 7, 26) ---

patch_fixture() {
  local kind=$1 base=$T/patch-base work=$T/patch-work patchdir=$T/patches
  rm -rf "$base" "$work" "$patchdir" "$T/empty"
  mkdir -p "$base/tree" "$work" "$patchdir"
  printf 'alpha\nbeta\ngamma\n' >"$base/tree/one"
  printf 'one\ntwo\nthree\n' >"$base/tree/two"
  cp -a "$base/tree" "$work/tree"
  case $kind in
    exact) sed -i 's/beta/BETA/' "$work/tree/one" ;;
    offset) sed -i 's/beta/BETA/' "$work/tree/one" ;;
    fuzz) sed -i 's/beta/BETA/' "$work/tree/one" ;;
    failed) sed -i 's/beta/BETA/' "$work/tree/one"; sed -i 's/beta/OTHER/' "$base/tree/one" ;;
    already) sed -i 's/beta/BETA/' "$work/tree/one" ;;
  esac
  (cd "$T" && diff -Naur patch-base/tree patch-work/tree) >"$patchdir/0001-one.patch" || [[ $? == 1 ]]
  if [[ $kind == fuzz ]]; then sed -i 's/ gamma/ GAMA/' "$patchdir/0001-one.patch"; fi
  LANAI_PATCHES=$patchdir
}

@test "patches_apply: applies an exact patch and orders patches by their names" {
  patch_fixture exact
  mkdir -p "$T/patch-base2/tree" "$T/patch-work2/tree"
  printf 'alpha\nBETA\ngamma\n' >"$T/patch-base2/tree/one"
  printf 'alpha\nFINAL\ngamma\n' >"$T/patch-work2/tree/one"
  (cd "$T" && diff -Naur patch-base2/tree/one patch-work2/tree/one) >"$LANAI_PATCHES/0002-two.patch" || [[ $? == 1 ]]
  mkdir -p "$T/empty/tree"
  cp "$T/patch-base/tree/one" "$T/empty/tree/one"
  cp "$T/patch-base/tree/two" "$T/empty/tree/two"
  patches_apply "$T/empty" "$T/apply.log"
  assert_equal "$(sed -n '2p' "$T/empty/tree/one")" FINAL
}

@test "patches_apply: a patch that only creates files applies to an empty folder" {
  patch_fixture exact
  rm "$T/patch-base/tree/one" "$T/patch-base/tree/two"
  (cd "$T" && diff -Naur patch-base/tree patch-work/tree) >"$LANAI_PATCHES/0001-one.patch" || [[ $? == 1 ]]
  mkdir "$T/empty"
  patches_apply "$T/empty" "$T/apply.log"
  assert_equal "$(cat "$T/empty/tree/one")" $'alpha\nBETA\ngamma'
}

@test "patches_apply: offset, fuzzed, failed and already-applied patches fail with their name" {
  local kind
  for kind in offset fuzz failed already; do
    patch_fixture "$kind"
    mkdir -p "$T/empty/tree"
    printf 'alpha\nbeta\ngamma\n' >"$T/empty/tree/one"
    if [[ $kind == already ]]; then sed -i 's/beta/BETA/' "$T/empty/tree/one"; fi
    if [[ $kind == offset ]]; then
      # Shift the target, not the patch's base: GNU patch alone takes it
      # with an offset, so only patches_apply's own check can refuse it.
      sed -i '1i extra' "$T/empty/tree/one"
      run patch -d "$T/empty" -p1 --dry-run --batch --fuzz=0 -i "$LANAI_PATCHES/0001-one.patch"
      assert_success
      assert_output --partial 'offset'
    fi
    run patches_apply "$T/empty" "$T/apply.log"
    [[ $status != 0 ]] || fail "$kind patch unexpectedly applied"
    assert_failure
    assert_output --partial '0001-one.patch'
  done
}

@test "patches_list and patches_id: handle missing or empty folders and identify patch names, content and set" {
  local empty_hash first second
  LANAI_PATCHES=$T/no-patches
  run patches_list
  assert_success
  assert_output ""
  empty_hash=$(printf '' | sha256sum | cut -d' ' -f1)
  assert_equal "$(patches_id)" "$empty_hash"
  run bash -c 'set -euo pipefail; source "$1/lib/lanai.sh"; LANAI_PATCHES=$2; [[ -z $(patches_list) ]]; patches_id' \
    _ "$REPO" "$LANAI_PATCHES"
  assert_success
  assert_output "$empty_hash"
  mkdir -p "$LANAI_PATCHES"
  run patches_list
  assert_success
  assert_output ""
  printf patch-a >"$LANAI_PATCHES/0002-b.patch"
  local one_patch_id
  one_patch_id=$(patches_id)
  printf patch-b >"$LANAI_PATCHES/0001-a.patch"
  printf ignored >"$LANAI_PATCHES/COPYING"
  run patches_list
  assert_output $'0001-a.patch\n0002-b.patch'
  first=$(patches_id)
  [[ $first != "$one_patch_id" ]]
  assert_equal "$(patches_id)" "$first"
  printf changed >"$LANAI_PATCHES/0001-a.patch"
  second=$(patches_id)
  [[ $second != "$first" ]]
  # A rename that keeps the order still changes the id.
  mv "$LANAI_PATCHES/0002-b.patch" "$LANAI_PATCHES/0002-z.patch"
  assert_equal "$(patches_list)" $'0001-a.patch\n0002-z.patch'
  [[ $(patches_id) != "$second" ]]
  mv "$LANAI_PATCHES/0002-z.patch" "$LANAI_PATCHES/0002-b.patch"
  mv "$LANAI_PATCHES/0001-a.patch" "$LANAI_PATCHES/0003-a.patch"
  [[ $(patches_id) != "$second" ]]
  rm "$LANAI_PATCHES/0002-b.patch"
  second=$(patches_id)
  printf ignored-too >"$LANAI_PATCHES/COPYING"
  assert_equal "$(patches_id)" "$second"
}

@test "client_exe: names the running binary's file and path, also once it is deleted" {
  local bin=$T/looking-glass-client id pid
  cp /usr/bin/sleep "$bin"
  "$bin" 30 3>&- &
  pid=$!
  BG_PIDS+=("$pid")
  id=$(stat -c %d:%i "$bin")
  run client_exe "$pid"
  assert_success
  assert_output "$id $bin"
  rm "$bin"
  run client_exe "$pid"
  assert_success
  assert_output "$id $bin (deleted)"
}

@test "build_patches_current: requires a binary and a current patch id file" {
  LANAI_PATCHES=$T/patches
  mkdir -p "$LANAI_PATCHES"
  local d=$LGDIR/$LG_BUILD
  mkdir -p "$d/bin"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/looking-glass-client"
  chmod +x "$d/bin/looking-glass-client"
  run build_patches_current
  assert_failure
  patches_id >"$d/build-patches"
  run build_patches_current
  assert_success
  echo stale >"$d/build-patches"
  run build_patches_current
  assert_failure
  # A current id file without the binary is not current.
  patches_id >"$d/build-patches"
  rm "$d/bin/looking-glass-client"
  run build_patches_current
  assert_failure
}

# Build a small stand-in for the pinned source tarball in $T/lg.tar.gz, with
# every submodule folder populated, and pin its SHA-256. `curl` copies it to
# the -o path and logs the URL; `cmake` configures (its feature summary from
# the spike's configure log), builds a fake client that reports the version
# in $T/client-version (default the pin), and installs it under --prefix.
lg_source() {
  local top=$T/src/looking-glass-$LG_BUILD d
  mkdir -p "$top/client"
  echo "$LG_BUILD" >"$top/VERSION"
  echo 'project(looking-glass-client C)' >"$top/client/CMakeLists.txt"
  for d in "${LG_SUBMODULES[@]}"; do
    mkdir -p "$top/$d"
    echo x >"$top/$d/file"
  done
  mkdir -p "$T/patchdiff/original" "$T/patchdiff/patched"
  cp -a "$top/." "$T/patchdiff/original/"
  cp -a "$top/." "$T/patchdiff/patched/"
  : >"$T/patchdiff/original/client/lanai-patched.txt"
  echo patched >"$T/patchdiff/patched/client/lanai-patched.txt"
  mkdir -p "$T/fixture-patches"
  (cd "$T/patchdiff" && diff -Naur original patched) \
    >"$T/fixture-patches/0001-fixture.patch" || [[ $? == 1 ]]
  LANAI_PATCHES=$T/fixture-patches
  tar -czf "$T/lg.tar.gz" -C "$T/src" "looking-glass-$LG_BUILD"
  LG_SOURCE_SHA=$(sha256sum "$T/lg.tar.gz" | cut -d' ' -f1)
  # With $T/curl-fails, curl leaves half a file and exits 22 (HTTP error).
  shim curl 'echo "$*" >>"$T/curl.calls"
while (($#)); do
  if [[ $1 == -o ]]; then
    if [[ -e $T/curl-fails ]]; then echo half >"$2"; exit 22; fi
    cp "$T/lg.tar.gz" "$2"
  fi
  shift
done'
  # With $T/configure-fails, cmake cannot configure; with $T/build-fails
  # or $T/install-fails, its build or install fails.
  shim cmake 'echo "$*" >>"$T/cmake.calls"
case $1 in
  -S)
    [[ -f $2/lanai-patched.txt ]] || { echo "patch was not applied"; exit 1; }
    [[ ! -e $T/configure-fails ]] || { echo "CMake Error: boom"; exit 1; }
    mkdir -p "$4"
    if [[ -e $T/no-usb ]]; then
      echo "-- libusbredirparser was not found, disabling USB audio support"
      grep -v ENABLE_USB_AUDIO "$FIX/cmake-features.txt"
    else
      cat "$FIX/cmake-features.txt"
    fi
    ;;
  --build)
    [[ ! -e $T/build-fails ]] || { echo "error: boom"; exit 1; }
    v=$(cat "$T/client-version" 2>/dev/null || echo "$LG_BUILD")
    printf "#!/usr/bin/env bash\necho \"00:00:00.000 [I]              main.c:4303 | main                           | Looking Glass (%s)\" >&2\n" "$v" >"$2/looking-glass-client"
    chmod +x "$2/looking-glass-client"
    ;;
  --install)
    [[ ! -e $T/install-fails ]] || { echo "install: boom"; exit 1; }
    mkdir -p "$4/bin"
    cp "$2/looking-glass-client" "$4/bin/"
    ;;
esac'
  export LG_BUILD FIX
}

@test "build_client: fetches, verifies, builds without X11 and installs under the build's name" {
  lg_source
  run build_client
  assert_success
  assert_output "$LGDIR/$LG_BUILD/bin/looking-glass-client"
  assert_equal "$(client_version "$LGDIR/$LG_BUILD/bin/looking-glass-client")" "$LG_BUILD"
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" "$(patches_id)"
  run cat "$T/curl.calls"
  assert_output --partial "--proto =https"
  assert_output --partial "$LG_SOURCE_URL"
  run sed -n 1p "$T/cmake.calls"
  assert_output --partial "-DENABLE_X11=no"
  # The verified download stays cached; the build folder does not.
  assert [ -f "$XDG_CACHE_HOME/lanai/downloads/looking-glass-$LG_BUILD-source.tar.gz" ]
  run find "$XDG_CACHE_HOME/lanai" -mindepth 1 -maxdepth 1 -name 'build*'
  assert_output ""
  # A second run finds the build and does no work.
  rm "$T/cmake.calls"
  run build_client
  assert_success
  assert [ ! -e "$T/cmake.calls" ]
}

@test "build_client: current patches take the quick path and missing patches rebuild the client" {
  lg_source
  mkdir -p "$LGDIR/$LG_BUILD/bin"
  printf '#!/bin/sh\necho "00:00:00.000 [I] main.c:4303 | main | Looking Glass (%s)" >&2\n' \
    "$LG_BUILD" >"$LGDIR/$LG_BUILD/bin/looking-glass-client"
  chmod +x "$LGDIR/$LG_BUILD/bin/looking-glass-client"
  patches_id >"$LGDIR/$LG_BUILD/build-patches"
  rm -rf "$T/curl.calls" "$T/cmake.calls"
  run build_client
  assert_success
  assert [ ! -e "$T/curl.calls" ]
  rm "$LGDIR/$LG_BUILD/build-patches"
  run build_client
  assert_success
  assert [ -e "$T/curl.calls" ]
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-stamp")" "$LG_BUILD"
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" "$(patches_id)"
  # A stale patch id rebuilds the client too (from the cached source).
  echo stale >"$LGDIR/$LG_BUILD/build-patches"
  rm "$T/cmake.calls"
  run build_client
  assert_success
  assert [ -e "$T/cmake.calls" ]
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" "$(patches_id)"
  # Current patches on a binary that reports another build rebuild it.
  printf '#!/bin/sh\necho "00:00:00.000 [I] main.c:4303 | main | Looking Glass (B7-1-deadbeef)" >&2\n' \
    >"$LGDIR/$LG_BUILD/bin/looking-glass-client"
  rm "$T/cmake.calls"
  run build_client
  assert_success
  assert [ -e "$T/cmake.calls" ]
  assert_equal "$(client_version "$LGDIR/$LG_BUILD/bin/looking-glass-client")" "$LG_BUILD"
}

@test "build_client: a failed update keeps the working client and its old identity" {
  local case sum
  for case in patch configure; do
    lg_source
    rm -f "$T/configure-fails"
    rm -rf "${LGDIR:?}"
    fake_build "$LG_BUILD"
    echo "$LG_BUILD" >"$LGDIR/$LG_BUILD/build-stamp"
    echo stale >"$LGDIR/$LG_BUILD/build-patches"
    sum=$(sha256sum <"$LGDIR/$LG_BUILD/bin/looking-glass-client")
    case $case in
      patch)
        sed -i 's#+++ patched/client/lanai-patched.txt#+++ patched/client#' \
          "$T/fixture-patches/0001-fixture.patch"
        ;;
      configure) touch "$T/configure-fails" ;;
    esac
    run build_client
    assert_failure
    assert_equal "$(sha256sum <"$LGDIR/$LG_BUILD/bin/looking-glass-client")" "$sum"
    assert_equal "$(<"$LGDIR/$LG_BUILD/build-stamp")" "$LG_BUILD"
    assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" stale
    run build_patches_current
    assert_failure
    rm -rf "${T:?}/src" "$T/patchdiff" "$T/fixture-patches"
  done
}

@test "build_client: the new build has both stamps before it replaces the old one" {
  lg_source
  # mv logs what the .partial folder holds when it moves into place.
  shim mv 'for a; do [[ $a != *.partial ]] || ls "$a" >"$T/partial.ls"; done
exec /usr/bin/mv "$@"'
  fake_build "$LG_BUILD"
  run build_client
  assert_success
  run cat "$T/partial.ls"
  assert_line build-stamp
  assert_line build-patches
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" "$(patches_id)"
}

# Spec requirement 4: a stop at any install step leaves the old client or
# the new one, complete. SIGKILL runs no trap, as at a power loss.
@test "build_client: a stop at each install step leaves a client that opens" {
  local step old bin=$LGDIR/$LG_BUILD/bin/looking-glass-client
  for step in installing installed stamped synced swapped committed cleaned; do
    rm -rf "${LGDIR:?}" "${T:?}/src" "$T/patchdiff" "$T/fixture-patches" "$XDG_CACHE_HOME/lanai"
    lg_source
    fake_build "$LG_BUILD"
    echo '# the old build' >>"$bin"
    echo "$LG_BUILD" >"$LGDIR/$LG_BUILD/build-stamp"
    echo stale >"$LGDIR/$LG_BUILD/build-patches"
    old=$(sha256sum <"$bin")
    STOP=$step
    build_step() { [[ $1 != "$STOP" ]] || kill -KILL "$BASHPID"; }
    run build_client
    assert_failure
    [[ -x $bin ]] || fail "no client is left after a stop at $step"
    assert_equal "$(client_version "$bin")" "$LG_BUILD"
    case $step in
      installing | installed | stamped | synced)
        assert_equal "$(sha256sum <"$bin")" "$old"
        assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" stale
        run build_patches_current
        assert_failure
        ;;
      *)
        [[ $(sha256sum <"$bin") != "$old" ]] || fail "the old binary is still in place after $step"
        assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" "$(patches_id)"
        build_patches_current
        ;;
    esac
    build_step() { :; }
    run build_client
    assert_success
    assert [ ! -e "$LGDIR/$LG_BUILD.partial" ]
    build_patches_current
  done
}

@test "build_client: the new tree is on disk before the swap, and the swap after" {
  local synced swap after
  lg_source
  shim sync 'echo "sync $*" >>"$T/order"; exec /usr/bin/sync "$@"'
  shim mv 'echo "mv $*" >>"$T/order"; exec /usr/bin/mv "$@"'
  # A first install has nothing to exchange with.
  run build_client
  assert_success
  run grep -c -- --exchange "$T/order"
  assert_output 0
  swap=$(grep -n -m1 -F -- "mv -T -- $LGDIR/$LG_BUILD.partial $LGDIR/$LG_BUILD" "$T/order" | cut -d: -f1)
  synced=$(grep -n -m1 -F -- "sync -- $LGDIR/$LG_BUILD.partial" "$T/order" | cut -d: -f1)
  after=$(grep -n -F -x -- "sync -- $LGDIR" "$T/order" | tail -n 1 | cut -d: -f1)
  ((synced < swap && swap < after)) || fail "order: $(cat "$T/order")"
  # An update exchanges the two trees in one rename.
  echo stale >"$LGDIR/$LG_BUILD/build-patches"
  rm "$T/order"
  run build_client
  assert_success
  swap=$(grep -n -m1 -F -- "mv --exchange -T -- $LGDIR/$LG_BUILD.partial $LGDIR/$LG_BUILD" "$T/order" | cut -d: -f1)
  synced=$(grep -n -m1 -F -- "sync -- $LGDIR/$LG_BUILD.partial" "$T/order" | cut -d: -f1)
  after=$(grep -n -F -x -- "sync -- $LGDIR" "$T/order" | tail -n 1 | cut -d: -f1)
  ((synced < swap && swap < after)) || fail "order: $(cat "$T/order")"
  run grep -F -- "sync -- $LGDIR/$LG_BUILD.partial" "$T/order"
  assert_output --partial "$LGDIR/$LG_BUILD.partial/bin/looking-glass-client"
  assert_output --partial "$LGDIR/$LG_BUILD.partial/build-patches"
  assert [ ! -e "$LGDIR/$LG_BUILD.partial" ]
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" "$(patches_id)"
}

@test "build_client: a failed sync after the swap keeps the old client beside the new one" {
  lg_source
  run build_client
  assert_success
  echo stale >"$LGDIR/$LG_BUILD/build-patches"
  echo old >"$LGDIR/$LG_BUILD/marker"
  # Only the sync of the parent folder, after the swap, fails.
  shim sync "[[ \"\$*\" != \"-- $LGDIR\" ]] || { echo 'sync: I/O error' >&2; exit 1; }
exec /usr/bin/sync \"\$@\""
  run build_client
  assert_failure
  # The swap took place, and the old tree stays until the swap is on disk.
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" "$(patches_id)"
  assert_equal "$(<"$LGDIR/$LG_BUILD.partial/marker")" old
  run cat "$(state_dir)/build-client.log"
  assert_output --partial "cannot write the swap to disk"
}

@test "build_client: a filesystem that refuses the exchange keeps the old client" {
  local sum bin=$LGDIR/$LG_BUILD/bin/looking-glass-client
  lg_source
  shim mv 'for a; do [[ $a != --exchange ]] || { echo "mv: not supported" >&2; exit 1; }; done
exec /usr/bin/mv "$@"'
  fake_build "$LG_BUILD"
  echo '# the old build' >>"$bin"
  echo "$LG_BUILD" >"$LGDIR/$LG_BUILD/build-stamp"
  echo stale >"$LGDIR/$LG_BUILD/build-patches"
  sum=$(sha256sum <"$bin")
  run build_client
  assert_failure
  assert_output --partial "cannot install into $LGDIR/$LG_BUILD"
  assert_equal "$(sha256sum <"$bin")" "$sum"
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-stamp")" "$LG_BUILD"
  assert_equal "$(<"$LGDIR/$LG_BUILD/build-patches")" stale
}

@test "build_client: an unapplied fixture patch fails before installation and cleans its work" {
  lg_source
  sed -i 's#+++ patched/client/lanai-patched.txt#+++ patched/client#' \
    "$T/fixture-patches/0001-fixture.patch"
  run build_client
  assert_failure
  assert_output --partial 'does not apply exactly'
  assert_output --partial '0001-fixture.patch'
  assert [ ! -e "$LGDIR/$LG_BUILD.partial" ]
  assert [ ! -e "$XDG_CACHE_HOME/lanai/build-$LG_BUILD" ]
}

@test "build_client: an empty patch fails with its name, though GNU patch takes it" {
  lg_source
  : >"$T/fixture-patches/0002-empty.patch"
  run patch -d "$T/src/looking-glass-$LG_BUILD" -p1 --dry-run --batch -i "$T/fixture-patches/0002-empty.patch"
  assert_success
  run --separate-stderr build_client
  assert_failure
  assert_output "the Lanai patch 0002-empty.patch does not apply exactly to Looking Glass $LG_BUILD; see $S/build-client.log"
  run tail -n 1 "$S/build-client.log"
  assert_output "the Lanai patch 0002-empty.patch does not apply exactly to Looking Glass $LG_BUILD; see $S/build-client.log"
  assert [ ! -e "$LGDIR/$LG_BUILD" ]
}

@test "build_client: no patches is an error that stamps nothing, even for an installed client" {
  lg_source
  LANAI_PATCHES=$T/no-patches
  mkdir -p "$LANAI_PATCHES"
  run build_client
  assert_failure
  assert_output "Lanai's Looking Glass patches are missing from $T/no-patches; reinstall Lanai"
  assert [ ! -e "$T/curl.calls" ]
  assert [ ! -e "$LGDIR/$LG_BUILD/build-stamp" ]
  assert [ ! -e "$LGDIR/$LG_BUILD/build-patches" ]

  # An installed client whose build-patches holds the empty list's id is
  # not taken as current either.
  fake_build "$LG_BUILD"
  patches_id >"$LGDIR/$LG_BUILD/build-patches"
  run build_client
  assert_failure
  assert_output --partial "patches are missing"
  assert [ ! -e "$LGDIR/$LG_BUILD/build-stamp" ]
}

@test "build_client.log: exact patch output and configure output both survive" {
  lg_source
  run build_client
  assert_success
  assert [ -s "$S/build-client.log" ]
  assert [ -f "$T/src/looking-glass-$LG_BUILD/client/CMakeLists.txt" ]
  run grep -F 'lanai-patched.txt' "$S/build-client.log"
  assert_success
  run grep -F 'features have been enabled:' "$S/build-client.log"
  assert_success
  # With two patches, both patches' apply lines stay in the log.
  rm -rf "${LGDIR:?}"
  mkdir -p "$T/patchdiff/patched2/client"
  cp -a "$T/patchdiff/patched/." "$T/patchdiff/patched2/"
  echo second >"$T/patchdiff/patched2/client/lanai-second.txt"
  (cd "$T/patchdiff" && diff -Naur patched patched2) \
    >"$T/fixture-patches/0002-second.patch" || [[ $? == 1 ]]
  run build_client
  assert_success
  run grep -F 'lanai-patched.txt' "$S/build-client.log"
  assert_success
  run grep -F 'lanai-second.txt' "$S/build-client.log"
  assert_success
}

@test "build_client.log: every failure leaves its reason and nothing from an older build" {
  local case reason
  # patchid stubs patches_id for the rest of the loop, so it comes last.
  for case in patches download unpack submodule offset configure usb build install version stamp patchid; do
    lg_source
    rm -rf "${LGDIR:?}" "$XDG_CACHE_HOME/lanai" "$T"/{curl,configure,build,install}-fails "$T/no-usb" "$T/client-version"
    mkdir -p "$S"
    echo "older build output" >"$S/build-client.log"
    case $case in
      patches) LANAI_PATCHES=$T/no-patches ;;
      download) touch "$T/curl-fails" ;;
      unpack) echo "not a tarball" >"$T/lg.tar.gz"; LG_SOURCE_SHA=$(sha256sum "$T/lg.tar.gz" | cut -d' ' -f1) ;;
      submodule)
        rm -rf "${T:?}/src/looking-glass-$LG_BUILD/${LG_SUBMODULES[0]}"
        tar -czf "$T/lg.tar.gz" -C "$T/src" "looking-glass-$LG_BUILD"
        LG_SOURCE_SHA=$(sha256sum "$T/lg.tar.gz" | cut -d' ' -f1)
        ;;
      offset)
        # The patch applies one line lower: GNU patch takes it with an
        # offset and leaves only its Hunk line in the log.
        printf 'a\nb\nc\n' >"$T/patchdiff/original/client/lanai-patched.txt"
        printf 'a\nB\nc\n' >"$T/patchdiff/patched/client/lanai-patched.txt"
        (cd "$T/patchdiff" && diff -Naur original patched) \
          >"$T/fixture-patches/0001-fixture.patch" || [[ $? == 1 ]]
        printf 'extra\na\nb\nc\n' >"$T/src/looking-glass-$LG_BUILD/client/lanai-patched.txt"
        tar -czf "$T/lg.tar.gz" -C "$T/src" "looking-glass-$LG_BUILD"
        LG_SOURCE_SHA=$(sha256sum "$T/lg.tar.gz" | cut -d' ' -f1)
        ;;
      configure) touch "$T/configure-fails" ;;
      usb) touch "$T/no-usb" ;;
      build) touch "$T/build-fails" ;;
      install) touch "$T/install-fails" ;;
      version) echo B7-1-deadbeef >"$T/client-version" ;;
      # The quick path: a current client whose build stamp cannot be written.
      stamp)
        fake_build "$LG_BUILD"
        patches_id >"$LGDIR/$LG_BUILD/build-patches"
        mkdir "$LGDIR/$LG_BUILD/build-stamp"
        ;;
      patchid) patches_id() { return 1; } ;;
    esac
    run --separate-stderr build_client
    assert_failure
    reason=$output
    [[ -n $reason ]] || fail "$case: no reason printed"
    [[ $reason != *$'\n'* ]] || fail "$case: more than one line: $reason"
    run cat "$S/build-client.log"
    refute_output --partial "older build output"
    assert_output --partial "$reason"
    rm -rf "${T:?}/src" "$T/patchdiff" "$T/fixture-patches"
  done
}

@test "build_client: a failure with no other message still says why" {
  lg_source
  # The build log is a folder, so the build cannot start it afresh.
  mkdir -p "$S/build-client.log"
  run --separate-stderr build_client
  assert_failure
  assert_output --partial "$S/build-client.log"
  rmdir "$S/build-client.log"
  # The work folder cannot be made.
  mkdir -p "$XDG_CACHE_HOME/lanai/downloads"
  chmod 555 "$XDG_CACHE_HOME/lanai"
  run --separate-stderr build_client
  chmod 755 "$XDG_CACHE_HOME/lanai"
  assert_failure
  assert_output --partial "$XDG_CACHE_HOME/lanai/build-$LG_BUILD"
  run cat "$S/build-client.log"
  assert_output --partial "$XDG_CACHE_HOME/lanai/build-$LG_BUILD"
  assert [ ! -e "$T/cmake.calls" ]
}

@test "build_client: a wrong checksum deletes the download and builds nothing" {
  lg_source
  LG_SOURCE_SHA=0000000000000000000000000000000000000000000000000000000000000000
  run build_client
  assert_failure
  assert_output --partial "SHA-256"
  assert [ ! -e "$XDG_CACHE_HOME/lanai/downloads/looking-glass-$LG_BUILD-source.tar.gz" ]
  assert [ ! -e "$T/cmake.calls" ]
  assert [ ! -e "$LGDIR/$LG_BUILD" ]
}

@test "build_client: an empty or missing submodule folder stops it before the build" {
  lg_source
  local d=${LG_SUBMODULES[2]}
  rm -rf "$T/src/looking-glass-$LG_BUILD/$d"
  mkdir -p "$T/src/looking-glass-$LG_BUILD/$d"
  tar -czf "$T/lg.tar.gz" -C "$T/src" "looking-glass-$LG_BUILD"
  LG_SOURCE_SHA=$(sha256sum "$T/lg.tar.gz" | cut -d' ' -f1)
  run build_client
  assert_failure
  assert_output --partial "$d"
  assert [ ! -e "$T/cmake.calls" ]
  rm -rf "${T:?}/src/looking-glass-$LG_BUILD/$d"
  tar -czf "$T/lg.tar.gz" -C "$T/src" "looking-glass-$LG_BUILD"
  LG_SOURCE_SHA=$(sha256sum "$T/lg.tar.gz" | cut -d' ' -f1)
  run build_client
  assert_failure
  assert_output --partial "$d"
  assert [ ! -e "$LGDIR/$LG_BUILD" ]
  # A symlink to a populated folder in the tree is not the submodule's tree.
  ln -s ../client "$T/src/looking-glass-$LG_BUILD/$d"
  tar -czf "$T/lg.tar.gz" -C "$T/src" "looking-glass-$LG_BUILD"
  LG_SOURCE_SHA=$(sha256sum "$T/lg.tar.gz" | cut -d' ' -f1)
  run build_client
  assert_failure
  assert_output --partial "$d"
  assert [ ! -e "$T/cmake.calls" ]
}

@test "build_client: a cached tarball that no longer matches the pin is fetched again" {
  lg_source
  local dl=$XDG_CACHE_HOME/lanai/downloads/looking-glass-$LG_BUILD-source.tar.gz
  mkdir -p "${dl%/*}"
  echo tampered >"$dl"
  run build_client
  assert_success
  assert [ -e "$T/curl.calls" ]
  verify_sha256 "$dl" "$LG_SOURCE_SHA"
  # A cached file that matches is used as is.
  rm "$T/curl.calls" "$T/cmake.calls"
  rm -rf "${LGDIR:?}/$LG_BUILD"
  run build_client
  assert_success
  assert [ ! -e "$T/curl.calls" ]
}

@test "build_client: fails when cmake disables USB audio, and installs nothing" {
  lg_source
  touch "$T/no-usb"
  run build_client
  assert_failure
  assert_output --partial "USB audio"
  assert [ ! -e "$LGDIR/$LG_BUILD" ]
}

@test "build_client: a binary that reports another version is not installed" {
  lg_source
  echo B7-1-deadbeef >"$T/client-version"
  run build_client
  assert_failure
  assert [ ! -e "$LGDIR/$LG_BUILD" ]
  assert [ ! -e "$LGDIR/$LG_BUILD.partial" ]
}

@test "build_client: a failed download leaves no partial file and builds nothing" {
  lg_source
  touch "$T/curl-fails"
  run build_client
  assert_failure
  assert_output --partial "could not download"
  run find "$XDG_CACHE_HOME/lanai/downloads" -type f
  assert_output ""
  assert [ ! -e "$T/cmake.calls" ]
}

@test "build_client: a failed configure stops it" {
  lg_source
  touch "$T/configure-fails"
  run build_client
  assert_failure
  assert_output --partial "could not configure"
  assert [ ! -e "$LGDIR/$LG_BUILD" ]
  run grep -c -- --build "$T/cmake.calls"
  assert_output 0
}

@test "build_client: a leftover .partial folder from a crash is not installed with it" {
  lg_source
  mkdir -p "$LGDIR/$LG_BUILD.partial"
  echo junk >"$LGDIR/$LG_BUILD.partial/junk"
  run build_client
  assert_success
  assert [ ! -e "$LGDIR/$LG_BUILD/junk" ]
  assert [ ! -e "$LGDIR/$LG_BUILD.partial" ]
}

@test "build_client: keeps older builds until the guest's IDD matches the pin" {
  lg_source
  fake_build B7-801-1a2b3c4d
  guest_version_set B7-801-g1a2b3c4d5e
  run build_client
  assert_success
  assert [ -x "$LGDIR/B7-801-1a2b3c4d/bin/looking-glass-client" ]
  guest_version_set B7-826-g236efcb155
  run build_client
  assert_success
  assert [ ! -e "$LGDIR/B7-801-1a2b3c4d" ]
  assert [ -x "$LGDIR/$LG_BUILD/bin/looking-glass-client" ]
}

@test "usb_audio_enabled: reads cmake's feature summary, not a stray mention" {
  usb_audio_enabled "$FIX/cmake-features.txt"
  grep -v ENABLE_USB_AUDIO "$FIX/cmake-features.txt" >"$T/log"
  printf ' * ENABLE_USB_AUDIO, USB audio support.\n' >>"$T/log"
  run usb_audio_enabled "$T/log"
  assert_failure
}

@test "lanai build-client: prints one JSON object with the installed client" {
  # bin/lanai reads the real pins, so this uses an installed build (the
  # functions above cover the build itself).
  fake_build "$LG_BUILD"
  patches_id >"$LGDIR/$LG_BUILD/build-patches"
  lanai_run build-client
  assert_success
  assert_equal "$(field client)" "$LGDIR/$LG_BUILD/bin/looking-glass-client"
  assert_equal "$(field build)" "$LG_BUILD"
  # A running client keeps its open binary, so the last word is to reopen.
  assert_equal "$(field message)" 'The Windows window is updated. If the Windows window is open, close it and open it again.'
}

@test "lanai build-client: a failed build's next step names its build log, not setup" {
  build_client() { echo "the client did not build; see $S/build-client.log"; return 1; }
  run --separate-stderr cmd_build_client
  assert_failure
  JSON=$output
  assert_equal "$(field message)" "The Windows window was not updated: the client did not build; see $S/build-client.log"
  assert_equal "$(field next)" "check the Windows window build log, $S/build-client.log, then run lanai build-client again"
  assert_equal "$(field reason)" null
}

@test "lanai build-client: missing patches say to reinstall Lanai" {
  LANAI_PATCHES=$T/no-patches
  run --separate-stderr cmd_build_client
  assert_failure
  JSON=$output
  assert_equal "$(field message)" "The Windows window was not updated: Lanai's Looking Glass patches are missing from $T/no-patches; reinstall Lanai"
  assert_equal "$(field next)" "reinstall Lanai"
}

@test "lanai build-client: refuses while another build runs" {
  fake_build "$LG_BUILD"
  mkdir -p "$S"
  flock "$S/build.lock" bash -c 'touch "$1"; exec sleep 30' _ "$T/locked" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/locked"
  lanai_run build-client
  assert_failure
  assert_equal "$(field reason)" build-busy
  assert_equal "$(field message)" "Another build of the Windows window is running."
}

@test "build_client_locked: waits out a shared probe" {
  mkdir -p "$S"
  : >"$S/build.lock"
  flock -s "$S/build.lock" bash -c 'touch "$1"; exec sleep 0.3' _ "$T/probed" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/probed"
  build_client() { echo built; }
  run build_client_locked
  assert_success
  assert_output built
}

@test "lock_held: true only for an exclusive holder" {
  run lock_held "$S/build.lock"
  assert_failure
  assert [ ! -e "$S/build.lock" ]
  mkdir -p "$S"
  : >"$S/build.lock"
  run lock_held "$S/build.lock"
  assert_failure
  flock "$S/build.lock" bash -c 'touch "$1"; exec sleep 30' _ "$T/exclusive" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/exclusive"
  run lock_held "$S/build.lock"
  assert_success
  stop_bg
  flock -s "$S/build.lock" bash -c 'touch "$1"; exec sleep 30' _ "$T/shared" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$T/shared"
  run lock_held "$S/build.lock"
  assert_failure
}

# --- lanai setup-host (spec 7; the one sudo, in the panel's terminal) ---

# pacman: -T (deptest, which honours provides) prints each argument not
# listed in $T/installed and exits 127 when it printed any, as pacman does.
host_shims() {
  shim pacman 'echo "$*" >>"$T/pacman.calls"
[[ $1 == -T ]] || exit 0
shift
[[ $1 != -- ]] || shift
rc=0
for p; do grep -qxF -- "$p" "$T/installed" 2>/dev/null || { echo "$p"; rc=127; }; done
exit $rc'
  shim sudo 'echo "$*" >>"$T/sudo.calls"; echo "sudo ran here"
exit "$(cat "$T/sudo-rc" 2>/dev/null || echo 0)"'
  shim omarchy 'echo "$*" >>"$T/omarchy.calls"'
}

@test "lanai setup-host: with every package installed, it opens no terminal" {
  host_shims
  printf '%s\n' "${LANAI_HOST_PACKAGES[@]}" >"$T/installed"
  lanai_run setup-host
  assert_success
  assert_equal "$(field missing)" "[]"
  assert_equal "$(field command)" ""
  sleep 0.5
  assert [ ! -e "$T/omarchy.calls" ]
  assert [ ! -e "$T/sudo.calls" ]
}

@test "host_packages_missing: a pacman that is not there counts every package missing" {
  # bash's own "command not found" is exit 127 with nothing on stdout, the
  # same code pacman -T uses for missing packages.
  shim pacman 'exit 127'
  PATH=$T/shims:$PATH run host_packages_missing
  assert_success
  assert_equal "$output" "$(printf '%s\n' "${LANAI_HOST_PACKAGES[@]}")"
}

@test "lanai setup-host: opens the panel's terminal for the install and never runs sudo itself" {
  host_shims
  printf '%s\n' "${LANAI_HOST_PACKAGES[@]}" | grep -v -x -e cmake -e passt >"$T/installed"
  lanai_run setup-host
  assert_success
  run jq -r '.missing | join(" ")' <<<"$JSON"
  assert_output "passt cmake"
  # Only what is missing: a package provided by another (jq-git for jq)
  # counts as installed, and is never offered for replacement.
  assert_equal "$(field command)" "sudo pacman -S --needed passt cmake"
  wait_for_file "$T/omarchy.calls"
  run cat "$T/omarchy.calls"
  assert_output "launch terminal -- $REPO/bin/lanai-setup-host"
  assert [ ! -e "$T/sudo.calls" ]
  # Lanai cannot see the window, so it does not claim one opened, and it
  # names the script to run by hand.
  run field message
  assert_output --partial "should open"
  refute_output --partial "opened"
  assert_output --partial "$REPO/bin/lanai-setup-host"
}

@test "lanai setup-host: fails when the terminal cannot be launched" {
  host_shims
  printf '%s\n' "${LANAI_HOST_PACKAGES[@]}" | grep -v -x -e cmake >"$T/installed"
  shim setsid 'echo "$*" >>"$T/setsid.calls"; exit 1'
  lanai_run setup-host
  assert_failure
  assert_equal "$(field ok)" false
  run field next
  assert_output --partial "$REPO/bin/lanai-setup-host"
  assert [ -e "$T/setsid.calls" ]
  assert [ ! -e "$T/sudo.calls" ]
}

@test "lanai-setup-host: refuses outside a terminal and runs nothing" {
  host_shims
  run --separate-stderr "$REPO/bin/lanai-setup-host" </dev/null
  assert_failure
  [[ $stderr == *"terminal"* ]] || fail "no reason: $stderr"
  assert [ ! -e "$T/sudo.calls" ]
}

@test "lanai-setup-host: in a terminal, prints the exact command, then runs it" {
  host_shims
  run script -q -e -c "$REPO/bin/lanai-setup-host" /dev/null <<<""
  assert_success
  local want="sudo pacman -S --needed ${LANAI_HOST_PACKAGES[*]}"
  output=${output//$'\r'/}
  assert_output --partial "$want"
  assert_equal "$(cat "$T/sudo.calls")" "pacman -S --needed ${LANAI_HOST_PACKAGES[*]}"
  # The command is on screen before sudo asks for the password.
  local printed ran
  printed=$(grep -n -F -- "$want" <<<"$output" | head -n1 | cut -d: -f1)
  ran=$(grep -n -F "sudo ran here" <<<"$output" | head -n1 | cut -d: -f1)
  [[ -n $printed && -n $ran ]] || fail "missing the command or the run: $output"
  ((printed < ran)) || fail "sudo ran before the command was printed"
}

@test "lanai-setup-host: installs only the missing packages, and nothing when none are" {
  host_shims
  printf '%s\n' "${LANAI_HOST_PACKAGES[@]}" | grep -v -x -e cmake -e passt >"$T/installed"
  run script -q -e -c "$REPO/bin/lanai-setup-host" /dev/null <<<""
  assert_success
  output=${output//$'\r'/}
  assert_output --partial "sudo pacman -S --needed passt cmake"
  assert_equal "$(cat "$T/sudo.calls")" "pacman -S --needed passt cmake"
  rm "$T/sudo.calls"
  printf '%s\n' "${LANAI_HOST_PACKAGES[@]}" >"$T/installed"
  run script -q -e -c "$REPO/bin/lanai-setup-host" /dev/null <<<""
  assert_success
  output=${output//$'\r'/}
  assert_output --partial "already installed"
  assert [ ! -e "$T/sudo.calls" ]
}

@test "lanai-setup-host: a failed install says so and exits non-zero" {
  host_shims
  echo 1 >"$T/sudo-rc"
  run script -q -e -c "$REPO/bin/lanai-setup-host" /dev/null <<<""
  assert_failure
  output=${output//$'\r'/}
  assert_output --partial "did not finish"
}
