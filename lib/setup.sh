# Lanai's setup (plan phase 6): setup state that follows the disk, the
# setup media, and the resumable lanai setup. lib/lanai.sh sources this
# file; it defines functions and constants only.
#
# Setup state lives in <state>/setup.json:
#   location  the storage location it belongs to (storage_dir's real path)
#   snapshot  "taken" or "declined" (step 3)
#   step5     absent until a setup boot starts; false while one has not
#             ended cleanly; true once record_previous_run saw it end with a
#             clean guest shutdown that the panel did not ask for
#   done      true once step 6 passed
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

# setup_set <key> <json>: set setup.json's <key> to <json>, or remove it for
# null, keeping the other keys. Replaces the file by rename. Callers hold
# lanai_flock (record_previous_run's callers do too).
setup_set() {
  local f cur
  f=$(setup_file)
  cur=$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null) || cur=""
  [[ -n $cur ]] || cur='{}'
  mkdir -p -- "${f%/*}" &&
    jq -c --arg k "$1" --argjson v "$2" 'if $v == null then del(.[$k]) else .[$k] = $v end' \
      <<<"$cur" >"$f.tmp" &&
    mv -f -- "$f.tmp" "$f"
}

# Return 0 when setup.json belongs to storage location <dir>.
setup_current() {
  jq -e --arg d "$1" '.location == $d' "$(setup_file)" >/dev/null 2>&1
}

# Forget all setup state: run record_previous_run first, so markers from an
# earlier boot cannot mark step 5 done on the new state, then remove
# setup.json and guest-version. Needs lanai_flock and a stopped unit: boot_vm
# (setup boots), lanai setup's resume and lanai restore call it.
setup_reset() {
  local s
  record_previous_run >/dev/null
  s=$(state_dir)
  rm -f -- "$s/setup.json" "$s/guest-version"
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
  if ! bsdtar -xf "$dl/looking-glass-idd-$LG_BUILD.zip" -C "$part" looking-glass-idd-setup.exe ||
    ! bsdtar -xf "$dl/virtio-win-$VIRTIO_WIN_VERSION.iso" -C "$part" viofs/w11/amd64 ||
    ! chmod -R u+rwX -- "$part"; then
    echo "cannot unpack the IDD installer or viofs/w11/amd64 from the downloads"
    rm -rf -- "$part"
    return 1
  fi
  for f in looking-glass-idd-setup.exe viofs/w11/amd64/viofs.inf viofs/w11/amd64/virtiofs.exe; do
    [[ -f $part/$f && ! -L $part/$f ]] || {
      echo "the downloads hold no $f"
      rm -rf -- "$part"
      return 1
    }
  done
  if ! cp -- "$dl/spice-vdagent-x64-$VDAGENT_VERSION.msi" "$part/spice-vdagent.msi" ||
    ! cp -- "$dl/qemu-ga-x86_64-$QEMU_GA_VERSION.msi" "$part/qemu-ga.msi" ||
    ! cp -- "$dl/winfsp-$WINFSP_VERSION.msi" "$part/winfsp.msi" ||
    ! cp -- "$guest/setup.cmd" "$guest/lanai-lock.cmd" "$guest/lanai-scale.ps1" "$part/" ||
    ! mv -T -- "$part" "$media"; then
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
  if ! dir=$(storage_dir) || ! setup_current "$dir" || [[ -z $(setup_get snapshot) ]]; then
    emit false setup-needed "Lanai setup has not offered its snapshot for this storage location yet." \
      "run lanai setup"
    return 1
  fi
  rc=0
  out=$(
    lanai_flock || exit 3
    st=$(unit_state) || st=unknown
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
    *)
      emit false "" "The setup media were not built: $out" "run setup again"
      return 1
      ;;
  esac
  boot_vm true "$window"
}

# --- lanai setup: the resumable steps (plan phase 6, the step table) ---

# Seconds after step 6's client starts during which a guest part that does
# not answer yet counts as still starting, not as missing.
LANAI_SETUP_GRACE=${LANAI_SETUP_GRACE:-60}

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

# Print the build client log <log> names ("Looking Glass (<build>)"), or
# nothing.
log_client_build() {
  sed -n 's/^.* | Looking Glass (\([^)]*\))$/\1/p' "$1" 2>/dev/null | head -n 1
}

