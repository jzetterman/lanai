# Lanai's setup (plan phase 6): setup state that follows the disk, the
# setup media, and the resumable lanai setup. lib/lanai.sh sources this
# file; it defines functions and constants only.
#
# Setup state lives in <state>/setup.json:
#   location  the storage location it belongs to (storage_dir's real path)
#   snapshot  "taken" or "declined" (step 3)
#   step5     absent until a setup boot is chosen; false while one has not
#             ended cleanly; true once record_previous_run saw it end with a
#             clean guest shutdown that the panel did not ask for
#   done      true once step 6 passed
#   round     true from a setup boot's start until step 7; while it is
#             open, a done setup (a pin bump, or a rerun) does not read as
#             finished, though lanai start still works (spec 8)
# State for another location, or none, counts as no state at all.
# shellcheck shell=bash

# --- setup.json ---

# Print the path of setup.json.
setup_file() {
  printf '%s\n' "$(state_dir)/setup.json"
}

# Print setup.json's <key> (jq -r form; false prints "false"), or nothing
# when the key or the file is missing.
setup_get() {
  jq -r --arg k "$1" 'if type == "object" and has($k) then .[$k] else empty end' \
    "$(setup_file)" 2>/dev/null || true
}

# setup_patch <json-object>: set each key of <json-object> in setup.json,
# or remove it for null, keeping the other keys, in one write (replaced by
# rename). Callers hold lanai_flock (record_previous_run's callers do too).
setup_patch() {
  local f cur
  f=$(setup_file)
  cur=$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null) || cur=""
  [[ -n $cur ]] || cur='{}'
  mkdir -p -- "${f%/*}" &&
    jq -c --argjson p "$1" 'reduce ($p | to_entries[]) as $e (.;
      if $e.value == null then del(.[$e.key]) else .[$e.key] = $e.value end)' \
      <<<"$cur" >"$f.tmp" &&
    mv -f -- "$f.tmp" "$f"
}

# setup_set <key> <json>: setup_patch for one key.
setup_set() {
  setup_patch "$(jq -n -c --arg k "$1" --argjson v "$2" '{($k): $v}')"
}

# Return 0 when setup.json belongs to storage location <dir>.
setup_current() {
  jq -e --arg d "$1" '.location == $d' "$(setup_file)" >/dev/null 2>&1
}

# Forget all setup state: run record_previous_run first, so markers from an
# earlier boot cannot mark step 5 done on the new state, then remove
# setup.json, setup-reply.json and guest-version. Needs lanai_flock and a
# stopped unit: lanai setup's resume and lanai restore call it.
setup_reset() {
  local s
  record_previous_run >/dev/null
  s=$(state_dir)
  rm -f -- "$s/setup.json" "$s/setup-reply.json" "$s/guest-version"
}

# setup_follow <dir>: make setup state follow the disk. When setup.json is
# missing, has no location, or names another, and <dir> passes layout_check
# (an unmounted drive behind a symlink must not wipe setup state), it runs
# setup_reset and records <dir> as the location. Same lock rules as
# setup_reset.
setup_follow() {
  local dir=$1
  setup_current "$dir" && return 0
  layout_check "$dir" >/dev/null || return 0
  setup_reset
  setup_set location "$(jq -n -c --arg d "$dir" '$d')"
}

# --- the setup media (spec 7, 26) ---

# Print the pinned guest files, one per line: "<cache name> <url> <sha256>"
# (lib/pins.sh, read at call time).
guest_pins() {
  printf '%s %s %s\n' \
    "looking-glass-idd-$LG_BUILD.zip" "$LG_IDD_URL" "$LG_IDD_SHA" \
    "spice-vdagent-x64-$VDAGENT_VERSION.msi" "$VDAGENT_URL" "$VDAGENT_SHA" \
    "qemu-ga-x86_64-$QEMU_GA_VERSION.msi" "$QEMU_GA_URL" "$QEMU_GA_SHA" \
    "winfsp-$WINFSP_VERSION.msi" "$WINFSP_URL" "$WINFSP_SHA" \
    "virtio-win-$VIRTIO_WIN_VERSION.iso" "$VIRTIO_WIN_URL" "$VIRTIO_WIN_SHA"
}

# Print the folder pinned downloads are cached in.
downloads_dir() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/lanai/downloads"
}

