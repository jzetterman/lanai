#!/usr/bin/env bats
# Tests for the VM unit's building blocks (plan phase 4): vm_args, the
# runtime folder, run bookkeeping, the QMP and guest agent clients, helper
# supervision, and the unit's ExecStart and ExecStop scripts. No real VM
# starts: QEMU, systemctl, systemd-inhibit, dbus-monitor and virtiofsd are
# PATH shims or fakes, and every socket lives in the test's temp dir.
# shellcheck disable=SC2030,SC2031,SC2016,SC2329

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  RUN=$XDG_RUNTIME_DIR/lanai
  S=$XDG_STATE_HOME/lanai
  mkdir -p "$T/shims"
  BG_PIDS=()
  # The fake servers (test/fixtures/fake-*) read their knobs from here.
  export FAKE_CONF=$T/fake.conf
}

# Set the fake servers' knobs (KEY=value lines) for their next connection.
conf() {
  printf '%s\n' "$@" >"$FAKE_CONF"
}

teardown() {
  local p
  for p in "${BG_PIDS[@]}"; do
    pkill -P "$p" 2>/dev/null || true
    kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true
  done
  for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
}

# --- vm_args ---

# The arguments Lanai adds after the template, for RUN=$1 and scale $2.
additions() {
  cat <<EOF
-netdev
passt,id=hostnet0,ipv6=off,map-host-loopback=none,dns-forward=192.168.1.1
-object
memory-backend-memfd,id=mem,size=8G,share=on
-machine
memory-backend=mem
-object
memory-backend-file,id=ivshmem,share=on,mem-path=$1/ivshmem,size=128M
-device
ivshmem-plain,memdev=ivshmem
-spice
unix=on,addr=$1/spice.sock,disable-ticketing=on
-device
virtio-serial-pci
-chardev
spicevmc,id=vdagent,name=vdagent
-device
virtserialport,chardev=vdagent,name=com.redhat.spice.0
-chardev
socket,id=qga0,path=$1/qga.sock,server=on,wait=off
-device
virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
-chardev
spicevmc,id=usbredir0,name=usbredir
-device
usb-redir,chardev=usbredir0
-chardev
socket,id=vfs,path=$1/virtiofs.sock
-device
vhost-user-fs-pci,chardev=vfs,tag=lanai
-qmp
unix:$1/qmp.sock,server=on,wait=off
-qmp
unix:$1/qmp-events.sock,server=on,wait=off
-qmp
unix:$1/qmp-cli.sock,server=on,wait=off
-smbios
type=11,value=lanai-scale=$2
EOF
}

@test "vm_args: the template filled from settings plus Lanai's devices, and nothing else" {
  run vm_args /vm/store 02:4B:81:73:3C:96 8 4 150 192.168.1.1
  assert_success
  local want
  want=$(
    grep -v -e '^#' -e '^$' "$REPO/lib/dockur-6.05.args" |
      sed -e 's|@STORAGE@|/vm/store|g' -e 's|@MAC@|02:4B:81:73:3C:96|' \
        -e 's|@MEMORY@|8|' -e 's|@CORES@|4|g'
    additions "$RUN" 150
    printf '%s\n' -vga none -display none
  )
  assert_output "$want"
}

