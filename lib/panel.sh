# The panel's read-only view and copy table. No setup reply file is consulted.
# shellcheck shell=bash

# old_task_note <running true|false>: print the standing note for an install
# whose scale task is from before live scale (scale_task_kind old).
old_task_note() {
  local how="click"
  [[ $1 != true ]] || how="shut Windows down and click"
  printf 'Scale saves apply the next time Windows starts. To make them apply while Windows runs, %s Run setup again.\n' "$how"
}

# Reply words depend on command, ok, step and structured details/reasons.
# The optional current plan step selects visible snapshot-choice retry controls.
# Offers and waits belong to the durable view and therefore have no result text.
# A settings save's words come from its scale_saved, running and scale_task_kind
# fields; for a scale save, cmd_settings prints the same words (plus
# old_task_note for the old task, which the panel shows under the scale list).
panel_words() {
  jq -r --arg c "$1" --arg step "${3:-}" '
    def log: {setup:"setup log",snapshot:"snapshot log",restore:"restore log","build-client":"Windows window build log"}[$c] // "button actions log";
    def oldtask: " Until you run setup again, the old scale task undoes scales you pick in Windows," +
      " and \u201cMatch my monitor\u201d does not follow the window. Running setup again also turns the Windows lock off again.";
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
      "guest-boot":"Windows did not finish starting, or its guest agent is missing. Shut down and set up Windows again.",
      "idd-missing":"The display driver in Windows did not answer. Shut down and set up Windows again.",
      mismatch:"The display driver in Windows needs an update. Shut down and set up Windows again.",
      agents:"The Windows agents did not answer. Shut down and set up Windows again.",
      answers:"The final checks did not pass. Shut down and set up Windows again.",
      "scale-task":"The display scale task in Windows did not start. It starts when the Windows user who ran setup.cmd signs in. Shut down and set up Windows again, then sign in as that user. If it happens again, check C:\\Program Files\\Lanai\\lanai-scale.log in Windows.",
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
      elif .reason and (reasons[.reason] != null) then reasons[.reason]
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

# One view: gather once, status makes its one bounded QMP session, and setup plans
# from the same host facts. Settings/list errors are data, never swallowed results.
cmd_panel() {
  local client_running=false setup_boot=false checks_boot=false basic_window=false stop_requested=false stop_inv stop_at
  local token='' at=0 facts status_details status plan records settings snapshots logs s run inv progress problem_line results='{}' group doc words note active
  local client_old=false task started=0
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
  plan=$(setup_plan "$facts")
  records=$(panel_records)
  problem_line=''
  if [[ $(jq -r .reason <<<"$plan") != '' ]]; then
    problem_line=$(panel_words setup "$(jq -c '. + {ok:false}' <<<"$plan")")
  fi
  s=$(state_dir); run=$(run_dir 2>/dev/null) || run=''
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
  task=$(scale_task_kind)
  # When the current client started (client.log's first line), or 0.
  [[ -z $run || ! -s $run/client.log ]] || started=$(log_client_start "$run/client.log")
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
    if [[ $group == setup ]] && jq -e --argjson p "$plan" '
      .reply.ok == false and
      ((.reply.step != null and .reply.step != $p.step) or
       (.reply.reason != null and .reply.reason == $p.reason))' <<<"$doc" >/dev/null; then
      words=''
    fi
    if jq -e '.held == false' <<<"$records" >/dev/null &&
      jq -e 'has("started") and (has("ended") | not)' <<<"$doc" >/dev/null; then
      case $(jq -r .command <<<"$doc") in
        snapshot) words="The snapshot did not finish. Try again." ;;
        restore) words="The restore did not finish. Finish the unfinished restore or restore another snapshot before starting Windows." ;;
        build-client) words="The update did not finish. Click Update the Windows window again." ;;
        *) words="Setup was interrupted. Continue setup to try again." ;;
      esac
    fi
    # An update's done words hold until a client starts after the job
    # ended (the next lanai open runs the new binary). Its failed and
    # interrupted words hold only while the client is still old.
    if [[ $group == client ]]; then
      if jq -e '.reply.ok == true' <<<"$doc" >/dev/null; then
        ! jq -e --argjson c "$started" '$c > .ended' <<<"$doc" >/dev/null || words=''
      elif ! $client_old; then words=''; fi
    fi
    results=$(jq -nc --argjson r "$results" --arg g "$group" --arg w "$words" '$r + {($g):$w}')
  done
  if settings=$(cmd_settings 2>/dev/null) && jq -e '.ok' <<<"$settings" >/dev/null; then
    # The note near the scale list: with the live scale task, while Windows
    # runs, that a scale save replaces a pick; with the old task, always,
    # how to make scale saves apply while Windows runs.
    note='' active=false
    ! jq -e '.active' <<<"$status" >/dev/null || active=true
    case $task in
      new) ! $active || note='Saving a scale replaces one you picked in Windows.' ;;
      old) note=$(old_task_note "$active") ;;
    esac
    settings=$(jq -c --arg steps "$LANAI_SCALE_STEPS" --arg note "$note" '{memory_gib,cores,windows_scale,error:"",
      line:"Memory and cores apply the next time Windows starts.",note:$note,
      scale_choices:([{value:"auto",label:"Match my monitor"}] +
        [$steps | splits(" ") | select(length > 0) | tonumber | {value:.,label:(tostring + "%")}])}' <<<"$settings")
  else settings='{"error":"Lanai could not read the VM settings. Check the settings file."}'; fi
  if snapshots=$(cmd_snapshots 2>/dev/null) && jq -e '.ok' <<<"$snapshots" >/dev/null; then
    snapshots=$(jq -c '{names:(.snapshots | map(split("/")[-1])),error:"",line:(if (.snapshots|length) == 0 then "No snapshots yet." else "Restoring replaces Windows. Anything saved since the snapshot is lost. Stop Windows in both VMs before restoring." end)}' <<<"$snapshots")
  else snapshots='{"names":[],"error":"Lanai could not read the snapshot list. Check the settings and logs."}'; fi
  logs=$(jq -nc --arg client "${run:+$run/client.log}" --arg job "$s/panel-job.log" --arg command "$s/panel-run.log" \
    --arg build "$s/build-client.log" \
    '{vm:"Windows VM log: in your user journal, under lanai-vm",job:("Setup, snapshot and restore log: " + $job),command:("Button actions log: " + $command),
      build:("Windows window build log: " + $build)} +
     (if $client == "" then {} else {client:("Windows window log: " + $client)} end)')
  jq -nc --argjson st "$status" --argjson p "$plan" --argjson rec "$records" --argjson r "$results" \
    --argjson progress "$progress" --argjson settings "$settings" --argjson snaps "$snapshots" --argjson logs "$logs" \
    --argjson client "$client_running" --argjson setupBoot "$setup_boot" --argjson checksBoot "$checks_boot" \
    --argjson stopRequested "$stop_requested" --argjson basicWindow "$basic_window" \
    --argjson clientOld "$client_old" --arg task "$task" \
    --arg token "$token" --argjson at "$at" --argjson now "$EPOCHSECONDS" --arg facts "$status_details" --arg problem_line "$problem_line" '
    def button($show;$enable;$label): {show:$show,enable:($show and $enable),label:$label};
    ({"not-installed":["Not installed","Windows is not installed","No supported Windows install was found.","Install Windows with Omarchy, then continue setup."],
      "setup-needed":["Setup needed","Windows needs setup","Lanai setup has not finished for this Windows install.","Follow the Setup section below."],
      stopped:["Stopped","Windows is stopped","Windows is ready to start.","Click Start Windows."],
      starting:["Starting","Windows is starting","Windows is still booting.","Wait for Windows, or use Shut down."],
      running:["Running","Windows is running","Windows is available.","Click Open window."],
      stopping:["Shutting down","Windows is shutting down","The shutdown request is still in progress.","Wait for Windows to finish shutting down."],
      "in-use":["In use","Windows is in use elsewhere","Another VM is running or preparing Windows.","Stop the other VM before using Windows here."],
      "version-mismatch":["Display driver needs an update","The Windows display needs an update","The client and Windows display driver have different versions.","Shut down and continue setup, or use Omarchy\u0027s Windows connection."],
      failed:["Failed","Windows is unavailable","Windows stopped with an error, or Lanai could not reach it.","Check the logs below. You can also use Omarchy\u0027s Windows connection after shutting Lanai down."]}[$st.state]) as $w |
    ([$rec.records[] | select(. != null and has("started") and (has("ended")|not))] | max_by(.started) // {}) as $job |
    ([$rec.records[] | select(.token == $token)] | length > 0) as $seen |
    ($token != "" and ($seen|not) and $now - $at < 10) as $pending |
    ($rec.held or $pending or $progress != null) as $busy |
    ($rec.held and $job.command == "setup") as $setupJob |
    (($rec.held|not) and ($rec.records.setup|has("started")) and ($rec.records.setup|has("ended")|not)) as $interruptedSetup |
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
     progress:$progress,notice:($st.notice // ""),warning:"",logs:$logs,settings:$settings,snapshots:($snaps + {show:$snapshotsShow}),
     busy:{active:$busy,line:(if $progress != null then (if ($progress.label | startswith("Restoring Windows:")) then "Keep Windows stopped until it finishes." else "You can close this panel." end) elif $rec.held and $job.reply and $job.command == "setup" then (if $job.reply.step == "5" then "Waiting for Windows to finish setup. You can close this panel." else "Checking Windows. You can close this panel." end)
       elif $busy then ({setup:"Working on setup. You can close this panel.",snapshot:"Taking a snapshot. You can close this panel.",restore:"Restoring Windows. Keep Windows stopped until it finishes.",
         "build-client":("Updating the Windows window. This may take several minutes. " +
           (if $off then "You can start Windows when it finishes. " else "" end) + "You can close this panel.")}[$job.command // ""] //
         "Starting the operation.") else "" end)},
     result:($r + {launch:(if $launchFailed then "The operation did not start. Check the setup, snapshot and restore log, then try again." else "" end)}),
     setup:{show:($p.finished|not),finished:$p.finished,
       attention:(($p.finished|not) and $st.state != "stopping" and ($p.reason != "" or $r.setup != "" or $launchFailed or
         ($p.step == "3" and $rec.records.snapshots.reply.ok == false) or $st.state == "failed" or
         $reopen or ($setupBoot and $st.state != "starting") or ($p.questions|length)>0 or ($busy|not))),step:$p.step,questions:$p.questions,
       choices:(if $p.finished then ["--no-window","--window"] else $p.choices end),
       again_line:"Choose how Windows should show during setup.",
       share_question:"Does Explorer show the files from your Linux Windows folder?",scale_question:"Does text in Windows look the right size?",
       lines:([if $st.state == "not-installed" and ($p.reason == "missing" or $p.reason == "layout") then empty
         elif $problem_line != "" then $problem_line else {"1":"Check the Windows install and the shared Windows folder before continuing.",
         "2":"Click Install in a terminal, complete installation there, then continue setup.",
         "3":"Before the first boot, take a snapshot so you can undo changes, or make a backup and continue without one.",
         "3a":"Continue setup to prepare the Windows install.",
         "4":"Continue setup to prepare the Windows window. This may take several minutes.",
         "5":(if $p.action == "setup-wait" then (if $setupJob then "In Windows, open Lanai\u0027s setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Use Shut down only if setup.cmd stops responding."
           else "In Windows, open Lanai\u0027s setup drive and run setup.cmd. Then click Continue setup so Lanai can restart Windows and check it when setup.cmd finishes." end)
           elif ($p.choices|length)>0 then "The setup boot did not finish. Choose the screen to use for another setup boot."
           elif $st.active then "Shut Windows down before continuing setup."
           else "Continue setup to install the drivers in Windows." end),
         "6":(if $st.state == "stopping" then "Wait for Windows to shut down, then click Continue setup."
           elif ($p.questions|length)>0 then "Sign in to Windows if it asks for your password. Then check the shared drive in Explorer and the text size, and send both answers."
           elif $setupJob and $p.scale_wait == true then "Waiting up to a minute for the display scale task to start in Windows. It starts when you sign in."
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
       continue_setup:button($interruptedSetup or (($p.choices|length)==0 and ($p.questions|length)==0 and $p.step != "3");
         ($busy|not) and $available and ($st.restore_pending|not) and (($p.finished|not) or $off) and
         $p.reason != "no-media" and $p.reason != "active" and ($p.step != "6" or $st.state != "stopping");(if $p.finished then "Run setup again" else "Continue setup" end)) +
         {hint:(if $p.finished and ($off|not) then "Shut Windows down to run setup again." else "" end)},
       install:button($p.step == "2";($busy|not);"Install in a terminal"),
       setup_snapshot:button($p.step == "3";$idle and ($busy|not);"Take a snapshot"),
       skip_snapshot:button($p.step == "3";$idle and ($busy|not);"Continue without a snapshot"),
       window:(button($p.finished or ($p.choices|length)>0;$idle and ($busy|not);"Set up in a basic window") +
         {hint:"Use a basic window if the Windows window is blank or the display driver needs repair."}),
       no_window:(button($p.finished or ($p.choices|length)>0;$idle and ($busy|not);"Set up in the Windows window") +
         {hint:"Use this if the Windows display driver already works."}),
       answer_yes:button(($p.questions|length)>0;($busy|not);"Yes"),
       answer_no:button(($p.questions|length)>0;($busy|not);"No"),
       send_answers:button(($p.questions|length)>0;($busy|not) and $st.active;"Send answers"),
       finish_restore:button($snapshotsShow and $st.restore_pending;$off and $available and ($busy|not);"Finish the unfinished restore"),
       take_snapshot:button($snapshotsShow;$idle and ($busy|not);"Take a snapshot"),
       restore_snapshot:button($snapshotsShow and ($snaps.names|length)>0;$off and $available and ($busy|not);"Restore snapshot") +
         {labels:($snaps.names | map({key:.,value:("Restore snapshot " + .)}) | from_entries)},
       restore_confirm:button($snapshotsShow and ($snaps.names|length)>0;$off and $available and ($busy|not);"Restore and replace Windows") +
         {labels:($snaps.names | map({key:.,value:("Restore " + . + " and replace Windows")}) | from_entries)},
       update_client:button($clientOld and $task == "new";($busy|not);"Update the Windows window"),
       save_settings:button(true;$settings.error == "";"Save settings")}} |
    if ($dailyControls|not) and ($st.state == "stopped" or $st.state == "running") then
      .next="Follow the Setup section below." |
      # Guard only: stopped implies setup_done and an off unit, so daily controls normally show.
      if $st.state == "stopped" then .cause="Lanai setup has not finished for this Windows install." else . end
    else . end |
    if $st.restore_pending then .cause="A restore did not finish, so Windows cannot start." |
      .next=(if $available then "When Windows is stopped, finish the unfinished restore or restore another snapshot." else "Stop the other VM, then finish the unfinished restore or restore another snapshot." end) else . end |
    if $st.force_stop then .next="Wait, or use Force stop below if you accept losing unsaved work." else . end |
    .warning = ([
      if $facts | contains("LanaiHelpersMissing=") then "Some background services stopped. Shut Windows down and start it again." else empty end,
      if $facts | contains("LanaiClient=timeout") then "The Windows window did not open in time. " +
        (if $dailyControls then "Try Open window again." elif $reopen then "Try Reopen the Windows window in Setup."
         else "Check the Windows window log, then shut down and continue setup." end) else empty end,
      if $st.state != "version-mismatch" and ($facts | contains("LanaiDriverOld=")) then "The Windows display driver needs an update. Shut down and continue setup." else empty end,
      # The resize warning (req 12): the update button with the live scale
      # task; with the old task, Run setup again, which also replaces it.
      if $clientOld then "Windows may start at, or change to, the wrong size until you " +
        (if $task == "new" then "click Update the Windows window. This changes nothing in Windows."
         elif $off then "click Run setup again." else "shut Windows down and click Run setup again." end) else empty end
    ] | join(" "))'
  # shellcheck disable=SC2034
  LANAI_EMITTED=1
}