# Download every pinned guest file into downloads_dir and verify its
# SHA-256 (fetch_verified: a cached file is used only while it matches; a
# mismatch deletes the file). On failure prints why.
setup_downloads() {
  local dl name url sum out
  dl=$(downloads_dir)
  mkdir -p -- "$dl" || {
    echo "cannot create $dl"
    return 1
  }
  while read -r name url sum; do
    if ! out=$(fetch_verified "$url" "$dl/$name" "$sum" 2>&1); then
      printf '%s\n' "${out:-could not download $url}"
      return 1
    fi
  done < <(guest_pins)
}

# Build the setup disk's folder, <state>/setup-media: remove the old media
# first, so a failure leaves none at all; download and verify the pinned
# guest files (setup_downloads); then, in setup-media.partial, renamed at
# the end, put the IDD installer from its zip, the three MSIs under the
# names setup.cmd uses, the guest scripts, and from the virtio-win ISO (too
# big for QEMU's FAT disk) only viofs/w11/amd64. The VM must be stopped: a
# running setup boot reads the folder. On failure prints why.
setup_media_build() {
  local dl media part guest=$LANAI_LIB/../guest f
  dl=$(downloads_dir)
  media=$(state_dir)/setup-media
  part=$media.partial
  chmod -R u+w -- "$media" "$part" 2>/dev/null || true
  if ! rm -rf -- "$media" "$part"; then
    echo "cannot remove the old $media"
    return 1
  fi
  setup_downloads || return 1
  mkdir -p -- "$part" || {
    echo "cannot create $part"
    return 1
  }
  # In the pinned ISO, viofs/w11/amd64's files are hard links to
  # viofs/2k25/amd64's (other folders link elsewhere, so not all of viofs
  # unpacks alone). Both unpack aside, and only w11/amd64 is kept. The ISO's
  # folders are read-only, so each path makes them writable before removal.
  if ! bsdtar -xf "$dl/looking-glass-idd-$LG_BUILD.zip" -C "$part" looking-glass-idd-setup.exe ||
    ! mkdir -p -- "$part/.iso" "$part/viofs/w11" ||
    ! bsdtar -xf "$dl/virtio-win-$VIRTIO_WIN_VERSION.iso" -C "$part/.iso" viofs/2k25/amd64 viofs/w11/amd64 ||
    ! chmod -R u+rwX -- "$part" ||
    ! mv -- "$part/.iso/viofs/w11/amd64" "$part/viofs/w11/amd64" ||
    ! rm -rf -- "$part/.iso"; then
    echo "cannot unpack the IDD installer or viofs/w11/amd64 from the downloads"
    chmod -R u+rwX -- "$part" 2>/dev/null || true
    rm -rf -- "$part"
    return 1
  fi
  for f in looking-glass-idd-setup.exe viofs/w11/amd64/viofs.inf viofs/w11/amd64/virtiofs.exe; do
    [[ -f $part/$f ]] || {
      echo "the downloads hold no $f"
      rm -rf -- "$part"
      return 1
    }
  done
  if ! cp -- "$dl/spice-vdagent-x64-$VDAGENT_VERSION.msi" "$part/spice-vdagent.msi" ||
    ! cp -- "$dl/qemu-ga-x86_64-$QEMU_GA_VERSION.msi" "$part/qemu-ga.msi" ||
    ! cp -- "$dl/winfsp-$WINFSP_VERSION.msi" "$part/winfsp.msi" ||
    ! cp -- "$guest/setup.cmd" "$guest/lanai-lock.cmd" "$guest/lanai-scale.ps1" "$part/"; then
    echo "cannot assemble $media"
    rm -rf -- "$part"
    return 1
  fi
  if [[ -n $(find "$part" -type l -print -quit) ]]; then
    echo "the setup media contain a symlink"
    rm -rf -- "$part"
    return 1
  fi
  if ! mv -T -- "$part" "$media"; then
    echo "cannot assemble $media"
    rm -rf -- "$part"
    return 1
  fi
}

# Print the window choice from setup-guest's options: auto, or true for
# --window and false for --no-window. Fails on any other option.
window_option() {
  local w=auto a
  for a; do
    case $a in
      --window) w=true ;;
      --no-window) w=false ;;
      *) return 1 ;;
    esac
  done
  printf '%s\n' "$w"
}

