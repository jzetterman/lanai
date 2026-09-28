#!/usr/bin/env bats
# Tests for the VM unit's building blocks (plan phase 4): vm_args, the
# runtime folder, run bookkeeping, the QMP and guest agent clients, helper
# supervision, and the unit's ExecStart and ExecStop scripts. No real VM
# starts: QEMU, systemctl, systemd-inhibit, dbus-monitor and virtiofsd are
# PATH shims or fakes, and every socket lives in the test's temp dir.
# shellcheck disable=SC2030,SC2031,SC2016

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
}

teardown() {
  local p
  for p in "${BG_PIDS[@]}"; do
    kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true
  done
  for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
}

# Put an executable shim <name> with body <script> first on PATH.
shim() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/shims/$1"
  chmod +x "$T/shims/$1"
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
