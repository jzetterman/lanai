# The Looking Glass client and host setup (plan phase 5): version checks on
# the client's log, the choice of client build, the wait before the client
# starts, the client build itself, and the host packages. lib/lanai.sh
# sources this file; it defines functions and constants only.
# shellcheck shell=bash

# shellcheck source-path=SCRIPTDIR source=pins.sh
source "$LANAI_LIB/pins.sh"

# The client's unit, started by lanai open with systemd-run.
LANAI_CLIENT_UNIT=lanai-client.service

# Seconds lanai-client-exec waits for QEMU to answer on qmp-cli.sock (tests
# shorten it), and seconds of "transport source is not available" that
# mean the IDD is missing.
LANAI_CLIENT_WAIT=${LANAI_CLIENT_WAIT:-60}
LANAI_IDD_WAIT=30

# The first line lanai-client-exec writes to client.log, before the client's
# own output: the client's start time, which version_check needs to time
# the IDD wait. And the line it writes instead when QEMU never answered.
LANAI_CLIENT_START="lanai: client started at"
LANAI_CLIENT_TIMEOUT="lanai: QEMU did not answer on qmp-cli.sock within"

# The host packages Lanai needs (spec 7): QEMU and its modules, the helpers,
# and the client's build dependencies. System packages come from the signed
# Arch repositories (spec 26).
LANAI_HOST_PACKAGES=(qemu-system-x86 qemu-img virtiofsd python qemu-ui-spice-core
  qemu-chardev-spice qemu-hw-usb-redirect qemu-ui-gtk qemu-hw-display-virtio-vga
  qemu-hw-display-virtio-gpu passt socat jq diffutils base-devel cmake spice-protocol
  libdecor usbredir fontconfig fuse3 libunwind libelf wayland libxkbcommon libglvnd
  nettle libpipewire libpulse libsamplerate)

# --- client flags ---

# Print the Looking Glass client's arguments for runtime folder <run>, one
# per line. The one place the flags live: phase 7's resize check may change
# them.
client_args() {
  printf '%s\n' -f "$1/ivshmem" "spice:host=$1/spice.sock" spice:port=0 win:setGuestRes=yes
}

# --- versions (spec 8) ---

# Print a Looking Glass version as "tag count hash": B7-826-236efcb1 (the
# client's build name) and B7-826-g236efcb155 (git describe, as the IDD
# reports it) both give "B7 826 <hash>", hash lower-cased without git's g.
# Fails on anything else, such as "unknown" or a bare tag.
lg_version_key() {
  [[ $1 =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)-([0-9]+)-g?([0-9A-Fa-f]{7,40})$ ]] || return 1
  printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3],,}"
}

# Return 0 when versions <a> and <b> name the same build: the same tag and
# count, and one hash a prefix of the other (the names abbreviate it to
# different lengths).
lg_same_build() {
  local a b ta ca ha tb cb hb
  a=$(lg_version_key "$1") && b=$(lg_version_key "$2") || return 1
  read -r ta ca ha <<<"$a"
  read -r tb cb hb <<<"$b"
  [[ $ta == "$tb" && $ca == "$cb" ]] || return 1
  [[ $ha == "$hb"* || $hb == "$ha"* ]]
}

