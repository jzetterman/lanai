# The VM unit's building blocks (plan phase 4): paths, QEMU arguments, the
# runtime folder, run bookkeeping, the QMP and guest agent clients, helper
# supervision, and the unit's start and stop paths. lib/lanai.sh sources this
# file; it defines functions and constants only.
# shellcheck shell=bash

# The static QEMU template (dockur 6.05's captured line). Tests may point it
# at a copy.
LANAI_ARGS_TEMPLATE=${LANAI_ARGS_TEMPLATE:-$LANAI_LIB/dockur-6.05.args}

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
# filled with the settings, then Lanai's devices (plan: VM hardware). With
# <setup-media>, the setup boot's GTK display and read-only setup disk
# replace the headless display. Every input is checked before use, and the
# result is scanned for listeners and container paths, failing closed.
#   vm_args <storage> <mac> <memory-gib> <cores> <scale> <gateway> [<setup-media>]
vm_args() {
  local storage=$1 mac=$2 mem=$3 cores=$4 scale=$5 gw=$6 media=${7:-} run arg
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
  if [[ ! $gw =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "the gateway must be an IPv4 address: ${gw@Q}"
    return 1
  fi
  if [[ -n $media && ($media != /* || $media == *[,$'\n']*) ]]; then
    echo "the setup media path must be absolute, without a comma or a newline: ${media@Q}"
    return 1
  fi
  if [[ $run == *[,$'\n']* ]]; then
    echo "the runtime folder must not contain a comma or a newline: ${run@Q}"
    return 1
  fi

  while IFS= read -r arg; do
    [[ -n $arg && $arg != \#* ]] || continue
    # The inner quotes keep a & in a path literal (bash 5.2 patsub_replacement).
    arg=${arg//@STORAGE@/"$storage"}
    arg=${arg//@MAC@/"$mac"}
    arg=${arg//@MEMORY@/"$mem"}
    out+=("${arg//@CORES@/"$cores"}")
  done <"$LANAI_ARGS_TEMPLATE"

  out+=(
    -netdev "passt,id=hostnet0,ipv6=off,map-host-loopback=none,dns-forward=$gw"
    -object "memory-backend-memfd,id=mem,size=${mem}G,share=on" -machine memory-backend=mem
    -object "memory-backend-file,id=ivshmem,share=on,mem-path=$run/ivshmem,size=128M"
    -device "ivshmem-plain,memdev=ivshmem"
    -spice "unix=on,addr=$run/spice.sock,disable-ticketing=on"
    -device virtio-serial-pci
    -chardev "spicevmc,id=vdagent,name=vdagent"
    -device "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
    -chardev "socket,id=qga0,path=$run/qga.sock,server=on,wait=off"
    -device "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"
    -chardev "spicevmc,id=usbredir0,name=usbredir"
    -device "usb-redir,chardev=usbredir0"
    -chardev "socket,id=vfs,path=$run/virtiofs.sock"
    -device "vhost-user-fs-pci,chardev=vfs,tag=lanai"
    -qmp "unix:$run/qmp.sock,server=on,wait=off"
    -qmp "unix:$run/qmp-events.sock,server=on,wait=off"
    -qmp "unix:$run/qmp-cli.sock,server=on,wait=off"
    -smbios "type=11,value=lanai-scale=$scale"
  )
  if [[ -n $media ]]; then
    # window-close=off: closing the setup window must not power off the VM.
    out+=(-vga virtio -display "gtk,window-close=off"
      -drive "if=none,id=setup,file=fat:$media,format=raw,readonly=on"
      -device "usb-storage,drive=setup")
  else
    out+=(-vga none -display none)
  fi

  # Fail closed (spec 25): no network listener, port forward, serial monitor
  # or container path. Options match only at a boundary, so vmport=off is
  # not port=. The only -netdev is Lanai's passt line.
  local listener='^-(vnc|gdb|s|incoming|nic|net|serial|monitor)$|(^|,)(tls-)?port=|(^|,)(vnc|websocket)=|(^|[,=:])(tcp|telnet|udp):|hostfwd|mon:'
  local netdevs=0
  for arg in "${out[@]}"; do
    [[ $arg != -netdev ]] || netdevs=$((netdevs + 1))
    if [[ $arg =~ $listener ]]; then
      echo "refusing a network listener or monitor in the VM's arguments: $arg"
      return 1
    elif [[ $arg == */storage* || $arg == */run/shm* ]]; then
      echo "refusing a container path in the VM's arguments: $arg"
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

# Turn the previous run's markers into a verdict in <state>/last-run, and
# print it (plan: Architecture). forced when the "forced" marker exists (it
# wins over a guest SHUTDOWN record); else clean when last-shutdown records a
# guest-initiated shutdown stamped with the same invocation id as the
# "running" marker; else forced when a "running" marker exists. Without
# either marker there is nothing to report, and last-run stays as it was
# (the panel clears it once shown). Always ends with the markers,
# last-shutdown and any stop request deleted. Every path that starts the
# unit calls it first, through preflight.
record_previous_run() {
  local s verdict="" inv=""
  s=$(state_dir)
  mkdir -p -- "$s"
  if [[ -e $s/forced ]]; then
    verdict=forced
  elif [[ -e $s/running ]]; then
    verdict=forced
    inv=$(<"$s/running") || inv=""
    if [[ -n $inv ]] && jq -e --arg inv "$inv" \
      '.invocation == $inv and .guest == true' "$s/last-shutdown" >/dev/null 2>&1; then
      verdict=clean
    fi
  fi
  if [[ -n $verdict ]]; then
    printf '%s\n' "$verdict" >"$s/last-run.tmp" && mv -f -- "$s/last-run.tmp" "$s/last-run"
  fi
  rm -f -- "$s/running" "$s/forced" "$s/last-shutdown" "$s/stop-requested"
  [[ -z $verdict ]] || printf '%s\n' "$verdict"
}
