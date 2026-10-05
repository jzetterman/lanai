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

# settings [<memory GiB> <cores>]: preserve all other keys; apply next boot.
# The ranges and integer syntax are the same as vm_args in lib/vm.sh.
cmd_settings() {
  local f doc='{}' mem cores tmp
  f=$(settings_file)
  if [[ -L $f ]] || { [[ -e $f ]] && ! doc=$(jq -ce 'select(type == "object")' "$f"); }; then
    emit false "" "Lanai cannot read its settings file: $f." "repair that file, then try again"
    return 1
  fi
  if (($# == 0)); then
    read -r mem cores < <(vm_settings) || return 1
  elif (($# == 2)); then
    mem=$1 cores=$2
  else
    emit false "" "Settings need memory in GiB and cores." "use lanai settings <memory> <cores>"
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
    if ! mkdir -p -- "${f%/*}" || ! tmp=$(mktemp "$f.XXXXXX"); then return 1; fi
    if ! jq --argjson m "$mem" --argjson c "$cores" '. + {memory_gib:$m, cores:$c}' <<<"$doc" >"$tmp" ||
      ! mv -f -- "$tmp" "$f"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  emit true "" "VM settings apply at the next start." "" \
    "$(jq -nc --argjson m "$mem" --argjson c "$cores" '{memory_gib:$m, cores:$c}')"
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
    snapshot|restore) echo snapshots ;;
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

# Launch the worker in a session unit, independent of the shell/plugin lifetime.
cmd_ui_job() {
  local token=${1:-} command=${2:-} v s
  local -a env=()
  [[ $token =~ ^[A-Za-z0-9-]+$ && $command =~ ^(setup|snapshot|restore)$ ]] || {
    emit false "" "Invalid panel job." ""; return 2;
  }
  umask 077
  s=$(state_dir); mkdir -p -- "$s"
  for v in WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME; do
    [[ -z ${!v:-} ]] || env+=("--setenv=$v=${!v}")
  done
  if ! systemd-run --user --collect --quiet --unit="lanai-panel-$token" \
    --description="Lanai panel operation" --slice=session.slice --expand-environment=no \
    -p PartOf=graphical-session.target -p After=graphical-session.target \
    "${env[@]}" -- "$LANAI_BIN/lanai" ui-job-worker "$@" >>"$s/panel-job.log" 2>&1; then
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
# before releasing. Refused launches leave the owner's record and log untouched.
cmd_ui_job_worker() {
  local token=${1:-} command=${2:-} group args s fd out started inv at reply
  [[ $token =~ ^[A-Za-z0-9-]+$ && $command =~ ^(setup|snapshot|restore)$ ]] || {
    emit false "" "Invalid panel job." ""; return 2;
  }
  shift 2
  umask 077
  s=$(state_dir); mkdir -p -- "$s"
  exec {fd}>>"$s/panel-job.lock"
  if ! flock -w 1 "$fd"; then emit false "" "A panel job is already running." ""; return 1; fi
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
    # A direct settings save or notice dismissal briefly owns the operation
    # lock. Keep the last wait visible and retry the guarded follow-up.
    if [[ $command == setup && ${1:-} == --follow ]] &&
      jq -e '.ok == false and .reason == "busy"' <<<"$reply" >/dev/null; then
      ui_sleep 2
      continue
    fi
    out=$reply
    inv=$(unit_invocation) at=$(ui_now)
    panel_result_write "$group" "$(ui_record "$token" "$command" "$args" "$started" "$inv" "$out" null)"
    if [[ $command != setup ]] || ! jq -e '.ok == true and
      (.step == "5" or (.step == "6" and ((.questions // []) | length) == 0))' <<<"$out" >/dev/null; then break; fi
    ui_setup_next "$out" "$inv" "$at" || break
    set -- --follow "$(jq -r .step <<<"$out")" "$inv"
  done
  panel_result_write "$group" "$(ui_record "$token" "$command" "$args" "$started" "$inv" "$out" "$(ui_timestamp)")"
  exec {fd}>&-
  emit true "" "Panel job finished." ""
}