# version_check <client-log> [<now>]: read a Looking Glass client log and
# print one verdict, then the guest's version when the log names one:
#   match <v>     the IDD's version is the client's build
#   mismatch [v]  another build, a version the client cannot tell, or an
#                 "Incompatible" line (a hard mismatch)
#   idd-missing   "transport source is not available" for 30 s, with no
#                 guest session since: the IDD is not running
#   waiting       that wait is shorter, or cannot be timed (no start line)
#   unknown       no log, or nothing about the guest yet
# The latest event wins, so a guest that comes back after a mismatch or a
# wait counts. The client's own times count from its start, which
# lanai-client-exec writes as the first line. <now> defaults to the clock.
version_check() {
  local log=$1 now=${2:-$EPOCHSECONDS} client="" event="" at="" guest="" start=""
  [[ -r $log ]] || {
    echo unknown
    return 0
  }
  {
    IFS= read -r client
    IFS= read -r event
    IFS= read -r at
    IFS= read -r guest
    IFS= read -r start
  } < <(awk -v prefix="$LANAI_CLIENT_START " '
    function secs(t, p) { split(t, p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] }
    # Only the first line: the guest can put text at the start of a later
    # line through its version string.
    NR == 1 && index($0, prefix) == 1 { start = substr($0, length(prefix) + 1); next }
    {
      # <time> [L] <file>:<line> | <function> | <message>
      i = index($0, " | "); if (!i) next
      rest = substr($0, i + 3); j = index(rest, " | "); if (!j) next
      msg = substr(rest, j + 3)
    }
    client == "" && msg ~ /^Looking Glass \(.*\)$/ { client = substr(msg, 16, length(msg) - 16); next }
    msg ~ /^The transport source is not available/ { event = "unavailable"; at = secs($1); ginfo = 0; next }
    msg ~ /^Incompatible .* version$/ || msg ~ /^The transport is not compatible with this client/ {
      event = "incompatible"; ginfo = 0; next
    }
    msg == "Guest Information:" { ginfo = 1; next }
    ginfo && index(msg, "Version  : ") == 1 { event = "guest"; guest = substr(msg, 12); ginfo = 0; next }
    END { print client; print event; print at; print guest; print start }' "$log")
  case $event in
    guest)
      if lg_same_build "$client" "$guest"; then
        echo "match $guest"
      else
        echo "mismatch $guest"
      fi
      ;;
    incompatible) echo mismatch ;;
    unavailable)
      if [[ $start =~ ^[0-9]+$ ]] &&
        awk -v n="$now" -v s="$start" -v a="$at" -v w="$LANAI_IDD_WAIT" 'BEGIN { exit !(n - s - a >= w) }'; then
        echo idd-missing
      else
        echo waiting
      fi
      ;;
    *) echo unknown ;;
  esac
}

# Record <version> as the guest's IDD version in <state>/guest-version, so
# lanai open picks the matching client build (plan phase 5). lanai status
# and lanai open record it from the client log; lanai setup-guest records
# the pin when it succeeds (phase 6). Refuses anything lg_version_key cannot
# read, such as "unknown". It always rewrites the file: its time is when the
# record was made, which guest_version_note compares with a client's start.
guest_version_set() {
  local s
  lg_version_key "$1" >/dev/null || return 1
  s=$(state_dir)
  mkdir -p -- "$s" && printf '%s\n' "$1" >"$s/guest-version.tmp" &&
    mv -f -- "$s/guest-version.tmp" "$s/guest-version"
}

# Print the recorded guest version, or nothing when there is none.
guest_version_get() {
  local f
  f=$(state_dir)/guest-version
  [[ ! -r $f ]] || printf '%s\n' "$(<"$f")"
}

# Record the guest version that client log <log> names, if any, but only
# when the log's client started after the record was written: a record from
# lanai setup-guest (phase 6) is newer than what this run's client saw
# before the update. A log without Lanai's start line records nothing.
guest_version_note() {
  local log=$1 guest="" first="" start f
  read -r _ guest < <(version_check "$log") || return 0
  [[ -n $guest ]] || return 0
  IFS= read -r first <"$log" || return 0
  start=${first#"$LANAI_CLIENT_START "}
  [[ $first == "$LANAI_CLIENT_START "* && $start =~ ^[0-9]+$ ]] || return 0
  f=$(state_dir)/guest-version
  if [[ -f $f ]] && ((start < $(stat -c %Y -- "$f"))); then return 0; fi
  guest_version_set "$guest" || true
}

# Print the recorded guest version when it is not the pinned build: the old
# client build keeps the window working, but the guest needs the new IDD
# (req 8). Prints nothing otherwise.
guest_version_behind() {
  local g
  g=$(guest_version_get)
  [[ -z $g ]] || lg_same_build "$LG_BUILD" "$g" || printf '%s\n' "$g"
}

# Return 0 while lanai-client.service runs or is starting.
client_active() {
  local st
  st=$(systemctl --user show -p ActiveState --value "$LANAI_CLIENT_UNIT" 2>/dev/null) || return 1
  [[ $st == active || $st == activating || $st == reloading ]]
}

# Print the folder that holds Lanai's client builds, one folder per build.
client_builds() {
  printf '%s\n' "$(data_dir)/looking-glass"
}

# Print the client binary lanai open runs (req 8): the installed build that
# matches the recorded guest version, else the pinned build. Fails when
# neither is installed.
build_select() {
  local root g d name
  root=$(client_builds)
  g=$(guest_version_get)
  if [[ -n $g ]] && ! lg_same_build "$LG_BUILD" "$g"; then
    for d in "$root"/*/; do
      name=${d%/}
      name=${name##*/}
      if lg_same_build "$name" "$g" && [[ -x $d/bin/looking-glass-client ]]; then
        printf '%s\n' "${d}bin/looking-glass-client"
        return 0
      fi
    done
  fi
  [[ -x $root/$LG_BUILD/bin/looking-glass-client ]] || return 1
  printf '%s\n' "$root/$LG_BUILD/bin/looking-glass-client"
}