# setup_guest <window auto|true|false>: step 5's setup boot (plan phase 6).
# Refuses before step 3 (no snapshot decision for this location). Builds
# the setup media under lanai_flock, with the VM stopped (in a subshell,
# released before boot_vm takes the lock again; the downloads can take
# minutes), then boots with the setup disk (boot_vm true). Emits one JSON
# object. Records no guest version: step 6 does, from evidence.
setup_guest() {
  local window=$1 dir out rc st
  if ! dir=$(storage_dir) || ! setup_current "$dir" ||
    [[ $(setup_get snapshot) != taken && $(setup_get snapshot) != declined ]]; then
    emit false setup-needed "Lanai setup has not offered its snapshot for this storage location yet." \
      "run lanai setup"
    return 1
  fi
  rc=0
  out=$(
    lanai_flock || exit 3
    st=$(unit_state) || exit 5
    [[ $st == inactive || $st == failed ]] || exit 4
    setup_media_build
  ) || rc=$?
  case $rc in
    0) ;;
    3)
      emit false "" "$LANAI_BUSY." "try again when it finishes"
      return 1
      ;;
    4)
      emit false "" "Windows is running under Lanai." "shut Windows down, then run setup again"
      return 1
      ;;
    5)
      emit false "" "Lanai cannot reach the systemd user manager." ""
      return 1
      ;;
    *)
      emit false "" "The setup media were not built: $out" "run setup again"
      return 1
      ;;
  esac
  boot_vm true "$window"
}

# --- lanai setup: the resumable steps (plan phase 6, the step table) ---

# Step 6's timing, in seconds. A guest part that has not answered counts as
# missing only once the guest agent's port has been open this long (Windows
# has booted); and a closed agent port is given up this long after step 6
# first sees it closed, including after a Windows restart.
LANAI_SETUP_GRACE=${LANAI_SETUP_GRACE:-60}
LANAI_SETUP_BOOT_LIMIT=${LANAI_SETUP_BOOT_LIMIT:-300}

# setup_reply <ok> <step> <message> <next> [details-json]: emit lanai setup's
# answer, with the step it stands at ("1" to "7", or "3a").
setup_reply() {
  local details=${5:-}
  [[ -n $details ]] || details='{}'
  emit "$1" "" "$3" "$4" "$(jq -c --arg s "$2" '. + {step: $s}' <<<"$details")"
}

# Print the pinned client binary, which step 6 runs directly.
pinned_client() {
  printf '%s\n' "$(client_builds)/$LG_BUILD/bin/looking-glass-client"
}

# setup_back5 <what failed>: a step 6 check failed, so setup goes back to
# step 5: step5 is forgotten, so the next lanai setup, once Windows is shut
# down, starts a setup boot with the display the record suggests.
setup_back5() {
  setup_set step5 null || true
  setup_reply false 5 "$1 Lanai setup did not finish: run setup.cmd again." \
    "shut Windows down, then run Lanai setup again"
}

# setup_wait <message>: answer that step 6 is still waiting.
setup_wait() {
  setup_reply true 6 "$1" "wait, then run setup again"
}

