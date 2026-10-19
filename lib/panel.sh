# The panel's read-only view and copy table. No setup reply file is consulted.
# shellcheck shell=bash

# old_task_note <running true|false> [<button>]: print the standing note for
# an install whose scale task is from before live scale (scale_task_kind
# old). <button> is the setup button that shows (default Run setup again).
old_task_note() {
  local how="click"
  [[ $1 != true ]] || how="shut Windows down and click"
  printf 'Scale saves apply the next time Windows starts. To make them apply while Windows runs, %s %s.\n' "$how" "${2:-Run setup again}"
}

# Reply words depend on command, ok, step and structured details/reasons.
# The optional current plan step selects visible snapshot-choice retry controls
# and a failed client build's words: step 7 (Run setup again) updates the
# Windows window, any other step prepares it (Continue setup).
# Offers and waits belong to the durable view and therefore have no result text.
# A settings save's words come from its scale_saved, running and scale_task_kind
# fields; for a scale save, cmd_settings prints the same words (plus
# old_task_note for the old task, which the panel shows under the scale list).
panel_words() {
  jq -r --arg c "$1" --arg step "${3:-}" '
    def log: {setup:"setup log",snapshot:"snapshot log",restore:"restore log","build-client":"update log"}[$c] // "button actions log";
    def oldtask: " Until you run setup again, the old scale task undoes scales you pick in Windows," +
      " and \u201cMatch my monitor\u201d does not follow the window. Running setup again also turns the Windows lock off again.";
    # Every step 6 time-out ends with both ways on (spec 7): Continue setup,
    # or a display button once Windows is off, which also covers a setup.cmd
    # that stopped. These words show under the buttons, so they name them.
    def tail: " Click Continue setup to check again. To install Lanai\u0027s parts in Windows again, shut" +
      " Windows down, then click Set up in a basic window or Set up in the Windows window. Do this" +
      " too if setup.cmd stopped with a message in Windows.";
    # An agents time-out names its parts, from a fixed list only.
    def parts: [(.parts // [] | if type == "array" then .[] else empty end) |
      select(. == "the SPICE agent" or . == "the QEMU guest agent")] |
      if length == 0 then "the Windows agents" else join(" and ") end;
    def reasons: {
      busy:"Lanai is busy with another task. Try again in a moment.",
      session:"Lanai can run setup only while you are signed in to the desktop.",
      settings:"Lanai could not read its settings. Check the settings file.",
      missing:"No Windows install was found. Install Windows with Omarchy, then continue setup.",
      layout:"The Windows install is not supported or is incomplete. Check the install before continuing.",
      restore:"A restore did not finish. Finish the unfinished restore or restore another snapshot before starting Windows.",
      share:"Lanai needs a folder named Windows in your home folder. It must be a real folder you own, not a link. Create or fix it, then continue setup.",
      container:"Windows is in use by another VM. Stop it before continuing here.",
      manager:"Lanai cannot reach your session services. Check the " + log + " and try again.",
      active:"Shut Windows down before continuing setup.",
      record:"Lanai could not save its setup progress. Check the setup log and try again.",
      "no-media":"Shut Windows down, then continue setup to attach the setup drive.",
      nostart:"Windows did not start. Check the Windows VM log before trying again.",
      incomplete:"The setup boot did not finish. Choose a display below and run setup.cmd again.",
      qmp:("Lanai could not reach Windows\u0027 virtual machine to check it." + tail),
      "guest-boot":("Windows did not finish starting, or its guest agent did not start." + tail),
      "window-closed":("The Windows window did not stay open long enough to check the display driver." + tail),
      "idd-missing":("The display driver in Windows did not answer." + tail),
      "scale-task":("The display scale task in Windows did not start. If Windows is at its sign-in screen, or" +
        " another user is signed in, sign in as the Windows user who ran setup." + tail +
        " If the task still does not start, see lanai-signin.log and lanai-scale.log in C:\\Program Files\\Lanai."),
      mismatch:"The display driver in Windows needs an update. Shut Windows down, then click Continue setup to set up Windows again.",
      allowlist:"The QEMU guest agent in Windows is missing its allow-list. Shut Windows down, then click Continue setup to set up Windows again.",
      client:"The Windows window could not open. Check the Windows window log and try again.",
      "build-busy":"Another build of the Windows window is running. Try again when it finishes.",
      "restore-unsupported":"The restore was refused because Lanai cannot verify an instant copy in this storage location. Choose storage that supports verified instant copies, then try again.",
      "snapshot-unsupported":"This filesystem cannot make an instant snapshot. Make a backup before continuing without a snapshot.",
      "invalid-reply":"Lanai did not give a readable reply. Check the " + log + " and try again."
    };
    if .ok == false then
      if $c == "setup" and (.step == null or .step == "3") and .reason == "record" then
        "Lanai could not save the snapshot choice. Check that your home folder has free space, then click " +
        (if $step == "3" or ($step == "" and .step == "3") then
          "Continue without a snapshot or take a snapshot again."
        else "Continue setup." end)
      elif .reason == "agents" then "In Windows, " + parts + " did not answer." + tail
      elif .reason and (reasons[.reason] != null) then reasons[.reason]
      elif $c == "setup" and .step == "4" then
        (if $step == "7" then "Setup could not update the Windows window. Check the Windows window build log, then click Run setup again in More actions."
        else "Setup could not prepare the Windows window. Check the Windows window build log, then click Continue setup." end)
      elif $c == "setup" and .step == "2" and .missing then ""
      elif $c == "setup" and .step == "3" and .reason == null then ""
      else ({start:"Windows could not start. Check the button actions log and the Windows VM log and try again.",
        open:"The Windows window could not open. Check the Windows window log and try again.",
        stop:"Windows could not be asked to shut down. Check the button actions log and try again.",
        "force-stop":"Windows could not be force-stopped. Check the button actions log and try again.",
        "notice-seen":"The notice could not be dismissed. Try again.",
        settings:"Settings could not be saved. Use whole numbers from 1 to 512 for memory and 1 to 64 for cores, and choose a listed Windows scale, then try again.",
        "setup-host":"The installation terminal could not open. Check the button actions log and try again.",
        setup:"Setup could not finish. Check the setup log, then continue setup.",
        snapshot:"Lanai could not take the snapshot. Check the snapshot log and try again.",
        restore:"Lanai could not restore the snapshot. Check the restore log before trying again.",
        "build-client":"The Windows window could not be updated. Check the Windows window build log (build-client.log), then try again."}[$c] //
        "The operation could not finish. Check the " + log + " and try again.") end
    elif $c == "snapshot" and .snapshot then
      "Snapshot saved at " + .snapshot + ". It shares disk space at first and grows as Windows changes. To delete it, remove that folder in your file manager."
    elif $c == "restore" then "The snapshot was restored."
    elif $c == "build-client" then "The Windows window is updated. If the Windows window is open, close it and open it again."
    elif $c == "settings" and (.scale_saved | type) == "boolean" then
      if .scale_saved | not then "Saved."
      elif .scale_task_kind == "new" and .running == true then
        "Saved. Windows uses the saved scale within 5 seconds if you\u0027re signed in, or when you next sign in."
      elif .scale_task_kind == "old" and .running == true then "Saved. Windows uses the saved scale the next time it starts." + oldtask
      elif .scale_task_kind == "old" then "Saved. Changes apply the next time Windows starts." + oldtask
      else "Saved. Changes apply the next time Windows starts." end
    elif $c == "start" and .network == false then "Windows started without a network. Connect Linux to a network, then shut down and start Windows again."
    else "" end' <<<"$2"
}

# Read group records only after probing the worker lock. The probe writes nothing
# and remains held for all reads, so launch/end cannot race the final-state read.
panel_records() {
  local s fd held=false group doc records='{}'
  s=$(state_dir)
  if [[ -f $s/panel-job.lock ]]; then
    exec {fd}<"$s/panel-job.lock"
    if ! flock -s -n "$fd"; then held=true; fi
  fi
  for group in vm setup settings snapshots client; do
    doc=$(jq -ce 'select(type == "object")' "$s/panel-result-$group.json" 2>/dev/null) || doc=null
    records=$(jq -nc --arg g "$group" --argjson d "$doc" --argjson r "$records" '$r + {($g):$d}')
  done
  [[ -z ${fd:-} ]] || exec {fd}>&-
  jq -nc --argjson r "$records" --argjson h "$held" '{held:$h,records:$r}'
}

# Keep the UTC folder name as the identity, even when it is not a real date.
panel_snapshot_item() {
  local name=$1 formatted='' date='' time='' label=$1
  if [[ $name =~ $LANAI_SNAP_RE ]]; then
    formatted=$(LC_ALL=C date -u -d "${name:0:4}-${name:4:2}-${name:6:2} ${name:9:2}:${name:11:2}:${name:13:2} UTC" \
      '+%Y%m%dT%H%M%SZ|%b %-d, %Y|%H:%M UTC' 2>/dev/null) || formatted=''
    if [[ ${formatted%%|*} == "$name" ]]; then
      formatted=${formatted#*|}
      date=${formatted%%|*} time=${formatted#*|}
      label="$date at $time"
    fi
  fi
  jq -nc --arg n "$name" --arg d "$date" --arg t "$time" --arg l "$label" \
    '{name:$n,date:(if $d == "" then null else $d end),time:(if $t == "" then null else $t end),
      label:$l,restore_label:("Restore " + $l),confirm_label:("Restore " + $l + " and replace Windows"),
      warning:"Replaces Windows. Changes since this snapshot are lost."}'
}

# Resolve display identity only against this read's validated snapshot list.
# Progress wins over an active job; a marker also covers interrupted CLI work.
panel_restore() {
  local progress=$1 records=$2 paths=$3 items=$4 storage=$5 marker=$6
  local job active=false pending=false name='' target='' snap='' source='' item=null use_marker=true
  [[ ! -e $marker ]] || pending=true
  job=$(jq -c 'if .held then [.records[] | select(. != null and has("started") and (has("ended")|not))] |
    max_by(.started) // {} else {} end' <<<"$records")
  if [[ $(jq -r '.operation' <<<"$progress") == restore || $(jq -r .command <<<"$job") == restore ]]; then
    active=true
    target=$(jq -r '.target // ""' <<<"$progress")
    if [[ $target =~ $LANAI_SNAP_RE ]] && jq -e --arg n "$target" 'any(.[]; .name == $n)' <<<"$items" >/dev/null; then
      name=$target
    elif [[ $(jq -r .command <<<"$job") == restore ]]; then
      target=$(jq -r '.args[0] // ""' <<<"$job")
      if [[ -n $target ]]; then
        use_marker=false
        if [[ $target =~ $LANAI_SNAP_RE ]] && jq -e --arg n "$target" 'any(.[]; .name == $n)' <<<"$items" >/dev/null; then
          name=$target
        fi
      fi
    fi
  fi
  if [[ -z $name && $use_marker == true && -f $marker ]]; then
    if { IFS= read -r snap && IFS= read -r source; } <"$marker" && [[ -n $storage && $source == "$storage" ]] &&
      jq -e --arg p "$snap" 'index($p) != null' <<<"$paths" >/dev/null; then
      name=${snap##*/}
    fi
  fi
  [[ -z $name ]] || item=$(jq -c --arg n "$name" '.[] | select(.name == $n)' <<<"$items")
  jq -nc --argjson a "$active" --argjson p "$pending" --argjson i "$item" \
    '{pending:$p,name:($i.name // null),label:(if $a then
        (if $i == null then "Restoring Windows" else "Restoring " + $i.label end)
      elif $p then (if $i == null then "Unfinished restore" else "Unfinished restore of " + $i.label end)
      else "" end),warning:(if $a or $p then "Keep Windows stopped until the restore finishes." else "" end)}'
}

# One view: gather once, status makes its one bounded QMP session, and setup plans
# from the same host facts. Settings/list errors are data, never swallowed results.
cmd_panel() {
  local client_running=false setup_boot=false checks_boot=false basic_window=false stop_requested=false stop_inv stop_at
  local token='' at=0 facts status_details status plan records settings snapshots logs s run inv progress problem_line results='{}' group doc words note active
  local client_old=false signin_missing=false update_shown=false task started=0 booted button
  local snapshot_paths='[]' items='[]' name restore log_rows path display label
  local check_since=null checks_stopped=false since vm_status
  if (($#)); then
    if [[ $# != 3 || $1 != --pending || ! $2 =~ ^[A-Za-z0-9-]+$ || ! $3 =~ ^[0-9]+$ ]]; then
      emit false "" "Invalid panel input." ""; return 2
    fi
    token=$2 at=$3
  fi
  progress=$(python3 "$LANAI_LIB/image-proof.py" activity "$(state_dir)/lock" "$(state_dir)/image-progress.json")
  facts=$(shared_facts "$progress")
  status_details=$(status_facts "$facts")
  status=$(status_map <<<"$status_details")
  # Reuse the gathered facts without setup masking the VM's runtime state.
  vm_status=$(status_map <<<"$status_details"$'\nLanaiSetup=done')
  plan=$(setup_plan "$facts")
  records=$(panel_records)
  problem_line=''
  if [[ $(jq -r .reason <<<"$plan") != '' ]]; then
    problem_line=$(panel_words setup "$(jq -c '. + {ok:false}' <<<"$plan")")
  fi
  s=$(state_dir); run=$(run_dir 2>/dev/null) || run=''
  if [[ -n $run ]]; then
    [[ ! -e $run/step6-stopped ]] || checks_stopped=true
    if [[ -s $run/step6-since ]]; then
      since=$(<"$run/step6-since")
      if step6_positive "$since" && ((since <= EPOCHSECONDS)); then check_since=$since; fi
    fi
  fi
  # Boot flags also cover activation, before status reports a window.
  if jq -e '.active' <<<"$status" >/dev/null; then
    jq -e '.setup == true' "$s/boot.json" >/dev/null 2>&1 && setup_boot=true
    if jq -e '.step6 == true' "$s/boot.json" >/dev/null 2>&1 &&
      [[ $(setup_get round) == true ]]; then checks_boot=true; fi
    boot_window && basic_window=true
    if jq -e '.finished == false' <<<"$plan" >/dev/null && ! $basic_window; then
      client_active && client_running=true
    fi
  fi
  inv=$(sed -n 's/^InvocationID=//p' <<<"$facts")
  if [[ -n $inv && -f $s/stop-requested ]] && read -r stop_inv stop_at <"$s/stop-requested" &&
    [[ $stop_inv == "$inv" && $stop_at =~ ^[0-9]+$ ]]; then stop_requested=true; fi
  # A finished install whose client is the pinned build without Lanai's
  # current patches (req 12): it keeps working, and the panel names the one
  # step that brings the resize fix. An older pin's build in use is req 8's
  # driver update instead, so it never counts here.
  if jq -e '.finished' <<<"$plan" >/dev/null && build_stamp_current && ! build_patches_current &&
    [[ -z $(guest_version_behind) ]]; then client_old=true; fi
  # A finished install whose scale task lacks the sign-in step (req 12):
  # Run setup again is then the one step, also for an old client or the
  # old task. An unfinished plan (req 8's driver update included) already
  # names its own step.
  if jq -e '.finished' <<<"$plan" >/dev/null && signin_step_missing; then signin_missing=true; fi
  task=$(scale_task_kind)
  # The update button shows for an old client only with the live scale
  # task and the sign-in step; else Run setup again is the one step.
  if $client_old && [[ $task == new ]] && ! $signin_missing; then update_shown=true; fi
  # When the current client started (client.log's first line), or 0.
  [[ -z $run || ! -s $run/client.log ]] || started=$(log_client_start "$run/client.log")
  # When the host booted, or 0. A reboot empties the runtime folder, and
  # client.log with it.
  booted=$(sed -n 's/^btime //p' "${LANAI_PROC:-/proc}/stat" 2>/dev/null) || booted=0
  [[ $booted =~ ^[0-9]+$ ]] || booted=0
  for group in vm setup settings snapshots client; do
    doc=$(jq -c --arg g "$group" '.records[$g] // {}' <<<"$records")
    words=''
    if jq -e 'has("reply")' <<<"$doc" >/dev/null; then
      # A settings save's words hold only for the VM run they were about: a
      # live save's words also go once the unit stops (a failed unit keeps
      # its InvocationID).
      if [[ $group == settings ]] && jq -e --arg i "$inv" --argjson a "$(jq '.active' <<<"$status")" \
        '.reply.ok == true and (.invocation != $i or (.reply.running == true and ($a | not)))' <<<"$doc" >/dev/null; then
        :
      elif [[ $(jq -r '.command' <<<"$doc") != start ]] ||
        [[ $(jq -r '.reply.ok' <<<"$doc") == false ]] ||
        { [[ $(jq -r '.active' <<<"$status") == true && $(jq -r '.invocation' <<<"$doc") == "$inv" ]]; }; then
        words=$(panel_words "$(jq -r '.command' <<<"$doc")" "$(jq -c .reply <<<"$doc")" "$(jq -r .step <<<"$plan")")
      fi
    fi
    # A failed reply about another step is over, and one with the plan's
    # reason repeats the problem line. One exception: a client build that
    # failed in Run setup again (the panel passes --window or --no-window).
    # The plan is then finished (step 7), and the failure holds while the
    # client is still old and the update button is hidden; with the button,
    # the resize warning names the one step.
    if [[ $group == setup ]] && jq -e --argjson p "$plan" --argjson old "$client_old" --argjson shown "$update_shown" '
      .reply.ok == false and
      ((.reply.step != null and .reply.step != $p.step and
        ((.reply.step == "4" and $p.finished and $old and ($shown | not) and
          any(.args[]?; . == "--window" or . == "--no-window")) | not)) or
       (.reply.reason != null and .reply.reason == $p.reason))' <<<"$doc" >/dev/null; then
      words=''
    fi
    if jq -e '.held == false' <<<"$records" >/dev/null &&
      jq -e 'has("started") and (has("ended") | not)' <<<"$doc" >/dev/null; then
      case $(jq -r .command <<<"$doc") in
        snapshot) words="The snapshot did not finish. Try again." ;;
        restore) words="The restore did not finish. Finish the unfinished restore or restore another snapshot before starting Windows." ;;
        build-client) words="The update did not finish. Click Update the Windows window in More actions again." ;;
        # Run setup again's step 4 build runs while the plan is finished.
        *) if jq -e '.finished' <<<"$plan" >/dev/null; then
          words="Setup was interrupted. Click Run setup again in More actions to try again."
        else words="Setup was interrupted. Continue setup to try again."; fi ;;
      esac
    fi
    # An update's done words hold until a client starts after the job
    # ended (the next lanai open runs the new binary), until a reboot
    # after it, or until the client is old again. Its failed and
    # interrupted words name the update button, so they hold only while
    # that button shows.
    if [[ $group == client ]]; then
      if jq -e '.reply.ok == true' <<<"$doc" >/dev/null; then
        if $client_old || jq -e --argjson c "$started" --argjson b "$booted" '$c > .ended or $b > .ended' <<<"$doc" >/dev/null; then
          words=''
        fi
      elif ! $update_shown; then words=''; fi
    fi
    results=$(jq -nc --argjson r "$results" --arg g "$group" --arg w "$words" '$r + {($g):$w}')
  done
  if settings=$(cmd_settings 2>/dev/null) && jq -e '.ok' <<<"$settings" >/dev/null; then
    # The note near the scale list: with the live scale task, while Windows
    # runs, that a scale save replaces a pick; with the old task, how to
    # make scale saves apply while Windows runs, unless the resize warning
    # already says it (the panel names Run setup again once). An unfinished
    # plan (req 8's driver update) shows Continue setup instead.
    note='' active=false button='Run setup again in More actions'
    ! jq -e '.active' <<<"$status" >/dev/null || active=true
    jq -e '.finished' <<<"$plan" >/dev/null || button='Continue setup'
    case $task in
      new) ! $active || note='Saving a scale replaces one you picked in Windows.' ;;
      old) $signin_missing || note=$(old_task_note "$active" "$button") ;;
    esac
    settings=$(jq -c --arg steps "$LANAI_SCALE_STEPS" --arg note "$note" '{memory_gib,cores,windows_scale,baseline,error:"",
      line:"Memory and cores apply the next time Windows starts.",note:$note,
      scale_choices:([{value:"auto",label:"Match my monitor"}] +
        [$steps | splits(" ") | select(length > 0) | tonumber | {value:.,label:(tostring + "%")}])}' <<<"$settings")
  else settings='{"error":"Lanai could not read the VM settings. Check the settings file."}'; fi
  if snapshots=$(cmd_snapshots 2>/dev/null) && jq -e '.ok' <<<"$snapshots" >/dev/null; then
    snapshot_paths=$(jq -c .snapshots <<<"$snapshots")
    items=$(while IFS= read -r name; do panel_snapshot_item "$name"; done < <(
      jq -r 'map(split("/")[-1]) | unique | reverse[]' <<<"$snapshot_paths") | jq -sc .)
    snapshots=$(jq -c --argjson items "$items" '{names:(.snapshots | map(split("/")[-1])),items:$items,count:($items|length),error:"",line:(if (.snapshots|length) == 0 then "No snapshots yet." else "Restoring replaces Windows. Anything saved since the snapshot is lost. Stop Windows in both VMs before restoring." end)}' <<<"$snapshots")
  else snapshots='{"names":[],"items":[],"count":0,"error":"Lanai could not read the snapshot list. Check the settings and logs."}'; fi
  restore=$(panel_restore "$progress" "$records" "$snapshot_paths" "$items" "$(sed -n 's/^LanaiStorage=//p' <<<"$facts")" "$s/restore-in-progress")
  logs=$(jq -nc --arg client "${run:+$run/client.log}" --arg job "$s/panel-job.log" --arg command "$s/panel-run.log" \
    --arg build "$s/build-client.log" \
    '{vm:"Windows VM log: in your user journal, under lanai-vm",job:("Setup, snapshot, restore and update log: " + $job),command:("Button actions log: " + $command),
      build:("Windows window build log: " + $build)} +
     (if $client == "" then {} else {client:("Windows window log: " + $client)} end)')
  log_rows=$(jq -nc --arg copy "$LANAI_LOGS" \
    '[{id:"vm",label:"VM",display:"journal: lanai-vm",copy_text:$copy,copy_label:"Copy VM log command"}]')
  for group in client build job command; do
    case $group in
      client) path=${run:+$run/client.log} label=Window ;;
      build) path=$s/build-client.log label=Build ;;
      job) path=$s/panel-job.log label=Jobs ;;
      command) path=$s/panel-run.log label=Actions ;;
    esac
    [[ -n $path && -f $path ]] || continue
    display=${path##*/}
    log_rows=$(jq -c --arg id "$group" --arg label "$label" --arg display "$display" --arg path "$path" \
      '. + [{id:$id,label:$label,display:$display,copy_text:$path,copy_label:("Copy " + $label + " log path")}]' <<<"$log_rows")
  done
  logs=$(jq -c --argjson rows "$log_rows" \
    '. + {rows:$rows,copied:"Copied",copy_error:"Could not copy. Try again.",copy_busy:"Another log is being copied. Try again in a moment."}' <<<"$logs")
  jq -nc --argjson st "$status" --argjson vm "$vm_status" --argjson p "$plan" --argjson rec "$records" --argjson r "$results" \
    --argjson progress "$progress" --argjson restore "$restore" --argjson settings "$settings" --argjson snaps "$snapshots" --argjson logs "$logs" \
    --argjson client "$client_running" --argjson setupBoot "$setup_boot" --argjson checksBoot "$checks_boot" \
    --argjson stopRequested "$stop_requested" --argjson basicWindow "$basic_window" \
    --argjson clientOld "$client_old" --argjson signinMissing "$signin_missing" --argjson updateShown "$update_shown" --arg task "$task" \
    --arg token "$token" --argjson at "$at" --argjson now "$EPOCHSECONDS" --arg facts "$status_details" --arg problem_line "$problem_line" \
    --arg invocation "$inv" --argjson checkSince "$check_since" --argjson checksStopped "$checks_stopped" '
    def button($show;$enable;$label): {show:$show,enable:($show and $enable),label:$label};
    ({"not-installed":["Not installed","Windows is not installed","No supported Windows install was found.","Install Windows with Omarchy, then continue setup."],
      "setup-needed":["Setup needed","Windows needs setup","Lanai setup has not finished for this Windows install.","Follow the Setup section below."],
      stopped:["Stopped","Windows is stopped","Windows is ready to start.","Click Start Windows."],
      starting:["Starting","Windows is starting","Windows is still booting.","Wait for Windows, or use Shut down."],
      running:["Running","Windows is running","Windows is available.","Click Open window."],
      stopping:["Shutting down","Windows is shutting down","The shutdown request is still in progress.","Wait for Windows to finish shutting down."],
      "in-use":["In use","Windows is in use elsewhere","Another VM is running or preparing Windows.","Stop the other VM before using Windows here."],
      "version-mismatch":["Display driver needs an update","The Windows display needs an update","The client and Windows display driver have different versions.","Shut down and continue setup, or use Omarchy\u0027s Windows connection."],
      failed:["Failed","Windows is unavailable","Windows stopped with an error, or Lanai could not reach it.","Check the logs below. You can also use Omarchy\u0027s Windows connection after shutting Lanai down."]}) as $states |
    $states[$st.state] as $w |
    ([$rec.records[] | select(. != null and has("started") and (has("ended")|not))] | max_by(.started) // {}) as $job |
    ([$rec.records[] | select(.token == $token)] | length > 0) as $seen |
    ($token != "" and ($seen|not) and $now - $at < 10) as $pending |
    ($rec.held or $pending or $progress != null) as $busy |
    ($rec.held and $job.command == "setup") as $setupJob |
    (($rec.held|not) and ($rec.records.setup|has("started")) and ($rec.records.setup|has("ended")|not)) as $interruptedSetup |
    # A step 6 time-out with Windows off: the display buttons repeat the
    # Windows install, beside Continue setup, with no arming step.
    ($rec.records.setup.reply as $sr | $sr.ok == false and $sr.step == "6" and $sr.stop == "timeout" and
      $p.step == "6" and ($p.finished|not) and ($st.active|not)) as $repeat |
    ($token != "" and ($seen|not) and $now - $at >= 10) as $launchFailed |
    ($st.active|not) as $off | ($st.state != "in-use") as $available |
    ($off and $available and ($st.restore_pending|not)) as $idle |
    ($st.setup_done == true and ($p.finished or ($st.active and ($setupBoot or $checksBoot)|not))) as $dailyControls |
    # Icon shortcuts require the current setup plan to be finished. Daily
    # controls still permit a working install to start beside a pending update.
    (if $st.state == "stopped" and $p.finished and ($busy|not) and ($st.restore_pending|not) then "start"
     elif $st.state == "running" and $p.finished and ($st.window|not) then "open"
     else "panel" end) as $rightClick |
    ($off or $dailyControls) as $snapshotsShow |
    ($facts | split("\n") | index("ActiveState=active") != null) as $unitActive |
    (($p.finished|not) and $st.active and $setupBoot and $st.state != "stopping" and
      ($stopRequested|not)) as $confirmStop |
    (($p.finished|not) and ($dailyControls|not) and $unitActive and ($basicWindow|not) and
      ($client|not) and $st.state != "stopping") as $reopen |
    {ok:true,state:$st.state,active:$st.active,label:$w[0],headline:$w[1],cause:$w[2],next:$w[3],
     right_click:$rightClick,
     right_click_tooltip:({start:"Right-click: Start Windows.",open:"Right-click: Open the Windows window.",panel:"Right-click: Open the panel."}[$rightClick]),
     pending_ack:(if $seen then $token else "" end),
     progress:$progress,restore:$restore,notice:($st.notice // ""),warning:"",logs:$logs,settings:$settings,snapshots:($snaps + {show:$snapshotsShow}),
     busy:{active:$busy,line:(if $progress != null then (if ($progress.label | startswith("Restoring Windows:")) then "Keep Windows stopped until it finishes." else "You can close this panel." end) elif $rec.held and $job.reply and $job.command == "setup" then (if $job.reply.step == "5" then "Waiting for Windows to finish setup. You can close this panel." else "Checking Windows. You can close this panel." end)
       elif $busy then ({setup:"Working on setup. You can close this panel.",snapshot:"Taking a snapshot. You can close this panel.",restore:"Restoring Windows. Keep Windows stopped until it finishes.",
         "build-client":("Updating the Windows window. This may take several minutes. " +
           (if $off then "You can start Windows when it finishes. " else "" end) + "You can close this panel.")}[$job.command // ""] //
         "Starting the operation.") else "" end)},
     result:($r + {launch:(if $launchFailed then "The operation did not start. Check the setup, snapshot, restore and update log, then try again." else "" end)}),
     setup:{show:($p.finished|not),finished:$p.finished,
       attention:(($p.finished|not) and $st.state != "stopping" and ($p.reason != "" or $r.setup != "" or $launchFailed or
         ($p.step == "3" and $rec.records.snapshots.reply.ok == false) or $st.state == "failed" or
         $reopen or ($setupBoot and $st.state != "starting") or ($busy|not))),step:$p.step,
       choices:(if $p.finished then ["--no-window","--window"] else $p.choices end),
       again_line:"Choose how Windows should show during setup.",
       lines:([if $st.state == "not-installed" and ($p.reason == "missing" or $p.reason == "layout") then empty
         elif $problem_line != "" then $problem_line else {"1":"Check the Windows install and the shared Windows folder before continuing.",
         "2":"Click Install in a terminal, complete installation there, then continue setup.",
         "3":"Before the first boot, take a snapshot so you can undo changes, or make a backup and continue without one.",
         "3a":"Continue setup to prepare the Windows install.",
         "4":"Continue setup to prepare the Windows window. This may take several minutes.",
         "5":(if $p.action == "setup-wait" then (if $setupJob then "In Windows, open Lanai\u0027s setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Use Shut down only if setup.cmd stops responding, or when its shared-folder check tells you to."
           else "In Windows, open Lanai\u0027s setup drive and run setup.cmd. Then click Continue setup so Lanai can restart Windows and check it when setup.cmd finishes." end)
           elif ($p.choices|length)>0 then "The setup boot did not finish. Choose the screen to use for another setup boot."
           elif $st.active then "Shut Windows down before continuing setup."
           else "Continue setup to install the drivers in Windows." end),
         "6":(if $st.state == "stopping" then "Wait for Windows to shut down, then click Continue setup."
           elif $setupJob and $p.scale_wait == true then "Waiting for the display scale task. If Windows is at its sign-in screen, or another user is signed in, sign in as the Windows user who ran setup."
           elif $setupJob then "Windows is starting or being checked."
           else "Click Continue setup so Lanai can check Windows." end),
         "7":"Setup is finished."}[$p.step] end])},
     buttons:{start:button($dailyControls and $off;$idle and ($busy|not) and ($st.setup_done == true);"Start Windows"),
       open:button($dailyControls and $st.active and ($st.window|not);$st.state != "stopping";"Open window"),
       stop:button($st.active;true;"Shut down") + {confirm:$confirmStop},
       stop_confirm:button($confirmStop;true;"Shut down and stop setup") +
         {hint:"Shutting down now stops setup. You\u0027ll choose how to continue."},
       reopen_window:button($reopen;true;"Reopen the Windows window"),
       force_stop:button($st.force_stop;$st.force_stop;"Force stop"),
       force_confirm:button($st.force_stop;$st.force_stop;"Force stop and lose unsaved work"),
       cancel:button(true;true;"Cancel"),
       dismiss_notice:button(($st.notice != null);true;"Dismiss notice"),
       continue_setup:button($interruptedSetup or (($p.choices|length)==0 and $p.step != "3");
         ($busy|not) and $available and ($st.restore_pending|not) and (($p.finished|not) or $off) and
         $p.reason != "no-media" and $p.reason != "active" and ($p.step != "6" or $st.state != "stopping");(if $p.finished then "Run setup again" else "Continue setup" end)) +
         {hint:(if $p.finished and ($off|not) then "Shut Windows down, then choose Run setup again in More actions." else "" end)},
       install:button($p.step == "2";($busy|not);"Install in a terminal"),
       setup_snapshot:button($p.step == "3";$idle and ($busy|not);"Take a snapshot"),
       skip_snapshot:button($p.step == "3";$idle and ($busy|not);"Continue without a snapshot"),
       window:(button($p.finished or ($p.choices|length)>0 or $repeat;$idle and ($busy|not);"Set up in a basic window") +
         {hint:"Use a basic window if the Windows window is blank or the display driver needs repair."}),
       no_window:(button($p.finished or ($p.choices|length)>0 or $repeat;$idle and ($busy|not);"Set up in the Windows window") +
         {hint:"Use this if the Windows display driver already works."}),
       finish_restore:button($snapshotsShow and $st.restore_pending;$off and $available and ($busy|not);"Finish the unfinished restore"),
       take_snapshot:button($snapshotsShow;$idle and ($busy|not);"Take a snapshot"),
       restore_snapshot:button($snapshotsShow and ($snaps.names|length)>0;$off and $available and ($busy|not);"Restore snapshot") +
         {labels:($snaps.names | map({key:.,value:("Restore snapshot " + .)}) | from_entries)},
       restore_confirm:button($snapshotsShow and ($snaps.names|length)>0;$off and $available and ($busy|not);"Restore and replace Windows") +
         {labels:($snaps.names | map({key:.,value:("Restore " + . + " and replace Windows")}) | from_entries)},
       update_client:button($updateShown;($busy|not);"Update the Windows window"),
       save_settings:button(true;$settings.error == "";"Save settings")}} |
    if ($dailyControls|not) and ($st.state == "stopped" or $st.state == "running") then
      .next="Follow the Setup section below." |
      # Guard only: stopped implies setup_done and an off unit, so daily controls normally show.
      if $st.state == "stopped" then .cause="Lanai setup has not finished for this Windows install." else . end
    else . end |
    if $st.restore_pending then .cause="A restore did not finish, so Windows cannot start." |
      .next=(if $available then "When Windows is stopped, finish the unfinished restore or restore another snapshot." else "Stop the other VM, then finish the unfinished restore or restore another snapshot." end) else . end |
    if $st.force_stop then .next="Wait, or use Force stop in More actions if you accept losing unsaved work." else . end |
    .warning = ([
      if $facts | contains("LanaiHelpersMissing=") then "Some background services stopped. Shut Windows down and start it again." else empty end,
      if $facts | contains("LanaiClient=timeout") then "The Windows window did not open in time. " +
        (if $dailyControls then "Try Open window again." elif $reopen then "Try Reopen the Windows window in Setup."
         else "Check the Windows window log, then shut down and continue setup." end) else empty end,
      if $st.state != "version-mismatch" and ($facts | contains("LanaiDriverOld=")) then "The Windows display driver needs an update. Shut down and continue setup." else empty end,
      # The resize warning (req 12): with the sign-in step present, an old
      # client gets the update button. Without the step, Run setup again
      # is the one step: one message says what it fixes (the size, from
      # the missing step and an old client, and scale saves with the old
      # task) and the lock.
      if $signinMissing then
        ([if $clientOld then "Windows may start at the wrong size and stay there until you resize the window, and it may change to the wrong size while it runs."
          else "After Windows starts, it may stay at its old size until you resize the window." end,
          if $task == "old" then "Scale saves apply only the next time Windows starts." else empty end]) as $fixes |
        ($fixes + ["To fix " + ({"1":"this","2":"both"}[$fixes | length | tostring]) + ", " +
          (if $off then "click Run setup again in More actions." else "shut Windows down and click Run setup again in More actions." end),
          "Running setup again also turns the Windows lock off again."] | join(" "))
      elif $updateShown then
        "Windows may start at, or change to, the wrong size until you click Update the Windows window in More actions. Updating changes nothing in Windows."
      else empty end
    ] | join(" ")) |
    # Presentation follows the existing decisions and never widens an offer.
    def currentSetup:
      $rec.records.setup as $d |
      ($d.invocation == null or $d.invocation == $invocation) and
      # Run setup again can fail at the client build while the plan stays finished.
      ($d.reply.step == null or $d.reply.step == $p.step or
        ($d.reply.step == "4" and $p.finished and $clientOld and ($updateShown|not) and
          any($d.args[]?; . == "--window" or . == "--no-window"))) and
      ($p.step != "6" or $checkSince == null or ($d.ended // $now) >= $checkSince);
    ($p.finished == false and $p.step == "6" and currentSetup and
      $rec.records.setup.reply.ok == false and $rec.records.setup.reply.stop == "timeout") as $timeout |
    # Settings refusals stay beside the drafts; prompts and timeouts keep their setup view.
    (["vm","setup","snapshots","client"] | any(.[];
      . as $g | $rec.records[$g] as $d |
      ($r[$g] != "" and $d != null and ($d.invocation == null or $d.invocation == $invocation) and
        ($d.reply.ok == false or (($rec.held|not) and ($d|has("started")) and ($d|has("ended")|not))) and
      (if $g == "setup" then currentSetup and ($timeout|not) and
        (($d.reply.step == "2" and $d.reply.missing != null) or
          ($d.reply.step == "3" and $d.reply.reason == null) | not)
       else true end)))) as $resultFailed |
    ($progress.operation == "restore" or ($rec.held and $job.command == "restore")) as $restoring |
    ($st.state == "failed" or (.restore.pending and ($restoring|not)) or $resultFailed or $launchFailed or
      ($facts | contains("LanaiHelpersMissing=") or contains("LanaiClient=timeout"))) as $failed |
    .layout = (if .restore.pending or $restoring then "restoring"
      elif $timeout then "setup_timeout"
      elif .setup.show then (if $p.step == "6" then "setup_verify" else "setup" end)
      elif $failed then "failed" else "daily" end) |
    .settings += {baseline:(.settings.baseline // null),
      labels:{memory:"Memory (GiB)",cores:"CPU cores",scale:"Windows scale",save:"Save",saved:"Saved",reset:"Reset",unsaved:"Unsaved"}} |
    (if $p.finished then null elif $p.step == "3a" then 4 else ($p.step | tonumber) end) as $number |
    ["Check","Packages","Snapshot","Prepare","Drivers","Verify"] as $names |
    .setup += {number:$number,name:(if $number == null then "" else $names[$number - 1] end),
      step_line:(if $number == null then "" else "Step \($number) of 6" end),
      steps:[$names | to_entries[] | {number:(.key + 1),name:.value,
        state:(if $number == null or .key + 1 < $number then "complete"
          elif .key + 1 == $number then "current" else "pending" end)}],
      title:({"1":"Check the Windows install","2":"Install host packages","3":"Snapshot before first boot",
        "3a":"Prepare the Windows install","4":"Prepare the Windows window","5":"Finish in Windows",
        "6":(if $timeout then "Windows checks timed out" elif $p.scale_wait then "Sign in to Windows to finish" else "Checking Windows" end),
        "7":"Setup is finished"}[$p.step])} |
    (.layout == "setup" or .layout == "setup_verify" or .layout == "setup_timeout") as $setupLayout |
    .header = {title:"Windows",meta:(if $setupLayout then
        .setup.step_line + " · " + .setup.name + (if $timeout then " · " + $states[$vm.state][0] else "" end)
      elif .settings.baseline != null then
        "\(.settings.memory_gib) GiB · \(.settings.cores) cores · " +
        (if .settings.windows_scale == "auto" then "Auto" else "\(.settings.windows_scale)%" end)
      else "" end),badge:(if $setupLayout then "Setup" elif .layout == "failed" then "Failed" else .label end)} |
    .sections = {settings:"Settings",snapshots:"Snapshots",logs:"Logs",more:"More actions",dismiss_click_notice:"Dismiss busy notice",default:(if .layout == "failed" then "logs" elif .restore.pending and ($restoring|not) then "snapshots" else "" end)} |
    def checkrow($id;$label;$probes):
      ($probes | map(.state // "not_checked")) as $states |
      (if $states | index("failed") then "failed" elif all($states[]; . == "done") then "done"
        elif $states | index("waiting") then "waiting" else "not_checked" end) as $state |
      {id:$id,label:$label,state:$state,status:({not_checked:"Not checked",waiting:"Waiting",done:"Done",failed:"Failed"}[$state]),
        detail:([$probes[] | select(.state == "waiting" or .state == "failed") |
          ({qmp:"Windows virtual machine", "guest-boot":"QEMU guest agent", "window-closed":"Windows window",
            "idd-missing":"display driver",mismatch:"pinned display driver build",spice:"SPICE agent",
            clock:"QEMU guest agent clock",allowlist:"QEMU guest agent allow-list","scale-task":"display scale task"}[.reason] // "Windows check") as $part |
          if .state == "waiting" then "Waiting for the " + $part + "." else "The " + $part + " failed." end] | join(" "))};
    .setup.checks = [checkrow("idd";"Display driver";[$p.checks.idd]),
      checkrow("agents";"Windows agents";[$p.checks.spice,$p.checks.clock,$p.checks.allowlist]),
      checkrow("scale";"Scale task";[$p.checks.scale])] |
    .setup.countdown = (if $setupJob and $job.invocation == $invocation and $invocation != "" and
        $job.reply.ok == true and $job.reply.step == "6" and $p.step == "6" and $p.scale_wait == true and
        $st.active and $st.state != "stopping" and ($stopRequested|not) and ($checksStopped|not) and ($timeout|not) and
        $p.checks.scale.state == "waiting" and
        ($p.scale_started_at | type == "number" and . > 0 and . <= $now and floor == .) and
        ($p.scale_limit_seconds | type == "number" and . > 0 and floor == .) then
      {started_at:$p.scale_started_at,limit_seconds:$p.scale_limit_seconds,
        remaining_seconds:([0,($p.scale_limit_seconds - ($now - $p.scale_started_at))] | max),label:"Time remaining to sign in"}
      else null end) |
    .primary_action = (.buttons as $buttons |
      (if .layout == "restoring" then ["finish_restore","restore_snapshot"]
       elif .setup.show then (if $dailyControls then ["start","open"] else [] end) +
         (if $p.step == "2" then ["install","continue_setup"] elif $p.step == "3" then ["setup_snapshot","skip_snapshot"]
          else ["reopen_window","continue_setup","window","no_window"] end)
       else ["start","open","continue_setup"] end) |
      map(select($buttons[.].show and $buttons[.].enable)) | .[0] // null) |
    ($timeout or (.setup.attention and ($restoring|not)) or
      ($p.step == "6" and $setupJob and $p.checks.scale.state == "waiting") or
      (currentSetup and $rec.records.setup.reply.ok == false and ($p.action == "packages" or $p.action == "snapshot")) or
      (["not-installed","in-use","version-mismatch"] | index($st.state) != null)) as $attention |
    .bar = {mode:(if $failed then "failed"
      elif $p.action == "setup-wait" and $st.active then "active"
      elif $attention then "attention" elif $busy then "busy" elif $st.active then "active" else "stopped" end),
      percent:(if $progress.total > 0 then $progress.percent else null end)} |
    .bar.label = ({stopped:"Stopped",active:"Active",busy:"Busy",attention:"Your turn",failed:"Failed"}[.bar.mode])'
  # shellcheck disable=SC2034
  LANAI_EMITTED=1
}
