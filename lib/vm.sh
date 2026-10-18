# The VM unit's building blocks (plan phase 4): paths, QEMU arguments, the
# runtime folder, run bookkeeping, the QMP and guest agent clients, helper
# supervision, and the unit's start and stop paths. lib/lanai.sh sources this
# file; it defines functions and constants only.
# shellcheck shell=bash

# The static QEMU template (dockur 6.05's captured line). Tests may point it
# at a copy.
LANAI_ARGS_TEMPLATE=${LANAI_ARGS_TEMPLATE:-$LANAI_LIB/dockur-6.05.args}

# The folder of Lanai's scripts (bin/ beside lib/, in the plugin or its
# runtime copy), and the virtiofsd binary (tests swap in a stand-in).
LANAI_BIN=$(cd -- "$LANAI_LIB/../bin" && pwd)
LANAI_VIRTIOFSD=${LANAI_VIRTIOFSD:-/usr/lib/virtiofsd}

# The VM unit's name.
LANAI_UNIT=lanai-vm.service

# The helpers lanai-vm-exec starts, by the name of their pid file in $RUN
# (the lanai-vm-helper subcommand, or virtiofsd), each with what is lost
# while it is down (lanai status shows it as a warning on the running
# state).
declare -gA LANAI_HELPERS=(
  [virtiofsd]="file sharing through ~/Windows is off"
  [shutdown-watch]="a clean Windows shutdown at reboot or power-off is off"
  [sleep-watch]="clock sync after suspend is off"
  [event-log]="clean-shutdown tracking is off, so the next start may report a forced stop"
  [scale-feed]="the Windows scale does not follow saves or monitors"
)

# The scale feed's loop period, start to start, and each send's deadline,
# in seconds (tests shorten both).
LANAI_SCALE_INTERVAL=${LANAI_SCALE_INTERVAL:-2}
LANAI_SCALE_SEND_TIMEOUT=${LANAI_SCALE_SEND_TIMEOUT:-1}

# How often lanai-vm-stop repeats system_powerdown while QEMU runs, in
# seconds (tests shorten it).
LANAI_POWERDOWN_INTERVAL=${LANAI_POWERDOWN_INTERVAL:-10}

# The Windows display scale steps (spec 12), for validation.
LANAI_SCALE_STEPS=" 100 125 150 175 200 225 250 300 350 400 450 500 "

# --- paths ---

# Print Lanai's state folder: setup state, run markers and last-run.
state_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/lanai"
}

# Print Lanai's data folder: runtime copies, snapshots and client builds.
data_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/lanai"
}

# Print the runtime folder $RUN. Fails when XDG_RUNTIME_DIR is unset.
run_dir() {
  [[ -n ${XDG_RUNTIME_DIR:-} ]] || {
    echo "lanai: XDG_RUNTIME_DIR is not set" >&2
    return 1
  }
  printf '%s\n' "$XDG_RUNTIME_DIR/lanai"
}

# --- QEMU arguments ---