@test "vm_args: keeps every item of the captured dockur command line that spec req 2 covers" {
  # Walk the real capture: every option and value must reach Lanai's line,
  # apart from the rewrites the plan lists.
  run vm_args /vm/store 02:4B:81:73:3C:96 16 6 100 192.168.1.1
  assert_success
  local -a cap
  local i opt val out=$'\n'$output$'\n'
  mapfile -t cap <"$REPO/spike/test/fixtures/dockur-cmdline.txt"
  for ((i = 1; i < ${#cap[@]}; i++)); do
    opt=${cap[i]}
    [[ -n $opt ]] || continue
    case $opt in
      -nodefaults | -enable-kvm)
        [[ $out == *$'\n'"$opt"$'\n'* ]] || fail "missing $opt"
        continue
        ;;
    esac
    i=$((i + 1))
    val=${cap[i]}
    case $opt in
      # Replaced on purpose: display, HMP monitor, pid file, serial monitor,
      # tap network (plan: Architecture, VM hardware).
      -display | -vga | -monitor | -pidfile | -serial | -netdev) continue ;;
      -name) val="Lanai,process=lanai" ;;
    esac
    val=${val//\/storage\//\/vm\/store\/}
    [[ $out == *$'\n'"$opt"$'\n'"$val"$'\n'* ]] || fail "missing: $opt $val"
  done
}

@test "vm_args: memory and cores come from the settings" {
  run vm_args /vm/store 02:4b:81:73:3c:96 12 3 100 10.0.0.1
  assert_success
  assert_line "12G"
  assert_line "memory-backend-memfd,id=mem,size=12G,share=on"
  assert_line "3,sockets=1,dies=1,cores=3,threads=1"
  assert_line "virtio-net-pci,id=net0,netdev=hostnet0,romfile=,mac=02:4b:81:73:3c:96"
  assert_line "passt,id=hostnet0,ipv6=off,map-host-loopback=none,dns-forward=10.0.0.1"
}

@test "vm_args: no listener, port forward, container path or serial monitor" {
  run vm_args /vm/store 02:4B:81:73:3C:96 8 4 100 192.168.1.1
  assert_success
  refute_output --partial hostfwd
  refute_output --partial tcp-ports
  refute_output --partial udp-ports
  refute_output --partial /storage
  refute_output --partial /run/shm
  refute_output --partial mon:stdio
  refute_output --regexp '(^|[,=:])(tcp|udp|telnet|vnc|websocket)[:=]'
  refute_line -serial
  refute_line -monitor
}

@test "vm_args: the setup boot adds the GTK display and the read-only setup disk" {
  run vm_args /vm/store 02:4B:81:73:3C:96 8 4 150 192.168.1.1 /media/dir
  assert_success
  local want
  want=$(
    grep -v -e '^#' -e '^$' "$REPO/lib/dockur-6.05.args" |
      sed -e 's|@STORAGE@|/vm/store|g' -e 's|@MAC@|02:4B:81:73:3C:96|' \
        -e 's|@MEMORY@|8|' -e 's|@CORES@|4|g'
    additions "$RUN" 150
    printf '%s\n' -vga virtio -display gtk,window-close=off \
      -drive if=none,id=setup,file=fat:/media/dir,format=raw,readonly=on \
      -device usb-storage,drive=setup
  )
  assert_output "$want"
}

@test "vm_args: refuses a storage path with a comma, a newline, or no leading slash" {
  local bad
  for bad in /vm/a,b $'/vm/a\nb' vm/store ""; do
    run vm_args "$bad" 02:4B:81:73:3C:96 8 4 100 192.168.1.1
    assert_failure
    assert_output --partial "storage"
  done
}

@test "vm_args: refuses a malformed MAC" {
  local bad
  for bad in 02:4B:81:73:3C 02:4B:81:73:3C:96:00 02-4B-81-73-3C-96 02:4B:81:73:3C:9G \
    "02:4B:81:73:3C:96,x=1" " 02:4B:81:73:3C:96" ""; do
    run vm_args /vm/store "$bad" 8 4 100 192.168.1.1
    assert_failure
    assert_output --partial "MAC"
  done
}

@test "vm_args: refuses memory or cores out of range or not an integer" {
  local bad
  for bad in 0 513 8G 8,share=off -1 "" 08x; do
    run vm_args /vm/store 02:4B:81:73:3C:96 "$bad" 4 100 192.168.1.1
    assert_failure
    assert_output --partial "memory"
  done
  for bad in 0 65 4,sockets=2 "" 1.5; do
    run vm_args /vm/store 02:4B:81:73:3C:96 8 "$bad" 100 192.168.1.1
    assert_failure
    assert_output --partial "cores"
  done
  run vm_args /vm/store 02:4B:81:73:3C:96 512 64 100 192.168.1.1
  assert_success
  run vm_args /vm/store 02:4B:81:73:3C:96 1 1 100 192.168.1.1
  assert_success
}

@test "vm_args: refuses a scale that is not a Windows step, and a bad gateway" {
  local bad
  for bad in 137 275 50 550 "150,x" ""; do
    run vm_args /vm/store 02:4B:81:73:3C:96 8 4 "$bad" 192.168.1.1
    assert_failure
    assert_output --partial "scale"
  done
  for bad in 192.168.1 "192.168.1.1,hostfwd=tcp::1-:1" fe80::1 ""; do
    run vm_args /vm/store 02:4B:81:73:3C:96 8 4 100 "$bad"
    assert_failure
    assert_output --partial "gateway"
  done
}

@test "vm_args: refuses a setup media path or runtime folder with a comma" {
  run vm_args /vm/store 02:4B:81:73:3C:96 8 4 100 192.168.1.1 /media/a,b
  assert_failure
  assert_output --partial "setup media"
  XDG_RUNTIME_DIR=/run/a,b run vm_args /vm/store 02:4B:81:73:3C:96 8 4 100 192.168.1.1
  assert_failure
  assert_output --partial "runtime"
}

@test "vm_args: a template line that would open a listener or keep a container path fails" {
  local extra
  for extra in '-vnc\n:1' '-chardev\nsocket,id=m,host=127.0.0.1,port=4444,server=on' \
    '-serial\nmon:stdio' '-netdev\nuser,id=n,hostfwd=tcp::2222-:22' '-drive\nfile=/storage/x.img' \
    '-chardev\nsocket,id=x,path=/run/shm/x.sock'; do
    { cat "$REPO/lib/dockur-6.05.args"; printf '%b\n' "$extra"; } >"$T/args"
    LANAI_ARGS_TEMPLATE=$T/args run vm_args /vm/store 02:4B:81:73:3C:96 8 4 100 192.168.1.1
    assert_failure
    assert_output --partial "refusing"
  done
}

# --- run_dir_check ---

@test "run_dir_check: creates the runtime folder with mode 0700" {
  run run_dir_check
  assert_success
  assert_equal "$(stat -c '%a %u' "$RUN")" "700 $(id -u)"
}

@test "run_dir_check: accepts an existing 0700 folder owned by the user" {
  mkdir -m 700 "$RUN"
  touch "$RUN/client.log"
  run run_dir_check
  assert_success
  assert [ -e "$RUN/client.log" ]
}

@test "run_dir_check: refuses a symlink, a file, or a folder with another mode" {
  mkdir -m 700 "$T/elsewhere"
  ln -s "$T/elsewhere" "$RUN"
  run run_dir_check
  assert_failure
  assert_output --partial "symlink"
  rm "$RUN"

  touch "$RUN"
  run run_dir_check
  assert_failure
  assert_output --partial "not a folder"
  rm "$RUN"

  local mode
  for mode in 755 777 711 500; do
    mkdir -m "$mode" "$RUN"
    run run_dir_check
    assert_failure
    assert_output --partial "0700"
    rmdir "$RUN"
  done
}

@test "run_dir_check: refuses a folder owned by another user" {
  mkdir -m 700 "$RUN"
  shim id 'if [[ $1 == -u ]]; then echo 4242; else exec /usr/bin/id "$@"; fi'
  PATH=$T/shims:$PATH run run_dir_check
  assert_failure
  assert_output --partial "owned by"
}

# --- record_previous_run ---

# Write the marker files of a run: running <invocation>, and optionally a
# last-shutdown record <invocation> <guest true|false>.
mark_running() {
  mkdir -p "$S"
  printf '%s\n' "$1" >"$S/running"
}
mark_shutdown() {
  mkdir -p "$S"
  printf '{"invocation":"%s","guest":%s,"reason":"%s"}\n' "$1" "$2" "${3:-guest-shutdown}" \
    >"$S/last-shutdown"
}

# Assert that the run markers are all gone.
assert_markers_gone() {
  assert [ ! -e "$S/running" ]
  assert [ ! -e "$S/forced" ]
  assert [ ! -e "$S/last-shutdown" ]
}

@test "record_previous_run: a guest shutdown of the same run is clean" {
  mark_running aaaa1111
  mark_shutdown aaaa1111 true
  run record_previous_run
  assert_success
  assert_output clean
  assert_equal "$(<"$S/last-run")" clean
  assert_markers_gone
}

@test "record_previous_run: a crash (running marker, no shutdown record) is forced" {
  mark_running aaaa1111
  run record_previous_run
  assert_output forced
  assert_equal "$(<"$S/last-run")" forced
  assert_markers_gone
}

@test "record_previous_run: an external SIGTERM is forced, since the guest did not start it" {
  mark_running aaaa1111
  mark_shutdown aaaa1111 false host-signal
  run record_previous_run
  assert_output forced
  assert_markers_gone
}

@test "record_previous_run: the forced marker wins over a guest shutdown record" {
  mark_running aaaa1111
  mark_shutdown aaaa1111 true
  : >"$S/forced"
  run record_previous_run
  assert_output forced
  assert_equal "$(<"$S/last-run")" forced
  assert_markers_gone
}

@test "record_previous_run: a SIGKILL at reboot leaves only the running marker, so forced" {
  mark_running bbbb2222
  run record_previous_run
  assert_output forced
}

@test "record_previous_run: another run's shutdown record does not count" {
  mark_running bbbb2222
  mark_shutdown aaaa1111 true
  run record_previous_run
  assert_output forced
  assert_markers_gone
}

@test "record_previous_run: an empty running marker never matches a record" {
  mark_running ""
  mark_shutdown "" true
  run record_previous_run
  assert_output forced
}

@test "record_previous_run: a start that failed before the running marker reports nothing, once" {
  mark_running aaaa1111
  run record_previous_run
  assert_output forced
  # The panel shows the notice and clears it.
  rm "$S/last-run"
  # The next start fails before lanai-vm-exec writes its marker.
  run record_previous_run
  assert_success
  assert_output ""
  assert [ ! -e "$S/last-run" ]
  # A verdict the panel has not shown yet stays as it was.
  printf 'forced\n' >"$S/last-run"
  run record_previous_run
  assert_output ""
  assert_equal "$(<"$S/last-run")" forced
}

@test "record_previous_run: no markers at all means nothing to report" {
  run record_previous_run
  assert_success
  assert_output ""
  assert [ ! -e "$S/last-run" ]
}

@test "record_previous_run: a stale stop request is cleared with the markers" {
  mark_running aaaa1111
  printf 'aaaa1111 1700000000\n' >"$S/stop-requested"
  run record_previous_run
  assert [ ! -e "$S/stop-requested" ]
}

# --- the QMP and guest agent clients ---

# Serve <socket> with the fake server <script> (one run per connection) in
# the background, and wait until the socket exists.
serve() {
  local i
  socat "UNIX-LISTEN:$1,fork" "EXEC:$2" >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  for ((i = 0; i < 100; i++)); do
    [[ -S $1 ]] && return 0
    sleep 0.05
  done
  fail "the fake server did not create $1"
}

# Wait until file <f> holds a line matching <regex> (up to 3 s).
wait_for_line() {
  local i
  for ((i = 0; i < 60; i++)); do
    grep -qE -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.05
  done
  fail "no line matching $2 in $1"
}

@test "qmp_call: negotiates, then prints each command's reply without its id" {
  export FAKE_QMP_LOG=$T/qmp.log
  serve "$T/q.sock" "$FIX/fake-qmp"
  run qmp_call "$T/q.sock" '{"execute":"query-status"}' '{"execute":"query-chardev"}'
  assert_success
  assert_line --index 0 '{"return":{"status":"running","singlestep":false,"running":true}}'
  assert_line --index 1 --partial '"label":"qga0"'
  assert_equal "${#lines[@]}" 2
  # qmp_capabilities goes first; every command carries its own id.
  assert_equal "$(sed -n 1p "$T/qmp.log")" '{"execute":"qmp_capabilities","id":1}'
  assert_equal "$(sed -n 2p "$T/qmp.log")" '{"execute":"query-status","id":2}'
  assert_equal "$(sed -n 3p "$T/qmp.log")" '{"execute":"query-chardev","id":3}'
}

@test "qmp_call: skips events that arrive before a reply" {
  export FAKE_QMP_MODE=events
  serve "$T/q.sock" "$FIX/fake-qmp"
  run qmp_call "$T/q.sock" '{"execute":"query-status"}'
  assert_success
  assert_output '{"return":{"status":"running","singlestep":false,"running":true}}'
}

@test "qmp_call: prints an error reply for the caller to judge" {
  serve "$T/q.sock" "$FIX/fake-qmp"
  run qmp_call "$T/q.sock" '{"execute":"no-such-thing"}'
  assert_success
  assert_output --partial '"class":"CommandNotFound"'
}

@test "qmp_call: disconnects before it returns, since QEMU serves one client per socket" {
  export FAKE_QMP_LOG=$T/qmp.log
  serve "$T/q.sock" "$FIX/fake-qmp"
  run qmp_call "$T/q.sock" '{"execute":"query-status"}'
  assert_success
  wait_for_line "$T/qmp.log" '^<closed>$'
}

@test "qmp_call: fails at once without a socket, and in 5 s when QEMU does not answer" {
  run qmp_call "$T/none.sock" '{"execute":"query-status"}'
  assert_failure
  export FAKE_QMP_MODE=silent
  serve "$T/q.sock" "$FIX/fake-qmp"
  local start=$SECONDS
  run qmp_call "$T/q.sock" '{"execute":"query-status"}'
  assert_failure
  (((SECONDS - start) >= 4 && (SECONDS - start) <= 7)) || fail "took $((SECONDS - start)) s"
}

@test "qga_reply sync: flushes with 0xFF, skips the parse error, accepts its own id" {
  export FAKE_QGA_LOG=$T/qga.log
  serve "$T/g.sock" "$FIX/fake-qga"
  run qga_reply "$T/g.sock" sync
  assert_success
  assert_equal "$(sed -n 1p "$T/qga.log")" "flush ff"
  local req
  req=$(sed -n 's/^sync //p' "$T/qga.log")
  run jq -r '.execute + " " + (.arguments.id | type)' <<<"$req"
  assert_output "guest-sync-delimited number"
}

@test "qga_reply sync: uses a fresh id each time" {
  export FAKE_QGA_LOG=$T/qga.log
  serve "$T/g.sock" "$FIX/fake-qga"
  qga_reply "$T/g.sock" sync
  qga_reply "$T/g.sock" sync
  run sed -n 's/^sync //p' "$T/qga.log"
  assert_equal "${#lines[@]}" 2
  [[ ${lines[0]} != "${lines[1]}" ]] || fail "the same id twice: ${lines[0]}"
}

@test "qga_reply sync: discards a stale reply with another id" {
  export FAKE_QGA=stale
  serve "$T/g.sock" "$FIX/fake-qga"
  run qga_reply "$T/g.sock" sync
  assert_success
  # A stale reply alone never counts as the sync.
  conf FAKE_QGA=stale-only
  run qga_reply "$T/g.sock" sync
  assert_failure
}

@test "qga_reply: rejects junk, wrong JSON and replies over 4 KiB" {
  serve "$T/g.sock" "$FIX/fake-qga"
  local mode
  for mode in junk string error big-pre big-line; do
    conf "FAKE_QGA=$mode"
    run qga_reply "$T/g.sock" sync
    assert_failure
    conf "FAKE_QGA=$mode"
    run qga_reply "$T/g.sock" command '{"execute":"guest-set-time"}'
    assert_failure
    conf "FAKE_QGA=$mode"
    run qga_reply "$T/g.sock" refusal '{"execute":"guest-exec"}'
    assert_failure
  done
}

@test "qga_reply: times out at 5 s when the agent is silent" {
  export FAKE_QGA=silent
  serve "$T/g.sock" "$FIX/fake-qga"
  local start=$SECONDS
  run qga_reply "$T/g.sock" sync
  assert_failure
  (((SECONDS - start) >= 4 && (SECONDS - start) <= 7)) || fail "took $((SECONDS - start)) s"
}

@test "qga_reply command: syncs first, then accepts only an empty return" {
  export FAKE_QGA_LOG=$T/qga.log
  serve "$T/g.sock" "$FIX/fake-qga"
  run qga_reply "$T/g.sock" command '{"execute":"guest-set-time","arguments":{"time":1}}'
  assert_success
  assert_equal "$(sed -n 3p "$T/qga.log")" 'cmd {"execute":"guest-set-time","arguments":{"time":1}}'
  local reply
  for reply in other generic disabled notfound; do
    conf "FAKE_QGA_CMD=$reply"
    run qga_reply "$T/g.sock" command '{"execute":"guest-set-time"}'
    assert_failure
  done
}

@test "qga_reply refusal: passes only on the 'has been disabled' CommandNotFound" {
  serve "$T/g.sock" "$FIX/fake-qga"
  conf FAKE_QGA_CMD=disabled
  run qga_reply "$T/g.sock" refusal '{"execute":"guest-exec"}'
  assert_success
  local reply
  for reply in empty other generic notfound; do
    conf "FAKE_QGA_CMD=$reply"
    run qga_reply "$T/g.sock" refusal '{"execute":"guest-exec"}'
    assert_failure
  done
}

@test "qga_reply: refuses an unknown mode, a missing command, and a missing socket" {
  run qga_reply "$T/g.sock" sync
  assert_failure
  serve "$T/g.sock" "$FIX/fake-qga"
  run qga_reply "$T/g.sock" command
  assert_failure
  run qga_reply "$T/g.sock" exec '{"execute":"guest-exec"}'
  assert_failure
}

# --- helper supervision ---

@test "restart_delay: backs off 1, 2, then 4 s by restarts in the last minute" {
  run restart_delay 1000
  assert_output 1
  run restart_delay 1000 990
  assert_output 2
  run restart_delay 1000 990 995
  assert_output 4
  run restart_delay 1000 950 960 970 980
  assert_output 4
}

@test "restart_delay: gives up after 5 restarts in a minute, and only counts that minute" {
  run restart_delay 1000 941 950 960 970 980
  assert_failure
  # The oldest restart is now more than 60 s ago.
  run restart_delay 1001 940 950 960 970 980
  assert_success
  assert_output 4
  # Restarts long ago do not count at all.
  run restart_delay 5000 100 200 300 400 500 600
  assert_output 1
}

@test "supervise: restarts a crashing helper with backoff, then gives up and drops its pid file" {
  mkdir -m 700 "$RUN"
  shim sleep 'echo "$1" >>"$SLEEP_LOG"'
  export SLEEP_LOG=$T/sleeps
  printf '#!/usr/bin/env bash\necho run >>"%s"\nexit 3\n' "$T/runs" >"$T/crash"
  chmod +x "$T/crash"
  PATH=$T/shims:$PATH run supervise crasher "$T/crash"
  assert_failure
  assert_equal "$(wc -l <"$T/runs")" 6
  assert_equal "$(paste -sd' ' "$T/sleeps")" "1 2 4 4 4"
  assert_output --partial "crasher exited (3) 5 times in a minute"
  assert [ ! -e "$RUN/crasher.pid" ]
}

@test "supervise: writes its own pid while the helper runs" {
  mkdir -m 700 "$RUN"
  supervise holder sleep 30 >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  local i
  for ((i = 0; i < 60; i++)); do
    [[ -s $RUN/holder.pid ]] && break
    sleep 0.05
  done
  assert_equal "$(<"$RUN/holder.pid")" "${BG_PIDS[0]}"
}

# --- helpers: event logger, shutdown and sleep watchers ---

@test "event_log: records the guest's SHUTDOWN with this run's invocation id" {
  mkdir -m 700 "$RUN"
  export FAKE_QMP_MODE=shutdown INVOCATION_ID=inv-1
  serve "$RUN/qmp-events.sock" "$FIX/fake-qmp"
  run timeout 10 bash -c 'source "$1"; event_log' _ "$REPO/lib/lanai.sh"
  assert_success
  assert_equal "$(jq -c . "$S/last-shutdown")" '{"invocation":"inv-1","guest":true,"reason":"guest-shutdown"}'
}

@test "event_log: records a host-initiated SHUTDOWN as not the guest's" {
  mkdir -m 700 "$RUN"
  export FAKE_QMP_MODE=shutdown FAKE_QMP_GUEST=false INVOCATION_ID=inv-2
  serve "$RUN/qmp-events.sock" "$FIX/fake-qmp"
  run timeout 10 bash -c 'source "$1"; event_log' _ "$REPO/lib/lanai.sh"
  assert_success
  assert_equal "$(jq -c .guest "$S/last-shutdown")" false
}

@test "event_log: waits for QEMU to create its socket, then connects" {
  mkdir -m 700 "$RUN"
  export FAKE_QMP_MODE=shutdown INVOCATION_ID=inv-3
  timeout 20 bash -c 'source "$1"; event_log' _ "$REPO/lib/lanai.sh" >/dev/null 2>&1 3>&- &
  local logger=$!
  BG_PIDS+=("$logger")
  sleep 1
  assert [ ! -e "$S/last-shutdown" ]
  serve "$RUN/qmp-events.sock" "$FIX/fake-qmp"
  wait "$logger"
  assert_equal "$(jq -r .invocation "$S/last-shutdown")" inv-3
}

@test "shutdown_watch_lines: PrepareForShutdown(true) stops the unit without blocking" {
  shim systemctl 'echo "$*" >>"$CALLS"'
  export CALLS=$T/calls
  PATH=$T/shims:$PATH run shutdown_watch_lines <<'EOF'
signal time=1727560849.995 sender=:1.3 -> destination=(null destination) serial=1 path=/org/freedesktop/login1; interface=org.freedesktop.login1.Manager; member=PrepareForShutdown
   boolean false
signal time=1727560850.000 sender=:1.3 -> destination=(null destination) serial=2 path=/org/freedesktop/login1; interface=org.freedesktop.login1.Manager; member=PrepareForShutdown
   boolean true
EOF
  assert_success
  assert_equal "$(<"$T/calls")" "--user stop --no-block lanai-vm.service"
}

@test "sleep_watch_lines: a resume sets the guest clock to the host's, a suspend does nothing" {
  # Stand-in for the agent call: log the mode and command.
  qga_reply() { printf '%s %s\n' "$2" "$3" >>"$T/qga-calls"; }
  run sleep_watch_lines <<'EOF'
   boolean true
   boolean false
EOF
  assert_success
  assert_equal "$(wc -l <"$T/qga-calls")" 1
  local mode cmd ns
  read -r mode cmd <"$T/qga-calls"
  assert_equal "$mode" command
  assert_equal "$(jq -r .execute <<<"$cmd")" guest-set-time
  ns=$(jq -r .arguments.time <<<"$cmd")
  # Nanoseconds since the epoch, within 5 s of now.
  (((ns / 1000000000) - $(date +%s) <= 5 && $(date +%s) - (ns / 1000000000) <= 5)) ||
    fail "time $ns is not now"
}

@test "clock_sync: retries a busy agent, and stops trying after 60 s" {
  shim sleep ':'
  echo 0 >"$T/count"
  # Busy twice, then answers.
  qga_reply() {
    local n=$(($(<"$T/count") + 1))
    echo "$n" >"$T/count"
    ((n >= 3))
  }
  PATH=$T/shims:$PATH run clock_sync
  assert_success
  assert_equal "$(<"$T/count")" 3
  # Never answers: it gives up after its 30 tries of 2 s.
  echo 0 >"$T/count"
  qga_reply() {
    echo $(($(<"$T/count") + 1)) >"$T/count"
    return 1
  }
  PATH=$T/shims:$PATH run clock_sync
  assert_failure
  assert_equal "$(<"$T/count")" 30
}

# --- lanai-vm-exec ---

# Shims for everything lanai-vm-exec starts: QEMU records its arguments and
# TMPDIR, virtiofsd creates its socket (unless NO_VFS_SOCKET is set), the
# inhibitor and dbus-monitor just wait, and ip reports a default route.
exec_shims() {
  shim qemu-system-x86_64 'printf "%s\n" "$@" >"$T/qemu.args.tmp"; echo "$TMPDIR" >"$T/qemu.tmpdir"
mv "$T/qemu.args.tmp" "$T/qemu.args"; exec sleep 30'
  shim virtiofsd 'printf "%s\n" "$@" >"$T/virtiofsd.args"
[[ -z ${NO_VFS_SOCKET:-} ]] || exec sleep 30
for a; do [[ $a != --socket-path=* ]] || p=${a#*=}; done
exec socat "UNIX-LISTEN:$p,fork" EXEC:/bin/true'
  shim systemd-inhibit 'printf "%s\n" "$@" >"$T/inhibit.args"; exec sleep 30'
  shim dbus-monitor 'exec sleep 30'
  shim ip 'echo "default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.20 metric 600"'
  export T LANAI_VIRTIOFSD=$T/shims/virtiofsd INVOCATION_ID=inv-exec
  make_install "$T/win"
  mkdir -p "$HOME/Windows" "$XDG_CONFIG_HOME/lanai"
  echo '{"storage": "'"$T/win"'", "memory_gib": 8, "cores": 4}' >"$XDG_CONFIG_HOME/lanai/settings.json"
}

# Start lanai-vm-exec in its own process group, in the background, with its
# output in $T/exec.out. Sets EXEC_PID (also the group id).
start_exec() {
  PATH=$T/shims:$PATH setsid "$REPO/bin/lanai-vm-exec" >"$T/exec.out" 2>&1 3>&- &
  EXEC_PID=$!
  BG_PIDS+=("$EXEC_PID")
}

@test "lanai-vm-exec: prepares \$RUN, starts the helpers, writes the marker, then becomes QEMU" {
  exec_shims
  mkdir -m 700 "$RUN"
  : >"$RUN/qmp.sock"
  : >"$RUN/ivshmem"
  echo "old client log" >"$RUN/client.log"
  mkdir -p "$S"
  echo '{"scale": 150, "setup": false}' >"$S/boot.json"
  start_exec
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -e $T/qemu.args ]] && break
    sleep 0.05
  done
  [[ -e $T/qemu.args ]] || fail "QEMU never started: $(cat "$T/exec.out")"
  # The stale files are gone and the log is empty.
  assert [ ! -e "$RUN/qmp.sock" ]
  assert [ ! -e "$RUN/ivshmem" ]
  assert [ ! -s "$RUN/client.log" ]
  assert_equal "$(stat -c %a "$RUN")" 700
  # QEMU runs as the unit's main process, with the arguments vm_args builds.
  assert_equal "$(<"$T/qemu.args")" "$(vm_args "$T/win" 02:4B:81:73:3C:96 8 4 150 192.168.1.1)"
  assert_equal "$(<"$T/qemu.tmpdir")" "$RUN"
  assert_equal "$(tr '\0' ' ' </proc/"$EXEC_PID"/cmdline)" "sleep 30 "
  assert_equal "$(<"$S/running")" inv-exec
  # Each helper runs under its supervisor, whose pid is in $RUN.
  local name
  for name in virtiofsd inhibitor sleep-watcher event-logger; do
    [[ -s $RUN/$name.pid ]] || fail "no pid file for $name"
    kill -0 "$(<"$RUN/$name.pid")" || fail "$name's supervisor is not running"
  done
  assert_equal "$(paste -sd' ' "$T/virtiofsd.args")" \
    "--sandbox namespace --shared-dir $HOME/Windows --socket-path=$RUN/virtiofs.sock"
  run cat "$T/inhibit.args"
  assert_line --index 0 --partial "--what=shutdown"
  assert_line --index 1 --partial "--mode=delay"
  assert_line --partial "lanai-vm-helper"
  assert_line shutdown-watch
}

