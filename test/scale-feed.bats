#!/usr/bin/env bats
# Tests for the scale feed (docs/plugin/plan.md, Follow-on: live scale): the
# pure target and line functions with fixture hyprctl JSON, one feed pass
# with PATH shims for hyprctl and systemctl, and the loop against fake scale
# sockets that read everything, never read, or flood. No VM, no Hyprland.
# shellcheck disable=SC2030,SC2031,SC2016,SC2034

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  RUN=$XDG_RUNTIME_DIR/lanai
  S=$XDG_STATE_HOME/lanai
  mkdir -m 700 "$RUN"
  mkdir -p "$S" "$XDG_CONFIG_HOME/lanai"
  # hyprctl answers from $T/clients.json and $T/monitors.json (fails when
  # $T/no-hyprland exists, hangs when $T/hyprland-hangs exists, and logs the
  # instance it was called with to $T/hypr-sigs). `hyprctl version` answers
  # as Hyprland does: only when its instance's socket has a listener.
  # systemctl prints the client unit's MainPID from $T/client-pid (0 when no
  # client runs) only for that exact query, and 0 for any other.
  shim hyprctl 'if [[ $1 == version ]]; then
  exec socat -u /dev/null "UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/${HYPRLAND_INSTANCE_SIGNATURE-}/.socket.sock" 2>/dev/null
fi
echo "${HYPRLAND_INSTANCE_SIGNATURE-}" >>"$T/hypr-sigs"
[[ ! -e $T/hyprland-hangs ]] || exec sleep 10
[[ ! -e $T/no-hyprland ]] || exit 1
case $1 in
  clients) cat "$T/clients.json" ;;
  monitors) cat "$T/monitors.json" ;;
  *) exit 1 ;;
esac'
  shim systemctl 'if [[ "$*" == "--user show -p MainPID --value lanai-client.service" ]]; then
  cat "$T/client-pid" 2>/dev/null || echo 0
else
  echo 0
fi'
  echo '[]' >"$T/clients.json"
  monitors DP-1:1.5:true HDMI-A-1:2:false
  export T PATH=$T/shims:$PATH
}

teardown() {
  stop_bg
}

# Write $T/monitors.json from <name>:<scale>:<focused> triples, ids from 0.
monitors() {
  local m i=0
  printf '[' >"$T/monitors.json"
  for m; do
    IFS=: read -r name scale focused <<<"$m"
    ((i == 0)) || printf ',' >>"$T/monitors.json"
    printf '{"id":%d,"name":"%s","scale":%s,"focused":%s}' "$i" "$name" "$scale" "$focused" >>"$T/monitors.json"
    i=$((i + 1))
  done
  printf ']\n' >>"$T/monitors.json"
}

# Put the Windows window (pid 4242) on the monitor with id <id>, or remove it.
window_on() {
  if [[ -z ${1:-} ]]; then
    echo '[{"pid":99,"monitor":0}]' >"$T/clients.json"
    echo 0 >"$T/client-pid"
  else
    printf '[{"pid":99,"monitor":0},{"pid":4242,"monitor":%s}]\n' "$1" >"$T/clients.json"
    echo 4242 >"$T/client-pid"
  fi
}

# Write settings.json with <windows_scale JSON> and <scale_save>.
settings() {
  printf '{"memory_gib":8,"cores":4,"windows_scale":%s,"scale_save":%s}\n' "$1" "$2" >"$(settings_file)"
}

# Serve $RUN/scale.sock and append everything received to $T/received.
serve_reader() {
  socat -u "UNIX-LISTEN:$RUN/scale.sock,fork" "OPEN:$T/received,creat,append" >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -S $RUN/scale.sock ]] && return 0
    sleep 0.05
  done
  fail "the reader never listened"
}

# Print the non-empty lines received so far.
received() {
  grep -v '^$' "$T/received" 2>/dev/null || true
}

# Run one feed pass in this shell, as the helper's loop does.
step() {
  scale_feed_step 2>>"$T/feed.log"
}

# --- pure functions ---

