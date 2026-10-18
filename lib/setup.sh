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
#   scale_task  2 once step 6 passed with the live scale task's port open:
#             the task's version (Lanai before live scale never wrote
#             it), so a finished setup without it has the old task
#   signin_step  LANAI_SIGNIN_STEP once step 6 passed: the scale task
#             carries the sign-in step in its current form (spec 12), 2
#             for the start program (guest/lanai-start.cs) and 1 for the
#             earlier step in PowerShell. A separate key, so a Lanai from
#             before the step still reads scale_task right; a finished
#             setup without the current mark has an older form or none
#   round     true from a setup boot's start until step 7; while it is
#             open, a done setup (a pin bump, or a rerun) does not read as
#             finished, though lanai start still works (spec 8)
# State for another location, or none, counts as no state at all.
# shellcheck shell=bash

# The sign-in step's current mark (signin_step above), which step 6 records
# and signin_step_missing (lib/ui.sh) checks. Bump it only for a change to
# guest/lanai-start.cs that the panel's sign-in warning describes: the
# panel then names Run setup again with those words. Any other change that
# an install must pick up, in guest/lanai-start.cs or
# guest/lanai-scale.ps1, needs its own mark and its own panel words.
LANAI_SIGNIN_STEP=2

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
  [[ ${2:-} == checked ]] || layout_check "$dir" >/dev/null || return 0
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
# names setup.cmd uses, the guest scripts and the start program's source
# (setup.cmd builds it in Windows), and from the virtio-win ISO (too
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
    ! cp -- "$guest/setup.cmd" "$guest/lanai-lock.cmd" "$guest/lanai-scale.ps1" "$guest/lanai-start.cs" \
      "$guest/lanai-share-check.ps1" "$part/"; then
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
      emit false "" "$LANAI_BUSY." "try again when it finishes" '{"reason":"busy"}'
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

# Step 6's time limits, in seconds (spec 7). One deadline covers every
# check before the scale task: LANAI_SETUP_LIMIT from $RUN/step6-since, the
# start of the current boot (lanai-vm-exec writes it at the VM's start,
# event_record at each RESET, and a Continue setup after a stop at the
# click). A Windows that restarts in a loop stops at three times that from
# $RUN/step6-run-since (the VM's start, or that Continue; never a RESET).
# The scale task starts at sign-in: its port gets LANAI_SETUP_SCALE_GRACE
# from $RUN/step6-checked, when the other checks first passed.
LANAI_SETUP_LIMIT=${LANAI_SETUP_LIMIT:-300}
LANAI_SETUP_SCALE_GRACE=${LANAI_SETUP_SCALE_GRACE:-120}

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

# setup_back5 <reason> <what is wrong>: a step 6 check got a wrong answer
# (mismatch, allowlist), so setup goes back to step 5: step5 is forgotten,
# so the next lanai setup, once Windows is shut down, starts a setup boot
# with the display the record suggests, and repeats the Windows install.
setup_back5() {
  local reason=$1
  shift
  setup_set step5 null || true
  setup_reply false 5 "$1 Lanai setup did not finish: run setup.cmd again." \
    "shut Windows down, then run Lanai setup again" "$(jq -nc --arg r "$reason" '{reason:$r}')"
}

# setup_wait <message>: answer that step 6 is still waiting.
setup_wait() {
  setup_reply true 6 "$1" "wait, then run setup again"
}

# setup_stop6 <reason> <what did not answer> [<part>...]: a step 6 check
# ran out of time. Setup stays at step 6 with step5 kept, so Continue setup
# checks again, and either display choice repeats the Windows install. The
# reply carries stop "timeout" (the panel's time-out words and display
# buttons read it) and, for agents, the parts that did not answer.
setup_stop6() {
  local reason=$1 msg=$2
  shift 2
  setup_reply false 6 "$msg If Windows' setup window stopped with a message, follow it first." \
    "continue setup to check again (lanai setup), or shut Windows down and run lanai setup --window or --no-window to repeat the Windows install" \
    "$(jq -nc --arg r "$reason" '{reason: $r, stop: "timeout"} +
      (if $ARGS.positional == [] then {} else {parts: $ARGS.positional} end)' --args -- "$@")"
}

