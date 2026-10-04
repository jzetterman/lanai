#!/usr/bin/env bats
# Tests for Lanai's setup (plan phase 6): setup state that follows the disk,
# step 5's verdict, the setup boot's display, the setup media, and the
# resumable lanai setup. systemctl, systemd-run, hyprctl, ip, curl and
# pacman are PATH shims: nothing talks to the real user manager, starts a
# VM, opens a window or downloads anything. QMP and the guest agent are the
# fake servers in test/fixtures.
# shellcheck disable=SC2030,SC2031,SC2016,SC2034,SC2329

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  RUN=$XDG_RUNTIME_DIR/lanai
  S=$XDG_STATE_HOME/lanai
  export T
  # systemctl: log every call. `show` answers from $T/show-<unit> (default:
  # inactive), all of it or, with --value, the one property asked for.
  # `start lanai-vm.service` makes the VM unit active, as systemd would.
  # `reset-failed` clears its failed state and result.
  # With $T/no-manager, `show` fails like an unreachable user manager; the
  # verb named in $T/systemctl-fail fails.
  shim systemctl 'echo "$*" >>"$T/systemctl.calls"
unit=""
for a; do [[ $a != *.service ]] || unit=$a; done
show=$(cat "$T/show-$unit" 2>/dev/null || printf "ActiveState=inactive\nSubState=dead\nResult=success\nInvocationID=\nMainPID=0\n")
[[ ! -f $T/systemctl-fail || $2 != "$(<"$T/systemctl-fail")" ]] || exit 1
if [[ " $* " == *" show "* ]]; then
  [[ ! -e $T/no-manager ]] || exit 1
  if [[ " $* " == *" --value "* ]]; then
    for a; do [[ ${prev:-} == -p ]] && sed -n "s/^$a=//p" <<<"$show"; prev=$a; done
  else
    printf "%s\n" "$show"
  fi
fi
if [[ $2 == start && $unit == lanai-vm.service && ! -e $T/start-keeps-state ]]; then
  printf "ActiveState=active\nSubState=running\nResult=success\nInvocationID=inv-new\nMainPID=4000\n" >"$T/show-lanai-vm.service"
fi
if [[ $2 == reset-failed && $unit == lanai-vm.service ]]; then
  printf "ActiveState=inactive\nSubState=dead\nResult=success\n" >"$T/show-lanai-vm.service"
fi
exit 0'
  shim systemd-run 'printf "%s\n" "$@" >"$T/systemd-run.args"
printf "ActiveState=active\nMainPID=77\n" >"$T/show-lanai-client.service"'
  shim hyprctl 'echo "[{\"focused\": true, \"scale\": 1}]"'
  echo '[{"dst":"default","gateway":"192.168.1.1","dev":"wlan0","flags":[]}]' >"$T/route.json"
  shim ip 'cat "$T/route.json"'
  shim pacman 'exit 0'
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

# A finished install at the default location, VM settings and a share.
# STORE is the install's real path, as setup.json records it.
install() {
  make_install "$HOME/.windows"
  mkdir -p "$HOME/Windows" "$S" "$XDG_CONFIG_HOME/lanai"
  echo '{"memory_gib": 8, "cores": 4}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  STORE=$(realpath "$HOME/.windows")
}

# Write setup.json: setup_json <json>, with "location" filled in as STORE
# unless the JSON names one.
setup_json() {
  mkdir -p "$S"
  jq -c --arg l "$STORE" 'if has("location") then . else {location: $l} + . end' <<<"$1" >"$S/setup.json"
}

# Leave the markers of a run that started and ended: ran <invocation>
# <setup true|false> <clean|forced|panel|crash>. crash leaves no shutdown
# record or forced marker; panel is a clean guest shutdown that the
# panel's Shut down asked for.
ran() {
  mkdir -p "$S"
  echo "$1" >"$S/running"
  echo "$1" >"$S/started"
  jq -n -c --argjson s "$2" '{scale: 100, setup: $s}' >"$S/boot.json"
  case $3 in
    clean | panel) printf '{"invocation":"%s","guest":true,"reason":"guest-shutdown"}\n' "$1" >"$S/last-shutdown" ;;
    forced) : >"$S/forced" ;;
    crash) rm -f -- "$S/last-shutdown" "$S/forced" ;;
  esac
  [[ $3 != panel ]] || echo "$1 $EPOCHSECONDS" >"$S/stop-requested"
}

# --- setup state follows the disk ---

@test "setup_done: needs done and the current storage location" {
  install
  run setup_done
  assert_failure
  setup_json '{"done": true}'
  run setup_done
  assert_success
  # No location, or another one, is not this disk's setup.
  echo '{"done": true}' >"$S/setup.json"
  run setup_done
  assert_failure
  setup_json '{"location": "/elsewhere", "done": true}'
  run setup_done
  assert_failure
  setup_json '{"done": false}'
  run setup_done
  assert_failure
}

@test "setup_done: a symlinked storage path matches its recorded real path" {
  make_install "$T/real-win"
  ln -s "$T/real-win" "$HOME/.windows"
  STORE=$T/real-win
  setup_json '{"done": true}'
  run setup_done
  assert_success
}

@test "lanai start: refuses a disk that setup has not seen" {
  install
  setup_json '{"location": "/elsewhere", "done": true}'
  lanai_run start
  assert_failure
  assert_equal "$(field state)" setup-needed
}

@test "lanai start: setup reset between its check and the lock refuses and starts nothing" {
  install
  setup_json '{"done": true}'
  eval "$(declare -f lanai_flock | sed '1s/lanai_flock/lock_after_reset/')"
  lanai_flock() {
    # A restore finishes after cmd_start's check, before boot_vm's lock.
    (
      lock_after_reset || exit 1
      setup_reset
    ) || return 1
    lock_after_reset
  }
  run --separate-stderr cmd_start
  JSON=$output
  assert_failure
  assert_equal "$(field state)" setup-needed
  assert_equal "$(field message)" "Lanai setup has not finished."
  assert_equal "$(field next)" "open the Lanai panel and run setup"
  ! grep -q -- '--user start' "$T/systemctl.calls" || fail "the unit was started"
  assert [ ! -e "$S/boot.json" ]
  assert [ ! -e "$T/systemd-run.args" ]
}

@test "setup_follow: resets setup state for another location, or none, and removes guest-version" {
  install
  local json
  for json in '{"location": "/elsewhere", "done": true, "step5": true}' '{"done": true}'; do
    echo "$json" >"$S/setup.json"
    echo B7-801-1a2b3c4d >"$S/guest-version"
    run setup_follow "$STORE"
    assert_success
    assert_equal "$(jq -c . "$S/setup.json")" "$(jq -n -c --arg l "$STORE" '{location: $l}')"
    assert [ ! -e "$S/guest-version" ]
  done
  # A missing setup.json gets the location too.
  rm "$S/setup.json"
  run setup_follow "$STORE"
  assert_equal "$(jq -r .location "$S/setup.json")" "$STORE"
}

@test "setup_follow: keeps the state of the current location" {
  install
  setup_json '{"snapshot": "declined", "step5": true}'
  echo B7-801-1a2b3c4d >"$S/guest-version"
  run setup_follow "$STORE"
  assert_success
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  assert [ -e "$S/guest-version" ]
}

@test "setup_follow: a dangling or failing storage location resets nothing" {
  install
  setup_json '{"done": true}'
  echo B7-801-1a2b3c4d >"$S/guest-version"
  local before
  before=$(<"$S/setup.json")
  # An unmounted drive behind a symlink.
  ln -s "$T/unmounted/win" "$T/link"
  run setup_follow "$T/link"
  assert_equal "$(<"$S/setup.json")" "$before"
  assert [ -e "$S/guest-version" ]
  # A location that fails the adoption checks.
  mkdir -p "$T/other"
  echo junk >"$T/other/stray"
  run setup_follow "$T/other"
  assert_equal "$(<"$S/setup.json")" "$before"
  assert [ -e "$S/guest-version" ]
}