# Print the VM's QEMU arguments (after argv[0]), one per line: the template
# filled with the settings, then Lanai's devices (plan: VM hardware). Two
# separate setup-boot choices (plan phase 6): <setup-media> adds the
# read-only setup disk, and <window> true shows QEMU's own GTK window
# instead of the headless display. Every input is checked before use, and
# the result is scanned for listeners and container paths, failing closed.
#   vm_args <storage> <mac> <memory-gib> <cores> <scale> <save> <gateway or ""> [<setup-media or ""> [<window true|false>]]
# An empty gateway (no default route) boots without passt's DNS forward.
# <save> is the scale save number (spec 27), the scale task's baseline.
vm_args() {
  local storage=$1 mac=$2 mem=$3 cores=$4 scale=$5 save=$6 gw=$7 media=${8:-} window=${9:-false} run arg
  local -a out=()
  run=$(run_dir) || return 1
  if [[ $storage != /* || $storage == *[,$'\n']* ]]; then
    echo "the storage location must be an absolute path without a comma or a newline: ${storage@Q}"
    return 1
  fi
  if [[ ! $mac =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "windows.mac does not hold a MAC address: ${mac@Q}"
    return 1
  fi
  if [[ ! $mem =~ ^[1-9][0-9]{0,2}$ ]] || ((mem > 512)); then
    echo "memory must be a whole number of GiB from 1 to 512: ${mem@Q}"
    return 1
  fi
  if [[ ! $cores =~ ^[1-9][0-9]?$ ]] || ((cores > 64)); then
    echo "cores must be a whole number from 1 to 64: ${cores@Q}"
    return 1
  fi
  if [[ ! $scale =~ ^[0-9]+$ || $LANAI_SCALE_STEPS != *" $scale "* ]]; then
    echo "the scale must be a Windows scale step: ${scale@Q}"
    return 1
  fi
  if [[ ! $save =~ ^[0-9]{1,9}$ ]]; then
    echo "the scale save number must be a whole number below 10^9: ${save@Q}"
    return 1
  fi
  if [[ -n $gw && ! $gw =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "the gateway must be an IPv4 address: ${gw@Q}"
    return 1
  fi
  if [[ -n $media && ($media != /* || $media == *[:,$'\n']*) ]]; then
    echo "the setup media path must be absolute, without a colon, comma or newline: ${media@Q}"
    return 1
  fi
  if [[ $window != true && $window != false ]]; then
    echo "the window choice must be true or false: ${window@Q}"
    return 1
  fi
  if [[ $run == *[,$'\n']* ]]; then
    echo "the runtime folder must not contain a comma or a newline: ${run@Q}"
    return 1
  fi

  while IFS= read -r arg; do
    [[ -n $arg && $arg != \#* ]] || continue
    # A container path the template kept by mistake. Checked before the
    # user's own paths are filled in, which may well contain "storage".
    if [[ $arg == */storage* || $arg == */run/shm* ]]; then
      echo "refusing a container path in the VM's arguments: $arg"
      return 1
    fi
    # The inner quotes keep a & in a path literal (bash 5.2 patsub_replacement).
    arg=${arg//@STORAGE@/"$storage"}
    arg=${arg//@MAC@/"$mac"}
    arg=${arg//@MEMORY@/"$mem"}
    out+=("${arg//@CORES@/"$cores"}")
  done <"$LANAI_ARGS_TEMPLATE"

  out+=(
    -netdev "passt,id=hostnet0,ipv6=off,map-host-loopback=none${gw:+,dns-forward=$gw}"
    -object "memory-backend-memfd,id=mem,size=${mem}G,share=on" -machine memory-backend=mem
    -object "memory-backend-file,id=ivshmem,share=on,mem-path=$run/ivshmem,size=128M"
    -device "ivshmem-plain,memdev=ivshmem"
    -spice "unix=on,addr=$run/spice.sock,disable-ticketing=on"
    -device virtio-serial-pci
    -chardev "spicevmc,id=vdagent,name=vdagent"
    -device "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
    -chardev "socket,id=qga0,path=$run/qga.sock,server=on,wait=off"
    -device "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"
    -chardev "socket,id=scale0,path=$run/scale.sock,server=on,wait=off"
    -device "virtserialport,chardev=scale0,name=io.lanai.scale.0"
    -chardev "spicevmc,id=usbredir0,name=usbredir"
    -device "usb-redir,chardev=usbredir0"
    -chardev "socket,id=vfs,path=$run/virtiofs.sock"
    # guest/lanai-share-check.ps1 finds the share by this tag as its
    # VolumeLabel: renaming it stops every setup at setup.cmd's [5/8].
    -device "vhost-user-fs-pci,chardev=vfs,tag=lanai"
    -qmp "unix:$run/qmp.sock,server=on,wait=off"
    -qmp "unix:$run/qmp-events.sock,server=on,wait=off"
    -qmp "unix:$run/qmp-cli.sock,server=on,wait=off"
    -smbios "type=11,value=lanai-scale=$scale,value=lanai-scale-save=$save"
  )
  if [[ -n $media ]]; then
    out+=(-drive "if=none,id=setup,file=fat:$media,format=raw,readonly=on"
      -device "usb-storage,drive=setup")
  fi
  if [[ $window == true ]]; then
    # window-close=off: closing the setup window must not power off the VM.
    out+=(-vga virtio -display "gtk,window-close=off")
  else
    out+=(-vga none -display none)
  fi

  # Fail closed (spec 25): no network listener, port forward (passt's
  # tcp-ports, udp-ports or raw param) or serial monitor. Options match only
  # at a boundary, so vmport=off is not port=. The only -netdev is Lanai's
  # passt line.
  local listener='^-(vnc|gdb|s|incoming|nic|net|serial|monitor)$|(^|,)(tls-)?port=|(^|,)(vnc|websocket|tcp-ports|udp-ports|param)=|(^|[,=:])(tcp|telnet|udp):|hostfwd|mon:'
  local netdevs=0
  for arg in "${out[@]}"; do
    [[ $arg != -netdev ]] || netdevs=$((netdevs + 1))
    if [[ $arg =~ $listener ]]; then
      echo "refusing a network listener or monitor in the VM's arguments: $arg"
      return 1
    fi
  done
  if ((netdevs != 1)); then
    echo "refusing a network backend other than passt in the VM's arguments"
    return 1
  fi
  printf '%s\n' "${out[@]}"
}

# --- runtime folder ---

# Create $RUN with mode 0700, or check the one that exists: refuse a symlink,
# a non-folder, another owner, or any mode but 0700 (plan: Paths). Runs
# before any runtime file is created. Prints the problem and fails.
run_dir_check() {
  local run st
  run=$(run_dir) || return 1
  if [[ -L $run ]]; then
    echo "$run is a symlink; remove it and start again"
    return 1
  fi
  if [[ ! -e $run ]] && ! mkdir -m 700 -- "$run" 2>/dev/null; then
    echo "cannot create $run"
    return 1
  fi
  if [[ -L $run || ! -d $run ]]; then
    echo "$run is not a folder; remove it and start again"
    return 1
  fi
  st=$(stat -c '%u %a' -- "$run") || return 1
  if [[ ${st% *} != "$(id -u)" ]]; then
    echo "$run is owned by another user"
    return 1
  elif [[ ${st#* } != 700 ]]; then
    echo "$run has mode 0${st#* }; Lanai needs 0700 (run: chmod 700 $run)"
    return 1
  fi
}

# --- run bookkeeping ---

# Read the other markers before running: its presence proves they predate cleanup.
# No writes; callers only interpret ended runs when the unit is stopped.
run_verdict() {
  local s inv="" started="" shutdown='{}' forced=false requested="" boot=false verdict=none complete=false
  s=$(state_dir)
  [[ ! -f $s/started ]] || started=$(<"$s/started")
  shutdown=$(jq -c . "$s/last-shutdown" 2>/dev/null) || shutdown='{}'
  [[ ! -e $s/forced ]] || forced=true
  [[ ! -f $s/stop-requested ]] || read -r requested _ <"$s/stop-requested" || true
  boot=$(jq -r '.setup == true' "$s/boot.json" 2>/dev/null) || boot=false
  [[ ! -f $s/running ]] || inv=$(<"$s/running")
  if $forced; then verdict=forced
  elif [[ -n $inv ]]; then
    if [[ $started == "$inv" ]]; then
      verdict=forced
      if jq -e --arg i "$inv" '.invocation == $i and .guest == true' <<<"$shutdown" >/dev/null; then
        verdict=clean
      fi
    else verdict=nostart; fi
  fi
  [[ $verdict != clean || $boot != true || $requested == "$inv" ]] || complete=true
  jq -nc --arg v "$verdict" --arg i "$inv" --argjson c "$complete" \
    '{verdict:$v, invocation:$i, completes_step5:$c}'
}

# Consume the pure verdict under the operation lock, recording last-run and
# step5 first. Remove running before the other markers so readers see the write.
record_previous_run() {
  local s doc verdict
  s=$(state_dir)
  mkdir -p -- "$s"
  doc=$(run_verdict)
  verdict=$(jq -r .verdict <<<"$doc")
  if [[ $verdict == clean || $verdict == forced ]]; then
    printf '%s\n' "$verdict" >"$s/last-run.tmp" && mv -f -- "$s/last-run.tmp" "$s/last-run"
  fi
  if [[ -f $s/setup.json ]] && jq -e '.completes_step5' <<<"$doc" >/dev/null; then
    setup_set step5 true || echo "lanai: cannot record step 5 in setup.json" >&2
  fi
  rm -f -- "$s/running"
  rm -f -- "$s/started" "$s/forced" "$s/last-shutdown" "$s/stop-requested"
  [[ $verdict == none ]] || printf '%s\n' "$verdict"
}

# --- socket clients (QMP and the guest agent) ---

# Print the time in microseconds since the epoch.
now_us() {
  printf '%s\n' "${EPOCHREALTIME//[!0-9]/}"
}

# Print the seconds left until <deadline> (microseconds since the epoch) as
# a decimal for read -t, or fail when none are left.
time_left() {
  local left=$(($1 - $(now_us)))
  ((left > 0)) || return 1
  printf '%d.%06d\n' $((left / 1000000)) $((left % 1000000))
}

# Connect to the Unix socket <sock> through socat. Sets LANAI_SOCK_R and
# LANAI_SOCK_W (read and write fds) and LANAI_SOCK_PID. One connection at a
# time; sock_close ends it. Fails when there is no socket or socat died.
sock_open() {
  LANAI_SOCK_R="" LANAI_SOCK_W="" LANAI_SOCK_PID=""
  [[ -S $1 ]] || return 1
  coproc LANAI_SOCK_CO { exec socat - "UNIX-CONNECT:$1" 2>/dev/null; }
  LANAI_SOCK_PID=$LANAI_SOCK_CO_PID
  # Copies of the coproc's fds: bash closes its own as soon as socat exits.
  if [[ -z ${LANAI_SOCK_CO[0]:-} || -z ${LANAI_SOCK_CO[1]:-} ]] ||
    ! { exec {LANAI_SOCK_R}<&"${LANAI_SOCK_CO[0]}" {LANAI_SOCK_W}>&"${LANAI_SOCK_CO[1]}"; } 2>/dev/null; then
    sock_close
    return 1
  fi
}

# Close the connection from sock_open and wait for socat to exit.
sock_close() {
  [[ -z ${LANAI_SOCK_W:-} ]] || exec {LANAI_SOCK_W}>&-
  [[ -z ${LANAI_SOCK_R:-} ]] || exec {LANAI_SOCK_R}<&-
  if [[ -n ${LANAI_SOCK_PID:-} ]]; then
    kill "$LANAI_SOCK_PID" 2>/dev/null || true
    wait "$LANAI_SOCK_PID" 2>/dev/null || true
  fi
  LANAI_SOCK_R="" LANAI_SOCK_W="" LANAI_SOCK_PID=""
}

# Write <line> and a newline to the open connection. The write runs in a
# subshell, so a closed connection fails it instead of killing the caller
# with SIGPIPE.
sock_send() {
  (printf '%s\n' "$1" >&"$LANAI_SOCK_W") 2>/dev/null
}

# qmp_call <socket> <command-json>...: one QMP session. It reads the
# greeting, negotiates capabilities, sends each command with its own id,
# and prints each command's reply on its own line as compact JSON (a
# "return" or an "error" object, id removed); events are skipped. It
# always disconnects before it returns, since QEMU serves one client per
# socket. Fails when it cannot connect, a line is not JSON, or the replies
# take longer than the session's budget (LANAI_QMP_BUDGET, default 5 s).
qmp_call() {
  local sock=$1 cmd rc=0
  shift
  qmp_open "$sock" || return 1
  for cmd; do
    qmp_send "$cmd" || {
      rc=1
      break
    }
  done
  sock_close
  return "$rc"
}

# qmp_open <socket>: connect, read QEMU's greeting and negotiate
# capabilities, leaving the connection open for qmp_send or for reading
# events on LANAI_SOCK_R. Starts the session's budget: LANAI_QMP_BUDGET
# seconds, default 5 (the client wait uses 2 per try). On failure the
# connection is closed.
qmp_open() {
  local t line
  sock_open "$1" || return 1
  LANAI_QMP_DEADLINE=$(($(now_us) + ${LANAI_QMP_BUDGET:-5} * 1000000)) LANAI_QMP_ID=0
  if t=$(time_left "$LANAI_QMP_DEADLINE") && IFS= read -r -t "$t" -u "$LANAI_SOCK_R" line &&
    jq -e 'has("QMP")' <<<"$line" >/dev/null 2>&1 &&
    qmp_send '{"execute":"qmp_capabilities"}' >/dev/null; then
    return 0
  fi
  sock_close
  return 1
}

# qmp_send <command-json>: on the connection from qmp_open, send one command
# with the next id and print its reply (compact, id removed); events before
# it are skipped. Fails on a line that is not JSON, or when the session's
# budget runs out. Call it directly, not in $(...), so the id count survives.
qmp_send() {
  local cmd line t reply="" id=$((LANAI_QMP_ID + 1))
  LANAI_QMP_ID=$id
  if ! cmd=$(jq -c --argjson id "$id" '. + {id: $id}' <<<"$1" 2>/dev/null) || ! sock_send "$cmd"; then
    return 1
  fi
  while [[ -z $reply ]]; do
    if ! { t=$(time_left "$LANAI_QMP_DEADLINE") && IFS= read -r -t "$t" -u "$LANAI_SOCK_R" line &&
      reply=$(jq -c --argjson id "$id" 'select(.id == $id) | del(.id)' <<<"$line" 2>/dev/null); }; then
      return 1
    fi
  done
  printf '%s\n' "$reply"
}

# chardev_open <label>: read qmp_call's replies on stdin and return 0 when
# query-chardev's reply shows chardev <label> with "frontend-open": true
# (the guest opened its port).
chardev_open() {
  jq -e --arg l "$1" 'select(.return | type == "array") | .return[] | select(.label == $l) |
    .["frontend-open"] == true' >/dev/null 2>&1
}

# qga_reply <socket> sync|command|refusal [<command-json>]: talk to the QEMU
# guest agent (plan phase 4). Every mode first syncs: it sends a 0xFF byte
# (to flush a half-read request), then guest-sync-delimited with a fresh
# random id, skips to the 0xFF that starts the agent's reply (past the
# parse error the flush byte earns, phase 1 proof 3), discards replies with
# any other id (left from an abandoned connection), and accepts only
# {"return": <that id>}. command mode then sends <command-json>, with any
# @NOW_NS@ replaced by the host's time in nanoseconds at that moment, and
# accepts only {"return": {}}. refusal mode (setup's step 6) passes only on a
# CommandNotFound error saying the command has been disabled, and returns 2
# for any other well-formed reply (a return or another error: a wrong
# answer, so the allow-list is missing). All fail with 1 on no reply, a
# reply over 4 KiB, junk or wrong JSON, and after 5 s in all.
qga_reply() {
  local sock=$1 mode=$2 cmd=${3:-} id deadline t skipped line rc=1 test
  local LC_ALL=C
  case $mode in
    sync) ;;
    command) test='. == {"return": {}}' ;;
    refusal) test='(has("return") | not) and .error.class == "CommandNotFound" and (.error.desc | type == "string" and test("has been disabled"))' ;;
    *) return 1 ;;
  esac
  [[ $mode == sync || -n $cmd ]] || return 1
  sock_open "$sock" || return 1
  id=$((SRANDOM % 2147483647 + 1))
  deadline=$(($(now_us) + 5000000))
  if sock_send $'\xff{"execute":"guest-sync-delimited","arguments":{"id":'"$id"'}}'; then
    while :; do
      # Up to the agent's 0xFF: at most 4 KiB of anything, then one line.
      if ! { t=$(time_left "$deadline") &&
        IFS= read -r -d $'\xff' -n 4097 -t "$t" -u "$LANAI_SOCK_R" skipped 2>/dev/null &&
        ((${#skipped} <= 4096)) &&
        t=$(time_left "$deadline") &&
        IFS= read -r -n 4097 -t "$t" -u "$LANAI_SOCK_R" line 2>/dev/null &&
        ((${#line} <= 4096)) &&
        line=$(jq -c 'if type == "object" and keys == ["return"] and (.return | type) == "number"
          then .return else error("not a sync reply") end' <<<"$line" 2>/dev/null); }; then
        break
      fi
      if [[ $line == "$id" ]]; then
        rc=0
        break
      fi
    done
  fi
  if ((rc == 0)) && [[ $mode != sync ]]; then
    rc=1
    # The host clock is read here, after the sync, as the command goes out.
    cmd=${cmd//@NOW_NS@/${EPOCHREALTIME//[!0-9]/}000}
    if sock_send "$cmd" && t=$(time_left "$deadline") &&
      IFS= read -r -n 4097 -t "$t" -u "$LANAI_SOCK_R" line 2>/dev/null &&
      ((${#line} <= 4096)); then
      if jq -e "$test" <<<"$line" >/dev/null 2>&1; then
        rc=0
      elif [[ $mode == refusal ]] &&
        jq -e 'type == "object" and (has("return") or (.error | type) == "object")' <<<"$line" >/dev/null 2>&1; then
        rc=2
      fi
    fi
  fi
  sock_close
  return "$rc"
}

# --- helper supervision ---

# restart_delay <now> [<restart-time>...]: print the seconds to wait before
# the next restart of a helper: 1, 2, then 4, by the number of restarts in
# the last 60 s. Fails (give up) when 5 restarts already fell in that minute.
restart_delay() {
  local now=$1 t n=0
  shift
  for t; do
    ((now - t >= 60)) || n=$((n + 1))
  done
  ((n < 5)) || return 1
  case $n in
    0) echo 1 ;;
    1) echo 2 ;;
    *) echo 4 ;;
  esac
}

# supervise <name> <command>...: run a helper and restart it whenever it
# exits, with restart_delay's backoff, until it has restarted 5 times in a
# minute. Writes its own pid to $RUN/<name>.pid for lanai status and removes
# it on giving up. Logs to stderr, the unit's journal.
supervise() {
  local name=$1 run pidfile delay rc
  local -a restarts=()
  shift
  run=$(run_dir) || return 1
  pidfile=$run/$name.pid
  printf '%s\n' "$BASHPID" >"$pidfile"
  while :; do
    rc=0
    "$@" || rc=$?
    if ! delay=$(restart_delay "$EPOCHSECONDS" "${restarts[@]}"); then
      echo "lanai: $name exited ($rc) 5 times in a minute; not restarting it" >&2
      rm -f -- "$pidfile"
      return 1
    fi
    echo "lanai: $name exited ($rc); restarting it in $delay s" >&2
    sleep "$delay"
    restarts+=("$EPOCHSECONDS")
  done
}

# run_once <name> <command>...: run a helper once, with its pid (this
# subshell's) in $RUN/<name>.pid while it runs, and remove the pid file when
# it exits, so lanai status warns. For virtiofsd: QEMU's vhost-user device
# never reconnects, so a restarted virtiofsd would serve nothing.
run_once() {
  local name=$1 run pidfile rc=0
  shift
  run=$(run_dir) || return 1
  pidfile=$run/$name.pid
  printf '%s\n' "$BASHPID" >"$pidfile"
  "$@" || rc=$?
  echo "lanai: $name exited ($rc); it is not restarted" >&2
  rm -f -- "$pidfile"
  return "$rc"
}

# --- helpers (run by bin/lanai-vm-helper under supervise) ---

# The logind signals the watchers listen for on the system bus. The sender
# must be logind itself: any local process can send a signal that looks
# like its PrepareForShutdown.
LANAI_LOGIND_MATCH="type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager'"

# logind_broadcasts <member>: read dbus-monitor's output on stdin and print
# "true" or "false" for each broadcast signal <member> (a header line with
# destination=(null destination), then its boolean body line). A user's
# dbus-monitor on the system bus falls back to eavesdropping, where the
# sender match rule does not filter signals sent to the monitor's own name,
# and any local process may send one; so a unicast signal, another member,
# or a body line without its header is ignored.
logind_broadcasts() {
  local member=$1 line armed=0
  while IFS= read -r line; do
    case $line in
      [![:space:]]*)
        armed=0
        [[ $line != signal\ * || $line != *"destination=(null destination) "* ||
          $line != *"member=$member" ]] || armed=1
        ;;
      *"boolean true" | *"boolean false")
        ((armed)) && printf '%s\n' "${line##* }"
        armed=0
        ;;
      *) armed=0 ;;
    esac
  done
}

# logind_confirms <property> <true|false>: return 0 when logind's own
# Manager property <property> (PreparingForShutdown, PreparingForSleep) has
# that value. dbus-monitor prints string arguments raw, newlines included,
# so a unicast signal can carry lines that look exactly like a broadcast:
# its output is only a trigger, and only logind can answer this. Fails, and
# logs, when busctl does not answer within 5 s (inside logind's 15 s delay).
# For shutdown this blocks forgery: logind reports true only while a
# shutdown is pending. For sleep it only filters a false seen while a sleep
# is still pending, since false is the resting value; a forged resume can
# only set the guest clock to the correct time.
logind_confirms() {
  local got
  if ! got=$(busctl --timeout=5 get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager "$1" 2>/dev/null); then
    echo "lanai: cannot read logind's $1" >&2
    return 1
  fi
  [[ $got == "b $2" ]]
}

# Read dbus-monitor's output for PrepareForShutdown on stdin; on a
# broadcast true that logind confirms (the host begins a reboot or
# power-off), stop the VM unit without waiting, so its ExecStop shuts
# Windows down while the delay inhibitor holds.
shutdown_watch_lines() {
  local value
  while IFS= read -r value; do
    [[ $value == true ]] || continue
    if ! logind_confirms PreparingForShutdown true; then
      echo "lanai: ignoring a PrepareForShutdown that logind does not confirm" >&2
      continue
    fi
    echo "lanai: the host is shutting down; stopping Windows" >&2
    systemctl --user stop --no-block "$LANAI_UNIT" ||
      echo "lanai: could not stop $LANAI_UNIT" >&2
  done < <(logind_broadcasts PrepareForShutdown)
}

# shutdown-watch helper: runs under `systemd-inhibit --mode=delay`.
shutdown_watch() {
  dbus-monitor --system "$LANAI_LOGIND_MATCH,member='PrepareForShutdown'" | shutdown_watch_lines
}

# Read dbus-monitor's output for PrepareForSleep on stdin; on a broadcast
# false that logind confirms (the host resumed), set the guest clock (spec
# 21).
sleep_watch_lines() {
  local value
  while IFS= read -r value; do
    [[ $value == false ]] || continue
    if ! logind_confirms PreparingForSleep false; then
      echo "lanai: ignoring a PrepareForSleep that logind does not confirm" >&2
      continue
    fi
    echo "lanai: the host resumed; setting the Windows clock" >&2
    clock_sync || echo "lanai: could not set the Windows clock after resume" >&2
  done < <(logind_broadcasts PrepareForSleep)
}

# sleep-watch helper.
sleep_watch() {
  dbus-monitor --system "$LANAI_LOGIND_MATCH,member='PrepareForSleep'" | sleep_watch_lines
}

# Set the guest clock to the host's through the guest agent: a sync, then
# guest-set-time with the host's time in nanoseconds, read as the command
# goes out. Retries every 2 s while the agent's socket is busy (only this
# watcher and setup's step 6 use it), until 60 s have passed (spec 21).
clock_sync() {
  local run end
  run=$(run_dir) || return 1
  end=$((SECONDS + 60))
  while :; do
    qga_reply "$run/qga.sock" command \
      '{"execute":"guest-set-time","arguments":{"time":@NOW_NS@}}' && return 0
    ((SECONDS < end)) || return 1
    sleep 2
  done
}

# Write the QMP line <line> to <state>/last-shutdown when it is a SHUTDOWN
# event, stamped with this run's $INVOCATION_ID: {"invocation", "guest",
# "reason"}. A RESET (Windows restarting) starts setup step 6's checks
# again for the new boot (step6_new_boot, lib/setup.sh). Other lines are
# ignored.
event_record() {
  local rec s run
  if jq -e '.event == "RESET"' <<<"$1" >/dev/null 2>&1; then
    if run=$(run_dir); then
      step6_new_boot "$run" false || true
    fi
    return 0
  fi
  rec=$(jq -c --arg inv "${INVOCATION_ID:-}" 'select(.event == "SHUTDOWN") |
    {invocation: $inv, guest: (.data.guest == true), reason: (.data.reason // "")}' <<<"$1" 2>/dev/null) ||
    return 0
  [[ -n $rec ]] || return 0
  s=$(state_dir)
  mkdir -p -- "$s"
  printf '%s\n' "$rec" >"$s/last-shutdown.tmp" && mv -f -- "$s/last-shutdown.tmp" "$s/last-shutdown"
}

# event-log helper: hold qmp-events.sock for the VM's life and record each
# SHUTDOWN event. Retries until QEMU answers on the socket, then stamps
# <state>/started with $INVOCATION_ID (the run really started, for
# record_previous_run); returns when QEMU closes the socket.
event_log() {
  local run line s
  run=$(run_dir) || return 1
  until qmp_open "$run/qmp-events.sock"; do
    sleep 0.5
  done
  s=$(state_dir)
  mkdir -p -- "$s"
  printf '%s\n' "${INVOCATION_ID:-}" >"$s/started.tmp" && mv -f -- "$s/started.tmp" "$s/started"
  while IFS= read -r line <&"$LANAI_SOCK_R"; do
    event_record "$line"
  done
  sock_close
}

# --- the scale feed (plan: Follow-on: live scale) ---

# scale_line <step> <save>: print the one message the scale channel carries,
# "lanai-scale <step> <save>" (spec 27). Fails on an unlisted step or a save
# number that is not a whole number below 10^9.
scale_line() {
  [[ $1 =~ ^[0-9]+$ && $LANAI_SCALE_STEPS == *" $1 "* && $2 =~ ^[0-9]{1,9}$ ]] || return 1
  printf 'lanai-scale %s %s\n' "$1" "$2"
}

# window_monitor <clients-json> <monitors-json> <pid>: print the name of the
# monitor that holds process <pid>'s window (the Looking Glass client's), from
# `hyprctl clients -j` and `hyprctl monitors -j`, or nothing.
window_monitor() {
  [[ $3 =~ ^[1-9][0-9]*$ ]] || return 0
  jq -r --argjson pid "$3" --argjson m "$2" '
    [.[]? | objects | select(.pid == $pid) | .monitor][0] as $id |
    if $id == null then empty else [$m[]? | objects | select(.id == $id) | .name | strings][0] // empty end' \
    <<<"$1" 2>/dev/null || true
}

# scale_target <setting> <monitors-json> <monitor> <last-target>: print the
# step Windows should use (spec 12). A fixed step is the target. For "auto",
# the step nearest the scale of monitor <monitor>; if Hyprland does not list
# it, the focused monitor's, then the first listed; with no monitors, the
# last target. Fails when there is none.
scale_target() {
  local scale
  if [[ $1 != auto ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  scale=$(jq -r --arg n "$3" '[.[]? | objects] |
    (first(.[] | select(.name == $n)) // first(.[] | select(.focused == true)) // first(.[]) // {}) |
    .scale | numbers' <<<"$2" 2>/dev/null) || scale=""
  if [[ -n $scale ]] && scale_step "$(scale_percent "$scale")" 2>/dev/null; then return 0; fi
  [[ -n $4 ]] || return 1
  printf '%s\n' "$4"
}

# scale_send <socket> <line>: send <line> over its own short connection, one
# way: socat -u copies stdin to the socket and never reads what the guest
# writes (spec 27). It is killed after LANAI_SCALE_SEND_TIMEOUT seconds, so a
# stalled port never blocks the feed. The leading newline ends any line a
# killed send cut short.
scale_send() {
  [[ -S $1 ]] || return 1
  printf '\n%s\n' "$2" | timeout "$LANAI_SCALE_SEND_TIMEOUT" socat -u - "UNIX-CONNECT:$1" 2>/dev/null
}

# The feed's state between passes: the last good line and target, the line
# last logged, the boot monitor and Hyprland instance, the instance last
# chosen (unset at first), the length of a hyprctl failure streak, and which
# problems are already logged (each is logged once, and again when it
# clears).
SCALE_FEED_LINE="" SCALE_FEED_TARGET="" SCALE_FEED_LOGGED_LINE="" SCALE_FEED_BOOT_MONITOR=""
SCALE_FEED_BOOT_SIG="" SCALE_FEED_HYPR_SIG="<unset>" SCALE_FEED_HYPR_FAILS=0
SCALE_FEED_SEND_FAILED=false SCALE_FEED_SETTINGS_BAD=false

# Return 0 when Hyprland instance <sig> is a plain name and answers
# `hyprctl version` within 1 s. Hyprland leaves the folders and sockets of
# old instances behind, so a socket file proves nothing.
hypr_alive() {
  [[ $1 =~ ^[A-Za-z0-9_]+$ ]] &&
    HYPRLAND_INSTANCE_SIGNATURE=$1 timeout 1 hyprctl version </dev/null >/dev/null 2>&1
}

# hypr_signature <candidate>: print the Hyprland instance hyprctl should
# use: <candidate> (boot.json's) when it answers, else the inherited
# HYPRLAND_INSTANCE_SIGNATURE when it answers, else the only instance under
# $XDG_RUNTIME_DIR/hypr that answers. Fails when none answers, or more than
# one is left to guess from.
hypr_signature() {
  local dir=${XDG_RUNTIME_DIR:-/nonexistent}/hypr sig f
  local -a live=()
  for sig in "$1" "${HYPRLAND_INSTANCE_SIGNATURE:-}"; do
    if hypr_alive "$sig"; then
      printf '%s\n' "$sig"
      return 0
    fi
  done
  for f in "$dir"/*/.socket.sock; do
    sig=${f%/.socket.sock}
    sig=${sig##*/}
    [[ ! -S $f ]] || ! hypr_alive "$sig" || live+=("$sig")
  done
  ((${#live[@]} == 1)) || return 1
  printf '%s\n' "${live[0]}"
}

# Export the Hyprland instance hypr_signature picks, trying boot.json's
# first (the user manager may lack the session's, and Hyprland may restart
# under a new one). Logs the choice only when it changes. With none found,
# the inherited one stays.
scale_feed_hypr() {
  local sig=""
  if sig=$(hypr_signature "$SCALE_FEED_BOOT_SIG"); then
    export HYPRLAND_INSTANCE_SIGNATURE=$sig
  fi
  [[ $sig != "$SCALE_FEED_HYPR_SIG" ]] || return 0
  SCALE_FEED_HYPR_SIG=$sig
  if [[ -n $sig ]]; then
    echo "lanai: the scale feed uses Hyprland instance $sig" >&2
  else
    echo "lanai: the scale feed finds no running Hyprland instance (boot.json names ${SCALE_FEED_BOOT_SIG:-none})" >&2
  fi
}

# Seed the feed: the last line it sent this VM run ($RUN/scale-line, so a
# restart under supervise never resends the boot save number), else the
# boot's step and save number from boot.json; the focused monitor at boot;
# and the session's Hyprland instance (scale_feed_hypr).
scale_feed_init() {
  local f save run sent="" save_sent="" word=""
  f=$(state_dir)/boot.json
  SCALE_FEED_TARGET=$(jq -r '.scale | numbers' "$f" 2>/dev/null) || SCALE_FEED_TARGET=""
  save=$(jq -r '.scale_save // 0 | numbers' "$f" 2>/dev/null) || save=""
  if run=$(run_dir) && [[ -f $run/scale-line ]]; then read -r word sent save_sent <"$run/scale-line" || true; fi
  if [[ $word == lanai-scale ]] && scale_line "$sent" "$save_sent" >/dev/null; then
    SCALE_FEED_TARGET=$sent save=$save_sent
  fi
  SCALE_FEED_LINE=$(scale_line "$SCALE_FEED_TARGET" "$save") || SCALE_FEED_LINE="" SCALE_FEED_TARGET=""
  SCALE_FEED_BOOT_MONITOR=$(jq -r '.boot_monitor | strings' "$f" 2>/dev/null) || SCALE_FEED_BOOT_MONITOR=""
  SCALE_FEED_BOOT_SIG=$(jq -r '.hyprland_instance_signature | strings' "$f" 2>/dev/null) || SCALE_FEED_BOOT_SIG=""
  scale_feed_hypr
}

# One pass of the scale feed: read settings.json once (vm_scale_settings);
# find the client window's monitor and record it in $RUN/scale-monitor when
# it changes; compute the target, where with no window the recorded monitor
# counts, else boot.json's; then send the line, changed or not, logging it
# when it changes. Unreadable settings keep the last good line. While
# hyprctl fails, the Hyprland instance is looked for again every 15 passes
# (about 30 s).
scale_feed_step() {
  local run settings setting="" save="" pid clients monitors name remembered="" target line
  run=$(run_dir) || return 1
  if settings=$(vm_scale_settings 2>/dev/null); then
    read -r setting save <<<"$settings"
    ! $SCALE_FEED_SETTINGS_BAD || echo "lanai: the scale feed reads settings.json again" >&2
    SCALE_FEED_SETTINGS_BAD=false
  elif ! $SCALE_FEED_SETTINGS_BAD; then
    SCALE_FEED_SETTINGS_BAD=true
    echo "lanai: the scale feed cannot read the Windows scale in settings.json; it sends the last good scale" >&2
  fi
  pid=$(timeout 1 systemctl --user show -p MainPID --value "$LANAI_CLIENT_UNIT" 2>/dev/null) || pid=""
  if clients=$(timeout 1 hyprctl clients -j </dev/null 2>/dev/null) &&
    monitors=$(host_monitors 1); then
    ((SCALE_FEED_HYPR_FAILS == 0)) || echo "lanai: hyprctl answers the scale feed again" >&2
    SCALE_FEED_HYPR_FAILS=0
  else
    clients='[]' monitors='[]'
    ((SCALE_FEED_HYPR_FAILS > 0)) ||
      echo "lanai: hyprctl does not answer (instance ${HYPRLAND_INSTANCE_SIGNATURE:-none}); the Windows scale keeps its last monitor" >&2
    # Hyprland may have restarted as a new instance.
    ((SCALE_FEED_HYPR_FAILS % 15 != 0)) || scale_feed_hypr
    SCALE_FEED_HYPR_FAILS=$((SCALE_FEED_HYPR_FAILS + 1))
  fi
  name=$(window_monitor "$clients" "$monitors" "$pid")
  [[ ! -f $run/scale-monitor ]] || read -r remembered <"$run/scale-monitor" || true
  if [[ -n $name && $name != "$remembered" ]]; then
    printf '%s\n' "$name" >"$run/scale-monitor.tmp" && mv -f -- "$run/scale-monitor.tmp" "$run/scale-monitor"
  fi
  name=${name:-${remembered:-$SCALE_FEED_BOOT_MONITOR}}
  if [[ -n $setting ]] && target=$(scale_target "$setting" "$monitors" "$name" "$SCALE_FEED_TARGET") &&
    line=$(scale_line "$target" "$save"); then
    SCALE_FEED_TARGET=$target SCALE_FEED_LINE=$line
  fi
  if [[ -n $SCALE_FEED_LINE && $SCALE_FEED_LINE != "$SCALE_FEED_LOGGED_LINE" ]]; then
    SCALE_FEED_LOGGED_LINE=$SCALE_FEED_LINE
    printf '%s\n' "$SCALE_FEED_LINE" >"$run/scale-line.tmp" && mv -f -- "$run/scale-line.tmp" "$run/scale-line"
    read -r _ target save <<<"$SCALE_FEED_LINE"
    echo "lanai: the scale feed sends $target% (save $save) for ${name:+monitor }${name:-no monitor}" >&2
  fi
  # No socket yet means QEMU is not up: nothing to send, nothing to log.
  [[ -n $SCALE_FEED_LINE && -S $run/scale.sock ]] || return 0
  if scale_send "$run/scale.sock" "$SCALE_FEED_LINE"; then
    ! $SCALE_FEED_SEND_FAILED || echo "lanai: the scale feed sends to Windows again" >&2
    SCALE_FEED_SEND_FAILED=false
  elif ! $SCALE_FEED_SEND_FAILED; then
    SCALE_FEED_SEND_FAILED=true
    echo "lanai: the scale feed cannot send to Windows; it keeps trying" >&2
  fi
}

# scale-feed helper: send the latest scale to Windows every
# LANAI_SCALE_INTERVAL seconds, measured start to start, for the VM's life
# (spec 12, 27). It needs no shell or panel.
scale_feed() {
  local start period left
  period=$(awk -v s="$LANAI_SCALE_INTERVAL" 'BEGIN { printf "%d", s * 1000000 }')
  scale_feed_init
  while :; do
    start=$(now_us)
    scale_feed_step || true
    left=$((start + period - $(now_us)))
    # Never more than a period, should the wall clock step back.
    ((left <= period)) || left=$period
    ((left <= 0)) || sleep "$((left / 1000000)).$(printf '%06d' $((left % 1000000)))"
  done
}

# --- the unit's ExecStart and ExecStop ---

# Print the VM's memory (GiB) and cores: "memory_gib" and "cores" from
# settings.json, each falling back to settings_seed when absent. vm_args
# checks the values.
vm_settings() {
  local f mem="" cores="" seed
  f=$(settings_file)
  if [[ -f $f && ! -L $f ]]; then
    mem=$(jq -r '.memory_gib // empty' "$f") || return 1
    cores=$(jq -r '.cores // empty' "$f") || return 1
  fi
  if [[ -z $mem || -z $cores ]]; then
    seed=$(settings_seed) || return 1
    [[ -n $mem ]] || mem=$(jq -r .memory_gib <<<"$seed")
    [[ -n $cores ]] || cores=$(jq -r .cores <<<"$seed")
  fi
  printf '%s %s\n' "$mem" "$cores"
}

# Preserve JSON types: only an absent key defaults to auto, never null or false.
windows_scale_value() {
  jq -er --arg steps "$LANAI_SCALE_STEPS" '
    select(type == "object") |
    (if has("windows_scale") then .windows_scale else "auto" end) |
    select(. == "auto" or (type == "number" and
      (. as $v | [$steps | splits(" ") | select(length > 0) | tonumber] | index($v) != null)))' <<<"$1"
}

# Print the scale save number of settings JSON <doc>: a whole number from 0
# to 999999999, 0 when the key is absent. Fails on any other value, which
# refuses saves and boots as an invalid scale does.
scale_save_value() {
  local v
  v=$(jq -r 'select(type == "object") | (if has("scale_save") then .scale_save else 0 end) |
    select(type == "number" and . >= 0 and . < 1000000000 and . == floor)' <<<"$1" 2>/dev/null) || return 1
  [[ $v =~ ^[0-9]{1,9}$ ]] || return 1
  printf '%s\n' "$((10#$v))"
}

# Print "<scale setting> <save number>" from one read of settings.json, so
# a save landing between two reads cannot pair a new number with an old
# step. boot_vm and the scale feed share it. Fails on an unreadable file or
# an invalid value.
vm_scale_settings() {
  local f doc='{}' scale save
  f=$(settings_file)
  [[ ! -L $f ]] || return 1
  if [[ -e $f ]]; then doc=$(cat -- "$f") || return 1; fi
  scale=$(windows_scale_value "$doc") || return 1
  save=$(scale_save_value "$doc") || return 1
  printf '%s %s\n' "$scale" "$save"
}

# A validated CLI value as JSON, retaining auto's string type.
scale_json() {
  if [[ $1 == auto ]]; then printf '"auto"\n'; else printf '%s\n' "$1"; fi
}

# Print the host's IPv4 default gateway, or nothing when there is no
# default route (or none with a gateway, such as `default dev wg0`).
default_gateway() {
  ip -j -4 route show default 2>/dev/null |
    jq -r '[.[] | .gateway // empty][0] // empty' 2>/dev/null || true
}

# vm_plan <scale> <save> <setup-media or ""> [<window true|false>]: check what
# lanai-vm-exec needs and print QEMU's arguments: the runtime folder
# (created 0700 when missing), the settings, windows.mac, the gateway and
# vm_args. On a problem, prints why and fails. boot_vm runs it as a dry run
# before it starts the unit, so the user sees why; lanai-vm-exec runs it
# again as the backstop.
vm_plan() {
  local problem storage mem="" cores="" mac=""
  # Repeated from preflight: a direct `systemctl --user start lanai-vm`
  # skips it, and must not boot a half-restored disk or share a replaced
  # ~/Windows.
  if problem=$(restore_pending); then
    echo "$problem"
    return 1
  fi
  problem=$(share_check) || {
    echo "$problem"
    return 1
  }
  problem=$(run_dir_check) || {
    echo "$problem"
    return 1
  }
  storage=$(storage_dir 2>/dev/null) || {
    echo "Lanai cannot read its settings file."
    return 1
  }
  read -r mem cores < <(vm_settings 2>/dev/null) || true
  [[ -n $mem && -n $cores ]] || {
    echo "Lanai cannot read the VM settings (memory and cores)."
    return 1
  }
  read -r mac 2>/dev/null <"$storage/windows.mac" || [[ -n $mac ]] || {
    echo "Lanai cannot read $storage/windows.mac."
    return 1
  }
  vm_args "$storage" "${mac//[[:space:]]/}" "$mem" "$cores" "$1" "$2" "$(default_gateway)" "$3" "${4:-false}"
}

# lanai-vm-exec, the unit's ExecStart (plan: Architecture). It reads the
# scale, its save number and the boot mode boot_vm left in
# <state>/boot.json, builds QEMU's arguments with vm_plan, removes stale
# sockets, run stamps and shared memory, empties client.log, starts the
# helpers in the background (in the unit's cgroup;
# systemd stops them after ExecStop): virtiofsd once, the others under
# supervise. It waits for virtiofsd's fresh socket, writes the "running"
# marker with $INVOCATION_ID, and execs QEMU. Only for a boot that shows
# QEMU's window does QEMU get WAYLAND_DISPLAY, from boot.json (the user
# manager may lack it). Prints why and fails on any problem, before QEMU
# starts.
vm_exec() {
  local run s scale=100 save=0 setup=false window=false wayland="" media="" out i name
  local -a args
  : "${INVOCATION_ID:?lanai-vm-exec runs only as lanai-vm.service}"
  run=$(run_dir) || return 1
  s=$(state_dir)
  if [[ -f $s/boot.json ]]; then
    scale=$(jq -r '.scale // 100' "$s/boot.json") || return 1
    save=$(jq -r '.scale_save // 0' "$s/boot.json") || return 1
    setup=$(jq -r '.setup // false' "$s/boot.json") || return 1
    window=$(jq -r '.window // false' "$s/boot.json") || return 1
    wayland=$(jq -r '.wayland_display // ""' "$s/boot.json") || return 1
  fi
  [[ $setup != true ]] || media=$s/setup-media
  if [[ $window == true ]]; then
    [[ -n $wayland ]] || {
      echo "lanai: boot.json asks for QEMU's window but names no WAYLAND_DISPLAY" >&2
      return 1
    }
    export WAYLAND_DISPLAY=$wayland
  else
    unset WAYLAND_DISPLAY
  fi
  out=$(vm_plan "$scale" "$save" "$media" "$window") || {
    echo "lanai: $out" >&2
    return 1
  }
  mapfile -t args <<<"$out"
  [[ -n $(default_gateway) ]] ||
    echo "lanai: the host has no default route; Windows starts without a network" >&2
  for name in qmp qmp-events qmp-cli spice qga virtiofs scale; do
    rm -f -- "$run/$name.sock"
  done
  for name in "${!LANAI_HELPERS[@]}"; do
    rm -f -- "$run/$name.pid"
  done
  # Setup's step 6 counts its limits from this start and keeps no marker
  # from an earlier run, and the scale feed's window monitor and last line
  # belong to one run.
  rm -f -- "$run/ivshmem" "$run/scale-monitor" "$run/scale-line"
  step6_new_boot "$run" true || return 1
  : >"$run/client.log"

  run_once virtiofsd "$LANAI_VIRTIOFSD" --sandbox namespace --shared-dir "$HOME/Windows" \
    --socket-path="$run/virtiofs.sock" &
  supervise shutdown-watch systemd-inhibit --what=shutdown --mode=delay --who=Lanai \
    --why="Shutting Windows down cleanly" "$LANAI_BIN/lanai-vm-helper" shutdown-watch &
  supervise sleep-watch "$LANAI_BIN/lanai-vm-helper" sleep-watch &
  supervise event-log "$LANAI_BIN/lanai-vm-helper" event-log &
  supervise scale-feed "$LANAI_BIN/lanai-vm-helper" scale-feed &
  for ((i = 0; i < 50; i++)); do
    [[ -S $run/virtiofs.sock ]] && break
    sleep 0.1
  done
  [[ -S $run/virtiofs.sock ]] || {
    echo "lanai: virtiofsd did not create $run/virtiofs.sock" >&2
    return 1
  }
  mkdir -p -- "$s"
  printf '%s\n' "$INVOCATION_ID" >"$s/running"
  # QEMU starts passt, which writes its pid file under TMPDIR.
  TMPDIR=$run exec qemu-system-x86_64 "${args[@]}"
}

# Return 0 while process <pid> runs: it exists and is not a zombie (one
# that exited but was not reaped still answers kill -0). Reads the real
# /proc.
pid_running() {
  local stat
  kill -0 "$1" 2>/dev/null || return 1
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  stat=${stat##*) }
  [[ ${stat:0:1} != [ZX] ]]
}

# lanai-vm-stop, the unit's ExecStop; systemd runs it after every stop.
# When QEMU still runs (a session end, the shutdown inhibitor, or systemctl
# stop) it sends system_powerdown on qmp.sock, and again every
# LANAI_POWERDOWN_INTERVAL seconds (a stop during early boot, before QMP or
# the guest's ACPI is ready), until QEMU exits; the unit's TimeoutStopSec
# bounds that wait. When QEMU already exited ($EXIT_CODE is set) it skips
# that. Either way it then stops the Looking Glass client's unit, waits up
# to 3 s for it to go, and waits up to 2 s for this run's last-shutdown
# record, so systemd does not kill the event logger before it writes.
vm_stop() {
  local run s i last=-1
  run=$(run_dir) || return 1
  s=$(state_dir)
  if [[ -z ${EXIT_CODE:-} && -n ${MAINPID:-} ]]; then
    while pid_running "$MAINPID"; do
      if ((last < 0 || SECONDS - last >= LANAI_POWERDOWN_INTERVAL)); then
        last=$SECONDS
        if qmp_call "$run/qmp.sock" '{"execute":"system_powerdown"}' >/dev/null; then
          echo "lanai: sent system_powerdown; waiting for Windows to shut down" >&2
        else
          echo "lanai: could not send system_powerdown on $run/qmp.sock" >&2
        fi
      fi
      sleep 0.2
    done
  fi
  # The Looking Glass client is useless once QEMU is gone, and would hold
  # the old shared memory into the next run. The client unit's PartOf= covers
  # a stop job; this covers a QEMU that exits on its own. Wait up to 3 s for
  # the unit to go, so a quick Start then Open starts a new client instead
  # of focusing the old one.
  systemctl --user stop --no-block "$LANAI_CLIENT_UNIT" >/dev/null 2>&1 || true
  for ((i = 0; i < 15; i++)); do
    case $(systemctl --user show -p ActiveState --value "$LANAI_CLIENT_UNIT" 2>/dev/null) in
      active | activating | deactivating | reloading) sleep 0.2 ;;
      *) break ;;
    esac
  done
  for ((i = 0; i < 10; i++)); do
    jq -e --arg inv "${INVOCATION_ID:-}" '.invocation == $inv' "$s/last-shutdown" >/dev/null 2>&1 &&
      return 0
    sleep 0.2
  done
  return 0
}