# Print the build a client binary reports: the "Looking Glass (<build>)"
# line it logs first, also for --help. Fails when it prints none.
client_version() {
  local v
  [[ -x $1 ]] || return 1
  v=$(timeout 10 "$1" --help </dev/null 2>&1 |
    sed -n 's/^.* | Looking Glass (\([^)]*\))$/\1/p' | head -n 1) || true
  [[ -n $v ]] || return 1
  printf '%s\n' "$v"
}

# --- the client's start (lanai-client-exec) ---

# client_wait <socket> <seconds>: wait until QEMU answers a command on the
# QMP <socket> (plan phase 5, proofs.md's extra check). Each try connects,
# reads the greeting, sends qmp_capabilities, then query-status, and counts
# only a reply whose return holds a status; the greeting alone does not.
# Each try has 2 s and closes its connection, since QEMU serves one client
# per socket and a status poll may hold it. A missing socket, a refused
# connect or a timeout means try again, until <seconds> have passed.
client_wait() {
  local sock=$1 end=$((EPOCHSECONDS + $2)) reply
  while :; do
    if reply=$(LANAI_QMP_BUDGET=2 qmp_call "$sock" '{"execute":"query-status"}') &&
      jq -e '.return.status | type == "string"' <<<"$reply" >/dev/null 2>&1; then
      return 0
    fi
    ((EPOCHSECONDS < end)) || return 1
    sleep 0.5
  done
}

# lanai-client-exec <client>, the ExecStart of lanai-client.service: wait
# for QEMU (client_wait on qmp-cli.sock, up to LANAI_CLIENT_WAIT seconds),
# check $RUN, then start client.log afresh with the start line and exec the
# client, its output appended to the log. QEMU creates the shared memory
# before it answers any command, so the client never opens a stale ivshmem.
# On a timeout the message goes to the journal and, as the log's only line,
# to client.log, where lanai status reads it.
client_exec() {
  local client=$1 run log problem msg
  local -a args
  run=$(run_dir) || return 1
  log=$run/client.log
  [[ -x $client ]] || {
    echo "lanai: no Looking Glass client at $client" >&2
    return 1
  }
  if ! client_wait "$run/qmp-cli.sock" "$LANAI_CLIENT_WAIT"; then
    msg="$LANAI_CLIENT_TIMEOUT $LANAI_CLIENT_WAIT s; the Windows window did not open"
    echo "$msg" >&2
    # -d first: run_dir_check would create a missing $RUN, and a timeout
    # never creates it (the VM does); ! -L, so the log is never written
    # through a symlink.
    if [[ -d $run && ! -L $run ]] && run_dir_check >/dev/null; then
      printf '%s\n' "$msg" >"$log"
    fi
    return 1
  fi
  problem=$(run_dir_check) || {
    echo "lanai: $problem" >&2
    return 1
  }
  mapfile -t args < <(client_args "$run")
  printf '%s %s\n' "$LANAI_CLIENT_START" "$EPOCHSECONDS" >"$log"
  # Appending keeps the log whole when lanai-vm-exec empties it at the next
  # VM start while this client still runs.
  exec "$client" "${args[@]}" >>"$log" 2>&1
}

