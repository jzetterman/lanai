# Settings and detached panel jobs. Sourced by lib/lanai.sh.
# shellcheck shell=bash
# CLI entry points own shell options; sourcing must preserve the caller.

# notice-seen: acknowledge the forced-stop notice without touching run markers.
cmd_notice_seen() {
  local s tmp
  if (($#)); then
    emit false "" "This command takes no arguments." ""
    return 2
  fi
  umask 077
  if ! lanai_flock; then
    emit false "" "$LANAI_BUSY." "try again when it finishes" '{"reason":"busy"}'
    return 1
  fi
  s=$(state_dir)
  mkdir -p -- "$s"
  tmp=$(mktemp "$s/last-run.XXXXXX") || return 1
  if ! printf 'clean\n' >"$tmp" || ! mv -f -- "$tmp" "$s/last-run"; then
    rm -f -- "$tmp"
    return 1
  fi
  emit true "" "Notice dismissed." ""
}

# Print which scale task Windows has, from Lanai's setup record (spec 12):
# "new" when finished setup recorded the live task (scale_task 2), "old"
# for a finished setup without that mark, "none" before setup finishes or
# while a setup round runs without the mark (setup.cmd may be replacing the
# task).
scale_task_kind() {
  if ! setup_done; then echo none
  elif [[ $(setup_get scale_task) == 2 ]]; then echo new
  elif [[ $(setup_get round) == true ]]; then echo none
  else echo old; fi
}

# Succeed when Windows' scale task lacks the current sign-in step (spec 12):
# setup is done, no setup round runs (setup.cmd may be replacing the task),
# and the record's signin_step is not LANAI_SIGNIN_STEP (lib/setup.sh). The
# old task and the step's earlier forms lack it too.
signin_step_missing() {
  setup_done && [[ $(setup_get round) != true && $(setup_get signin_step) != "$LANAI_SIGNIN_STEP" ]]
}

# client_update_case <finished true|false> [<patches id>]: print which step
# brings the client up to date (spec 12). The id, when given, saves hashing
# the patches again. "none": the plan is not finished, the client
# is current, its stamp is not the pin's, or the guest's driver is behind
# (req 8's case). "update": the client was built without the current
# patches, and the live scale task has the sign-in step, so Update the
# Windows window is the one step, and Lanai runs it by itself
# (docs/plugin/client-auto-update/spec.md). "setup": the client is old and
# Run setup again is the one step. The panel view and Lanai's own update
# worker both decide from it.
client_update_case() {
  if [[ $1 != true ]] || ! build_stamp_current || build_patches_current "${2:-}" ||
    [[ -n $(guest_version_behind) ]]; then
    echo none
  elif [[ $(scale_task_kind) == new ]] && ! signin_step_missing; then
    echo update
  else
    echo setup
  fi
}

# --- Lanai's own client update (docs/plugin/client-auto-update/) ---
#
# The try record, <state>/client-auto.json, survives reboots:
#   {"patches":"<patches_id>","tries":[{"token":"auto-...","at":<time>,"outcome":null}]}
# One entry per counted try, at most two. outcome is null (no result yet),
# "ok", "failed" or "launch" (the launch could not start). Every write
# happens under panel-job.lock. Builds Lanai did not start by itself never
# touch it.

auto_record_file() { printf '%s\n' "$(state_dir)/client-auto.json"; }

# auto_record_read <patches id>: print the record for patch set <id>. A
# missing, unreadable or foreign record (another patch set) counts as an
# empty one, so a new patch set gets new tries.
auto_record_read() {
  jq -ce --arg p "$1" 'select(type == "object" and .patches == $p and
    (.tries | type == "array" and all(.[]; type == "object")))' "$(auto_record_file)" 2>/dev/null ||
    jq -nc --arg p "$1" '{patches:$p,tries:[]}'
}

# auto_record_write <doc>: replace the record with <doc> so that it survives
# a power loss: a temporary file, synced, moved into place, then the folder
# synced.
auto_record_write() {
  local f tmp
  f=$(auto_record_file)
  mkdir -p -- "${f%/*}" || return 1
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if ! printf '%s\n' "$1" >"$tmp" || ! sync -- "$tmp" || ! mv -f -- "$tmp" "$f" || ! sync -- "${f%/*}"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# auto_try_due <doc>: succeed while record <doc> allows a try: fewer than
# two entries, and none failed or could not launch.
auto_try_due() {
  jq -e '(.tries | length) < 2 and all(.tries[]; .outcome != "failed" and .outcome != "launch")' <<<"$1" >/dev/null
}

# auto_try_add <doc> <token> <outcome json>: print <doc> with one entry more.
auto_try_add() {
  jq -c --arg t "$2" --argjson at "$(ui_timestamp)" --argjson o "$3" '.tries += [{token:$t,at:$at,outcome:$o}]' <<<"$1"
}

# auto_outcome_set <token> <outcome>: set the outcome of try <token>, only
# while it has none, in whatever patch set the record holds.
auto_outcome_set() {
  local doc
  doc=$(jq -ce --arg t "$1" --arg o "$2" 'select(type == "object" and (.tries | type) == "array") |
    .tries |= map(if type == "object" and .token == $t and .outcome == null then .outcome = $o else . end)' \
    "$(auto_record_file)" 2>/dev/null) || return 1
  auto_record_write "$doc"
}

# Print the token of each automatic update unit (lanai-panel-auto-*) that
# runs, one per line. A unit that systemd is stopping still counts, so a
# logout's stop does not read as a finished stop before the unit is gone.
auto_units() {
  systemctl --user list-units --plain --no-legend --state=activating,active,reloading,deactivating \
    'lanai-panel-auto-*' 2>/dev/null |
    awk '$1 ~ /^lanai-panel-auto-[A-Za-z0-9-]+\.service$/ {
      u = $1; sub(/^lanai-panel-/, "", u); sub(/\.service$/, "", u); print u }' || true
}

# Succeed while a command-line snapshot or restore shows progress: its
# operation lock is held and its progress record is live.
auto_progress_active() {
  local s p
  s=$(state_dir)
  p=$(python3 "$LANAI_LIB/image-proof.py" activity "$s/lock" "$s/image-progress.json" 2>/dev/null) || return 1
  [[ -n $p && $p != null ]]
}

# auto_launch_failed <token>: systemd-run could not start the update's unit,
# so record a "launch" try, which ends the tries. Not while the session or
# the user manager stops (a logout or reboot): that refusal spends no try.
# The one write a launch makes. It waits for panel-job.lock with no time
# limit, which also waits out the view's read probe. A subshell, so the
# lock goes when it returns.
auto_launch_failed() (
  local fd manager id doc
  mkdir -p -- "$(state_dir)" || return 1
  exec {fd}>>"$(state_dir)/panel-job.lock" || return 1
  flock "$fd" || return 1
  systemctl --user is-active --quiet graphical-session.target >/dev/null 2>&1 || return 0
  # degraded exits 1 but still runs units.
  manager=$(systemctl --user is-system-running 2>/dev/null) || true
  [[ $manager == running || $manager == degraded ]] || return 0
  id=$(patches_id) || return 1
  doc=$(auto_record_read "$id")
  auto_try_due "$doc" || return 0
  auto_record_write "$(auto_try_add "$doc" "$1" '"launch"')"
)

# auto_step <name>: a no-op seam that auto_update_worker calls after it
# counts the try (counted), writes the client record (published), builds
# (built) and records the outcome (recorded). Tests override it.
auto_step() { :; }

# The worker's EXIT trap: after the try is counted, an exit with an error
# that no signal caused writes "failed", if the try has no outcome yet. A
# stop by a signal leaves the try without one. Then lanai_main's trap runs,
# so a worker that printed nothing still prints its JSON object.
auto_on_exit() {
  local rc=$1
  if [[ ${AUTO_COUNTED:-false} == true ]] && ((rc != 0 && ${AUTO_SIGNAL:-0} == 0)); then
    auto_outcome_set "$AUTO_TOKEN" failed || true
  fi
  lanai_on_exit "$rc"
}

# auto_update_worker <token>: Lanai's own update of the Windows window, in
# its unit lanai-panel-<token>.service (lanai ui-job <token> build-client
# --auto). It waits until no panel job, client build, or command-line
# snapshot or restore holds it back, holding no lock while it sleeps. Then
# it checks from fresh state that an update is due. If one is, its first
# act is to count the try in the record. Then it writes the panel's client
# record, builds, records the outcome and ends the client record. It takes
# panel-job.lock before build.lock, as every job does, and runs build_client
# itself under build.lock.
auto_update_worker() {
  local s fd bfd plan="" plan_ok=true id doc started inv rc=0 out reply
  AUTO_TOKEN=$1 AUTO_COUNTED=false AUTO_SIGNAL=0
  # Bash runs the trap when the running command ends; systemd signals the
  # build's processes too, so the trap runs before the outcome is written.
  trap 'AUTO_SIGNAL=1; exit 143' TERM INT HUP
  trap 'auto_on_exit $?' EXIT
  umask 077
  s=$(state_dir)
  mkdir -p -- "$s"
  exec {fd}>>"$s/panel-job.lock"
  exec {bfd}>>"$s/build.lock"
  # 1. Wait.
  while :; do
    if lock_held "$s/build.lock" || auto_progress_active; then
      ui_sleep 2
      continue
    fi
    flock "$fd"
    if ! flock -w 1 "$bfd"; then
      flock -u "$fd"
      ui_sleep 2
      continue
    fi
    if auto_progress_active; then
      flock -u "$bfd"
      flock -u "$fd"
      ui_sleep 2
      continue
    fi
    break
  done
  # 2. Check. A logout or reboot that queued this start spends nothing.
  if ! systemctl --user is-active --quiet graphical-session.target >/dev/null 2>&1; then
    emit true "" "No update is due: the desktop session is not active." ""
    return 0
  fi
  if ! plan=$(setup_plan "$(shared_facts)"); then plan_ok=false; fi
  if $plan_ok && [[ $(client_update_case "$(jq -r .finished <<<"$plan")") != update ]]; then
    emit true "" "No update is due." ""
    return 0
  fi
  id=$(patches_id)
  doc=$(auto_record_read "$id")
  if ! auto_try_due "$doc"; then
    emit true "" "No update is due: Lanai's tries for these patches are over." ""
    return 0
  fi
  # 3. Count. From here every error is in the Jobs log.
  auto_record_write "$(auto_try_add "$doc" "$AUTO_TOKEN" null)"
  AUTO_COUNTED=true
  : >"$s/panel-job.log"
  exec 2>>"$s/panel-job.log"
  if ! $plan_ok; then
    echo "Lanai could not read the setup plan" >&2
    exit 1
  fi
  auto_step counted
  # 4. The panel's client record, as for every panel job.
  started=$(ui_timestamp)
  inv=$(unit_invocation)
  panel_result_write client "$(ui_record "$AUTO_TOKEN" build-client '["--auto"]' "$started" "$inv" null null)"
  auto_step published
  # 5. Build, and turn the result into lanai build-client's reply.
  out=$(build_client) || rc=$?
  reply=$(build_client_emit "$rc" "$out") || true
  auto_step built
  # 6. The outcome.
  if ((rc == 0)); then auto_outcome_set "$AUTO_TOKEN" ok; else auto_outcome_set "$AUTO_TOKEN" failed; fi
  auto_step recorded
  # 7. End the client record, then release.
  panel_result_write client "$(ui_record "$AUTO_TOKEN" build-client '["--auto"]' "$started" "$inv" "$reply" "$(ui_timestamp)")"
  exec {bfd}>&- {fd}>&-
  emit true "" "Panel job finished." ""
}

# settings [<memory GiB> <cores> [<Windows scale>]]: show or save settings.
# Two-argument saves keep the scale, its save number and unrelated keys.
# Three-argument saves are scale saves: they also count the save number up
# (spec 27), even for an unchanged step, so the scale task drops a pick.
# A save's reply carries scale_saved, running and scale_task_kind. A scale
# save's message is the panel's words for them (panel_words); a memory and
# cores save says when those apply, where the panel says only "Saved.".
cmd_settings() {
  local f doc='{}' mem cores scale save tmp reply message running=false
  f=$(settings_file)
  if [[ -L $f ]] || { [[ -e $f ]] && ! doc=$(jq -ce 'select(type == "object")' "$f"); }; then
    emit false "" "Lanai cannot read its settings file: $f." "repair that file, then try again"
    return 1
  fi
  if ! save=$(scale_save_value "$doc"); then
    emit false "" "Lanai cannot read the Windows scale save number in its settings file." "repair that file, then try again"
    return 1
  fi
  if (($# == 0)); then
    read -r mem cores < <(vm_settings) || return 1
  elif (($# == 2 || $# == 3)); then
    mem=$1 cores=$2
  else
    emit false "" "Settings need memory in GiB, cores and optionally Windows scale." "use lanai settings <memory> <cores> [auto|scale]"
    return 2
  fi
  if [[ ! $mem =~ ^[1-9][0-9]{0,2}$ ]] || ((mem > 512)); then
    emit false "" "Memory must be a whole number of GiB from 1 to 512." "choose a valid memory size"
    return 2
  fi
  if [[ ! $cores =~ ^[1-9][0-9]?$ ]] || ((cores > 64)); then
    emit false "" "Cores must be a whole number from 1 to 64." "choose a valid core count"
    return 2
  fi
  if (($# == 3)); then
    scale=$3
    if [[ $scale != auto && ! ( $scale =~ ^[1-9][0-9]{2}$ && $LANAI_SCALE_STEPS == *" $scale "* ) ]]; then
      emit false "" "Windows scale must be auto or a Windows scale step." "choose Match my monitor or a listed percentage"
      return 2
    fi
  elif ! scale=$(windows_scale_value "$doc"); then
    emit false "" "Lanai cannot read Windows scale in its settings file." "set auto or a valid Windows scale step"
    return 1
  fi
  if (($#)); then
    if ! lanai_flock; then
      emit false "" "$LANAI_BUSY." "try again when it finishes" '{"reason":"busy"}'
      return 1
    fi
    # Read again under the operation lock: setup may have seeded settings.
    if [[ -L $f ]] || { [[ -e $f ]] && ! doc=$(jq -ce 'select(type == "object")' "$f"); }; then
      emit false "" "Lanai cannot read its settings file: $f." "repair that file"
      return 1
    fi
    if (($# == 2)) && ! scale=$(windows_scale_value "$doc"); then
      emit false "" "Lanai cannot read Windows scale in its settings file." "set auto or a valid Windows scale step"
      return 1
    fi
    if ! save=$(scale_save_value "$doc"); then
      emit false "" "Lanai cannot read the Windows scale save number in its settings file." "repair that file, then try again"
      return 1
    fi
    # Below 10^9 (spec 27); the guest treats any change as a save, so the
    # wrap after a billion saves still counts as one.
    (($# == 2)) || save=$(((save + 1) % 1000000000))
    if ! mkdir -p -- "${f%/*}" || ! tmp=$(mktemp "$f.XXXXXX"); then return 1; fi
    if ! jq --argjson m "$mem" --argjson c "$cores" --argjson w "$(scale_json "$scale")" --argjson n "$save" \
      '. + {memory_gib:$m, cores:$c, windows_scale:$w, scale_save:$n}' <<<"$doc" >"$tmp" ||
      ! mv -f -- "$tmp" "$f"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  reply=$(jq -nc --argjson m "$mem" --argjson c "$cores" --argjson w "$(scale_json "$scale")" \
    '{memory_gib:$m, cores:$c, windows_scale:$w}')
  if (($#)); then
    [[ $(unit_state 2>/dev/null) != active ]] || running=true
    reply=$(jq -c --argjson s "$([[ $# == 3 ]] && echo true || echo false)" --argjson r "$running" \
      --arg t "$(scale_task_kind)" '. + {scale_saved:$s, running:$r, scale_task_kind:$t}' <<<"$reply")
    if (($# == 3)); then
      message=$(panel_words settings "$(jq -c '. + {ok:true}' <<<"$reply")")
      # The CLI has no standing note under the scale list: add it.
      [[ $(jq -r .scale_task_kind <<<"$reply") != old ]] || message+=" $(old_task_note "$running")"
      emit true "" "$message" "" "$reply"
    else
      emit true "" "Saved. Memory and cores apply the next time Windows starts." "" "$reply"
    fi
  else
    # Suggested sizing stays editable, but is not a saved panel baseline.
    reply=$(jq -c --argjson d "$doc" '. + {baseline:(if $d.memory_gib != null and $d.cores != null then
      {memory_gib,cores,windows_scale} else null end)}' <<<"$reply")
    emit true "" "Memory and cores apply the next time Windows starts." "" "$reply"
  fi
}

# Atomic result per group; no temporary file is shared between callers.
panel_result_write() {
  local f tmp
  f=$(state_dir)/panel-result-$1.json
  mkdir -p -- "${f%/*}" || return 1
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if ! printf '%s\n' "$2" >"$tmp" || ! mv -f -- "$tmp" "$f"; then
    rm -f -- "$tmp"; return 1
  fi
}

# Map only the commands the panel offers to their result group.
panel_group() {
  case $1 in
    start|open|stop|force-stop|notice-seen) echo vm ;;
    setup|setup-host) echo setup ;;
    settings) echo settings ;;
    snapshot|restore|delete-snapshot) echo snapshots ;;
    build-client) echo client ;;
    *) return 1 ;;
  esac
}

# Small clock seams let fixtures check cadence without waiting ten seconds.
ui_timestamp() { local LC_ALL=C; printf '%s\n' "$EPOCHREALTIME"; }
ui_now() { printf '%s\n' "$EPOCHSECONDS"; }
ui_sleep() { sleep "$1"; }
unit_invocation() { systemctl --user show -p InvocationID --value "$LANAI_UNIT" 2>/dev/null || true; }

# Run a literal command and validate its one JSON reply, logging only stderr.
ui_call() {
  local log=$1 out rc=0
  shift
  out=$("$LANAI_BIN/lanai" "$@" 2>>"$log") || rc=$?
  if ! jq -se 'length == 1 and (.[0] | type == "object" and (.ok | type == "boolean"))' <<<"$out" >/dev/null 2>&1; then
    out=$(jq -nc --argjson rc "$rc" '{ok:false,reason:"invalid-reply",exit:$rc}')
  fi
  printf '%s\n' "$out"
}

# Emit the record with the launch arguments; follow-ups carry only their guard.
ui_record() {
  local token=$1 command=$2 args=$3 started=$4 invocation=$5 reply=$6 ended=$7
  jq -nc --arg t "$token" --arg c "$command" --argjson a "$args" --argjson s "$started" \
    --arg i "$invocation" --argjson r "$reply" --argjson e "$ended" \
    '{token:$t,command:$c,args:$a,invocation:$i,started:$s} +
     (if $r == null then {} else {reply:$r} end) + (if $e == null then {} else {ended:$e} end)'
}

# ui-run has no deadline. Its record uses the invocation at command completion.
cmd_ui_run() {
  local token=${1:-} command=${2:-} group args started out s
  [[ $token =~ ^[A-Za-z0-9-]+$ && $command =~ ^(start|open|stop|force-stop|notice-seen|settings|setup-host)$ ]] || {
    emit false "" "Invalid panel command." ""; return 2;
  }
  shift 2
  group=$(panel_group "$command") args=$(jq -nc '$ARGS.positional' --args -- "$@") started=$(ui_timestamp)
  umask 077
  s=$(state_dir); mkdir -p -- "$s"
  : >"$s/panel-run.log"
  out=$(ui_call "$s/panel-run.log" "$command" "$@")
  panel_result_write "$group" "$(ui_record "$token" "$command" "$args" "$started" "$(unit_invocation)" "$out" "$(ui_timestamp)")"
  jq -c --arg c "$command" '. + {panel_requested: (($c == "start" or $c == "open") and (.ok == false or .last_run == "forced"))}' <<<"$out"
  # shellcheck disable=SC2034
  LANAI_EMITTED=1
}

# ui_job_auto <token> <command> [<arg>...]: print true for Lanai's own
# update (build-client --auto, with an auto- token), false for any other
# panel job, and fail for any other mix: build-client takes no argument or
# exactly --auto, and the auto- prefix goes with --auto only. The prefix
# names the unit lanai-panel-auto-*, which the view finds (auto_units).
ui_job_auto() {
  local token=$1 command=$2 auto=false
  shift 2
  if [[ $command == build-client ]]; then
    case $# in
      0) ;;
      1) [[ $1 == --auto ]] || return 1; auto=true ;;
      *) return 1 ;;
    esac
  fi
  if [[ $token == auto-* ]]; then [[ $auto == true ]] || return 1
  else [[ $auto == false ]] || return 1; fi
  echo "$auto"
}

# Launch the worker in a session unit, independent of the shell/plugin
# lifetime. --service-type=exec makes systemd-run fail when the worker
# cannot be executed (the default type reports success right after the
# fork). A client build (the button, or Lanai's own update with --auto)
# yields to the VM and the Windows window: it gets CPU only when they leave
# some (CPUWeight=idle), the kernel's OOM killer picks it first
# (OOMScoreAdjust=1000), and a killed compiler fails the build without
# stopping the unit (OOMPolicy=continue), so the worker records the failure.
# For --auto, a failed systemd-run records a "launch" try.
cmd_ui_job() {
  local token=${1:-} command=${2:-} v s auto
  local -a env=() props=(--service-type=exec)
  if [[ ! $token =~ ^[A-Za-z0-9-]+$ || ! $command =~ ^(setup|snapshot|restore|delete-snapshot|build-client)$ ]] ||
    ! auto=$(ui_job_auto "$@"); then
    emit false "" "Invalid panel job." ""; return 2
  fi
  [[ $command != build-client ]] || props+=(-p CPUWeight=idle -p OOMScoreAdjust=1000 -p OOMPolicy=continue)
  umask 077
  s=$(state_dir); mkdir -p -- "$s"
  # The session's display and Hyprland instance: setup's boot_vm records
  # them for QEMU's window and the scale feed (the user manager may lack them).
  for v in WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME; do
    [[ -z ${!v:-} ]] || env+=("--setenv=$v=${!v}")
  done
  if ! systemd-run --user --collect --quiet --unit="lanai-panel-$token" \
    --description="Lanai panel operation" --slice=session.slice --expand-environment=no "${props[@]}" \
    -p PartOf=graphical-session.target -p After=graphical-session.target \
    "${env[@]}" -- "$LANAI_BIN/lanai" ui-job-worker "$@" >>"$s/panel-job.log" 2>&1; then
    [[ $auto != true ]] || auto_launch_failed "$token" || true
    emit false "" "Lanai could not start the panel job." "see the panel job log"; return 1
  fi
  emit true "" "Panel job launched." ""
}

# Wait only for this reply's expected next state; all checks are two seconds apart.
# A clean step 5 completion and step 6 retries both retain ten-second spacing.
ui_setup_next() {
  local reply=$1 invocation=$2 at=$3 st verdict requested="" s
  s=$(state_dir)
  while :; do
    ui_sleep 2
    systemctl --user is-active --quiet graphical-session.target || return 1
    st=$(unit_state) || return 1
    case $(jq -r .step <<<"$reply") in
      5)
        case $st in
          inactive|failed)
            verdict=$(run_verdict)
            jq -e --arg i "$invocation" '.completes_step5 and .invocation == $i' <<<"$verdict" >/dev/null || return 1
            (( $(ui_now) - at < 10 )) || return 0 ;;
          active|activating|reloading|deactivating)
            [[ $(unit_invocation) == "$invocation" ]] || return 1 ;;
          *) return 1 ;;
        esac ;;
      6)
        [[ $st == active || $st == activating || $st == reloading ]] || return 1
        [[ $(unit_invocation) == "$invocation" ]] || return 1
        requested=""
        [[ ! -f $s/stop-requested ]] || read -r requested _ <"$s/stop-requested" || true
        [[ $requested != "$invocation" ]] || return 1
        (( $(ui_now) - at < 10 )) || return 0 ;;
      *) return 1 ;;
    esac
  done
}

# Internal worker: publish started after locking, then following, then ended
# before releasing. Refused launches leave the owner's record untouched and append
# their reason to the job log, so a pending launch failure has a diagnostic.
# build-client --auto (an auto- token) is Lanai's own update instead
# (auto_update_worker), with the same token and argument rules as cmd_ui_job.
cmd_ui_job_worker() {
  local token=${1:-} command=${2:-} group args s fd out started inv at reply auto
  if [[ ! $token =~ ^[A-Za-z0-9-]+$ || ! $command =~ ^(setup|snapshot|restore|delete-snapshot|build-client)$ ]] ||
    ! auto=$(ui_job_auto "$@"); then
    emit false "" "Invalid panel job." ""; return 2
  fi
  if [[ $auto == true ]]; then
    auto_update_worker "$token"
    return
  fi
  shift 2
  umask 077
  s=$(state_dir); mkdir -p -- "$s"
  exec {fd}>>"$s/panel-job.lock"
  if ! flock -w 1 "$fd"; then
    printf '%s\n' "A panel job is already running." >>"$s/panel-job.log"
    emit false "" "A panel job is already running." ""
    return 1
  fi
  group=$(panel_group "$command") args=$(jq -nc '$ARGS.positional' --args -- "$@") started=$(ui_timestamp)
  inv=$(unit_invocation)
  panel_result_write "$group" "$(ui_record "$token" "$command" "$args" "$started" "$inv" null null)"
  : >"$s/panel-job.log"
  while :; do
    # Lingering keeps the user manager alive after logout. Never let an old
    # setup worker enter a call that could boot Windows outside its session.
    if [[ $command == setup ]] && ! systemctl --user is-active --quiet graphical-session.target; then
      out=${out:-'{"ok":false,"reason":"session"}'}
      break
    fi
    reply=$(ui_call "$s/panel-job.log" "$command" "$@")
    # Retry only setup_resume's lock refusal before it consumes run markers.
    # A later boot lock refusal ends following and leaves Continue setup visible.
    if [[ $command == setup && ${1:-} == --follow ]] &&
      jq -e '.ok == false and .reason == "busy" and .follow_retry == true' <<<"$reply" >/dev/null; then
      ui_sleep 2
      continue
    fi
    out=$reply
    inv=$(unit_invocation) at=$(ui_now)
    panel_result_write "$group" "$(ui_record "$token" "$command" "$args" "$started" "$inv" "$out" null)"
    if [[ $command != setup ]] || ! jq -e '.ok == true and (.step == "5" or .step == "6")' <<<"$out" >/dev/null; then break; fi
    ui_setup_next "$out" "$inv" "$at" || break
    set -- --follow "$(jq -r .step <<<"$out")" "$inv"
  done
  panel_result_write "$group" "$(ui_record "$token" "$command" "$args" "$started" "$inv" "$out" "$(ui_timestamp)")"
  exec {fd}>&-
  emit true "" "Panel job finished." ""
}
