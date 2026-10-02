#!/usr/bin/env bats
# Tests for Lanai's setup (plan phase 6): setup state that follows the disk,
# step 5's verdict, the setup boot's display, the setup media, and the
# resumable lanai setup. systemctl, systemd-run, hyprctl, ip, curl and
# pacman are PATH shims: nothing talks to the real user manager, starts a
# VM, opens a window or downloads anything. QMP and the guest agent are the
# fake servers in test/fixtures.
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
  # systemctl: log every call. `show` answers from $T/show-<unit> (default:
  # inactive), all of it or, with --value, the one property asked for.
  # `start lanai-vm.service` makes the VM unit active, as systemd would.
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
if [[ $2 == start && $unit == lanai-vm.service && ! -e $T/start-keeps-state ]]; then
  printf "ActiveState=active\nSubState=running\nResult=success\nInvocationID=inv-new\nMainPID=4000\n" >"$T/show-lanai-vm.service"
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
# <setup true|false> <clean|forced|panel>. panel is a clean guest shutdown
# that the panel's Shut down asked for.
ran() {
  mkdir -p "$S"
  echo "$1" >"$S/running"
  echo "$1" >"$S/started"
  jq -n -c --argjson s "$2" '{scale: 100, setup: $s}' >"$S/boot.json"
  case $3 in
    clean | panel) printf '{"invocation":"%s","guest":true,"reason":"guest-shutdown"}\n' "$1" >"$S/last-shutdown" ;;
    forced) : >"$S/forced" ;;
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
  run setup_reset
  assert_success
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
  for how in "true panel" "true forced" "false clean"; do
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

@test "a storage change after a clean setup boot leaves step5 unset and no guest-version" {
  install
  setup_json '{"location": "/elsewhere"}'
  ran inv-1 true clean
  echo B7-801-1a2b3c4d >"$S/guest-version"
  # The next setup boot: preflight records the run, then setup follows the disk.
  record_previous_run >/dev/null
  setup_follow "$STORE"
  assert_equal "$(jq -c . "$S/setup.json")" "$(jq -n -c --arg l "$STORE" '{location: $l}')"
  assert [ ! -e "$S/guest-version" ]
}