# Start lanai-client.service running lanai-client-exec <client>, outside
# Hyprland's cgroup, and return at once. The user manager's environment
# may lack the session's, so the display and XDG paths go along, taken
# literally (no $ expansion). PartOf= makes every stop of the VM unit stop
# the client too (even when ExecStop is killed at TimeoutStopSec), and
# unlike Requires= or BindsTo= it never starts the VM. session.slice, like
# the VM's: Omarchy has oomd kill in app.slice under memory pressure.
client_start() {
  local v
  local -a env=()
  for v in WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME; do
    [[ -z ${!v:-} ]] || env+=("--setenv=$v=${!v}")
  done
  systemd-run --user --collect --quiet --unit="${LANAI_CLIENT_UNIT%.service}" \
    --description="Lanai Windows window" --property="PartOf=$LANAI_UNIT" --slice=session.slice \
    --expand-environment=no "${env[@]}" -- "$LANAI_BIN/lanai-client-exec" "$1"
}

# --- the client build (spec 7, 26) ---

# fetch_verified <url> <dst> <sha256>: download <url> to <dst> over HTTPS
# only, unless a copy that matches the pin is already there. A mismatch
# deletes the file and fails. A stalled download (under 1 KiB/s for 60 s)
# fails, so it cannot hold build.lock forever.
fetch_verified() {
  local url=$1 dst=$2 sum=$3
  if [[ -f $dst ]] && verify_sha256 "$dst" "$sum" 2>/dev/null; then return 0; fi
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
    -o "$dst.part" "$url" || {
    rm -f -- "$dst.part"
    echo "lanai: could not download $url" >&2
    return 1
  }
  mv -f -- "$dst.part" "$dst" || return 1
  verify_sha256 "$dst" "$sum"
}

# Print each submodule folder (LG_SUBMODULES) of source tree <src> that is
# missing or holds no file. Prints nothing when all are populated. A
# symlink counts as missing: find does not follow a symlinked start.
submodules_missing() {
  local d
  for d in "${LG_SUBMODULES[@]}"; do
    [[ -d $1/$d && -n $(find "$1/$d" -type f -print -quit 2>/dev/null) ]] ||
      printf '%s\n' "$d"
  done
}

# Return 0 when cmake's configure output <log> lists USB audio among the
# enabled features (task 7 of the spike needs it).
usb_audio_enabled() {
  awk '/features have been enabled:/ { on = 1; next }
    /features have been disabled:/ { on = 0 }
    on && /^ \* ENABLE_USB_AUDIO,/ { found = 1 }
    END { exit !found }' "$1"
}

# Remove every client build but the pin's, once the guest's IDD is the
# pinned build (req 8: until then the old build keeps the window working).
builds_prune() {
  local d
  lg_same_build "$LG_BUILD" "$(guest_version_get)" || return 0
  for d in "$(client_builds)"/*; do
    [[ ! -e $d || ${d##*/} == "$LG_BUILD" ]] || rm -rf -- "$d"
  done
}