# Print when the client of log <log> started (its first line), or 0.
log_client_start() {
  local first="" start
  IFS= read -r first <"$1" 2>/dev/null || true
  start=${first#"$LANAI_CLIENT_START "}
  [[ $first == "$LANAI_CLIENT_START "* && $start =~ ^[0-9]+$ ]] || start=0
  printf '%s\n' "$start"
}

# setup_back5 <what failed>: a step 6 check failed, so setup goes back to
# step 5: step5 is forgotten, so the next lanai setup, once Windows is shut
# down, starts a setup boot with the display the record suggests.
setup_back5() {
  setup_set step5 null || true
  setup_reply false 5 "$1 Lanai setup did not finish: run setup.cmd again." \
    "shut Windows down, then run Lanai setup again"
}

# setup_step6 <share yes|no|""> <scale yes|no|"">: check the running step 6
# boot part by part. The pinned client must be the one logging: any other
# build's client, or a client that closed before Windows answered, is
# (re)started with the pinned build and not counted. Then: the client's
# verdict (version_check) waiting or unknown means wait; idd-missing or
# mismatch sends setup back to step 5, keeping the guest version record;
# match records the pin from this log (guest_version_note). Then the SPICE
# agent's port must be open, and the guest agent must set the clock and
# refuse an argument-free guest-exec as disabled (the allow-list took
# effect); a part that does not answer within LANAI_SETUP_GRACE of the
# client's start sends setup back to step 5. Last, the user's two answers
# (~/Windows shows in Explorer, the text size is right): both yes finishes
# setup, a no sends it back to step 5, none asks the questions.
setup_step6() {
  local share=$1 scale=$2 run log verdict="" guest="" build out wrong=""
  local -a missing=()
  if ! run=$(run_dir); then
    setup_reply false 6 "XDG_RUNTIME_DIR is not set, so Lanai cannot reach Windows." ""
    return 1
  fi
  log=$run/client.log
  read -r verdict guest < <(version_check "$log") || verdict=unknown
  build=$(log_client_build "$log")
  if [[ -n $build && $build != "$LG_BUILD" ]] || { [[ $verdict != match ]] && ! client_active; }; then
    ! client_active || systemctl --user stop "$LANAI_CLIENT_UNIT" >&2 || true
    if ! client_start "$(pinned_client)" >&2; then
      setup_reply false 6 "Lanai could not open the Windows window to check the display driver." \
        "see the logs with journalctl --user -u $LANAI_CLIENT_UNIT"
      return 1
    fi
    setup_reply true 6 "Lanai opened the Windows window with its own client to check the display driver." \
      "wait, then run setup again"
    return 0
  fi
  case $verdict in
    match) guest_version_note "$log" ;;
    idd-missing)
      setup_back5 "The Looking Glass display driver in Windows did not answer."
      return 1
      ;;
    mismatch)
      setup_back5 "The display driver in Windows${guest:+ ($guest)} is not Lanai's build ($LG_BUILD)."
      return 1
      ;;
    *)
      setup_reply true 6 "Windows is starting. Lanai checks each part once it has booted." \
        "wait, then run setup again"
      return 0
      ;;
  esac
  out=$(qmp_call "$run/qmp-cli.sock" '{"execute":"query-chardev"}') || out=""
  [[ $(jq -r 'select(.return | type == "array") | .return[] | select(.label == "vdagent") |
    .["frontend-open"]' <<<"$out" 2>/dev/null) == true ]] || missing+=("the SPICE agent")
  # The agent's port must be open first: a sync on a closed one waits 5 s.
  if [[ $(jq -r 'select(.return | type == "array") | .return[] | select(.label == "qga0") |
    .["frontend-open"]' <<<"$out" 2>/dev/null) != true ]] ||
    ! qga_reply "$run/qga.sock" command '{"execute":"guest-set-time","arguments":{"time":@NOW_NS@}}' ||
    ! qga_reply "$run/qga.sock" refusal '{"execute":"guest-exec"}'; then
    missing+=("the QEMU guest agent with its allow-list")
  fi
  if ((${#missing[@]})); then
    out="${missing[0]}${missing[1]:+ and ${missing[1]}}"
    if ((EPOCHSECONDS - $(log_client_start "$log") < LANAI_SETUP_GRACE)); then
      setup_reply true 6 "Windows is still starting: $out did not answer yet." "wait, then run setup again"
      return 0
    fi
    setup_back5 "In Windows, $out did not answer."
    return 1
  fi
  if [[ -z $share || -z $scale ]]; then
    setup_reply true 6 "Windows is set up. Two last checks, in Windows: does ~/Windows show in Explorer, and does text look the right size?" \
      "answer with lanai setup --share-ok yes|no --scale-ok yes|no" '{"questions": ["share", "scale"]}'
    return 0
  fi
  [[ $share == yes ]] || wrong="Explorer does not show ~/Windows."
  [[ $scale == yes ]] || wrong+="${wrong:+ }The text size is wrong (the sign-in scale task)."
  if [[ -n $wrong ]]; then
    setup_back5 "$wrong"
    return 1
  fi
  if ! setup_set "done" true || ! setup_set step5 null; then
    setup_reply false 6 "Lanai cannot record its setup state." "run setup again"
    return 1
  fi
  setup_reply true 7 "Lanai setup is finished." "use Windows from the bar"
}

# setup_resume <window> <no-snapshot true|false> <share> <scale>: under
# lanai_flock, find the first step that is not done (the step table) and
# either answer it (one JSON object) or print the one action cmd_setup runs
# once the lock is released: "build" (step 4), "setup-boot" (step 5) or
# "normal-boot" (step 6). Each step is detected, not assumed. With the unit
# stopped it first records the previous run (step 5's verdict) and makes
# setup state follow the disk. done with a guest version behind the pin
# goes back to step 5 (a pin bump; the old client keeps working).
setup_resume() {
  local window=$1 nosnap=$2 share=$3 scale=$4 st stopped=false dir problem missing details want s
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
    record_previous_run >/dev/null
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
      setup_set snapshot '"taken"'
    elif [[ $nosnap == true ]]; then
      setup_set snapshot '"declined"'
    else
      setup_reply false 3 "Before Windows first boots under Lanai, Lanai can take an instant snapshot of $dir, so a bad first boot can be undone." \
        "take one with lanai snapshot, or go on without one with lanai setup --no-snapshot"
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

  # 7. Done, unless the guest's IDD is behind the pin.
  if setup_done && [[ -z $(guest_version_behind) ]]; then
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
  case $(setup_get step5) in
    true) echo normal-boot ;;
    false)
      if [[ $window == auto ]]; then
        setup_reply false 5 "The setup boot did not finish: Windows did not shut down by itself after setup.cmd. A Shut down from the panel or a forced stop does not count." \
          "start it again on QEMU's screen (--window) while Windows has no Lanai display driver yet, or in the Windows window (--no-window) once it has" \
          '{"choices": ["--window", "--no-window"]}'
        return 1
      fi
      echo setup-boot
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
  # lanai_on_exit reads it.
  # shellcheck disable=SC2034
  LANAI_EMITTED=1
}