@test "setup_reset: records the previous run first, so its markers cannot mark step 5 on the new state" {
  install
  setup_json '{}'
  ran inv-1 true clean
  echo B7-801-1a2b3c4d >"$S/guest-version"
  echo '{"step":"6"}' >"$S/setup-reply.json"
  run setup_reset
  assert_success
  assert [ ! -e "$S/setup-reply.json" ]
  assert [ ! -e "$S/setup.json" ]
  assert [ ! -e "$S/guest-version" ]
  assert [ ! -e "$S/running" ]
  assert_equal "$(<"$S/last-run")" clean
  # The next setup state starts empty.
  run setup_follow "$STORE"
  assert_equal "$(jq -r '.step5 // "unset"' "$S/setup.json")" unset
}

# --- step 5's verdict ---

@test "record_previous_run: a clean setup boot sets step5" {
  install
  setup_json '{"snapshot": "declined"}'
  ran inv-1 true clean
  run record_previous_run
  assert_output clean
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  assert_equal "$(jq -r .snapshot "$S/setup.json")" declined
}

@test "record_previous_run: no step5 after a panel Shut down, a forced stop, or a clean normal boot" {
  install
  local how
  for how in "true panel" "true forced" "true crash" "false clean"; do
    setup_json '{"snapshot": "declined"}'
    # shellcheck disable=SC2086
    ran inv-1 $how
    run record_previous_run
    assert_equal "$(jq -r '.step5 // "unset"' "$S/setup.json")" unset
  done
}

@test "record_previous_run: a panel Shut down of an earlier run does not block step5" {
  install
  setup_json '{}'
  ran inv-2 true clean
  echo "inv-1 $EPOCHSECONDS" >"$S/stop-requested"
  run record_previous_run
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
}

@test "lanai setup: a storage change after a clean setup boot leaves step5 unset and no guest-version" {
  install
  setup_json '{"location": "/elsewhere", "snapshot": "declined", "step5": false}'
  ran inv-1 true clean
  echo B7-801-1a2b3c4d >"$S/guest-version"
  run --separate-stderr cmd_setup
  JSON=$output
  # Setup records the run, then follows the disk: the new location starts
  # at its snapshot offer.
  assert_equal "$(field step)" 3
  assert_equal "$(jq -c . "$S/setup.json")" "$(jq -n -c --arg l "$STORE" '{location: $l}')"
  assert [ ! -e "$S/guest-version" ]
  assert_equal "$(<"$S/last-run")" clean
}

# --- the setup boot's display ---

# Install a fake client build <name> that reports version <version> (default
# <name>) on --help, as the real one does on its first log line.
fake_build() {
  local bin=$XDG_DATA_HOME/lanai/looking-glass/$1/bin/looking-glass-client
  mkdir -p "${bin%/*}"
  printf '#!/usr/bin/env bash\necho "00:00:00.000 [I]              main.c:4303 | main                           | Looking Glass (%s)" >&2\n' \
    "${2:-$1}" >"$bin"
  chmod +x "$bin"
}

# Run boot_vm with bats' run and keep its JSON for field.
boot() {
  run --separate-stderr boot_vm "$@"
  JSON=$output
}

@test "setup boot: no record means QEMU's window and no client" {
  install
  setup_json '{"snapshot": "declined"}'
  export WAYLAND_DISPLAY=wayland-3
  boot true auto
  assert_success
  assert_equal "$(field window)" true
  assert_equal "$(jq -c . "$S/boot.json")" '{"scale":100,"setup":true,"window":true,"wayland_display":"wayland-3"}'
  # Step 5 has started and not ended.
  assert_equal "$(jq -r .step5 "$S/setup.json")" false
  assert [ ! -e "$T/systemd-run.args" ]
  # A client would show nothing, so open refuses.
  fake_build "$LG_BUILD"
  lanai_run open
  assert_failure
  run field message
  assert_output --partial "QEMU's window"
  assert [ ! -e "$T/systemd-run.args" ]
}

@test "setup boot: a record means no window, and lanai open starts the matching client" {
  install
  setup_json '{"snapshot": "declined"}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  fake_build "$LG_BUILD"
  fake_build B7-801-1a2b3c4d
  unset WAYLAND_DISPLAY
  boot true auto
  assert_success
  assert_equal "$(field window)" false
  assert_equal "$(field next)" "open the Windows window"
  assert_equal "$(jq -c . "$S/boot.json")" '{"scale":100,"setup":true,"window":false}'
  lanai_run open
  assert_success
  run tail -n 1 "$T/systemd-run.args"
  assert_output "$XDG_DATA_HOME/lanai/looking-glass/B7-801-1a2b3c4d/bin/looking-glass-client"
}

@test "setup boot: --window with a record forces the window and leaves the record unchanged" {
  install
  setup_json '{"snapshot": "declined"}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  export WAYLAND_DISPLAY=wayland-3
  boot true true
  assert_success
  assert_equal "$(field window)" true
  assert_equal "$(<"$S/guest-version")" B7-801-g1a2b3c4d5e
}

@test "setup boot: --no-window without a record forces the client" {
  install
  setup_json '{"snapshot": "declined"}'
  export WAYLAND_DISPLAY=wayland-3
  boot true false
  assert_success
  assert_equal "$(field window)" false
  assert_equal "$(jq -r .window "$S/boot.json")" false
}

@test "setup boot: a window boot without WAYLAND_DISPLAY refuses, and keeps the record" {
  install
  setup_json '{"snapshot": "declined"}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  unset WAYLAND_DISPLAY
  boot true true
  assert_failure
  run field message
  assert_output --partial WAYLAND_DISPLAY
  assert [ -e "$S/guest-version" ]
  ! grep -q -- '--user start' "$T/systemctl.calls" || fail "the unit was started"
  rm "$S/guest-version"
  boot true auto
  assert_failure
}

@test "setup boot: a changed location preserves setup state, refuses and starts nothing" {
  install
  setup_json '{"location": "/elsewhere", "snapshot": "declined", "step5": true}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  local before
  before=$(<"$S/setup.json")
  export WAYLAND_DISPLAY=wayland-3
  boot true auto
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(field message)" "Lanai setup changed while it was preparing Windows."
  assert_equal "$(field next)" "run setup again"
  assert_equal "$(<"$S/setup.json")" "$before"
  assert_equal "$(<"$S/guest-version")" B7-801-g1a2b3c4d5e
  assert [ ! -e "$S/boot.json" ]
  ! grep -q -- '--user start' "$T/systemctl.calls" || fail "a unit was started"
  assert [ ! -e "$T/systemd-run.args" ]
}

@test "setup boot: no valid snapshot decision refuses and starts nothing" {
  install
  export WAYLAND_DISPLAY=wayland-3
  local json
  for json in '{}' '{"snapshot": null}' '{"snapshot": "pending"}'; do
    setup_json "$json"
    boot true auto
    assert_failure
    assert_equal "$(field ok)" false
    assert_equal "$(field message)" "Lanai setup changed while it was preparing Windows."
    assert_equal "$(field next)" "run setup again"
    assert [ ! -e "$S/boot.json" ]
    ! grep -q -- '--user start' "$T/systemctl.calls" || fail "a unit was started"
    assert [ ! -e "$T/systemd-run.args" ]
  done
}

@test "a normal boot never shows QEMU's window" {
  install
  setup_json '{"done": true}'
  export WAYLAND_DISPLAY=wayland-3
  lanai_run start
  assert_success
  assert_equal "$(jq -c . "$S/boot.json")" '{"scale":100,"setup":false,"window":false}'
}