# step6_timeout <outer true|false> <reason> <message> [<part>...]: setup_stop6,
# except past only the outer limit: Windows restarted in a loop, so the
# reason is guest-boot whatever was missing.
step6_timeout() {
  if [[ $1 == true ]]; then
    setup_stop6 guest-boot "Windows did not finish starting, or its guest agent did not start."
  else
    shift
    setup_stop6 "$@"
  fi
}

# step6_since <file>: print the time in step 6 stamp <file>, writing now
# when the stamp is missing or not a number.
step6_since() {
  local t=""
  [[ ! -s $1 ]] || t=$(<"$1")
  if [[ ! $t =~ ^[0-9]+$ ]]; then
    t=$EPOCHSECONDS
    step6_stamp "$1" "$t" || true
  fi
  printf '%s\n' "$t"
}

# Mark a step 6 failure in $RUN/step6-stopped, so the next Continue setup
# gets fresh limits (setup_step6).
step6_mark_stop() {
  local run
  run=$(run_dir) || return 0
  : >"$run/step6-stopped" 2>/dev/null || true
}

# setup_step6 [<follow step>]: check the running step 6 boot (step6_check)
# and mark every failure with step6_mark_stop. <follow step> is set for the
# panel job's follow-ups (lanai setup --follow), which keep the limits.
setup_step6() {
  local out rc=0
  out=$(step6_check "${1:-}") || rc=$?
  ((rc == 0)) || step6_mark_stop
  printf '%s\n' "$out"
  return "$rc"
}