# Build and install the pinned client (plan phase 5): fetch the source
# tarball into <cache>/lanai/downloads, verify its SHA-256 (which covers
# every submodule, spec 26), unpack it, check the submodule folders, build
# the client with -DENABLE_X11=no, fail if USB audio is off, and install
# into <data>/looking-glass/<build>/ through a .partial folder. The
# installed binary must report the pinned build. Keeps other builds until
# the guest's IDD matches the pin. Build output goes to <state>/build-client.log.
# Prints the client binary; on failure prints why. Does nothing when the
# pinned build is already installed.
build_client() {
  local cache dl dest work src log part out
  dest=$(client_builds)/$LG_BUILD
  if [[ $(client_version "$dest/bin/looking-glass-client" 2>/dev/null) == "$LG_BUILD" ]]; then
    builds_prune
    printf '%s\n' "$dest/bin/looking-glass-client"
    return 0
  fi
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/lanai
  dl=$cache/downloads/looking-glass-$LG_BUILD-source.tar.gz
  work=$cache/build-$LG_BUILD
  log=$(state_dir)/build-client.log
  mkdir -p -- "${dl%/*}" "${log%/*}" || return 1
  if ! out=$(fetch_verified "$LG_SOURCE_URL" "$dl" "$LG_SOURCE_SHA" 2>&1); then
    printf '%s\n' "${out:-could not download the Looking Glass source}"
    return 1
  fi
  rm -rf -- "$work" && mkdir -p -- "$work" || return 1
  # From here every failure removes the work folder.
  (
    trap 'rm -rf -- "$work"' EXIT
    tar -xzf "$dl" -C "$work" --no-same-owner || {
      echo "cannot unpack $dl"
      exit 1
    }
    src=$work/looking-glass-$LG_BUILD
    [[ -f $src/client/CMakeLists.txt ]] || {
      echo "the source tarball has no looking-glass-$LG_BUILD/client folder"
      exit 1
    }
    out=$(submodules_missing "$src")
    [[ -z $out ]] || {
      echo "the source tarball is missing submodule folders: ${out//$'\n'/, }"
      exit 1
    }
    cmake -S "$src/client" -B "$work/build" -DENABLE_X11=no >"$log" 2>&1 || {
      echo "cmake could not configure the client; see $log"
      exit 1
    }
    usb_audio_enabled "$log" || {
      echo "cmake turned USB audio off (a build dependency is missing); see $log"
      exit 1
    }
    cmake --build "$work/build" -j "$(nproc)" >>"$log" 2>&1 || {
      echo "the client did not build; see $log"
      exit 1
    }
    part=$dest.partial
    rm -rf -- "$part"
    cmake --install "$work/build" --prefix "$part" >>"$log" 2>&1 || {
      rm -rf -- "$part"
      echo "the client did not install; see $log"
      exit 1
    }
    out=$(client_version "$part/bin/looking-glass-client") || out="nothing"
    [[ $out == "$LG_BUILD" ]] || {
      rm -rf -- "$part"
      echo "the built client reports $out, not $LG_BUILD"
      exit 1
    }
    rm -rf -- "$dest" && mv -T -- "$part" "$dest" || {
      echo "cannot install into $dest"
      exit 1
    }
  ) || return 1
  builds_prune
  printf '%s\n' "$dest/bin/looking-glass-client"
}

# --- host packages (spec 7) ---

# Print each package of LANAI_HOST_PACKAGES that is not installed, one per
# line. pacman -T (deptest) honours provides, so jq-git counts for jq and is
# never offered for replacement. When pacman fails otherwise, every package
# counts as missing.
host_packages_missing() {
  local out rc=0
  out=$(pacman -T -- "${LANAI_HOST_PACKAGES[@]}" 2>/dev/null) || rc=$?
  case $rc in
    0) ;;
    127) [[ -z $out ]] || printf '%s\n' "$out" ;;
    *) printf '%s\n' "${LANAI_HOST_PACKAGES[@]}" ;;
  esac
}

# Print the one command that installs packages <pkg>..., exactly as
# lanai-setup-host runs it.
host_install_command() {
  printf '%s\n' "sudo pacman -S --needed $*"
}

# lanai-setup-host: in the terminal the panel opened, print the exact
# command for the missing packages, run it (sudo asks for the password
# there), and wait for Enter so the result stays readable. The one place
# Lanai runs sudo (CLAUDE.md); it refuses outside a terminal.
host_install() {
  local rc=0
  local -a pkgs
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "lanai-setup-host: runs only in a terminal; use setup in the Lanai panel" >&2
    return 1
  fi
  mapfile -t pkgs < <(host_packages_missing)
  if ((${#pkgs[@]} == 0)); then
    echo "The host packages Lanai needs are already installed."
    read -r -p "Press Enter to close this window. " _ || true
    return 0
  fi
  printf 'Lanai needs these host packages from the Arch repositories. It runs:\n\n  %s\n\n' \
    "$(host_install_command "${pkgs[@]}")"
  sudo pacman -S --needed "${pkgs[@]}" || rc=$?
  echo
  if ((rc == 0)); then
    echo "Done. Go back to the Lanai panel to continue setup."
  else
    echo "The install did not finish (exit $rc). Close this window and try again from the Lanai panel."
  fi
  read -r -p "Press Enter to close this window. " _ || true
  return "$rc"
}