@test "lanai-vm-exec: the setup boot attaches the setup media" {
  exec_shims
  mkdir -p "$S/setup-media"
  echo '{"scale": 100, "setup": true}' >"$S/boot.json"
  start_exec
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -e $T/qemu.args ]] && break
    sleep 0.05
  done
  run cat "$T/qemu.args"
  assert_line "if=none,id=setup,file=fat:$S/setup-media,format=raw,readonly=on"
  assert_line "gtk,window-close=off"
}

@test "lanai-vm-exec: a bad runtime folder stops it before anything starts" {
  exec_shims
  mkdir -m 755 "$RUN"
  start_exec
  local rc=0
  wait "$EXEC_PID" || rc=$?
  ((rc != 0)) || fail "lanai-vm-exec succeeded"
  assert [ ! -e "$T/qemu.args" ]
  assert [ ! -e "$T/virtiofsd.args" ]
  assert [ ! -e "$S/running" ]
  run cat "$T/exec.out"
  assert_output --partial "0700"
}

@test "lanai-vm-exec: without virtiofsd's socket it fails and writes no marker" {
  exec_shims
  export NO_VFS_SOCKET=1
  start_exec
  local rc=0
  wait "$EXEC_PID" || rc=$?
  ((rc != 0)) || fail "lanai-vm-exec succeeded"
  assert [ ! -e "$T/qemu.args" ]
  assert [ ! -e "$S/running" ]
  run cat "$T/exec.out"
  assert_output --partial "virtiofsd"
}