# setup_step6 <share yes|no|""> <scale yes|no|"">: check the running step 6
# boot part by part.
# - QMP's query-chardev must answer, else it tries again. The first time it
#   shows the guest agent's port open, $RUN/qga-open-since is stamped (it is
#   removed whenever the port is closed, since a Windows restart keeps the
#   same QEMU). Every grace below counts from that stamp: Windows has booted.
#   The first closed-port poll stamps $RUN/qga-closed-since; an open port
#   removes it. After LANAI_SETUP_BOOT_LIMIT with the port closed, setup goes
#   back to step 5. lanai-vm-exec removes both stamps at each start.
# - After the port timers, a client that is not running with unknown or
#   waiting past the open-port grace is a host client failure at step 6,
#   without reopening or going back to step 5. A running client still in its
#   own 30 s (as after a reopen) is waited for.
#   The pinned client must be the one logging: a client of another build is
#   replaced; one that closed with unknown, waiting or idd-missing is reopened
#   for a fresh 30 s, within those bounds (match and mismatch stand).
# - The verdict: unknown or waiting before the grace means wait; mismatch
#   sends setup back to step 5, keeping the guest version record. The client
#   starts its 30 s count when QEMU starts, so firmware and boot time use it up;
#   idd-missing counts only once the guest agent's port has been open for
#   LANAI_SETUP_GRACE, and means wait before that. match records the pin
#   from this log (guest_version_note).
# - Then the SPICE agent's port must be open, and the guest agent must set
#   the clock and refuse an argument-free guest-exec as disabled (the
#   allow-list took effect); a part still not answering once the grace has
#   passed sends setup back to step 5.
# - Last, the user's two answers (~/Windows shows in Explorer, the text
#   size is right): a no sends setup back to step 5, two yeses finish it,
#   and otherwise it asks the questions.
setup_step6() {
  local share=$1 scale=$2 run log stamp closed_stamp verdict="" guest="" build out wrong="" since="" age=-1
  local -a missing=()
  if ! run=$(run_dir); then
    setup_reply false 6 "XDG_RUNTIME_DIR is not set, so Lanai cannot reach Windows." ""
    return 1
  fi
  log=$run/client.log
  stamp=$run/qga-open-since
  closed_stamp=$run/qga-closed-since
  read -r verdict guest < <(version_check "$log") || verdict=unknown
  build=$(log_client_build "$log")
  if ! out=$(qmp_call "$run/qmp-cli.sock" '{"execute":"query-chardev"}'); then
    setup_wait "QEMU did not answer Lanai's question about Windows' agents; it asks again next time."
    return 0
  fi
  if chardev_open qga0 <<<"$out"; then
    rm -f -- "$closed_stamp"
    [[ -s $stamp ]] || printf '%s\n' "$EPOCHSECONDS" >"$stamp" || true
    [[ ! -s $stamp ]] || since=$(<"$stamp")
    [[ $since =~ ^[0-9]+$ ]] && age=$((EPOCHSECONDS - since))
  else
    rm -f -- "$stamp"
    [[ -s $closed_stamp ]] || printf '%s\n' "$EPOCHSECONDS" >"$closed_stamp" || true
    [[ ! -s $closed_stamp ]] || since=$(<"$closed_stamp")
    if [[ $since =~ ^[0-9]+$ ]] && ((EPOCHSECONDS - since >= LANAI_SETUP_BOOT_LIMIT)); then
      setup_back5 "Windows did not finish starting, or its guest agent is missing."
      return 1
    fi
  fi
  if [[ $verdict == unknown || $verdict == waiting ]] && ((age >= LANAI_SETUP_GRACE)) && ! client_active; then
    setup_reply false 6 "The Windows window did not stay open long enough to check the display driver." \
      "see the logs with journalctl --user -u ${LANAI_CLIENT_UNIT%.service}, then run setup again"
    return 1
  fi
  if [[ -n $build && $build != "$LG_BUILD" ]] ||
    { [[ $verdict == unknown || $verdict == waiting || $verdict == idd-missing ]] && ! client_active; }; then
    ! client_active || systemctl --user stop "$LANAI_CLIENT_UNIT" >&2 || true
    if ! client_start "$(pinned_client)" >&2; then
      setup_reply false 6 "Lanai could not open the Windows window to check the display driver." \
        "see the logs with journalctl --user -u $LANAI_CLIENT_UNIT"
      return 1
    fi
    setup_wait "Lanai opened the Windows window with its own client to check the display driver."
    return 0
  fi
  case $verdict in
    match) guest_version_note "$log" ;;
    idd-missing)
      if ((age >= LANAI_SETUP_GRACE)); then
        setup_back5 "The Looking Glass display driver in Windows did not answer."
        return 1
      fi
      setup_wait "Windows is starting. Lanai checks each part once it has booted."
      return 0
      ;;
    mismatch)
      setup_back5 "The display driver in Windows${guest:+ ($guest)} is not Lanai's build ($LG_BUILD)."
      return 1
      ;;
    *)
      setup_wait "Windows is starting. Lanai checks each part once it has booted."
      return 0
      ;;
  esac
  chardev_open vdagent <<<"$out" || missing+=("the SPICE agent")
  # Only an open port is asked: a sync on a closed one waits 5 s.
  if ((age < 0)) ||
    ! qga_reply "$run/qga.sock" command '{"execute":"guest-set-time","arguments":{"time":@NOW_NS@}}' ||
    ! qga_reply "$run/qga.sock" refusal '{"execute":"guest-exec"}'; then
    missing+=("the QEMU guest agent with its allow-list")
  fi
  if ((${#missing[@]})); then
    out="${missing[0]}${missing[1]:+ and ${missing[1]}}"
    if ((age < LANAI_SETUP_GRACE)); then
      setup_wait "Windows is still starting: $out did not answer yet."
      return 0
    fi
    setup_back5 "In Windows, $out did not answer."
    return 1
  fi
  [[ $share != no ]] || wrong="Explorer does not show ~/Windows."
  [[ $scale != no ]] || wrong+="${wrong:+ }The text size is wrong (the sign-in scale task)."
  if [[ -n $wrong ]]; then
    setup_back5 "$wrong"
    return 1
  fi
  if [[ $share != yes || $scale != yes ]]; then
    setup_reply true 6 "Windows is set up. Two last checks, in Windows: does ~/Windows show in Explorer, and does text look the right size?" \
      "answer with lanai setup --share-ok yes|no --scale-ok yes|no" '{"questions": ["share", "scale"]}'
    return 0
  fi
  if ! setup_patch '{"done": true, "step5": null, "round": null}'; then
    setup_reply false 6 "Lanai cannot record its setup state." "run setup again"
    return 1
  fi
  setup_reply true 7 "Lanai setup is finished." "use Windows from the bar"
}

# setup_resume <window> <no-snapshot true|false> <share> <scale>: under
# lanai_flock, find the first step that is not done (the step table) and
# either answer it (one JSON object) or print the one action setup_command
# runs once the lock is released: "build" (step 4), "setup-boot" (step 5) or
# "normal-boot" (step 6). Each step is detected, not assumed. With the unit
# stopped it first records the previous run (step 5's verdict) and makes
# setup state follow the disk. done with a guest version behind the pin,
# or with a setup round open, is not reported finished (the old client
# keeps working). An explicit display choice also bypasses step 7.
# Call it inside $(...): the lock it takes lasts
# until that subshell exits, so it is free again for boot_vm.
setup_resume() {
  local window=$1 nosnap=$2 share=$3 scale=$4 st stopped=false nostart=false dir problem missing details want s verdict
  local -a list
  if ! lanai_flock; then
    emit false "" "$LANAI_BUSY." "try again when it finishes"
    return 1
  fi
  if ! st=$(unit_state); then
    emit false "" "Lanai cannot reach the systemd user manager." ""
    return 1
  fi
  [[ $st != inactive && $st != failed ]] || stopped=true
  s=$(state_dir)
  if ! dir=$(storage_dir); then
    setup_reply false 1 "Lanai cannot read its settings file." "fix $(settings_file)"
    return 1
  fi

  # 1. Checks.
  if problem=$(restore_pending) || ! problem=$(layout_check "$dir") || ! problem=$(share_check) ||
    problem=$(container_blocked); then
    setup_reply false 1 "${problem//$'\n'/; }" "fix that, then run setup again"
    return 1
  fi
  if $stopped; then
    verdict=$(record_previous_run)
    if [[ $verdict == nostart ]] ||
      { [[ -z $verdict && $st == failed ]] &&
        [[ $(systemctl --user show -p Result --value "$LANAI_UNIT" 2>/dev/null) == exit-code ]]; }; then
      nostart=true
    fi
    if ! setup_follow "$dir"; then
      setup_reply false 1 "Lanai cannot record its setup state in $s." ""
      return 1
    fi
  elif ! setup_current "$dir"; then
    setup_reply false 1 "Windows is running under Lanai ($st)." "shut Windows down, then run setup again"
    return 1
  fi

  # 2. Host packages.
  missing=$(host_packages_missing)
  if [[ -n $missing ]]; then
    mapfile -t list <<<"$missing"
    details=$(jq -n -c --arg m "$missing" --arg c "$(host_install_command "${list[@]}")" \
      '{missing: ($m | split("\n") | map(select(. != ""))), command: $c}')
    setup_reply false 2 "Lanai needs host packages that are not installed: ${missing//$'\n'/, }." \
      "install them with lanai setup-host, which opens a terminal" "$details"
    return 1
  fi

  # 3. The snapshot offer, before any Lanai boot.
  if [[ -z $(setup_get snapshot) ]]; then
    if [[ -n $(snapshot_list "$dir") ]]; then
      want=taken
    elif [[ $nosnap == true ]]; then
      want=declined
    else
      setup_reply false 3 "Before Windows first boots under Lanai, Lanai can take an instant snapshot of $dir, so a bad first boot can be undone." \
        "take one with lanai snapshot, or go on without one with lanai setup --no-snapshot"
      return 1
    fi
    if ! setup_set snapshot "\"$want\""; then
      setup_reply false 3 "Lanai cannot record its setup state." "run setup again"
      return 1
    fi
  fi

  # 3a. An empty or missing windows.base gets the name dockur would write,
  # after the snapshot, so a restore brings back the original.
  if $stopped && [[ ! -s $dir/windows.base ]]; then
    if ! want=$(expected_base) || ! printf '%s\n' "$want" >"$dir/windows.base"; then
      setup_reply false 3a "Lanai cannot fill in windows.base: $want" "fix that, then run setup again"
      return 1
    fi
    setup_reply true 3a "windows.base was empty, so Lanai wrote $want into it, the name a container start would write, so a later one rewrites nothing." \
      "run setup again"
    return 0
  fi

  # 4. The pinned client.
  if [[ $(client_version "$(pinned_client)" 2>/dev/null) != "$LG_BUILD" ]]; then
    echo build
    return 0
  fi

  # 7. Done, unless the guest's IDD is behind the pin or a setup round is
  # still open (its step 6 may have recorded the pin, so "behind" alone
  # cannot tell), or the display was explicit.
  if [[ $window == auto ]] && setup_done &&
    [[ -z $(guest_version_behind) && $(setup_get round) != true && $(setup_get step5) != false ]]; then
    setup_reply true 7 "Lanai setup is finished." "start Windows"
    return 0
  fi

  # 5 and 6, by the VM's state.
  if ! $stopped; then
    if jq -e '.setup == true' "$s/boot.json" >/dev/null 2>&1; then
      setup_reply true 5 "The setup boot is running. In Windows, open Lanai's setup drive and run setup.cmd; Windows shuts down by itself when it finishes." \
        "once Windows has shut down, run setup again" \
        "$(jq -n -c --argjson w "$(boot_window && echo true || echo false)" '{active: true, window: $w}')"
      return 0
    fi
    if [[ $(setup_get step5) == true ]]; then
      if [[ $st != active ]]; then
        setup_reply true 6 "Windows is starting or shutting down ($st)." "wait, then run setup again"
        return 0
      fi
      setup_step6 "$share" "$scale"
      return
    fi
    setup_reply false 5 "Windows is running without Lanai's setup drive." "shut Windows down, then run setup again"
    return 1
  fi
  # An explicit display choice always starts a setup boot: the way out of a
  # step 6 that cannot finish.
  if [[ $window != auto ]]; then
    setup_set step5 false || true
    echo setup-boot
    return 0
  fi
  case $(setup_get step5) in
    true)
      if $nostart; then
        setup_reply false 6 "Windows did not start." "see the logs with $LANAI_LOGS, then run setup again"
        # Consume systemd's sticky failure too, so the next call retries.
        systemctl --user reset-failed "$LANAI_UNIT" >/dev/null 2>&1 || true
        return 1
      fi
      echo normal-boot
      ;;
    false)
      if $nostart; then
        setup_reply false 5 "Windows did not start." \
          "see the logs with $LANAI_LOGS, then start it again with --window or --no-window" \
          '{"choices": ["--window", "--no-window"]}'
      else
        setup_reply false 5 "The setup boot did not finish: Windows did not shut down by itself after setup.cmd. A Shut down from the panel or a forced stop does not count." \
          "start it again on QEMU's screen (--window) while Windows has no Lanai display driver yet, or in the Windows window (--no-window) once it has" \
          '{"choices": ["--window", "--no-window"]}'
      fi
      return 1
      ;;
    *) echo setup-boot ;;
  esac
}

# setup_with_step <step> [<message suffix>]: read one JSON reply on stdin
# and print it with the step added (and, when ok, the suffix after its
# message), as lanai setup's one object.
setup_with_step() {
  local out
  out=$(jq -c --arg s "$1" --arg add "${2:-}" \
    '. + {step: $s} + (if .ok and $add != "" then {message: (.message + " " + $add)} else {} end)') ||
    return 1
  printf '%s\n' "$out"
}