@test "scale_line: a listed step and a save number, nothing else" {
  run scale_line 150 7
  assert_success
  assert_output "lanai-scale 150 7"
  run scale_line 500 999999999
  assert_output "lanai-scale 500 999999999"
  local -a bad=(137 1 150 1000000000 150 -1 150 "1,2" auto 3 " 150" 3 150 "" 150 1.5 150 "3 x")
  local i
  for ((i = 0; i < ${#bad[@]}; i += 2)); do
    run scale_line "${bad[i]}" "${bad[i + 1]}"
    assert_failure
  done
}

@test "window_monitor: the monitor of the client's window, by its pid" {
  window_on 1
  run window_monitor "$(<"$T/clients.json")" "$(<"$T/monitors.json")" 4242
  assert_output HDMI-A-1
  window_on 0
  run window_monitor "$(<"$T/clients.json")" "$(<"$T/monitors.json")" 4242
  assert_output DP-1
  # No client, another pid, a monitor id Hyprland does not list, bad JSON.
  local pid
  for pid in 0 "" 4243 abc; do
    run window_monitor "$(<"$T/clients.json")" "$(<"$T/monitors.json")" "$pid"
    assert_output ""
  done
  window_on 7
  run window_monitor "$(<"$T/clients.json")" "$(<"$T/monitors.json")" 4242
  assert_output ""
  run window_monitor 'not json' "$(<"$T/monitors.json")" 4242
  assert_output ""
  run window_monitor '{}' '{}' 4242
  assert_output ""
}

@test "scale_target: a fixed step is the target whatever the monitors" {
  local m
  for m in '[]' 'not json' "$(<"$T/monitors.json")"; do
    run scale_target 225 "$m" HDMI-A-1 100
    assert_output 225
  done
}

@test "scale_target auto: the named monitor's step, ties down, then focused, first, last" {
  run scale_target auto "$(<"$T/monitors.json")" HDMI-A-1 100
  assert_output 200
  run scale_target auto "$(<"$T/monitors.json")" DP-1 100
  assert_output 150
  monitors DP-1:1.125:false HDMI-A-1:2.75:true
  run scale_target auto "$(<"$T/monitors.json")" DP-1 300
  assert_output 100
  # A gone monitor: the focused one counts.
  run scale_target auto "$(<"$T/monitors.json")" DP-3 300
  assert_output 250
  # No monitor focused: the first one listed.
  monitors DP-1:1.75:false HDMI-A-1:1:false
  run scale_target auto "$(<"$T/monitors.json")" DP-3 300
  assert_output 175
  run scale_target auto "$(<"$T/monitors.json")" "" 300
  assert_output 175
  # No monitors: the last target stays.
  run scale_target auto '[]' DP-1 300
  assert_output 300
  run scale_target auto 'not json' DP-1 300
  assert_output 300
  run scale_target auto '[]' DP-1 ""
  assert_failure
}

# --- one feed pass ---

@test "feed pass: sends the line for the window's monitor and remembers it" {
  serve_reader
  settings '"auto"' 3
  window_on 1
  step
  window_on 0
  step
  step
  assert_equal "$(received)" $'lanai-scale 200 3\nlanai-scale 150 3\nlanai-scale 150 3'
  assert_equal "$(<"$RUN/scale-monitor")" DP-1
  # One log line per changed line, naming the step and the monitor.
  run grep 'scale feed sends' "$T/feed.log"
  assert_equal "${#lines[@]}" 2
  assert_line --index 0 --partial "sends 200% (save 3) for monitor HDMI-A-1"
  assert_line --index 1 --partial "sends 150% (save 3) for monitor DP-1"
}

@test "feed pass: with the window closed the remembered monitor counts, else the boot monitor" {
  serve_reader
  echo '{"scale":100,"scale_save":0,"boot_monitor":"HDMI-A-1"}' >"$S/boot.json"
  scale_feed_init 2>>"$T/feed.log"
  settings '"auto"' 0
  # Before the window first opens, the boot monitor counts, and so do its
  # scale changes; once it is unplugged, the focused monitor counts.
  step
  monitors DP-1:1.5:true HDMI-A-1:3:false
  step
  monitors DP-1:1.5:true
  step
  assert_equal "$(received)" $'lanai-scale 200 0\nlanai-scale 300 0\nlanai-scale 150 0'
  : >"$T/received"
  # The window was on HDMI-A-1, then closed: that monitor counts, not focus.
  monitors DP-1:1.5:true HDMI-A-1:2:false
  window_on 1
  step
  window_on
  step
  monitors DP-1:1.5:true HDMI-A-1:2.5:false
  step
  assert_equal "$(received)" $'lanai-scale 200 0\nlanai-scale 200 0\nlanai-scale 250 0'
}

@test "feed pass: the monitor recorded under a fixed setting counts after a switch to auto" {
  serve_reader
  echo '{"scale":100,"scale_save":4,"boot_monitor":"DP-1"}' >"$S/boot.json"
  scale_feed_init 2>>"$T/feed.log"
  settings 125 4
  window_on 1
  step
  assert_equal "$(<"$RUN/scale-monitor")" HDMI-A-1
  window_on
  settings '"auto"' 5
  step
  assert_equal "$(received)" $'lanai-scale 125 4\nlanai-scale 200 5'
}

@test "feed pass: a new save number never pairs with an old step, because settings are read once" {
  serve_reader
  # A FIFO yields one document to one open; a second read would block.
  rm -f "$(settings_file)"
  mkfifo "$(settings_file)"
  printf '{"windows_scale":175,"scale_save":9}\n' >"$(settings_file)" &
  BG_PIDS+=("$!")
  run timeout 10 bash -c 'source "$1/lib/lanai.sh"; scale_feed_step' _ "$REPO"
  assert_success
  assert_equal "$(received)" "lanai-scale 175 9"
}

@test "feed pass: unreadable settings keep sending the last good line, logged once" {
  serve_reader
  settings 150 2
  step
  printf broken >"$(settings_file)"
  step
  step
  settings 150 abc
  step
  assert_equal "$(received)" $'lanai-scale 150 2\nlanai-scale 150 2\nlanai-scale 150 2\nlanai-scale 150 2'
  run grep -c 'settings' "$T/feed.log"
  assert_output 1
  settings 250 3
  step
  assert_equal "$(received | tail -n 1)" "lanai-scale 250 3"
}

@test "feed pass: a failing hyprctl is logged once with its instance, the last target stays, and recovery is logged" {
  serve_reader
  settings '"auto"' 1
  step
  : >"$T/no-hyprland"
  step
  step
  assert_equal "$(received)" $'lanai-scale 150 1\nlanai-scale 150 1\nlanai-scale 150 1'
  run grep -c 'hyprctl does not answer' "$T/feed.log"
  assert_output 1
  run grep 'hyprctl does not answer' "$T/feed.log"
  assert_output --partial "instance none"
  rm "$T/no-hyprland"
  step
  run grep -c 'hyprctl answers the scale feed again' "$T/feed.log"
  assert_output 1
}

@test "feed pass: a hung hyprctl times out after 1 s, the last good line still goes out" {
  serve_reader
  settings 150 2
  : >"$T/hyprland-hangs"
  local start=$EPOCHREALTIME
  step
  local took
  took=$(awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN { print b - a }')
  awk -v t="$took" 'BEGIN { exit !(t < 3) }' || fail "the pass took $took s"
  step
  assert_equal "$(received)" $'lanai-scale 150 2\nlanai-scale 150 2'
  run grep -c 'hyprctl does not answer' "$T/feed.log"
  assert_output 1
}

@test "feed pass: no scale socket yet is silent; a failed send is logged once, and again when it recovers" {
  settings 150 1
  # QEMU has not created the socket yet: no send problem to log.
  step
  step
  run grep -c 'send to Windows' "$T/feed.log"
  assert_output 0
  # A socket nobody accepts on: logged once.
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$RUN/scale.sock"
  step
  step
  run grep -c 'cannot send' "$T/feed.log"
  assert_output 1
  rm "$RUN/scale.sock"
  serve_reader
  step
  step
  run grep -c 'sends to Windows again' "$T/feed.log"
  assert_output 1
  run grep -c 'to Windows' "$T/feed.log"
  assert_output 2
  assert_equal "$(received)" $'lanai-scale 150 1\nlanai-scale 150 1'
}

# Make a live Hyprland instance <sig>: a socket under $XDG_RUNTIME_DIR/hypr
# with a listener, so `hyprctl version` answers.
hypr_live() {
  mkdir -p "$XDG_RUNTIME_DIR/hypr/$1"
  socat "UNIX-LISTEN:$XDG_RUNTIME_DIR/hypr/$1/.socket.sock,fork" EXEC:/bin/true >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  echo "$!" >"$T/hypr-pid-$1"
  wait_for_file "$XDG_RUNTIME_DIR/hypr/$1/.socket.sock"
}

# Make a stale instance <sig>, as Hyprland leaves them: its folder and a
# socket file with no listener.
hypr_stale() {
  local sock=$XDG_RUNTIME_DIR/hypr/$1/.socket.sock
  if [[ -f $T/hypr-pid-$1 ]]; then
    kill "$(<"$T/hypr-pid-$1")" 2>/dev/null || true
    rm -f "$T/hypr-pid-$1"
    sleep 0.1
  fi
  mkdir -p "${sock%/*}"
  rm -f "$sock"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"
}

@test "feed init: seeds the line from boot.json" {
  serve_reader
  echo '{"scale":175,"scale_save":6}' >"$S/boot.json"
  scale_feed_init 2>>"$T/feed.log"
  # With settings unreadable from the start, the boot line goes out.
  printf broken >"$(settings_file)"
  step
  assert_equal "$(received)" "lanai-scale 175 6"
}

@test "feed init: boot.json's Hyprland instance counts only when it answers" {
  hypr_live live_1
  hypr_live inherited_2
  # boot.json's live instance wins over the inherited one.
  echo '{"scale":100,"hyprland_instance_signature":"live_1"}' >"$S/boot.json"
  HYPRLAND_INSTANCE_SIGNATURE=inherited_2
  scale_feed_init 2>>"$T/feed.log"
  assert_equal "$HYPRLAND_INSTANCE_SIGNATURE" live_1
  run cat "$T/feed.log"
  assert_output --partial "live_1"
  # A stale one (its socket file left behind), a missing or an invalid one
  # gives way to the live inherited instance.
  hypr_stale gone_3
  local sig
  for sig in gone_3 missing_9 "" "../x" "a b"; do
    HYPRLAND_INSTANCE_SIGNATURE=inherited_2
    jq -nc --arg s "$sig" '{scale:100,hyprland_instance_signature:$s}' >"$S/boot.json"
    scale_feed_init 2>/dev/null
    assert_equal "$HYPRLAND_INSTANCE_SIGNATURE" inherited_2
  done
}

@test "feed init: among many stale instances, the only live one is used" {
  local i
  for i in 1 2 3 4 5 6; do hypr_stale "stale_$i"; done
  mkdir -p "$XDG_RUNTIME_DIR/hypr/empty_5"
  hypr_live only_4
  echo '{"scale":100,"hyprland_instance_signature":"stale_1"}' >"$S/boot.json"
  HYPRLAND_INSTANCE_SIGNATURE=stale_2
  scale_feed_init 2>>"$T/feed.log"
  assert_equal "$HYPRLAND_INSTANCE_SIGNATURE" only_4
  # Two live instances: no guess, logged.
  hypr_live other_6
  unset HYPRLAND_INSTANCE_SIGNATURE
  : >"$T/feed.log"
  scale_feed_init 2>>"$T/feed.log"
  assert_equal "${HYPRLAND_INSTANCE_SIGNATURE-unset}" unset
  run cat "$T/feed.log"
  assert_output --partial "stale_1"
}

@test "feed pass: while hyprctl fails, the instance is found again every 15 passes, logged once per change" {
  serve_reader
  settings '"auto"' 1
  hypr_live old_7
  echo '{"scale":100,"hyprland_instance_signature":"old_7"}' >"$S/boot.json"
  scale_feed_init 2>>"$T/feed.log"
  step
  # Hyprland dies; its folder and socket file stay. hyprctl fails from now.
  hypr_stale old_7
  : >"$T/no-hyprland"
  local i
  for ((i = 0; i < 20; i++)); do step; done
  run grep -c 'Hyprland instance' "$T/feed.log"
  # "uses old_7" at init, then "finds no running instance" once.
  assert_output 2
  # It comes back under a new instance; the next search (pass 31) finds it.
  hypr_live new_8
  for ((i = 0; i < 11; i++)); do step; done
  assert_equal "$HYPRLAND_INSTANCE_SIGNATURE" new_8
  run grep -c 'uses Hyprland instance new_8' "$T/feed.log"
  assert_output 1
  rm "$T/no-hyprland"
  : >"$T/hypr-sigs"
  step
  assert_equal "$(sort -u "$T/hypr-sigs")" new_8
  run grep -c 'hyprctl does not answer' "$T/feed.log"
  assert_output 1
  run grep -c 'Hyprland instance' "$T/feed.log"
  assert_output 3
}

# --- sending ---

@test "scale_send: a cut write followed by a full line arrives whole" {
  serve_reader
  printf 'lanai-scale 15' | socat -u - "UNIX-CONNECT:$RUN/scale.sock"
  scale_send "$RUN/scale.sock" "lanai-scale 150 3"
  local i
  for ((i = 0; i < 50; i++)); do
    (($(received | wc -l) >= 2)) && break
    sleep 0.05
  done
  # The reader's children may append in either order; each line is whole.
  run received
  assert_equal "${#lines[@]}" 2
  assert_line "lanai-scale 15"
  assert_line "lanai-scale 150 3"
}

@test "scale_send: a flooding guest is never read and the send ends in time" {
  # A guest that writes as fast as it can to every connection.
  socat "UNIX-LISTEN:$RUN/scale.sock,fork" "SYSTEM:yes GUEST-DATA" >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$RUN/scale.sock"
  local start=$SECONDS
  LANAI_SCALE_SEND_TIMEOUT=1 run scale_send "$RUN/scale.sock" "lanai-scale 150 3"
  assert_success
  ((SECONDS - start <= 2)) || fail "the send took $((SECONDS - start)) s"
  # A send that read the socket would copy the guest's bytes to its output.
  refute_output --partial GUEST-DATA
}

# --- the loop ---

@test "scale feed: resends every loop, changed or not" {
  serve_reader
  settings 150 4
  LANAI_SCALE_INTERVAL=0.1 "$REPO/bin/lanai-vm-helper" scale-feed 2>>"$T/feed.log" 3>&- &
  BG_PIDS+=("$!")
  local i
  for ((i = 0; i < 100; i++)); do
    (($(received | wc -l) >= 5)) && break
    sleep 0.05
  done
  (($(received | wc -l) >= 5)) || fail "only $(received | wc -l) lines arrived"
  run bash -c 'grep -v "^\$" "$1" | sort -u' _ "$T/received"
  assert_output "lanai-scale 150 4"
}

# As QEMU does with a stalled port: accept one client and never read, so
# later connects queue and each send can take the whole deadline.
serve_stalled() {
  python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
c = s.accept(); time.sleep(600)' "$RUN/scale.sock" 3>&- &
  BG_PIDS+=("$!")
  wait_for_file "$RUN/scale.sock"
}

@test "scale feed: a server that never reads keeps the cadence" {
  serve_stalled
  settings 150 4
  # socat stamps each send's start in $T/sends.
  shim socat 'echo "$EPOCHREALTIME" >>"$T/sends"; exec /usr/bin/socat "$@"'
  LANAI_SCALE_INTERVAL=0.2 LANAI_SCALE_SEND_TIMEOUT=0.1 \
    "$REPO/bin/lanai-vm-helper" scale-feed 2>>"$T/feed.log" 3>&- &
  BG_PIDS+=("$!")
  local i
  for ((i = 0; i < 200; i++)); do
    (($(wc -l <"$T/sends" 2>/dev/null || echo 0) >= 25)) && break
    sleep 0.1
  done
  # Every gap after the first few sends (which the backlog still accepts)
  # stays near the 0.2 s period, though each send takes its whole deadline.
  run awk 'NR > 1 { g = $1 - p; n++; s += g; if (g > m) m = g } { p = $1 }
    END { printf "%d %.3f %.3f\n", n, s / n, m }' "$T/sends"
  read -r n mean max <<<"$output"
  ((n >= 24)) || fail "only $n gaps"
  awk -v m="$mean" -v x="$max" 'BEGIN { exit !(m >= 0.18 && m <= 0.3 && x < 0.6) }' ||
    fail "mean gap $mean s, longest $max s"
}

@test "scale feed: a server that never reads keeps the feed's memory flat over 500 sends" {
  serve_stalled
  # A fixed step and no Hyprland keep each pass cheap: one failing hyprctl
  # call, no monitor reads.
  settings 150 4
  : >"$T/no-hyprland"
  # socat counts each send in $T/sends.
  shim socat 'echo >>"$T/sends"; exec /usr/bin/socat "$@"'
  LANAI_SCALE_INTERVAL=0.01 LANAI_SCALE_SEND_TIMEOUT=0.01 \
    "$REPO/bin/lanai-vm-helper" scale-feed 2>>"$T/feed.log" 3>&- &
  local pid=$! first="" now sends=0 start=$SECONDS
  BG_PIDS+=("$pid")
  # Bounded at 90 s, well inside the 120 s per-test limit, to fail with its
  # own message.
  while ((SECONDS - start < 90)); do
    sends=$(wc -l <"$T/sends" 2>/dev/null || echo 0)
    if [[ -z $first ]] && ((sends >= 50)); then
      first=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status")
    fi
    ((sends >= 550)) && break
    sleep 0.1
  done
  ((sends >= 550)) || fail "only $sends sends in $((SECONDS - start)) s"
  now=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status")
  ((now - first <= 2048)) || fail "RSS grew from $first kB to $now kB"
  run cat "$T/feed.log"
  assert_output --partial "cannot send"
}