@test "lanai-vm-exec: refuses bad settings through vm_args" {
  exec_shims
  echo '{"storage": "'"$T/win"'", "memory_gib": "8,share=off", "cores": 4}' \
    >"$XDG_CONFIG_HOME/lanai/settings.json"
  start_exec
  local rc=0
  wait "$EXEC_PID" || rc=$?
  ((rc != 0)) || fail "lanai-vm-exec succeeded"
  assert [ ! -e "$T/qemu.args" ]
  run cat "$T/exec.out"
  assert_output --partial "memory"
}

# --- lanai-vm-stop ---

# Start a stand-in for QEMU that is not this shell's child (so it never
# lingers as a zombie). Sets FAKE_PID.
fake_main() {
  FAKE_PID=$(bash -c 'sleep 60 >/dev/null 2>&1 3>&- & echo $!')
}

@test "lanai-vm-stop: sends system_powerdown, waits for QEMU, then for this run's record" {
  mkdir -m 700 "$RUN"
  fake_main
  export FAKE_QMP_LOG=$T/qmp.log FAKE_QMP_KILL=$FAKE_PID FAKE_QMP_RECORD=$S/last-shutdown \
    FAKE_QMP_INVOCATION=inv-stop
  mkdir -p "$S"
  serve "$RUN/qmp.sock" "$FIX/fake-qmp"
  local start=$SECONDS
  INVOCATION_ID=inv-stop MAINPID=$FAKE_PID run "$REPO/bin/lanai-vm-stop"
  assert_success
  grep -q '"execute":"system_powerdown"' "$T/qmp.log" || fail "no system_powerdown sent"
  ! kill -0 "$FAKE_PID" 2>/dev/null || fail "returned while QEMU still ran"
  # The record was already there, so there was no 2 s wait.
  (((SECONDS - start) <= 1)) || fail "took $((SECONDS - start)) s"
}