@test "lanai status: reports window and active" {
  install
  setup_json '{"snapshot": "declined"}'
  lanai_run status
  assert_equal "$(field active)" false
  assert_equal "$(field window)" false
  export WAYLAND_DISPLAY=wayland-3
  boot true auto
  assert_success
  lanai_run status
  assert_equal "$(field active)" true
  assert_equal "$(field window)" true
  # Once the unit stops, the window is gone, whatever boot.json says.
  unit_is lanai-vm.service inactive
  lanai_run status
  assert_equal "$(field active)" false
  assert_equal "$(field window)" false
  # A client boot.
  unit_is lanai-vm.service active
  echo '{"scale":100,"setup":true,"window":false}' >"$S/boot.json"
  lanai_run status
  assert_equal "$(field active)" true
  assert_equal "$(field window)" false
}

# --- the setup media (lanai setup-guest) ---

# Make stand-ins for the pinned guest files in $T/src, point the pins at
# them (https://pins.test/<file>) with their real SHA-256, and shim curl to
# serve them by name. The ISO stand-in is a tar archive (bsdtar reads
# either) with the viofs driver for several Windows versions.
pinned_files() {
  local d=$T/src/tree
  mkdir -p "$d/idd" "$d/iso/viofs/w11/amd64" "$d/iso/viofs/w10/amd64" "$d/iso/NetKVM/w11/amd64"
  echo idd-exe >"$d/idd/looking-glass-idd-setup.exe"
  echo readme >"$d/idd/README.txt"
  bsdtar -a -cf "$T/src/idd.zip" -C "$d/idd" looking-glass-idd-setup.exe README.txt
  echo inf >"$d/iso/viofs/w11/amd64/viofs.inf"
  echo exe >"$d/iso/viofs/w11/amd64/virtiofs.exe"
  echo old >"$d/iso/viofs/w10/amd64/viofs.inf"
  echo net >"$d/iso/NetKVM/w11/amd64/netkvm.inf"
  bsdtar -cf "$T/src/virtio-win.iso" -C "$d/iso" viofs NetKVM
  echo vdagent >"$T/src/vdagent.msi"
  echo qga >"$T/src/qemu-ga.msi"
  echo winfsp >"$T/src/winfsp.msi"
  sum() { sha256sum "$T/src/$1" | cut -d' ' -f1; }
  LG_IDD_URL=https://pins.test/idd.zip LG_IDD_SHA=$(sum idd.zip)
  VDAGENT_URL=https://pins.test/vdagent.msi VDAGENT_SHA=$(sum vdagent.msi)
  QEMU_GA_URL=https://pins.test/qemu-ga.msi QEMU_GA_SHA=$(sum qemu-ga.msi)
  WINFSP_URL=https://pins.test/winfsp.msi WINFSP_SHA=$(sum winfsp.msi)
  VIRTIO_WIN_URL=https://pins.test/virtio-win.iso VIRTIO_WIN_SHA=$(sum virtio-win.iso)
  shim curl 'url=${!#}
while (($#)); do [[ $1 != -o ]] || out=$2; shift; done
echo "$url" >>"$T/curl.calls"
cp "$T/src/${url##*/}" "$out"'
}

# Run cmd_setup_guest in this shell (the pins are overridden here) and keep
# its JSON for field.
setup_guest_run() {
  run --separate-stderr cmd_setup_guest "$@"
  JSON=$output
}

@test "lanai setup-guest: verified media with only viofs\\w11\\amd64 from the ISO, then the setup boot" {
  install
  setup_json '{"snapshot": "declined"}'
  pinned_files
  export WAYLAND_DISPLAY=wayland-3
  setup_guest_run
  assert_success
  assert_equal "$(field window)" true
  local media=$S/setup-media
  run bash -c 'cd "$1" && find . -mindepth 1 | LC_ALL=C sort' _ "$media"
  assert_output "$(printf '%s\n' ./lanai-lock.cmd ./lanai-scale.ps1 ./looking-glass-idd-setup.exe \
    ./qemu-ga.msi ./setup.cmd ./spice-vdagent.msi ./viofs ./viofs/w11 ./viofs/w11/amd64 \
    ./viofs/w11/amd64/viofs.inf ./viofs/w11/amd64/virtiofs.exe ./winfsp.msi)"
  cmp "$media/setup.cmd" "$REPO/guest/setup.cmd"
  cmp "$media/lanai-lock.cmd" "$REPO/guest/lanai-lock.cmd"
  cmp "$media/spice-vdagent.msi" "$T/src/vdagent.msi"
  # Every file setup.cmd calls by %~dp0 is on the media.
  local f
  while IFS= read -r f; do
    f=${f#%~dp0}
    [[ -z $f ]] || [[ -f $media/${f//\\//} ]] || fail "setup.cmd calls $f, which the media lack"
  done < <(grep -oE '%~dp0[A-Za-z][A-Za-z0-9._\\-]*' "$REPO/guest/setup.cmd" | sort -u)
  # The downloads stay in the cache, outside the media.
  assert [ -f "$XDG_CACHE_HOME/lanai/downloads/virtio-win-$VIRTIO_WIN_VERSION.iso" ]
  assert [ ! -e "$S/setup-media.partial" ]
  assert_equal "$(jq -r .setup "$S/boot.json")" true
  grep -q -- '--user start lanai-vm.service' "$T/systemctl.calls" || fail "the unit did not start"
}

@test "lanai setup-guest: a wrong checksum for any pinned file stops the build, with no unverified file in the media" {
  install
  setup_json '{"snapshot": "declined"}'
  pinned_files
  export WAYLAND_DISPLAY=wayland-3
  local pin good
  for pin in LG_IDD_SHA VDAGENT_SHA QEMU_GA_SHA WINFSP_SHA VIRTIO_WIN_SHA; do
    rm -rf "$XDG_CACHE_HOME/lanai/downloads" "$S/setup-media"
    mkdir -p "$S/setup-media"
    echo stale >"$S/setup-media/qemu-ga.msi"
    good=${!pin}
    printf -v "$pin" '%064d' 0
    setup_guest_run
    assert_failure
    run field message
    assert_output --partial "SHA-256 mismatch"
    # No media at all, so nothing unverified can reach Windows.
    assert [ ! -e "$S/setup-media" ]
    assert [ ! -e "$S/setup-media.partial" ]
    printf -v "$pin" '%s' "$good"
  done
  ! grep -q -- '--user start' "$T/systemctl.calls" 2>/dev/null || fail "the unit was started"
}

@test "lanai setup-guest: refuses before step 3, and while Windows runs" {
  install
  pinned_files
  export WAYLAND_DISPLAY=wayland-3
  setup_guest_run
  assert_failure
  run field next
  assert_output --partial "lanai setup"
  assert [ ! -e "$T/curl.calls" ]
  echo '{}' >"$S/setup.json"
  setup_guest_run
  assert_failure
  assert [ ! -e "$T/curl.calls" ]
  # Also refuse a matching location without a snapshot decision.
  setup_json '{}'
  setup_guest_run
  assert_failure
  assert [ ! -e "$T/curl.calls" ]
  setup_json '{"snapshot": "declined"}'
  unit_is lanai-vm.service active
  mkdir -p "$S/setup-media"
  echo in-use >"$S/setup-media/setup.cmd"
  setup_guest_run
  assert_failure
  run field message
  assert_output --partial "running"
  assert_equal "$(<"$S/setup-media/setup.cmd")" in-use
}

@test "lanai setup-guest: --window and --no-window pass on; anything else is refused" {
  install
  setup_json '{"snapshot": "declined"}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  pinned_files
  export WAYLAND_DISPLAY=wayland-3
  setup_guest_run --bogus
  assert_failure
  setup_guest_run --window
  assert_success
  assert_equal "$(field window)" true
  assert_equal "$(<"$S/guest-version")" B7-801-g1a2b3c4d5e
  unit_is lanai-vm.service inactive
  setup_guest_run --no-window
  assert_success
  assert_equal "$(field window)" false
}

# --- lanai setup: the resumable steps ---

# Run cmd_setup in this shell (pins and stubs are overridden here) and keep
# its JSON for field.
setup_run() {
  run --separate-stderr cmd_setup "$@"
  JSON=$output
}

# An install that has passed steps 1 to 4: checks, packages, the snapshot
# offer (declined) and the pinned client. Pinned guest files are served.
through_step4() {
  install
  setup_json '{"snapshot": "declined"}'
  fake_build "$LG_BUILD"
  pinned_files
}

# Print client log <file> as lanai-client-exec leaves it: its start line
# (<age> seconds ago, default 5), then the client's output.
started_log() {
  echo "lanai: client started at $((EPOCHSECONDS - ${2:-5}))"
  cat "$1"
}

# The state after a step 5 setup boot ended: the unit is stopped, and the
# markers say how (clean, panel or forced), as ran does.
setup_boot_ended() {
  unit_is lanai-vm.service inactive
  ran inv-setup true "$1"
}

# A running step 6 boot: the unit is active with a normal boot, step5 is
# true, QMP and the guest agent answer (the agent with setup.cmd's
# allow-list), and the pinned client runs with client log <file> started
# <age> seconds ago (default 5). A fourth argument of no-servers lets a
# test supply direct responses instead of starting the socket servers.
step6_running() {
  through_step4
  setup_json '{"snapshot": "declined", "step5": true}'
  echo '{"scale":100,"setup":false,"window":false}' >"$S/boot.json"
  unit_is lanai-vm.service active
  unit_is lanai-client.service active MainPID=77
  [[ -d $RUN ]] || mkdir -m 700 "$RUN"
  started_log "$1" "${2:-5}" >"$RUN/client.log"
  rm -f "$RUN/qga-open-since" "$RUN/qga-closed-since" "$T/qga.log"
  # With <stamp-age>, the guest agent's port has been open that long.
  [[ -z ${3:-} ]] || echo "$((EPOCHSECONDS - $3))" >"$RUN/qga-open-since"
  conf FAKE_QGA_CMD=allowlist
  export FAKE_QGA_LOG=$T/qga.log
  [[ ${4:-} != no-servers ]] || return 0
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  serve "$RUN/qga.sock" "$FIX/fake-qga"
}

# A closed-port step 6 poll needs only QMP's chardev response, no sockets.
step6_closed() {
  step6_running "$1" "${2:-5}" "${3:-}" no-servers
  qmp_call() { echo '{"return":[{"label":"qga0","frontend-open":false}]}'; }
  qga_reply() { echo asked >>"$T/qga.log"; return 1; }
}

# Assert that the guest agent got a guest-set-time with the host's time in
# nanoseconds, within 5 s of now.
assert_set_time_now() {
  local ns
  ns=$(sed -n 's/^cmd .*"guest-set-time".*"time":\([0-9]*\).*/\1/p' "$T/qga.log" | tail -n 1)
  [[ $ns =~ ^[0-9]{19}$ ]] || fail "no guest-set-time with a nanosecond time: $(cat "$T/qga.log")"
  ((${ns:0:10} - EPOCHSECONDS <= 5 && EPOCHSECONDS - ${ns:0:10} <= 5)) || fail "guest-set-time $ns is not now"
}

@test "lanai setup: writes its reply to setup-reply.json too, for the panel's detached runs" {
  install
  lanai_run setup
  assert_failure
  assert_equal "$(field step)" 3
  assert_equal "$(<"$S/setup-reply.json")" "$JSON"
  assert [ ! -e "$S/setup-reply.json.tmp" ]
  # An option error is a reply too.
  lanai_run setup --bogus
  assert_equal "$(<"$S/setup-reply.json")" "$JSON"
}

@test "lanai setup: concurrent reply writes each publish JSON and leave no temporary file" {
  install
  # Hold both writers immediately before rename to force the collision.
  shim mv 'if [[ ${*: -1} == */setup-reply.json ]]; then
  echo "${*: -2:1}" >"$T/reply-source-$PPID"
  for ((i = 0; i < 100; i++)); do
    sources=("$T"/reply-source-*)
    ((${#sources[@]} == 2)) && break
    sleep 0.05
  done
  ((${#sources[@]} == 2)) || exit 1
fi
exec /usr/bin/mv "$@"'
  local first second
  cmd_setup --bogus >"$T/reply-first.json" 2>"$T/reply-first.err" &
  first=$!
  BG_PIDS+=("$first")
  cmd_setup --another >"$T/reply-second.json" 2>"$T/reply-second.err" &
  second=$!
  BG_PIDS+=("$second")
  local first_rc=0 second_rc=0
  wait "$first" || first_rc=$?
  wait "$second" || second_rc=$?
  assert_equal "$first_rc" 2
  assert_equal "$second_rc" 2
  assert [ ! -s "$T/reply-first.err" ]
  assert [ ! -s "$T/reply-second.err" ]
  run jq -e -s 'length == 1 and .[0].ok == false' "$S/setup-reply.json"
  assert_success
  local reply
  reply=$(<"$S/setup-reply.json")
  [[ $reply == "$(<"$T/reply-first.json")" || $reply == "$(<"$T/reply-second.json")" ]] ||
    fail "published reply is not either call's JSON"
  local -a temps
  shopt -s nullglob
  temps=("$S"/setup-reply.json.*)
  assert_equal "${#temps[@]}" 0
}

@test "lanai setup: a failed reply rename removes its temporary file" {
  install
  shim mv 'exit 1'
  setup_run --bogus
  assert_equal "$status" 2
  assert [ ! -e "$S/setup-reply.json" ]
  local -a temps
  shopt -s nullglob
  temps=("$S"/setup-reply.json.*)
  assert_equal "${#temps[@]}" 0
}

@test "lanai setup: a step that answers nothing still gives one JSON reply" {
  install
  setup_resume() { :; }
  setup_run
  assert_failure
  assert_equal "$(field ok)" false
  run field message
  assert_output --partial "no answer"
  assert_equal "$(<"$S/setup-reply.json")" "$JSON"
}

@test "lanai setup step 1: a failed check stops it, naming the problem" {
  install
  rm "$HOME/.windows/windows.boot"
  setup_run
  assert_failure
  assert_equal "$(field step)" 1
  run field message
  assert_output --partial "windows.boot is missing"
  make_install "$HOME/.windows"
  rmdir "$HOME/Windows"
  setup_run
  assert_equal "$(field step)" 1
  run field message
  assert_output --partial "does not exist"
  mkdir "$HOME/Windows"
  fake_proc 700 "$DOCKER_SCOPE" /usr/bin/qemu-system-x86_64 -name windows
  setup_run
  assert_equal "$(field step)" 1
  run field message
  assert_output --partial "omarchy-windows-vm"
  rm -rf "$T/proc/700"
  printf '/snap\n%s\n' "$STORE" >"$S/restore-in-progress"
  setup_run
  assert_equal "$(field step)" 1
  run field message
  assert_output --partial "restore did not finish"
}

@test "lanai setup step 2: missing host packages are named, with the command" {
  install
  shim pacman 'echo qemu-ui-gtk; echo passt; exit 127'
  setup_run
  assert_failure
  assert_equal "$(field step)" 2
  assert_equal "$(jq -c .missing <<<"$JSON")" '["qemu-ui-gtk","passt"]'
  assert_equal "$(field command)" "sudo pacman -S --needed qemu-ui-gtk passt"
  run field next
  assert_output --partial "lanai setup-host"
  # Setup state now follows this disk.
  assert_equal "$(jq -r .location "$S/setup.json")" "$STORE"
}

@test "lanai setup step 3: offers the snapshot before any boot; declining or a snapshot moves on" {
  install
  setup_run
  assert_failure
  assert_equal "$(field step)" 3
  run field next
  assert_output --partial "lanai snapshot"
  assert_output --partial "--no-snapshot"
  assert_equal "$(jq -r '.snapshot // "unset"' "$S/setup.json")" unset
  # Declined: recorded, and setup goes on (to step 4: no client yet).
  build_client() { echo "no network"; return 1; }
  setup_run --no-snapshot
  assert_equal "$(jq -r .snapshot "$S/setup.json")" declined
  assert_equal "$(field step)" 4
  # A snapshot of this location counts as taken.
  setup_json '{}'
  snapshot_list() { echo "$XDG_DATA_HOME/lanai/snapshots/20261001T000000Z"; }
  setup_run
  assert_equal "$(jq -r .snapshot "$S/setup.json")" taken
  assert_equal "$(field step)" 4
}

@test "lanai setup step 3: a snapshot decision that cannot be recorded stops setup" {
  install
  setup_set() { return 1; }
  build_client() { touch "$T/build-called"; return 1; }
  local decision
  for decision in taken declined; do
    setup_json '{}'
    snapshot_list() { [[ $decision != taken ]] || echo snapshot; }
    setup_run --no-snapshot
    assert_failure
    assert_equal "$(field ok)" false
    assert_equal "$(field step)" 3
    assert_equal "$(field message)" "Lanai cannot record its setup state."
    assert_equal "$(field next)" "run setup again"
    assert_equal "$(jq -r '.snapshot // "unset"' "$S/setup.json")" unset
    assert [ ! -e "$T/build-called" ]
    assert [ ! -e "$T/systemd-run.args" ]
  done
}

@test "lanai setup step 3a: an empty or missing windows.base gets dockur's name, once, and it says so" {
  install
  setup_json '{"snapshot": "declined"}'
  fake_build "$LG_BUILD"
  : >"$HOME/.windows/windows.base"
  setup_run
  assert_success
  assert_equal "$(field step)" 3a
  run field message
  assert_output --partial "win11x64.iso"
  assert_equal "$(<"$HOME/.windows/windows.base")" win11x64.iso
  rm "$HOME/.windows/windows.base"
  setup_run
  assert_equal "$(field step)" 3a
  assert_equal "$(<"$HOME/.windows/windows.base")" win11x64.iso
  # With a name in place, setup goes on.
  pinned_files
  setup_run
  refute [ "$(field step)" = 3a ]
}

@test "lanai setup step 4: builds the pinned client, then goes on to the setup boot" {
  install
  setup_json '{"snapshot": "declined"}'
  pinned_files
  export WAYLAND_DISPLAY=wayland-3
  build_client() { fake_build "$LG_BUILD"; echo "$XDG_DATA_HOME/lanai/looking-glass/$LG_BUILD/bin/looking-glass-client"; }
  setup_run
  assert_success
  assert_equal "$(field step)" 5
  assert_equal "$(field window)" true
  # A failed build stops at step 4 with its reason.
  rm -rf "$XDG_DATA_HOME/lanai/looking-glass"
  unit_is lanai-vm.service inactive
  build_client() { echo "cmake turned USB audio off"; return 1; }
  setup_run
  assert_failure
  assert_equal "$(field step)" 4
  run field message
  assert_output --partial "USB audio"
}

@test "lanai setup step 5: starts the setup boot, then reports it while it runs" {
  through_step4
  export WAYLAND_DISPLAY=wayland-3
  setup_run
  assert_success
  assert_equal "$(field step)" 5
  assert_equal "$(field window)" true
  assert [ -f "$S/setup-media/setup.cmd" ]
  assert_equal "$(jq -r .step5 "$S/setup.json")" false
  setup_run
  assert_success
  assert_equal "$(field step)" 5
  assert_equal "$(field active)" true
  run field message
  assert_output --partial "setup.cmd"
}

@test "lanai setup step 5: a clean shutdown of the setup boot goes on to step 6's boot with the pinned client" {
  through_step4
  setup_json '{"snapshot": "declined", "step5": false}'
  setup_boot_ended clean
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  fake_build B7-801-1a2b3c4d
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  assert_equal "$(jq -c . "$S/boot.json")" '{"scale":100,"setup":false,"window":false}'
  # The pinned client, not the build that matches the old record.
  run tail -n 1 "$T/systemd-run.args"
  assert_output "$XDG_DATA_HOME/lanai/looking-glass/$LG_BUILD/bin/looking-glass-client"
}

@test "lanai setup step 6: setup changed between resume and boot refuses and starts nothing" {
  # Simulate restore taking and releasing the lock before boot_vm takes it.
  eval "$(declare -f boot_vm | sed '1s/boot_vm/boot_after_reset/')"
  boot_vm() {
    (
      lanai_flock || exit 1
      setup_reset
      case $changed in
        location) setup_json '{"location": "/elsewhere", "step5": true}' ;;
        step5-false) setup_json '{"step5": false}' ;;
        step5-missing) setup_json '{}' ;;
      esac
    ) || return 1
    boot_after_reset "$@"
  }
  local changed
  for changed in reset location step5-false step5-missing; do
    through_step4
    setup_json '{"snapshot": "declined", "step5": true}'
    unit_is lanai-vm.service inactive
    : >"$T/systemctl.calls"
    setup_run
    assert_failure
    assert_equal "$(field step)" 6
    assert_equal "$(field message)" "Lanai setup changed while it was starting Windows."
    ! grep -q -- '--user start' "$T/systemctl.calls" || fail "the unit was started"
    assert [ ! -e "$S/boot.json" ]
    assert [ ! -e "$T/systemd-run.args" ]
  done
}

@test "lanai setup step 5: a panel Shut down or a forced stop did not finish it; the user picks the display" {
  through_step4
  export WAYLAND_DISPLAY=wayland-3
  local how
  for how in panel forced crash; do
    setup_json '{"snapshot": "declined", "step5": false}'
    setup_boot_ended "$how"
    : >"$T/systemctl.calls"
    setup_run
    assert_failure
    assert_equal "$(field step)" 5
    run field message
    assert_output --partial "did not finish"
    assert_equal "$(jq -c .choices <<<"$JSON")" '["--window","--no-window"]'
    ! grep -q -- '--user start' "$T/systemctl.calls" || fail "it booted without a choice"
  done
  setup_run --no-window
  assert_success
  assert_equal "$(field step)" 5
  assert_equal "$(field window)" false
}

@test "lanai setup step 5: a setup boot that never started says so, with the logs" {
  through_step4
  # QEMU never answered: a running marker without the started stamp, and a
  # failed unit.
  setup_json '{"snapshot": "declined", "step5": false}'
  echo '{"scale":100,"setup":true,"window":true}' >"$S/boot.json"
  echo inv-setup >"$S/running"
  printf '%s\n' ActiveState=failed SubState=failed Result=exit-code >"$T/show-lanai-vm.service"
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  run field message
  assert_output "Windows did not start."
  run field next
  assert_output --partial "journalctl --user -u lanai-vm"
  # Asked again, the failed unit still says so.
  setup_run
  run field message
  assert_output --partial "did not start"
}

@test "lanai setup step 5: --window or --no-window starts a setup boot, whatever step5 says" {
  through_step4
  export WAYLAND_DISPLAY=wayland-3
  local s
  for s in true false; do
    unit_is lanai-vm.service inactive
    setup_json "{\"snapshot\": \"declined\", \"step5\": $s}"
    setup_run --no-window
    assert_success
    assert_equal "$(field step)" 5
    assert_equal "$(field window)" false
    assert_equal "$(jq -r .step5 "$S/setup.json")" false
  done
}

@test "lanai setup step 5: a finished install restarts setup with either explicit display choice" {
  through_step4
  export WAYLAND_DISPLAY=wayland-3
  local option expected
  for option in --window --no-window; do
    unit_is lanai-vm.service inactive
    setup_json '{"snapshot": "declined", "done": true}'
    echo "$LG_BUILD" >"$S/guest-version"
    : >"$T/systemctl.calls"
    setup_run "$option"
    assert_success
    assert_equal "$(field step)" 5
    expected=false
    [[ $option != --window ]] || expected=true
    assert_equal "$(field window)" "$expected"
    assert_equal "$(jq -r .setup "$S/boot.json")" true
    assert_equal "$(jq -r .round "$S/setup.json")" true
    run cat "$T/systemctl.calls"
    assert_output --partial '--user start lanai-vm.service'
  done
}

@test "setup boot: --window keeps the record when the unit fails to start" {
  install
  setup_json '{"snapshot": "declined"}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  export WAYLAND_DISPLAY=wayland-3
  echo start >"$T/systemctl-fail"
  boot true true
  assert_failure
  assert [ -e "$S/guest-version" ]
  assert_equal "$(<"$S/guest-version")" B7-801-g1a2b3c4d5e
}

@test "lanai setup-guest: an unreachable user manager is named as such" {
  install
  setup_json '{"snapshot": "declined"}'
  pinned_files
  : >"$T/no-manager"
  setup_guest_run
  assert_failure
  run field message
  assert_output --partial "user manager"
}

@test "lanai status: active is true while the unit starts or stops, false once it failed" {
  install
  local st
  for st in activating deactivating; do
    unit_is lanai-vm.service "$st"
    lanai_run status
    assert_equal "$(field active)" true
  done
  unit_is lanai-vm.service failed Result=exit-code
  lanai_run status
  assert_equal "$(field active)" false
}

@test "lanai setup step 6: waits while Windows starts, and reopens a closed client" {
  step6_running "$FIX/client-logs/waiting.log"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  run field message
  assert_output --partial "starting"
  assert [ ! -e "$T/systemd-run.args" ]
  # The client closed before the guest answered: it is reopened, not counted.
  unit_is lanai-client.service inactive
  : >"$RUN/client.log"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  run tail -n 1 "$T/systemd-run.args"
  assert_output "$XDG_DATA_HOME/lanai/looking-glass/$LG_BUILD/bin/looking-glass-client"
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
}

@test "lanai setup step 6: a match records the pin, checks the agents, then asks the two questions" {
  step6_running "$FIX/client-logs/match.log"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert_equal "$(jq -c .questions <<<"$JSON")" '["share","scale"]'
  assert_equal "$(<"$S/guest-version")" B7-826-g236efcb155
  assert_set_time_now
  run setup_done
  assert_failure
  # Both answered yes: setup is done, and lanai start works.
  setup_run --share-ok yes --scale-ok yes
  assert_success
  assert_equal "$(field step)" 7
  run setup_done
  assert_success
  setup_run
  assert_success
  assert_equal "$(field step)" 7
}

@test "lanai setup step 6: a missing or mismatched IDD sends setup back to step 5 and keeps the record" {
  local log
  for log in idd-missing mismatch; do
    if [[ $log == idd-missing ]]; then
      step6_running "$FIX/client-logs/waiting.log" 120
      # The guest agent's port has been open past the grace.
      echo "$((EPOCHSECONDS - LANAI_SETUP_GRACE - 1))" >"$RUN/qga-open-since"
    else
      step6_running "$FIX/client-logs/other-build.log"
    fi
    echo B7-801-g1a2b3c4d5e >"$S/guest-version"
    touch -d '1 hour ago' "$S/guest-version"
    setup_run
    assert_failure
    assert_equal "$(field step)" 5
    run field message
    assert_output --partial "run setup.cmd again"
    assert_equal "$(jq -r '.step5 // "unset"' "$S/setup.json")" unset
    assert_equal "$(<"$S/guest-version")" B7-801-g1a2b3c4d5e
  done
}

@test "lanai setup step 6: a missing IDD waits until the guest agent's port has been open for the grace" {
  # The client starts its 30 s count when QEMU starts, so firmware and boot
  # time use it up: idd-missing alone says nothing until Windows has booted.
  step6_running "$FIX/client-logs/waiting.log" 120
  conf FAKE_QMP_QGA=false
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  run field message
  assert_output --partial "starting"
  assert [ ! -e "$RUN/qga-open-since" ]
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  # The port has just opened: still waiting, and the time is stamped once.
  conf FAKE_QMP_QGA=true
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert [ ! -e "$RUN/qga-closed-since" ]
  local since
  since=$(<"$RUN/qga-open-since")
  ((EPOCHSECONDS - since <= 5)) || fail "stamp $since is not now"
  echo "$((since - 10))" >"$RUN/qga-open-since"
  setup_run
  assert_equal "$(field step)" 6
  assert_equal "$(<"$RUN/qga-open-since")" "$((since - 10))"
  # Windows restarted (the port closed): the grace starts again.
  conf FAKE_QMP_QGA=false
  setup_run
  assert_equal "$(field step)" 6
  assert [ ! -e "$RUN/qga-open-since" ]
  conf FAKE_QMP_QGA=true
  # Open for longer than the grace: the IDD is missing.
  echo "$((EPOCHSECONDS - LANAI_SETUP_GRACE - 1))" >"$RUN/qga-open-since"
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  run field message
  assert_output --partial "display driver"
}

@test "lanai setup step 6: a match after an early idd-missing finishes normally" {
  step6_running "$FIX/client-logs/waiting.log" 120
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  # The IDD loaded later in the same client's run.
  started_log "$FIX/client-logs/match.log" 120 >"$RUN/client.log"
  setup_run --share-ok yes --scale-ok yes
  assert_success
  assert_equal "$(field step)" 7
}

@test "lanai setup step 6: after a partly failed setup.cmd, a missing part sends setup back to step 5" {
  # Windows shut down after setup.cmd stopped part way: the IDD answers,
  # but the agent has no allow-list and the SPICE agent never opened its port.
  step6_running "$FIX/client-logs/match.log" 90 90
  conf FAKE_QGA_CMD=open FAKE_QMP_VDAGENT=false
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  run field message
  assert_output --partial "setup did not finish: run setup.cmd again"
  assert_output --partial "QEMU guest agent"
  assert_output --partial "SPICE agent"
  assert_equal "$(jq -r '.step5 // "unset"' "$S/setup.json")" unset
  # Shut down, the next setup goes back to the setup boot, as the guess says
  # (the IDD answered, so the record is the pin: the Windows window).
  unit_is lanai-vm.service inactive
  unit_is lanai-client.service inactive
  setup_run
  assert_success
  assert_equal "$(field step)" 5
  assert_equal "$(field window)" false
}

@test "lanai setup step 6: an agent that refuses to set the clock sends setup back to step 5" {
  step6_running "$FIX/client-logs/match.log" 90 90
  conf FAKE_QGA_CMD=notime
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  run field message
  assert_output --partial "QEMU guest agent"
  refute_output --partial "SPICE agent"
}

@test "lanai setup step 6: a client that keeps closing cannot bypass the closed-port boot limit" {
  step6_closed "$FIX/client-logs/waiting.log"
  : >"$RUN/client.log"
  unit_is lanai-client.service inactive
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert [ -s "$RUN/qga-closed-since" ]
  assert [ -e "$T/systemd-run.args" ]
  rm "$T/systemd-run.args"
  unit_is lanai-client.service inactive
  echo "$((EPOCHSECONDS - LANAI_SETUP_BOOT_LIMIT - 1))" >"$RUN/qga-closed-since"
  setup_run
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(field step)" 5
  run field message
  assert_output --partial "Windows did not finish starting, or its guest agent is missing"
  assert_equal "$(jq -r '.step5 // "unset"' "$S/setup.json")" unset
  assert [ ! -e "$T/systemd-run.args" ]
  assert [ ! -s "$T/qga.log" ]
}

@test "lanai setup step 6: a closed client with unknown or waiting past the open-port grace fails without reopening it" {
  local verdict
  for verdict in unknown waiting; do
    step6_closed "$FIX/client-logs/waiting.log"
    if [[ $verdict == unknown ]]; then
      : >"$RUN/client.log"
    fi
    unit_is lanai-client.service inactive
    qmp_call() { echo '{"return":[{"label":"qga0","frontend-open":true}]}'; }
    setup_run
    assert_success
    assert_equal "$(field step)" 6
    assert [ -s "$RUN/qga-open-since" ]
    rm -f "$T/systemd-run.args"
    unit_is lanai-client.service inactive
    echo "$((EPOCHSECONDS - LANAI_SETUP_GRACE - 1))" >"$RUN/qga-open-since"
    setup_run
    assert_failure
    assert_equal "$(field ok)" false
    assert_equal "$(field step)" 6
    assert_equal "$(field message)" "The Windows window did not stay open long enough to check the display driver."
    assert_equal "$(field next)" "see the logs with journalctl --user -u lanai-client, then run setup again"
    assert_equal "$(jq -r .step5 "$S/setup.json")" true
    assert [ ! -e "$T/systemd-run.args" ]
    assert [ ! -s "$T/qga.log" ]
  done
}

@test "lanai setup step 6: a running client still in its own wait past the open-port grace is waited for" {
  local verdict
  for verdict in unknown waiting; do
    step6_closed "$FIX/client-logs/waiting.log"
    if [[ $verdict == unknown ]]; then
      : >"$RUN/client.log"
    fi
    unit_is lanai-client.service active
    qmp_call() { echo '{"return":[{"label":"qga0","frontend-open":true}]}'; }
    echo "$((EPOCHSECONDS - LANAI_SETUP_GRACE - 1))" >"$RUN/qga-open-since"
    setup_run
    assert_success
    assert_equal "$(field ok)" true
    assert_equal "$(field step)" 6
    assert_equal "$(jq -r .step5 "$S/setup.json")" true
    assert [ ! -e "$T/systemd-run.args" ]
  done
}

@test "lanai setup step 6: a closed port with no client start line waits and stamps the boot" {
  step6_closed "$FIX/client-logs/waiting.log"
  : >"$RUN/client.log"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  local since
  since=$(<"$RUN/qga-closed-since")
  ((EPOCHSECONDS - since <= 5)) || fail "stamp $since is not now"
}

@test "lanai setup step 6: a restart after the client's boot limit gets a fresh closed-port stamp" {
  step6_closed "$FIX/client-logs/match.log" "$((LANAI_SETUP_BOOT_LIMIT + 60))" 60
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert [ ! -e "$RUN/qga-open-since" ]
  local since
  since=$(<"$RUN/qga-closed-since")
  ((EPOCHSECONDS - since <= 5)) || fail "stamp $since is not now"
}

@test "lanai setup step 6: a closed port is given up after its boot limit, without asking the agent" {
  step6_closed "$FIX/client-logs/match.log" "$((LANAI_SETUP_BOOT_LIMIT + 60))"
  local since=$((EPOCHSECONDS - LANAI_SETUP_BOOT_LIMIT + 10))
  echo "$since" >"$RUN/qga-closed-since"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert_equal "$(<"$RUN/qga-closed-since")" "$since"
  echo "$((EPOCHSECONDS - LANAI_SETUP_BOOT_LIMIT - 1))" >"$RUN/qga-closed-since"
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  run field message
  assert_output --partial "Windows did not finish starting, or its guest agent is missing"
  # A sync on a closed port would wait 5 s: the agent was never asked.
  assert [ ! -s "$T/qga.log" ]
}

@test "lanai setup step 6: an open port removes the closed-port stamp" {
  step6_closed "$FIX/client-logs/waiting.log"
  echo "$((EPOCHSECONDS - LANAI_SETUP_BOOT_LIMIT - 1))" >"$RUN/qga-closed-since"
  qmp_call() { echo '{"return":[{"label":"qga0","frontend-open":true}]}'; }
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert [ ! -e "$RUN/qga-closed-since" ]
  assert [ -s "$RUN/qga-open-since" ]
}

@test "lanai setup step 6: QMP not answering means try again, not a missing part" {
  step6_running "$FIX/client-logs/match.log" 90 90
  rm "$RUN/qmp-cli.sock"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  run field message
  assert_output --partial "asks again"
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
}

@test "lanai setup step 6: a closed client with a decisive verdict is not reopened" {
  step6_running "$FIX/client-logs/match.log"
  unit_is lanai-client.service inactive
  setup_run
  assert_success
  assert_equal "$(jq -c .questions <<<"$JSON")" '["share","scale"]'
  assert [ ! -e "$T/systemd-run.args" ]
}

@test "lanai setup step 6: a lone no is acted on" {
  local opt
  for opt in --share-ok --scale-ok; do
    step6_running "$FIX/client-logs/match.log"
    setup_run "$opt" no
    assert_failure
    assert_equal "$(field step)" 5
  done
}

@test "lanai setup step 6: a part not answering yet is waited for at first" {
  step6_running "$FIX/client-logs/match.log" 5
  conf FAKE_QGA_CMD=allowlist FAKE_QMP_VDAGENT=false
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
}

@test "lanai setup step 6: a no to either question sends setup back to step 5" {
  step6_running "$FIX/client-logs/match.log"
  setup_run --share-ok no --scale-ok yes
  assert_failure
  assert_equal "$(field step)" 5
  run field message
  assert_output --partial "Explorer does not show ~/Windows"
  run setup_done
  assert_failure
  setup_run --share-ok maybe
  assert_failure
  run field message
  assert_output --partial "unknown option"
}

@test "lanai setup step 6: a client of another build is replaced by the pinned one" {
  step6_running "$FIX/client-logs/match.log"
  sed -e 's/Looking Glass (B7-826-236efcb1)/Looking Glass (B7-801-1a2b3c4d)/' \
    -e 's/Version  : B7-826-g236efcb155/Version  : B7-801-g1a2b3c4d5e/' "$FIX/client-logs/match.log" |
    started_log /dev/stdin >"$RUN/client.log"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  grep -q -- '--user stop lanai-client.service' "$T/systemctl.calls" || fail "the old client was not stopped"
  run tail -n 1 "$T/systemd-run.args"
  assert_output "$XDG_DATA_HOME/lanai/looking-glass/$LG_BUILD/bin/looking-glass-client"
}

@test "lanai setup: with done and a guest version behind the pin, it resumes at step 5" {
  through_step4
  setup_json '{"snapshot": "declined", "done": true}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  setup_run
  assert_success
  assert_equal "$(field step)" 5
  # The record names the old IDD, so the setup boot uses the Windows window,
  # and the old client keeps working meanwhile (spec 8).
  assert_equal "$(field window)" false
  run setup_done
  assert_success
  # The setup boot opened a round, which only step 7 closes.
  assert_equal "$(jq -r .round "$S/setup.json")" true
}

@test "lanai setup: with done, a step 6 failure after the pin was recorded resumes at step 5, not 7" {
  # A pin bump: the setup boot ran, then step 6 saw a match (recording the
  # pin, so nothing is behind any more) but the guest agent failed.
  step6_running "$FIX/client-logs/match.log" 90 90
  setup_json '{"snapshot": "declined", "step5": true, "done": true, "round": true}'
  conf FAKE_QGA_CMD=open
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  assert_equal "$(<"$S/guest-version")" B7-826-g236efcb155
  # Shut down: the next setup goes back to the setup boot.
  unit_is lanai-vm.service inactive
  unit_is lanai-client.service inactive
  setup_run
  assert_success
  assert_equal "$(field step)" 5
  run setup_done
  assert_success
}

@test "lanai setup: with done, --window then a panel Shut down asks for the display; a clean one goes to step 6" {
  through_step4
  setup_json '{"snapshot": "declined", "done": true}'
  echo B7-801-g1a2b3c4d5e >"$S/guest-version"
  export WAYLAND_DISPLAY=wayland-3
  setup_run --window
  assert_success
  assert_equal "$(field step)" 5
  assert_equal "$(field window)" true
  # The round stays open while the old record still selects the matching client.
  assert_equal "$(<"$S/guest-version")" B7-801-g1a2b3c4d5e
  setup_boot_ended panel
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  assert_equal "$(jq -c .choices <<<"$JSON")" '["--window","--no-window"]'
  setup_boot_ended clean
  setup_run
  assert_success
  assert_equal "$(field step)" 6
}

@test "lanai setup: a finished round reports step 7 and closes the round" {
  step6_running "$FIX/client-logs/match.log"
  setup_json '{"snapshot": "declined", "step5": true, "done": true, "round": true}'
  setup_run --share-ok yes --scale-ok yes
  assert_success
  assert_equal "$(field step)" 7
  assert_equal "$(jq -c 'del(.location)' "$S/setup.json")" '{"snapshot":"declined","done":true}'
  setup_run
  assert_equal "$(field step)" 7
}

@test "lanai setup: interrupted after each step, it resumes at the right step" {
  install
  export WAYLAND_DISPLAY=wayland-3
  pinned_files
  shim pacman 'echo passt; exit 127'
  setup_run
  assert_equal "$(field step)" 2
  shim pacman 'exit 0'
  setup_run
  assert_equal "$(field step)" 3
  setup_run
  assert_equal "$(field step)" 3
  build_client() { echo "interrupted"; return 1; }
  setup_run --no-snapshot
  assert_equal "$(field step)" 4
  fake_build "$LG_BUILD"
  setup_run
  assert_equal "$(field step)" 5
  assert_equal "$(field window)" true
  # Interrupted mid setup boot: still step 5.
  setup_run
  assert_equal "$(field step)" 5
  # The setup boot ended in setup.cmd's shutdown.
  setup_boot_ended clean
  setup_run
  assert_equal "$(field step)" 6
  # Interrupted while Windows starts: still step 6.
  [[ -d $RUN ]] || mkdir -m 700 "$RUN"
  started_log "$FIX/client-logs/match.log" >"$RUN/client.log"
  conf FAKE_QGA_CMD=allowlist
  serve "$RUN/qmp-cli.sock" "$FIX/fake-qmp"
  serve "$RUN/qga.sock" "$FIX/fake-qga"
  setup_run
  assert_equal "$(field step)" 6
  assert_equal "$(jq -c .questions <<<"$JSON")" '["share","scale"]'
  setup_run --share-ok yes --scale-ok yes
  assert_equal "$(field step)" 7
  # Rerun after done: nothing to do.
  setup_run
  assert_equal "$(field step)" 7
}

@test "lanai setup step 4: a successful build with the wrong version stops once at step 4" {
  install
  setup_json '{"snapshot": "declined"}'
  build_client() {
    echo built >>"$T/build.calls"
    fake_build "$LG_BUILD" B7-wrong
  }
  setup_run
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(field step)" 4
  assert_equal "$(wc -l <"$T/build.calls")" 1
  ! grep -q -- '--user start' "$T/systemctl.calls" || fail "the unit was started"
}

@test "lanai setup: a running VM at another storage location refuses without altering state" {
  through_step4
  setup_json '{"location": "/elsewhere", "snapshot": "declined", "step5": true}'
  local before
  before=$(<"$S/setup.json")
  unit_is lanai-vm.service active
  setup_run
  assert_failure
  assert_equal "$(field step)" 1
  assert_equal "$(<"$S/setup.json")" "$before"
  run field next
  assert_output --partial "shut Windows down"
  ! grep -q -- '--user start' "$T/systemctl.calls" || fail "the unit was started"
}

@test "lanai setup step 6: an inactive boot that never started reports its logs once, then retries" {
  through_step4
  setup_json '{"snapshot": "declined", "step5": true}'
  echo inv-normal >"$S/running"
  setup_run
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(field step)" 6
  assert_equal "$(field message)" "Windows did not start."
  run field next
  assert_output --partial "$LANAI_LOGS"
  assert [ ! -e "$S/last-run" ]
  ! grep -q -- '--user start' "$T/systemctl.calls" || fail "the unit was started"
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  run cat "$T/systemctl.calls"
  assert_output --partial '--user start lanai-vm.service'
}

@test "lanai setup step 6: a unit that stays failed reports its logs once, then retries" {
  through_step4
  setup_json '{"snapshot": "declined", "step5": true}'
  printf '%s\n' ActiveState=failed SubState=failed Result=exit-code >"$T/show-lanai-vm.service"
  setup_run
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(field step)" 6
  assert_equal "$(field message)" "Windows did not start."
  run field next
  assert_output --partial "$LANAI_LOGS"
  ! grep -q -- '--user start' "$T/systemctl.calls" || fail "the unit was started"
  run grep -Fx -- '--user reset-failed lanai-vm.service' "$T/systemctl.calls"
  assert_success
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  run grep -Fx -- '--user start lanai-vm.service' "$T/systemctl.calls"
  assert_success
}

@test "lanai setup step 5: failed explicit display boots keep false and offer both choices next time" {
  local failure option
  for failure in download display; do
    for option in --window --no-window; do
      through_step4
      unit_is lanai-vm.service inactive
      setup_json '{"snapshot": "declined", "step5": true}'
      if [[ $failure == download ]]; then
        shim curl 'exit 1'
        rm -rf "$XDG_CACHE_HOME/lanai/downloads"
      else
        unset WAYLAND_DISPLAY
        # Both options are tested for downloads; only --window needs a display.
        [[ $option != --no-window ]] || continue
      fi
      setup_run "$option"
      assert_failure
      assert_equal "$(field step)" 5
      assert_equal "$(jq -r .step5 "$S/setup.json")" false
      setup_run
      assert_failure
      assert_equal "$(field step)" 5
      assert_equal "$(jq -c .choices <<<"$JSON")" '["--window","--no-window"]'
    done
  done
}

@test "lanai setup step 6: a closed client's stale idd-missing reopens; mismatch stays decisive" {
  step6_running "$FIX/client-logs/waiting.log" 120 120 no-servers
  qmp_call() { echo '{"return":[{"label":"qga0","frontend-open":true}]}'; }
  unit_is lanai-client.service inactive
  setup_run
  assert_success
  assert_equal "$(field step)" 6
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  run tail -n 1 "$T/systemd-run.args"
  assert_output "$(pinned_client)"
  rm "$T/systemd-run.args"
  started_log "$FIX/client-logs/other-build.log" >"$RUN/client.log"
  unit_is lanai-client.service inactive
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  assert [ ! -e "$T/systemd-run.args" ]
}

@test "setup media: refuses a symlink anywhere in the assembled media" {
  install
  pinned_files
  ln -s viofs.inf "$T/src/tree/iso/viofs/w11/amd64/extra.dll"
  bsdtar -cf "$T/src/virtio-win.iso" -C "$T/src/tree/iso" viofs NetKVM
  VIRTIO_WIN_SHA=$(sha256sum "$T/src/virtio-win.iso" | cut -d' ' -f1)
  run setup_media_build
  assert_failure
  assert_output --partial symlink
  assert [ ! -e "$S/setup-media" ]
  assert [ ! -e "$S/setup-media.partial" ]
}

@test "lanai setup step 5: a failed explicit retry of a finished install still offers display choices" {
  through_step4
  setup_json '{"snapshot": "declined", "done": true}'
  echo "$LG_BUILD" >"$S/guest-version"
  shim curl 'exit 1'
  setup_run --no-window
  assert_failure
  assert_equal "$(jq -r .step5 "$S/setup.json")" false
  setup_run
  assert_failure
  assert_equal "$(field step)" 5
  assert_equal "$(jq -c .choices <<<"$JSON")" '["--window","--no-window"]'
}

@test "client builds: both commands refuse the shared build lock before building" {
  install
  setup_json '{"snapshot": "declined"}'
  local fd
  exec {fd}>>"$S/build.lock"
  flock -n "$fd"
  build_client() { echo called >>"$T/build.calls"; return 1; }
  run --separate-stderr cmd_build_client
  assert_failure
  assert_output --partial 'Another Looking Glass client build is running'
  setup_run
  assert_failure
  assert_equal "$(field step)" 4
  run field message
  assert_output --partial 'another Looking Glass client build is running'
  assert [ ! -e "$T/build.calls" ]
  exec {fd}>&-
}