# step6_check <follow step>: setup_step6's checks, part by part. It asks no
# question: a wrong answer stops at once (setup_back5), and a part that has
# not answered is waited for until its limit, then stops (setup_stop6).
# - Limits: a call without <follow step> that finds step6-stopped starts
#   every limit again from now (Continue setup); other calls keep them, so
#   repeated calls still meet them. A boot stamp found missing is written
#   now. Port state starts no timer.
# - Once step6-checked exists, only the scale task's port is awaited (its
#   own limit; no other deadline), so a short fault while the user signs
#   in cannot stop setup with the wrong reason. A RESET removes it.
# - QMP's query-chardev must answer, else it tries again. Past the deadline
#   a failure stops as qmp only when the call before it failed too
#   (step6-qmp-failed), since the panel's status shares QEMU's one client
#   socket.
# - Past the deadline, the first part missing names the stop, in this
#   order: guest-boot (the guest agent's port is closed), window-closed,
#   idd-missing, agents; past only the outer limit, guest-boot.
# - The pinned client must be the one logging. Before the deadline, a
#   client of another build is replaced, and one that closed with unknown,
#   waiting or idd-missing is reopened for a fresh 30 s (match and mismatch
#   stand). The client starts its 30 s count when QEMU starts, so an early
#   idd-missing means wait. At the deadline, a closed or replaced client
#   is window-closed, and the pinned client without an IDD verdict
#   (unknown, waiting or idd-missing) is idd-missing.
# - mismatch sends setup back to step 5, keeping the guest version record;
#   match records the pin from this log (guest_version_note).
# - Then the SPICE agent's port must be open, and the guest agent must set
#   the clock and refuse an argument-free guest-exec as disabled. Any other
#   reply to it means the allow-list is missing: back to step 5.
# - Last, step6_scale.
step6_check() {
  local follow=$1 run log now since run_since checked="" late=false outer=false qga_open=false
  local verdict="" guest="" build pinned=true chardevs out rc
  local -a missing=()
  if ! run=$(run_dir); then
    setup_reply false 6 "XDG_RUNTIME_DIR is not set, so Lanai cannot reach Windows." ""
    return 1
  fi
  log=$run/client.log
  now=$EPOCHSECONDS
  if [[ -z $follow && -e $run/step6-stopped ]]; then
    rm -f -- "$run/step6-stopped" "$run/step6-checked" "$run/step6-qmp-failed"
    step6_stamp "$run/step6-since" "$now" || true
    step6_stamp "$run/step6-run-since" "$now" || true
  fi
  since=$(step6_since "$run/step6-since")
  run_since=$(step6_since "$run/step6-run-since")
  [[ ! -s $run/step6-checked ]] || checked=$(<"$run/step6-checked")
  [[ $checked =~ ^[0-9]+$ ]] || checked=""
  if [[ -n $checked ]]; then
    ((now - checked < LANAI_SETUP_SCALE_GRACE)) || late=true
  elif ((now - since >= LANAI_SETUP_LIMIT)); then
    late=true
  elif ((now - run_since >= 3 * LANAI_SETUP_LIMIT)); then
    late=true outer=true
  fi
  if ! chardevs=$(qmp_call "$run/qmp-cli.sock" '{"execute":"query-chardev"}'); then
    if $late && [[ -e $run/step6-qmp-failed ]]; then
      setup_stop6 qmp "QEMU did not answer when Lanai checked Windows' agents."
      return 1
    fi
    : >"$run/step6-qmp-failed" || true
    setup_wait "QEMU did not answer Lanai's question about Windows' agents; it asks again next time."
    return 0
  fi
  rm -f -- "$run/step6-qmp-failed"
  if [[ -n $checked ]]; then
    step6_scale "$chardevs" "$late"
    return
  fi
  chardev_open qga0 <<<"$chardevs" && qga_open=true
  if $late && ! $qga_open; then
    step6_timeout "$outer" guest-boot "Windows did not finish starting, or its guest agent did not start."
    return 1
  fi
  read -r verdict guest < <(version_check "$log") || verdict=unknown
  build=$(log_client_build "$log")
  [[ -z $build || $build == "$LG_BUILD" ]] || pinned=false
  if ! $pinned || { [[ $verdict == unknown || $verdict == waiting || $verdict == idd-missing ]] && ! client_active; }; then
    if $late && $pinned && [[ $verdict == idd-missing ]]; then
      step6_timeout "$outer" idd-missing "The Looking Glass display driver in Windows did not answer."
      return 1
    elif $late; then
      step6_timeout "$outer" window-closed "The Windows window did not stay open long enough to check the display driver."
      return 1
    fi
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
    mismatch)
      setup_back5 mismatch "The display driver in Windows${guest:+ ($guest)} is not Lanai's build ($LG_BUILD)."
      return 1
      ;;
    *)
      # The pinned client is open, and the IDD has not answered it yet.
      if $late; then
        step6_timeout "$outer" idd-missing "The Looking Glass display driver in Windows did not answer."
        return 1
      fi
      setup_wait "Windows is starting. Lanai checks each part once it has booted."
      return 0
      ;;
  esac
  chardev_open vdagent <<<"$chardevs" || missing+=("the SPICE agent")
  # Only an open port is asked: a sync on a closed one waits 5 s. The
  # command the allow-list must refuse has no arguments, so it runs nothing
  # even when an agent accepts it (spec 27).
  if ! $qga_open ||
    ! qga_reply "$run/qga.sock" command '{"execute":"guest-set-time","arguments":{"time":@NOW_NS@}}'; then
    missing+=("the QEMU guest agent")
  else
    rc=0
    qga_reply "$run/qga.sock" refusal '{"execute":"guest-exec"}' || rc=$?
    if ((rc == 2)); then
      setup_back5 allowlist "The QEMU guest agent in Windows is missing its allow-list: it did not refuse a command the allow-list leaves out."
      return 1
    fi
    ((rc == 0)) || missing+=("the QEMU guest agent")
  fi
  if ((${#missing[@]})); then
    out="${missing[0]}${missing[1]:+ and ${missing[1]}}"
    if $late; then
      step6_timeout "$outer" agents "In Windows, $out did not answer." "${missing[@]}"
      return 1
    fi
    setup_wait "Windows is still starting: $out did not answer yet."
    return 0
  fi
  step6_stamp "$run/step6-checked" "$now" || true
  step6_scale "$chardevs" false
}

# step6_scale <query-chardev reply> <late true|false>: the last check, once
# the others passed. Only the elevated scale task opens scale0, and it
# starts when the Windows user who ran setup signs in, which may come long
# after boot. QEMU's port state, not data from the guest (spec 27): open
# finishes setup; closed waits, until <late>.
step6_scale() {
  if ! chardev_open scale0 <<<"$1"; then
    if [[ $2 == true ]]; then
      setup_stop6 scale-task "In Windows, the display scale task did not start. If Windows is at its sign-in screen, or another user is signed in, sign in as the Windows user who ran setup first."
      return 1
    fi
    setup_wait "Waiting for the display scale task. It starts when the Windows user who ran setup signs in. If Windows asks for a password, sign in."
    return 0
  fi
  # The scale task's port is open, so Windows has the live task:
  # scale_task 2, with the start program's sign-in step: signin_step
  # LANAI_SIGNIN_STEP. A record without them means the old task, or a task
  # without the current step (spec 12).
  if ! setup_patch "{\"done\": true, \"step5\": null, \"round\": null, \"scale_task\": 2, \"signin_step\": $LANAI_SIGNIN_STEP}"; then
    setup_reply false 6 "Lanai cannot record its setup state." "run setup again"
    return 1
  fi
  setup_reply true 7 "Lanai setup is finished." "use Windows from the bar"
}

# Emit a read-only setup decision, with no action or QMP call.
setup_decision() {
  local details=${4:-'{}'}
  jq -nc --arg step "$1" --arg action "$2" --arg reason "${3:-}" --argjson d "$details" \
    '{step:$step, action:$action, reason:$reason, finished:($step == "7"), choices:[]} + $d'
}

# Apply pending bookkeeping before reading setup.json. Shared facts are supplied
# by panel/resume so the container and layout are read only once per call.
setup_plan() {
  local facts=${1:-$(shared_facts)} window=${2:-auto} nosnap=${3:-false} prior=${4:-}
  local line doc run stopped=false verdict v st dir problem missing snapshot step5
  local -A f=()
  while IFS= read -r line; do [[ $line != *=* ]] || f[${line%%=*}]=${line#*=}; done <<<"$facts"
  st=${f[ActiveState]:-unknown} dir=${f[LanaiStorage]:-}
  [[ $st != inactive && $st != failed ]] || stopped=true
  verdict=$(run_verdict)
  v=${prior:-$(jq -r .verdict <<<"$verdict")}
  doc=$(jq -c 'select(type == "object")' "$(setup_file)" 2>/dev/null) || doc='{}'
  if ! jq -e --arg d "$dir" '.location == $d' <<<"$doc" >/dev/null; then doc='{}'
  elif $stopped && jq -e '.completes_step5' <<<"$verdict" >/dev/null; then
    doc=$(jq -c '.step5=true' <<<"$doc")
  fi
  if [[ $window == auto ]] && build_stamp_current &&
    jq -e '.done == true and .round != true and .step5 != false' <<<"$doc" >/dev/null &&
    [[ -z $(guest_version_behind) ]]; then setup_decision 7 "done"; return; fi
  if [[ $st == unknown ]]; then setup_decision 1 problem manager; return; fi
  if [[ -n ${f[LanaiProblemReason]:-} ]]; then
    setup_decision 1 problem "${f[LanaiProblemReason]}"; return
  fi
  if [[ ${f[LanaiRestorePending]:-false} == true ]]; then setup_decision 1 problem restore; return; fi
  if ! problem=$(share_check); then
    setup_decision 1 problem share "$(jq -nc --arg p "$problem" '{problem:$p}')"; return
  fi
  if [[ ${f[LanaiContainer]:-none} != none ]]; then setup_decision 1 problem container; return; fi
  if ! $stopped && ! jq -e --arg d "$dir" '.location == $d' <<<"$doc" >/dev/null; then
    setup_decision 1 problem active; return
  fi
  missing=$(host_packages_missing)
  if [[ -n $missing ]]; then
    setup_decision 2 packages '' "$(jq -nc --arg m "$missing" '{missing:($m|split("\n"))}')"; return
  fi
  snapshot=$(jq -r '.snapshot // empty' <<<"$doc")
  if [[ -z $snapshot ]]; then
    if [[ -n $(snapshot_list "$dir") ]]; then snapshot=taken
    elif [[ $nosnap == true ]]; then snapshot=declined
    else setup_decision 3 snapshot; return; fi
  fi
  if $stopped && [[ ! -s $dir/windows.base ]]; then setup_decision 3a base; return; fi
  if ! build_stamp_current || ! build_patches_current; then setup_decision 4 build; return; fi
  step5=$(jq -r 'if has("step5") then .step5 else "" end' <<<"$doc")
  if ! $stopped; then
    if jq -e '.setup == true' "$(state_dir)/boot.json" >/dev/null 2>&1; then
      setup_decision 5 setup-wait; return
    fi
    if [[ $step5 == true ]]; then
      run=$(run_dir) || run=''
      if [[ $st == active && -n $run && -f $run/step6-checked ]]; then
        # The other checks passed; the display scale task's port is awaited.
        setup_decision 6 checks '' '{"scale_wait":true}'
      elif [[ $st == active ]]; then setup_decision 6 checks
      else setup_decision 6 wait; fi
    else setup_decision 5 problem no-media; fi
    return
  fi
  if [[ $window != auto ]]; then setup_decision 5 setup-boot; return; fi
  if [[ ($step5 == true || $step5 == false) &&
    ($v == nostart || ($st == failed && ${f[Result]:-} == exit-code && $v == none)) ]]; then
    if [[ $step5 == true ]]; then setup_decision 6 problem nostart
    else setup_decision 5 choices nostart '{"choices":["--window","--no-window"]}'; fi
  elif [[ $step5 == true ]]; then setup_decision 6 normal-boot
  elif [[ $step5 == false ]]; then setup_decision 5 choices incomplete '{"choices":["--window","--no-window"]}'
  else setup_decision 5 setup-boot; fi
}

# Lock, consume bookkeeping, follow storage, plan once, then act. Boot/build
# actions are returned to setup_command so it can release this lock first.
setup_resume() {
  local window=$1 nosnap=$2 follow_step=${3:-} follow_inv=${4:-} requested="" s facts plan st dir verdict="" action step reason want missing details next
  local -a list=()
  # Only this lock refusal is safe to retry with the same follow-up guard:
  # no bookkeeping has run yet. A later boot lock refusal must end following.
  if ! lanai_flock; then
    emit false "" "$LANAI_BUSY." "try again when it finishes" '{"reason":"busy","follow_retry":true}'
    return 1
  fi
  facts=$(shared_facts)
  st=$(sed -n 's/^ActiveState=//p' <<<"$facts")
  dir=$(sed -n 's/^LanaiStorage=//p' <<<"$facts")
  # The worker's probe is advisory. Recheck its expectation inside the same
  # operation lock as the setup decision, before consuming or changing state.
  if [[ -n $follow_step ]]; then
    case $follow_step in
      5)
        if [[ $st == inactive || $st == failed ]] &&
          jq -e --arg i "$follow_inv" '.completes_step5 and .invocation == $i' <<<"$(run_verdict)" >/dev/null; then
          :
        else
          emit true "" "The setup wait ended." "" '{"follow_stopped":true}'; return 0
        fi ;;
      6)
        s=$(state_dir)
        [[ ! -f $s/stop-requested ]] || read -r requested _ <"$s/stop-requested" || true
        if [[ $st != active && $st != activating && $st != reloading ]] ||
          [[ $(sed -n 's/^InvocationID=//p' <<<"$facts") != "$follow_inv" || $requested == "$follow_inv" ]]; then
          emit true "" "The setup wait ended." "" '{"follow_stopped":true}'; return 0
        fi ;;
    esac
  fi
  if [[ $st == inactive || $st == failed ]]; then
    verdict=$(record_previous_run)
    verdict=${verdict:-none}
    if [[ -n $dir && $(sed -n 's/^LanaiProblemReason=//p' <<<"$facts") == '' ]]; then
      setup_follow "$dir" checked || {
        setup_reply false 1 "Lanai cannot record its setup state." "" '{"reason":"record"}'; return 1;
      }
    fi
  fi
  plan=$(setup_plan "$facts" "$window" "$nosnap" "$verdict")
  action=$(jq -r .action <<<"$plan") step=$(jq -r .step <<<"$plan") reason=$(jq -r .reason <<<"$plan")
  if [[ $action != problem && $action != packages && $action != snapshot && $action != "done" ]] &&
    [[ -z $(setup_get snapshot) ]]; then
    want=taken
    [[ $nosnap != true || -n $(snapshot_list "$dir") ]] || want=declined
    # Existing snapshots advance the read-only plan even if this write fails.
    # Keep the failure stepless so the panel retains it until the next action.
    setup_set snapshot "\"$want\"" || { emit false "" "Lanai cannot record its setup state." "run setup again" '{"reason":"record"}'; return 1; }
  fi
  case $action in
    done) setup_reply true 7 "Lanai setup is finished." "start Windows" ;;
    build|normal-boot) echo "$action" ;;
    setup-boot)
      [[ $window == auto ]] || setup_set step5 false || true
      echo setup-boot ;;
    base)
      if ! want=$(expected_base) || ! printf '%s\n' "$want" >"$dir/windows.base"; then
        setup_reply false 3a "Lanai cannot fill in windows.base." "run setup again"; return 1
      fi
      setup_reply true 3a "windows.base was empty, so Lanai wrote $want into it, the name a container start would write, so a later one rewrites nothing." "run setup again" ;;
    packages)
      missing=$(jq -r '.missing[]' <<<"$plan"); mapfile -t list <<<"$missing"
      details=$(jq -c --arg c "$(host_install_command "${list[@]}")" '{missing,command:$c}' <<<"$plan")
      setup_reply false 2 "Lanai needs host packages: ${missing//$'\n'/, }." "run lanai setup-host" "$details"; return 1 ;;
    snapshot)
      setup_reply false 3 "Before Windows first boots under Lanai, Lanai can take an instant snapshot of $dir, so a bad first boot can be undone." \
        "take one with lanai snapshot, or use lanai setup --no-snapshot"; return 1 ;;
    setup-wait)
      setup_reply true 5 "The setup boot is running. Open Lanai's setup drive and run setup.cmd." \
        "wait for Windows to shut down" "$(jq -nc --argjson w "$(boot_window && echo true || echo false)" '{active:true,window:$w}')" ;;
    wait) setup_wait "Windows is starting or shutting down." ;;
    checks) setup_step6 "$follow_step" ;;
    choices|problem)
      if [[ $reason == nostart && $step == 6 ]]; then systemctl --user reset-failed "$LANAI_UNIT" >/dev/null 2>&1 || true; fi
      # CLI and panel each have their own copy, keyed on the same reason.
      case $reason in
        settings) want="Lanai cannot read its settings file." ;;
        missing) want="No Windows install was found." ;;
        layout) want=$(sed -n 's/^LanaiProblem=//p' <<<"$facts") ;;
        restore) want="A restore did not finish." ;;
        share) want=$(jq -r .problem <<<"$plan") ;;
        container) want="A Docker VM is running or preparing to start (possibly omarchy-windows-vm). Stop it with omarchy-windows-vm stop first." ;;
        manager) want="Lanai cannot reach the systemd user manager." ;;
        active|no-media) want="Windows is running without Lanai's setup drive." ;;
        nostart) want="Windows did not start." ;;
        *) want="The setup boot did not finish with Windows shutting down by itself." ;;
      esac
      next="fix that, then run setup again"
      case $reason in
        active|no-media) next="shut Windows down, then run setup again" ;;
        nostart) next="see the logs with $LANAI_LOGS, then run setup again" ;;
      esac
      setup_reply false "$step" "$want" "$next" "$(jq -c '{reason,choices}' <<<"$plan")"
      return 1 ;;
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