@test "lanai-vm-stop: after QEMU exited on its own it skips the powerdown" {
  mkdir -m 700 "$RUN"
  export FAKE_QMP_LOG=$T/qmp.log
  serve "$RUN/qmp.sock" "$FIX/fake-qmp"
  mkdir -p "$S"
  printf '{"invocation":"inv-x","guest":true,"reason":"guest-shutdown"}\n' >"$S/last-shutdown"
  EXIT_CODE=exited EXIT_STATUS=0 INVOCATION_ID=inv-x MAINPID="" run "$REPO/bin/lanai-vm-stop"
  assert_success
  assert [ ! -e "$T/qmp.log" ]
}

@test "lanai-vm-stop: waits at most about 2 s for a record that never comes" {
  mkdir -m 700 "$RUN"
  mkdir -p "$S"
  # Another run's record does not end the wait.
  printf '{"invocation":"inv-old","guest":true,"reason":"guest-shutdown"}\n' >"$S/last-shutdown"
  local start=$SECONDS
  EXIT_CODE=killed EXIT_STATUS=KILL INVOCATION_ID=inv-new run "$REPO/bin/lanai-vm-stop"
  assert_success
  (((SECONDS - start) >= 1 && (SECONDS - start) <= 4)) || fail "took $((SECONDS - start)) s"
}
