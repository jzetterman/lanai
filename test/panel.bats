#!/usr/bin/env bats
# Panel decisions use isolated files and functions, never sockets or a VM.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329,SC2016
load helpers
load panel-fixtures

setup() { isolate_home; panel_fixture_setup; }

@test "redesign settings: a refused save stays inline without failing the panel or bar" {
  state "$CURRENT"
  for reply in '{"ok":false,"reason":"busy"}' '{"ok":false}'; do
    panel_result_write settings "$(jq -nc --argjson r "$reply" '{command:"settings",ended:1,reply:$r}')"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .layout <<<"$output")" daily
    assert_equal "$(jq -r .bar.mode <<<"$output")" stopped
    assert_equal "$(jq -r .header.badge <<<"$output")" Stopped
    assert_equal "$(jq -r .sections.default <<<"$output")" ''
    assert_equal "$(jq -r .result.settings <<<"$output")" "$(panel_words settings "$reply")"
  done
  # A real VM failure still opens Logs even with a refused settings save.
  ST=failed RESULT=exit-code
  run cmd_panel
  assert_equal "$(jq -r .layout <<<"$output")" failed
  assert_equal "$(jq -r .sections.default <<<"$output")" logs
}

@test "redesign restore: unfinished idle recovery opens its primary action" {
  state "$CURRENT"
  : >"$S/restore-in-progress"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .layout <<<"$output")" restoring
  assert_equal "$(jq -r .primary_action <<<"$output")" finish_restore
  assert_equal "$(jq -r .sections.default <<<"$output")" snapshots
}

@test "redesign words: hidden recovery controls name More actions" {
  state "$CURRENT"
  ST=active
  echo "inv $((EPOCHSECONDS - 121))" >"$S/stop-requested"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .next <<<"$output")" 'Wait, or use Force stop in More actions if you accept losing unsaved work.'
  rm "$S/stop-requested"
  run cmd_panel
  assert_equal "$(jq -r .buttons.continue_setup.hint <<<"$output")" 'Shut Windows down, then choose Run setup again in More actions.'
}

@test "panel scale: supplies current value and every labeled scale choice" {
  state "$CURRENT"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .settings.windows_scale <<<"$output")" auto
  assert_equal "$(jq -c '.settings.scale_choices | map(.value)' <<<"$output")" '["auto",100,125,150,175,200,225,250,300,350,400,450,500]'
  assert_equal "$(jq -r .settings.scale_choices[0].label <<<"$output")" 'Match my monitor'
  assert_equal "$(jq -r .settings.scale_choices[-1].label <<<"$output")" '500%'
  jq '.windows_scale=175' "$(settings_file)" >"$T/settings"
  mv "$T/settings" "$(settings_file)"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .settings.windows_scale <<<"$output")" 175
}

@test "panel words: settings saves for a live, stopped, memory-only and old-task save" {
  local live='Saved. Windows uses the saved scale within 5 seconds if you'"'"'re signed in, or when you next sign in.'
  local stopped='Saved. Changes apply the next time Windows starts.'
  local tail='Until you run setup again, the old scale task undoes scales you pick in Windows, and “Match my monitor” does not follow the window. Running setup again also turns the Windows lock off again.'
  run panel_words settings '{"ok":true,"scale_saved":true,"running":true,"scale_task_kind":"new"}'
  assert_output "$live"
  run panel_words settings '{"ok":true,"scale_saved":true,"running":false,"scale_task_kind":"new"}'
  assert_output "$stopped"
  # The Settings line already says when memory and cores apply.
  run panel_words settings '{"ok":true,"scale_saved":false,"running":true,"scale_task_kind":"new"}'
  assert_output "Saved."
  run panel_words settings '{"ok":true,"scale_saved":false,"running":false,"scale_task_kind":"old"}'
  assert_output "Saved."
  # The old task: the next start, the lost picks and following, and the
  # lock; the standing note under the scale list says how to run setup.
  run panel_words settings '{"ok":true,"scale_saved":true,"running":true,"scale_task_kind":"old"}'
  assert_output "Saved. Windows uses the saved scale the next time it starts. $tail"
  run panel_words settings '{"ok":true,"scale_saved":true,"running":false,"scale_task_kind":"old"}'
  assert_output "$stopped $tail"
  # A first setup expects no mark yet: every scale save uses the stopped words.
  run panel_words settings '{"ok":true,"scale_saved":true,"running":true,"scale_task_kind":"none"}'
  assert_output "$stopped"
}

# The words that end every step 6 time-out: both ways on, with the setup.cmd
# condition (spec 7). They show under the display buttons, so they name them
# (LanaiPanel.qml).
TIMEOUT_TAIL="Click Continue setup to check again. To install Lanai's parts in Windows again, shut Windows down, then click Set up in a basic window or Set up in the Windows window. Do this too if setup.cmd stopped with a message in Windows."

@test "panel words: each step 6 time-out names what did not answer, with the setup.cmd condition and both ways on" {
  local reason words
  for reason in qmp guest-boot window-closed idd-missing agents scale-task; do
    words=$(panel_words setup "$(jq -nc --arg r "$reason" '{ok:false,step:"6",stop:"timeout",reason:$r,parts:["the SPICE agent"],message:"UNTRUSTED",next:"UNTRUSTED"}')")
    [[ $words == ?*" $TIMEOUT_TAIL"* ]] ||
      fail "$reason: $words"
    [[ $words != *UNTRUSTED* ]] || fail "$reason shows CLI prose: $words"
  done
  # The display buttons' labels, as the panel shows them.
  run cmd_panel
  assert_equal "$(jq -r '.buttons.window.label + "|" + .buttons.no_window.label' <<<"$output")" "Set up in a basic window|Set up in the Windows window"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"qmp"}'
  assert_output "Lanai could not reach Windows' virtual machine to check it. $TIMEOUT_TAIL"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"guest-boot"}'
  assert_output "Windows did not finish starting, or its guest agent did not start. $TIMEOUT_TAIL"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"window-closed"}'
  assert_output "The Windows window did not stay open long enough to check the display driver. $TIMEOUT_TAIL"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"idd-missing"}'
  assert_output "The display driver in Windows did not answer. $TIMEOUT_TAIL"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"scale-task"}'
  # The sign-in condition names the user, then where to look if the task
  # still does not start.
  assert_output "The display scale task in Windows did not start. If Windows is at its sign-in screen, or another user is signed in, sign in as the Windows user who ran setup. $TIMEOUT_TAIL If the task still does not start, see lanai-signin.log and lanai-scale.log in C:\\Program Files\\Lanai."
}

@test "panel words: an agents time-out names each part that did not answer, and only known parts" {
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"agents","parts":["the SPICE agent"]}'
  assert_output "In Windows, the SPICE agent did not answer. $TIMEOUT_TAIL"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"agents","parts":["the QEMU guest agent"]}'
  assert_output "In Windows, the QEMU guest agent did not answer. $TIMEOUT_TAIL"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"agents","parts":["the SPICE agent","the QEMU guest agent"]}'
  assert_output "In Windows, the SPICE agent and the QEMU guest agent did not answer. $TIMEOUT_TAIL"
  run panel_words setup '{"ok":false,"step":"6","stop":"timeout","reason":"agents","parts":["UNTRUSTED"]}'
  assert_output "In Windows, the Windows agents did not answer. $TIMEOUT_TAIL"
}

@test "panel words: a wrong answer says what is wrong and to set Windows up again" {
  run panel_words setup '{"ok":false,"step":"5","reason":"mismatch","message":"UNTRUSTED"}'
  assert_output 'The display driver in Windows needs an update. Shut Windows down, then click Continue setup to set up Windows again.'
  run panel_words setup '{"ok":false,"step":"5","reason":"allowlist","message":"UNTRUSTED"}'
  assert_output 'The QEMU guest agent in Windows is missing its allow-list. Shut Windows down, then click Continue setup to set up Windows again.'
}

@test "panel: the step 6 wait line names the scale task only while step 6 waits for it" {
  local fd
  ST=active
  state '{"snapshot":"declined","step5":true}'
  echo '{"setup":false}' >"$S/boot.json"
  panel_result_write setup '{"command":"setup","started":1,"reply":{"ok":true,"step":"6"}}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'Windows is starting or being checked.'
  # The other checks passed, and the setup job waits for the scale task.
  checks_passed
  run cmd_panel
  exec {fd}>&-
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'Waiting for the display scale task. If Windows is at its sign-in screen, or another user is signed in, sign in as the Windows user who ran setup.'
  # With no setup job running, nothing waits: Continue setup checks again.
  run cmd_panel
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'Click Continue setup so Lanai can check Windows.'
}

@test "panel: a step 6 time-out with Windows on offers Continue setup and shows the time-out words" {
  ST=active
  state '{"snapshot":"declined","step5":true}'
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  client_active() { return 0; }
  timeout_record agents "the SPICE agent" "the QEMU guest agent"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.step <<<"$output")" 6
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  assert_equal "$(jq -r .result.setup <<<"$output")" "In Windows, the SPICE agent and the QEMU guest agent did not answer. $TIMEOUT_TAIL"
  assert_equal "$(jq -c '[.buttons.continue_setup.show, .buttons.continue_setup.enable, .buttons.continue_setup.label]' <<<"$output")" '[true,true,"Continue setup"]'
  # The display buttons wait for Windows to shut down.
  assert_equal "$(jq -r '.buttons.window.show or .buttons.no_window.show' <<<"$output")" false
}

@test "panel: a step 6 time-out with Windows off offers Continue setup and both display buttons, with no arming" {
  local reason
  for reason in qmp guest-boot window-closed idd-missing agents scale-task; do
    ST=inactive
    state '{"snapshot":"declined","step5":true}'
    timeout_record "$reason" "the SPICE agent"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.step <<<"$output")" 6
    assert_equal "$(jq -r .setup.finished <<<"$output")" false
    [[ $(jq -r .result.setup <<<"$output") == ?*" $TIMEOUT_TAIL"* ]] || fail "$reason: $(jq -r .result.setup <<<"$output")"
    assert_equal "$(jq -c '[.buttons.continue_setup.show, .buttons.continue_setup.enable]' <<<"$output")" '[true,true]'
    assert_equal "$(jq -c '[.buttons.window.show, .buttons.window.enable, .buttons.no_window.show, .buttons.no_window.enable]' <<<"$output")" '[true,true,true,true]'
    # Each display button repeats the Windows install: setup's plan takes
    # the setup boot for either explicit choice.
    assert_equal "$(setup_plan "$(shared_facts)" true | jq -r '.step + " " + .action')" '5 setup-boot'
    assert_equal "$(setup_plan "$(shared_facts)" false | jq -r '.step + " " + .action')" '5 setup-boot'
  done
}

@test "panel: a step 6 failure that is not a time-out keeps its words and buttons, without the display buttons" {
  local reply
  ST=inactive
  state '{"snapshot":"declined","step5":true}'
  for reply in '{"ok":false,"step":"6","reason":"client"}' '{"ok":false,"step":"6","message":"Lanai could not open the Windows window to check the display driver."}'; do
    panel_result_write setup "$(jq -nc --argjson r "$reply" '{command:"setup",started:1,ended:2,reply:$r}')"
    run cmd_panel
    assert_success
    assert [ -n "$(jq -r .result.setup <<<"$output")" ]
    assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" true
    assert_equal "$(jq -r '.buttons.window.show or .buttons.no_window.show' <<<"$output")" false
  done
  # A time-out from an earlier step 6 is over once the plan moved on.
  state '{"snapshot":"declined","step5":false}'
  timeout_record agents "the SPICE agent"
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 5
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  # A setup started over, at step 3, shows no display buttons for it.
  state '{}'
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 3
  assert_equal "$(jq -r '.buttons.window.show or .buttons.no_window.show' <<<"$output")" false
}

@test "panel: a wrong answer's words show while Windows runs and after it shuts down, with Continue setup" {
  local reason reply
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  client_active() { return 0; }
  for reason in mismatch allowlist; do
    ST=active
    state '{"snapshot":"declined","step5":true}'
    reply=$(setup_back5 "$reason" 'UNTRUSTED') || true
    panel_result_write setup "$(jq -nc --argjson r "$reply" '{command:"setup",started:1,ended:2,reply:$r}')"
    run cmd_panel
    assert_equal "$(jq -r .setup.step <<<"$output")" 5
    assert_equal "$(jq -r .result.setup <<<"$output")" "$(panel_words setup "$reply")"
    ST=inactive
    run cmd_panel
    assert_equal "$(jq -r .setup.step <<<"$output")" 5
    assert_equal "$(jq -r .result.setup <<<"$output")" "$(panel_words setup "$reply")"
    assert_equal "$(jq -c '[.buttons.continue_setup.show, .buttons.continue_setup.enable]' <<<"$output")" '[true,true]'
  done
}

@test "panel settings: running save words clear once the unit is no longer active, even with its invocation" {
  panel_result_write settings '{"command":"settings","invocation":"inv","ended":1,"reply":{"ok":true,"scale_saved":true,"running":true,"scale_task_kind":"new"}}'
  ST=active INV=inv
  run cmd_panel
  assert_output --partial 'within 5 seconds'
  # A failed unit keeps its InvocationID.
  ST=failed RESULT=exit-code INV=inv
  run cmd_panel
  assert_equal "$(jq -r .result.settings <<<"$output")" ''
}

@test "panel settings: the view names memory and cores, and the scale note follows the task and the VM" {
  local note='Saving a scale replaces one you picked in Windows.'
  local old='Scale saves apply the next time Windows starts. To make them apply while Windows runs,'
  # A first setup that has not finished: no note.
  state '{}'
  run cmd_panel
  assert_equal "$(jq -r .settings.line <<<"$output")" 'Memory and cores apply the next time Windows starts.'
  assert_equal "$(jq -r .settings.note <<<"$output")" ''
  # The old task on a finished install: the resize warning names Run setup
  # again with the scale fix, so the note under the scale list is empty.
  state '{"done":true}'
  run cmd_panel
  assert_equal "$(jq -r .settings.note <<<"$output")" ''
  assert_output --partial 'Scale saves apply only the next time Windows starts.'
  # While an update step waits, the warning is not shown: a standing note
  # says how to get live saves, stopped and running, with the button that
  # shows for the unfinished plan.
  build_stamp_current() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .setup.finished <<<"$output")" false
  assert_equal "$(jq -r .warning <<<"$output")" ''
  assert_equal "$(jq -r .settings.note <<<"$output")" "$old click Continue setup."
  ST=active
  run cmd_panel
  assert_equal "$(jq -r .settings.note <<<"$output")" "$old shut Windows down and click Continue setup."
  build_stamp_current() { return 0; }
  # The new task: the pick note only while Windows runs.
  state "$CURRENT"
  run cmd_panel
  assert_equal "$(jq -r .settings.note <<<"$output")" "$note"
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .settings.note <<<"$output")" ''
}

@test "panel settings: save words clear once the VM's invocation differs from the record's" {
  local reply='{"ok":true,"scale_saved":true,"running":true,"scale_task_kind":"new"}'
  panel_result_write settings "{\"command\":\"settings\",\"invocation\":\"inv\",\"ended\":1,\"reply\":$reply}"
  ST=active INV=inv
  run cmd_panel
  assert_output --partial 'within 5 seconds'
  INV=other-inv
  run cmd_panel
  assert_equal "$(jq -r .result.settings <<<"$output")" ''
  # A save while stopped holds until the next start.
  panel_result_write settings '{"command":"settings","invocation":"","ended":1,"reply":{"ok":true,"scale_saved":true,"running":false,"scale_task_kind":"new"}}'
  ST=inactive INV=''
  run cmd_panel
  assert_equal "$(jq -r .result.settings <<<"$output")" 'Saved. Changes apply the next time Windows starts.'
  ST=active INV=next-inv
  run cmd_panel
  assert_equal "$(jq -r .result.settings <<<"$output")" ''
  # A refused save keeps its words.
  panel_result_write settings '{"command":"settings","invocation":"","ended":1,"reply":{"ok":false}}'
  run cmd_panel
  assert_output --partial 'Settings could not be saved'
}

@test "panel scale: invalid persisted scale shows a settings error" {
  local value
  for value in null true '"125"' '{}' '[]' 275 125.5; do
    jq --argjson v "$value" '.windows_scale=$v' "$(settings_file)" >"$T/settings"
    mv "$T/settings" "$(settings_file)"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r '.settings.error != ""' <<<"$output")" true
    assert_equal "$(jq -r .buttons.save_settings.enable <<<"$output")" false
  done
}

@test "redesign snapshots: UTC rows are newest first and keep restore names" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  local root name
  root=$(data_dir)/snapshots
  for name in 20260902T070500Z 20261012T091200Z 20260930T184700Z 20260230T091200Z 20260228T240000Z; do
    display_snapshot "$root/$name"
  done
  export TZ=Pacific/Honolulu LC_TIME=C.utf8
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.snapshots.items | map(.name)' <<<"$output")" '["20261012T091200Z","20260930T184700Z","20260902T070500Z","20260230T091200Z","20260228T240000Z"]'
  assert_equal "$(jq -r '.snapshots.items[0].date' <<<"$output")" 'Oct 12, 2026'
  assert_equal "$(jq -r '.snapshots.items[0].time' <<<"$output")" '09:12 UTC'
  assert_equal "$(jq -r '.snapshots.items[0].label' <<<"$output")" 'Oct 12, 2026 at 09:12 UTC'
  assert_equal "$(jq -r '.snapshots.items[0].restore_label' <<<"$output")" 'Restore Oct 12, 2026 at 09:12 UTC'
  assert_equal "$(jq -r '.snapshots.items[0].confirm_label' <<<"$output")" 'Restore now: Oct 12, 2026 at 09:12 UTC and replace Windows'
  assert_equal "$(jq -r '.snapshots.items[0].warning' <<<"$output")" 'Changes since this snapshot are lost.'
  assert_equal "$(jq -c '.snapshots.items[-2] | [.date,.time,.label]' <<<"$output")" '[null,null,"20260230T091200Z"]'
  assert_equal "$(jq -c '.snapshots.items[-1] | [.date,.time,.label]' <<<"$output")" '[null,null,"20260228T240000Z"]'
  assert_equal "$(jq -r '.buttons.restore_snapshot.labels["20261012T091200Z"]' <<<"$output")" 'Restore snapshot 20261012T091200Z'
  run cmd_snapshots
  assert_success
  assert_equal "$(jq -r '.snapshots[0] | split("/")[-1]' <<<"$output")" 20260228T240000Z
}

@test "redesign snapshots: running guidance is brief and saved details can be disclosed" {
  state '{"snapshot":"declined","done":true}'
  panel_result_write snapshots '{"command":"snapshot","ended":1,"reply":{"ok":true,"snapshot":"/copy"}}'
  ST=active
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .snapshots.line <<<"$output")" 'Shut down Windows to take a snapshot.'
  # The list already shows the new snapshot first: no separate summary line.
  assert_equal "$(jq -r '.snapshots.saved | has("summary")' <<<"$output")" false
  assert_equal "$(jq -r .snapshots.saved.show_label <<<"$output")" 'Show details'
  assert_equal "$(jq -r .snapshots.saved.hide_label <<<"$output")" 'Hide details'
  assert_equal "$(jq -r .snapshots.saved.path <<<"$output")" '/copy'
  assert_equal "$(jq -r .snapshots.saved.path_line <<<"$output")" 'Snapshot saved at /copy'
  assert_equal "$(jq -r .snapshots.saved.advice <<<"$output")" 'It shares disk space at first and grows as Windows changes. To delete it, use Delete beside the snapshot below.'
  assert_equal "$(jq -r .snapshots.saved.copy_label <<<"$output")" 'Copy snapshot path'
  ST=inactive
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .snapshots.line <<<"$output")" 'No snapshots yet.'
}

@test "snapshot deletion: running view offers a named action and unfinished restores disable it" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  local snap fd
  snap="$(data_dir)/snapshots/20261012T091200Z"
  display_snapshot "$snap"
  state '{"snapshot":"taken","done":true}'
  ST=active
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '[.buttons.delete_snapshot.show,.buttons.delete_snapshot.enable,.buttons.delete_confirm.enable]' <<<"$output")" '[true,true,true]'
  # The rows show these words; the item labels name the target.
  assert_equal "$(jq -c '[.buttons.delete_snapshot.label,.buttons.delete_confirm.label,.buttons.restore_snapshot.label]' <<<"$output")" '["Delete","Delete snapshot","Restore"]'
  assert_equal "$(jq -r .snapshots.items[0].delete_label <<<"$output")" 'Delete Oct 12, 2026 at 09:12 UTC'
  assert_equal "$(jq -r .snapshots.items[0].delete_confirm_label <<<"$output")" 'Delete snapshot: Oct 12, 2026 at 09:12 UTC, permanently'
  assert_equal "$(jq -r .snapshots.items[0].delete_warning <<<"$output")" 'Windows stays as it is.'
  assert_equal "$(jq -r .snapshots.line <<<"$output")" 'Shut down Windows to take or restore snapshots.'
  # Another VM blocks taking and restoring, but deletion still works.
  ST=inactive
  container_fact() { echo running; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .state <<<"$output")" in-use
  assert_equal "$(jq -r .snapshots.line <<<"$output")" 'Stop the other VM to take or restore snapshots.'
  assert_equal "$(jq -c '[.buttons.take_snapshot.enable,.buttons.restore_snapshot.enable,.buttons.delete_snapshot.enable,.buttons.delete_confirm.enable]' <<<"$output")" '[false,false,true,true]'
  container_fact() { echo none; }
  printf '%s\n%s\n' "$snap" "$STORE" >"$S/restore-in-progress"
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '[.buttons.delete_snapshot.show,.buttons.delete_snapshot.enable,.buttons.delete_confirm.enable]' <<<"$output")" '[true,false,false]'
  rm "$S/restore-in-progress"
  exec {fd}>"$S/panel-job.lock"
  flock -n "$fd"
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '[.buttons.delete_snapshot.enable,.buttons.delete_confirm.enable]' <<<"$output")" '[false,false]'
  exec {fd}>&-
}

@test "snapshot deletion: success is quiet and failures say what happened from structured job results" {
  state '{"snapshot":"taken","done":true}'
  # The row going away shows the result.
  panel_result_write snapshots '{"command":"delete-snapshot","ended":2,"reply":{"ok":true,"name":"20261012T091200Z"}}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .result.snapshots <<<"$output")" ''
  panel_result_write snapshots '{"command":"delete-snapshot","ended":3,"reply":{"ok":false,"reason":"snapshot-delete-failed","remaining":true}}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .result.snapshots <<<"$output")" 'Could not delete the snapshot. It is still listed and can be restored. Check the Jobs log and try again.'
}

@test "snapshot deletion: each failure reason has its own words, naming the Jobs log" {
  local reply
  while IFS='|' read -r reply words; do
    run panel_words delete-snapshot "$reply"
    assert_success
    assert_equal "$output" "$words"
  done <<'WORDS'
{"ok":false,"reason":"snapshot-delete-failed","remaining":true}|Could not delete the snapshot. It is still listed and can be restored. Check the Jobs log and try again.
{"ok":false,"reason":"snapshot-delete-failed","remaining":false}|Could not remove every file of the snapshot. It is no longer listed and cannot be restored. Check the Jobs log.
{"ok":false,"reason":"snapshot-not-found"}|That snapshot was already deleted.
{"ok":false,"reason":"restore-pending"}|Finish the unfinished restore before deleting a snapshot.
{"ok":false,"reason":"busy"}|Another operation is running. Try deleting the snapshot when it finishes.
{"ok":false,"reason":"manager"}|Lanai cannot reach your session services. Check the Jobs log and try again.
{"ok":false}|Lanai could not delete the snapshot. Check the Jobs log and try again.
{"ok":false,"reason":"storage"}|Lanai could not delete the snapshot. Check the Jobs log and try again.
{"ok":true,"name":"20261012T091200Z"}|
WORDS
}

@test "snapshot deletion: interrupted job names deletion without claiming the restore point survived" {
  state '{"snapshot":"taken","done":true}'
  panel_result_write snapshots '{"command":"delete-snapshot","started":1,"args":["20261012T091200Z"]}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .result.snapshots <<<"$output")" 'Snapshot deletion was interrupted. Check whether the snapshot is still listed before trying again.'
  refute_output --partial 'Setup was interrupted'
}

@test "redesign snapshots: counts exclude partial, foreign and invalid snapshots" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  local root
  root=$(data_dir)/snapshots
  display_snapshot "$root/20261012T091200Z"
  display_snapshot "$STORE.lanai-snapshots/20261012T091200Z"
  display_snapshot "$root/20261013T091200Z.partial"
  display_snapshot "$root/20261014T091200Z"
  echo "$T/foreign" >"$root/20261014T091200Z/SOURCE"
  display_snapshot "$root/20261015T091200Z"
  rm "$root/20261015T091200Z/COMPLETE"
  display_snapshot "$root/20261016T091200Z"
  echo extra >"$root/20261016T091200Z/extra"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .snapshots.count <<<"$output")" 1
  assert_equal "$(jq -c '.snapshots.items | map(.name)' <<<"$output")" '["20261012T091200Z"]'
  assert_equal "$(snapshot_find "$STORE" 20261012T091200Z)" "$(snapshot_list "$STORE" | head -n 1)"
}

# Write a display snapshot <name> with the saved label <label>.
labeled_snapshot() {
  display_snapshot "$(data_dir)/snapshots/$1"
  printf '%s\n' "$2" >"$(data_dir)/snapshots/$1/LABEL"
}

@test "snapshot names: a saved label joins its UTC date in every action wording" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  state "$CURRENT"
  labeled_snapshot 20261012T091200Z 'Before ${HOME} $(id) ../x'
  display_snapshot "$(data_dir)/snapshots/20261011T080000Z"
  export TZ=Pacific/Honolulu LC_TIME=C.utf8
  run cmd_panel
  assert_success
  local item legacy
  item=$(jq -c '.snapshots.items[0]' <<<"$output") legacy=$(jq -c '.snapshots.items[1]' <<<"$output")
  local when='Oct 12, 2026 at 09:12 UTC' full='“Before ${HOME} $(id) ../x” from Oct 12, 2026 at 09:12 UTC'
  assert_equal "$(jq -c '[.name,.user_label,.date,.time,.label]' <<<"$item")" \
    "$(jq -nc --arg w "$when" '["20261012T091200Z","Before ${HOME} $(id) ../x","Oct 12, 2026","09:12 UTC",$w]')"
  assert_equal "$(jq -r .full_label <<<"$item")" "$full"
  assert_equal "$(jq -r .restore_label <<<"$item")" "Restore $full"
  assert_equal "$(jq -r .confirm_label <<<"$item")" "Restore now: $full and replace Windows"
  assert_equal "$(jq -r .confirm_note <<<"$item")" "Restore this snapshot and replace Windows?"
  assert_equal "$(jq -r .delete_label <<<"$item")" "Delete $full"
  assert_equal "$(jq -r .delete_confirm_label <<<"$item")" "Delete snapshot: $full, permanently"
  assert_equal "$(jq -r .delete_confirm_note <<<"$item")" "Delete this snapshot permanently?"
  # The UTC identifier stays the action target.
  assert_equal "$(jq -c '.snapshots.names | sort' <<<"$output")" '["20261011T080000Z","20261012T091200Z"]'
  assert_equal "$(jq -r '.buttons.restore_snapshot.labels["20261012T091200Z"]' <<<"$output")" 'Restore snapshot 20261012T091200Z'
  # Legacy rows keep their wording.
  assert_equal "$(jq -c '[.user_label,.full_label,.confirm_label,.delete_label]' <<<"$legacy")" \
    '[null,"Oct 11, 2026 at 08:00 UTC","Restore now: Oct 11, 2026 at 08:00 UTC and replace Windows","Delete Oct 11, 2026 at 08:00 UTC"]'
}

@test "snapshot names: equal labels in one displayed minute show seconds in rows and restore status" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  state "$CURRENT"
  labeled_snapshot 20261012T091200Z Same
  labeled_snapshot 20261012T091245Z Same
  labeled_snapshot 20261012T091230Z Other
  labeled_snapshot 20261012T091300Z Same
  display_snapshot "$(data_dir)/snapshots/20261012T091210Z"
  display_snapshot "$(data_dir)/snapshots/20261012T091220Z"
  export TZ=Pacific/Honolulu LC_TIME=C.utf8
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.snapshots.items | map([.name,.time])' <<<"$output")" \
    '[["20261012T091300Z","09:13 UTC"],["20261012T091245Z","09:12:45 UTC"],["20261012T091230Z","09:12 UTC"],["20261012T091220Z","09:12 UTC"],["20261012T091210Z","09:12 UTC"],["20261012T091200Z","09:12:00 UTC"]]'
  local first
  first=$(jq -c '.snapshots.items[] | select(.name == "20261012T091245Z")' <<<"$output")
  assert_equal "$(jq -r .label <<<"$first")" 'Oct 12, 2026 at 09:12:45 UTC'
  assert_equal "$(jq -r .restore_label <<<"$first")" 'Restore “Same” from Oct 12, 2026 at 09:12:45 UTC'
  assert_equal "$(jq -r .confirm_label <<<"$first")" 'Restore now: “Same” from Oct 12, 2026 at 09:12:45 UTC and replace Windows'
  assert_equal "$(jq -r .delete_label <<<"$first")" 'Delete “Same” from Oct 12, 2026 at 09:12:45 UTC'
  assert_equal "$(jq -r .delete_confirm_label <<<"$first")" 'Delete snapshot: “Same” from Oct 12, 2026 at 09:12:45 UTC, permanently'
  printf '%s\n%s\n' "$(data_dir)/snapshots/20261012T091200Z" "$STORE" >"$S/restore-in-progress"
  run cmd_panel
  assert_equal "$(jq -r .restore.label <<<"$output")" 'Unfinished restore of “Same” from Oct 12, 2026 at 09:12:00 UTC'
  local fd
  exec {fd}>"$S/lock"
  flock -n "$fd"
  jq -nc --argjson p "$BASHPID" '{operation:"restore",phase:"checking",done:0,total:0,pid:$p,target:"20261012T091245Z"}' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r .restore.label <<<"$output")" 'Restoring “Same” from Oct 12, 2026 at 09:12:45 UTC'
  exec {fd}>&-
}

@test "snapshot names: a failed label reader keeps every row, unlabeled and restorable" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  state "$CURRENT"
  labeled_snapshot 20261012T091200Z Kept
  python3() { [[ $1 != */snapshot-label.py ]] || return 1; command python3 "$@"; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.snapshots.items | map([.name,has("user_label"),.user_label])' <<<"$output")" '[["20261012T091200Z",true,null]]'
  assert_equal "$(jq -c '[.buttons.restore_snapshot.show,.buttons.restore_snapshot.enable,.buttons.delete_snapshot.enable]' <<<"$output")" '[true,true,true]'
}

# Write the snapshots group's record for token <token> and reply <json>.
snapshot_job() {
  panel_result_write snapshots "$(jq -nc --arg t "$1" --argjson r "$2" '{token:$t,command:"snapshot",args:["a<b"],started:1,ended:2,reply:$r}')"
}

@test "snapshot names: an invalid-label refusal reaches only its field, in daily and setup layouts" {
  local reply layout
  reply=$(cmd_snapshot 'a<b') || true
  assert_equal "$(jq -c '[.reason,.rule]' <<<"$reply")" '["invalid-label","angle-bracket"]'
  for layout in setup daily; do
    [[ $layout == setup ]] || state "$CURRENT"
    snapshot_job "$layout-field" "$reply"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .layout <<<"$output")" "$layout"
    assert_equal "$(jq -r .result.snapshots <<<"$output")" ''
    assert_equal "$(jq -r .sections.default <<<"$output")" ''
    [[ $(jq -r .bar.mode <<<"$output") != failed ]] || fail "the bar shows Failed"
    [[ $(jq -r .header.badge <<<"$output") != Failed ]] || fail "the badge shows Failed"
    assert_equal "$(jq -c .snapshots.job <<<"$output")" \
      "{\"token\":\"$layout-field\",\"ended\":true,\"ok\":false,\"message\":\"Remove < and >.\"}"
  done
  # The daily view shows a Snapshots result note only for other failures.
  run panel_words snapshot "$reply"
  assert_output ''
  snapshot_job other '{"ok":false,"message":"UNTRUSTED"}'
  run cmd_panel
  assert_equal "$(jq -r .layout <<<"$output")" failed
  assert_equal "$(jq -r .result.snapshots <<<"$output")" 'Lanai could not take the snapshot. Check the snapshot log and try again.'
  assert_equal "$(jq -c '.snapshots.job | [.token,.ok,.message]' <<<"$output")" '["other",false,""]'
}

@test "snapshot names: a snapshot job's token and outcome show in daily and setup layouts" {
  local layout fd
  for layout in setup daily; do
    [[ $layout == setup ]] || state "$CURRENT"
    snapshot_job "$layout-ok" '{"ok":true,"snapshot":"/copy","name":"20261012T091200Z","label":"a"}'
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .layout <<<"$output")" "$layout"
    assert_equal "$(jq -c .snapshots.job <<<"$output")" "{\"token\":\"$layout-ok\",\"ended\":true,\"ok\":true,\"message\":\"\"}"
  done
  exec {fd}>"$S/panel-job.lock"
  flock -n "$fd"
  panel_result_write snapshots '{"token":"running","command":"snapshot","args":[],"started":1}'
  run cmd_panel
  assert_equal "$(jq -c '.snapshots.job | [.token,.ended,.ok]' <<<"$output")" '["running",false,null]'
  exec {fd}>&-
  panel_result_write snapshots '{"token":"gone","command":"delete-snapshot","args":["20261012T091200Z"],"started":1,"ended":2,"reply":{"ok":true}}'
  run cmd_panel
  assert_equal "$(jq -c .snapshots.job <<<"$output")" null
}

@test "redesign restore: marker supplies the target without a panel job" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  local snap fd job_fd pid=$BASHPID
  snap=$(data_dir)/snapshots/20261012T091200Z
  display_snapshot "$snap"
  printf '%s\n%s\n' "$snap" "$STORE" >"$S/restore-in-progress"
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.restore | [.pending,.name,.label,.warning]' <<<"$output")" '[true,"20261012T091200Z","Unfinished restore of Oct 12, 2026 at 09:12 UTC","Keep Windows stopped until the restore finishes."]'
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
  exec {fd}>"$S/lock"
  flock -n "$fd"
  jq -nc --argjson p "$pid" '{operation:"restore",phase:"checking",done:0,total:0,pid:$p}' >"$S/image-progress.json"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .restore.label <<<"$output")" 'Restoring Oct 12, 2026 at 09:12 UTC'
  assert_equal "$(jq -r .bar.mode <<<"$output")" busy
  assert_equal "$(jq -r .header.meta <<<"$output")" '8 GiB · 4 cores · Auto'
  display_snapshot "$(data_dir)/snapshots/20261013T101500Z"
  exec {job_fd}>"$S/panel-job.lock"
  flock -n "$job_fd"
  panel_result_write snapshots '{"command":"restore","args":["20261013T101500Z"],"started":1}'
  run cmd_panel
  assert_equal "$(jq -r .restore.name <<<"$output")" 20261013T101500Z
  jq '.target="20261012T091200Z"' "$S/image-progress.json" >"$T/progress"
  mv "$T/progress" "$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r .restore.name <<<"$output")" 20261012T091200Z
  rm "$S/image-progress.json"
  panel_result_write snapshots '{"command":"restore","args":[],"started":1}'
  run cmd_panel
  assert_equal "$(jq -r .restore.name <<<"$output")" 20261012T091200Z
  panel_result_write snapshots '{"command":"restore","args":["missing"],"started":1}'
  run cmd_panel
  assert_equal "$(jq -r .restore.name <<<"$output")" null
  panel_result_write snapshots '{"command":"restore","args":["20261013T101500Z"],"started":1,"ended":2}'
  rm "$S/restore-in-progress"
  run cmd_panel
  assert_equal "$(jq -c '.restore | [.pending,.name,.label,.warning]' <<<"$output")" '[false,null,"",""]'
  exec {job_fd}>&-
  exec {fd}>&-
}

@test "redesign restore: invalid or foreign targets use generic wording" {
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  local snap fd pid=$BASHPID
  snap=$(data_dir)/snapshots/20261012T091200Z
  display_snapshot "$snap"
  printf '%s\n%s\n' "$snap" "$T/foreign" >"$S/restore-in-progress"
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.restore | [.name,.label]' <<<"$output")" '[null,"Unfinished restore"]'
  printf '%s\n%s\n' "$snap" "$STORE" >"$S/restore-in-progress"
  rm "$snap/COMPLETE"
  run cmd_panel
  assert_equal "$(jq -c '.restore | [.name,.label]' <<<"$output")" '[null,"Unfinished restore"]'
  rm "$S/restore-in-progress"
  exec {fd}>"$S/lock"
  flock -n "$fd"
  jq -nc --argjson p "$pid" '{operation:"restore",phase:"hashing",done:0,total:100,pid:$p,target:"20261012T091200Z"}' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -c '.restore | [.name,.label]' <<<"$output")" '[null,"Restoring Windows"]'
  exec {fd}>&-
}

@test "redesign progress: accepted totals distinguish unmeasured work from zero percent hashing" {
  local fd pid=$BASHPID total
  exec {fd}>"$S/lock"
  flock -n "$fd"
  for total in 0 100; do
    jq -nc --argjson p "$pid" --argjson t "$total" '{operation:"snapshot",phase:(if $t == 0 then "checking" else "hashing" end),done:0,total:$t,pid:$p}' >"$S/image-progress.json"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .progress.operation <<<"$output")" snapshot
    assert_equal "$(jq -r .progress.total <<<"$output")" "$total"
    assert_equal "$(jq -r .progress.percent <<<"$output")" 0
  done
  exec {fd}>&-
}

# Leave a stopped setup boot's evidence; a panel request is clean but incomplete.
ended() {
  printf inv >"$S/running"
  printf inv >"$S/started"
  echo '{"invocation":"inv","guest":true}' >"$S/last-shutdown"
  echo '{"setup":true}' >"$S/boot.json"
  [[ ${1:-clean} != panel ]] || echo 'inv 1' >"$S/stop-requested"
  [[ ${1:-clean} != forced ]] || : >"$S/forced"
}

# Compare the decision with the observable action/reply, not just its step.
assert_plan_agreement() {
  local plan=$1 reply=$2 action step
  case $reply in
    build) action=build; step=4 ;;
    setup-boot) action="setup-boot"; step=5 ;;
    normal-boot) action="normal-boot"; step=6 ;;
    *)
      step=$(jq -r .step <<<"$reply")
      assert_equal "$(jq -r '.reason // ""' <<<"$reply")" "$(jq -r .reason <<<"$plan")"
      case $step in
        1) action=problem ;;
        2) action=packages ;;
        3) action=snapshot ;;
        3a) action=base ;;
        5)
          if jq -e '.ok' <<<"$reply" >/dev/null; then action="setup-wait"
          elif jq -e '(.choices // [] | length) > 0' <<<"$reply" >/dev/null; then action=choices
          else action=problem; fi ;;
        6)
          if jq -e '.reason != null' <<<"$reply" >/dev/null; then action=problem
          else action=$(jq -r '.test_action // "wait"' <<<"$reply"); fi ;;
        7) action="done" ;;
      esac ;;
  esac
  assert_equal "$step" "$(jq -r .step <<<"$plan")"
  assert_equal "$action" "$(jq -r .action <<<"$plan")"
}

@test "panel: every status state has plain words and the full view" {
  local fixture_facts expected
  state "$CURRENT"
  for expected in not-installed setup-needed stopped starting running stopping in-use version-mismatch failed; do
    case $expected in
      not-installed) fixture_facts=$'ActiveState=inactive\nLanaiInstall=none' ;;
      setup-needed) fixture_facts=$'ActiveState=inactive\nLanaiSetup=needed' ;;
      stopped) fixture_facts=$'ActiveState=inactive\nLanaiSetup=done' ;;
      starting) fixture_facts='ActiveState=activating' ;;
      running) fixture_facts=$'ActiveState=active\nLanaiSetup=done\nLanaiQmp=running\nLanaiQga=open' ;;
      stopping) fixture_facts='ActiveState=deactivating' ;;
      in-use) fixture_facts=$'ActiveState=inactive\nLanaiContainer=running' ;;
      version-mismatch) fixture_facts=$'ActiveState=active\nLanaiSetup=done\nLanaiVersion=mismatch' ;;
      failed) fixture_facts=$'ActiveState=failed\nResult=exit-code' ;;
    esac
    status_facts() { printf '%s\n' "$fixture_facts"; }
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .state <<<"$output")" "$expected"
    case $expected in
      not-installed|in-use|version-mismatch) assert_equal "$(jq -r .bar.mode <<<"$output")" attention ;;
      setup-needed) assert_equal "$(jq -r .bar.mode <<<"$output")" stopped ;;
      starting|running|stopping) assert_equal "$(jq -r .bar.mode <<<"$output")" active ;;
      *) assert_equal "$(jq -r .bar.mode <<<"$output")" "$expected" ;;
    esac
    assert_equal "$(jq -r '[.label,.headline,.cause,.next,.notice,.warning,.busy,.buttons,.setup,.result,.settings,.snapshots,.logs] | length' <<<"$output")" 13
    case $expected in
      stopped) assert_right_click start ;;
      running) assert_right_click open ;;
      *) assert_right_click panel ;;
    esac
    # The journal command belongs only to the clipboard payload.
    assert_equal "$(jq 'del(.logs.rows[].copy_text) | tostring | contains("journalctl")' <<<"$output")" false
    refute_output --partial '—'
  done
}

@test "panel: finished setup offers both repair displays with labels and hints" {
  state '{"snapshot":"declined","done":true}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Run setup again'
  assert_equal "$(jq -c .setup.choices <<<"$output")" '["--no-window","--window"]'
  assert_equal "$(jq -r .buttons.no_window.label <<<"$output")" 'Set up in the Windows window'
  assert_equal "$(jq -r .buttons.window.label <<<"$output")" 'Set up in a basic window'
  run jq -e 'all(.buttons.no_window, .buttons.window; .show and .enable and (.hint | length > 0))' <<<"$output"
  assert_success
}

@test "panel words: failed snapshot decision is actionable while the offer stays silent" {
  run panel_words setup '{"ok":false,"reason":"record","message":"UNTRUSTED"}' 3
  assert_success
  assert_output 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue without a snapshot or take a snapshot again.'
  run panel_words setup '{"ok":false,"reason":"record","message":"UNTRUSTED"}' 5
  assert_output 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue setup.'
  state '{}'
  setup_set() { return 1; }
  run setup_resume auto true
  assert_failure
  assert_equal "$(jq 'has("step")' <<<"$output")" false
  assert_equal "$(jq -r .reason <<<"$output")" record
  panel_result_write setup "$(jq -nc --argjson r "$output" '{command:"setup",ended:1,reply:$r}')"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.step <<<"$output")" 3
  assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" false
  assert_equal "$(jq -r .buttons.skip_snapshot.show <<<"$output")" true
  assert_equal "$(jq -r .buttons.setup_snapshot.show <<<"$output")" true
  assert_equal "$(jq -r .result.setup <<<"$output")" 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue without a snapshot or take a snapshot again.'
  run panel_words setup '{"ok":false,"step":"3"}'
  assert_output ''
}

@test "panel: failed existing snapshot decision stays visible at steps 4 and 5 until the next setup action" {
  state '{}'
  snapshot_list() { echo "$T/snapshot"; }
  setup_set() { return 1; }
  local step attempt
  for step in 4 5; do
    build_stamp_current() { [[ $step == 5 ]]; }
    for attempt in 1 2; do
      run setup_resume auto false
      assert_failure
      assert_equal "$(jq 'has("step")' <<<"$output")" false
      assert_equal "$(jq -r .reason <<<"$output")" record
      assert_equal "$(jq -r '.snapshot // "unset"' "$S/setup.json")" unset
      panel_result_write setup "$(jq -nc --argjson r "$output" --argjson a "$attempt" '{command:"setup",ended:$a,reply:$r}')"
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.step <<<"$output")" "$step"
      assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" true
      assert_equal "$(jq -r .result.setup <<<"$output")" 'Lanai could not save the snapshot choice. Check that your home folder has free space, then click Continue setup.'
    done
  done
  run cmd_panel
  assert_output --partial 'Lanai could not save the snapshot choice.'
  panel_result_write setup '{"command":"setup","ended":3,"reply":{"ok":true,"step":"5"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
}

@test "setup plan: steps and acting resume agree before and after marker consumption" {
  local fixture markers planned acted
  for markers in present consumed; do
    for fixture in offer build boot clean panel forced nostart normalnostart normal failed-setup failed-normal "done" explicit; do
      rm -f "$S/"{running,started,forced,last-shutdown,stop-requested,boot.json}
      ST=inactive RESULT=success
      state '{"snapshot":"declined"}'
      build_stamp_current() { [[ $fixture != build ]]; }
      case $fixture in
        offer) state '{}' ;;
        clean|panel|forced|nostart) state '{"snapshot":"declined","step5":false}'; ended "$fixture"
          [[ $fixture != nostart ]] || rm "$S/started" ;;
        failed-setup|failed-normal)
          ST=failed RESULT=exit-code
          state '{"snapshot":"declined","step5":false}'
          [[ $fixture != failed-normal ]] || state '{"snapshot":"declined","step5":true}'
          ended; rm "$S/last-shutdown" ;;
        normal) state '{"snapshot":"declined","step5":true}' ;;
        normalnostart) state '{"snapshot":"declined","step5":true}'; echo inv >"$S/running" ;;
        done) state '{"snapshot":"declined","done":true}' ;;
        explicit) state '{"snapshot":"declined","done":true,"step5":false}' ;;
      esac
      [[ $markers != consumed ]] || record_previous_run >/dev/null
      planned=$(setup_plan "$(shared_facts)")
      # Only replace the active checks: all step selection remains real.
      setup_step6() { setup_reply true 6 waiting '' '{"test_action":"checks"}'; }
      acted=$(setup_resume auto false) || true
      assert_plan_agreement "$planned" "$acted"
      [[ $fixture != explicit ]] || assert_equal "$(jq -r .finished <<<"$planned")" false
    done
  done
}

@test "setup plan: changed storage and existing snapshots overlay without writes" {
  state '{"snapshot":"declined","step5":true,"done":true}'
  jq '.location="other"' "$S/setup.json" >"$S/new"; mv "$S/new" "$S/setup.json"
  snapshot_list() { echo "$T/snapshot"; }
  local before
  before=$(cat "$S/setup.json")
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .step <<<"$output")" 5
  assert_equal "$(cat "$S/setup.json")" "$before"
}

@test "setup plan: finished ignores missing share and container but requires stamp and closed round" {
  state '{"snapshot":"declined","done":true}'
  share_check() { echo missing; return 1; }
  container_fact() { echo running; }
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .finished <<<"$output")" true
  state '{"snapshot":"declined","done":true,"round":true}'
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .step <<<"$output")" 1
}

@test "setup plan: the scale wait follows step6-checked, and a RESET leaves step 6's records as they were" {
  ST=active
  state '{"snapshot":"declined","step5":true}'
  echo '{"setup":false}' >"$S/boot.json"
  checks_passed
  : >"$RUN/step6-stopped"
  : >"$RUN/step6-qmp-failed"
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -c '[.step, .action, .scale_wait]' <<<"$output")" '["6","checks",true]'
  # Windows restarts: the limits and markers stay, so the scale wait goes on.
  local before
  before=$(cd "$RUN" && ls && cat step6-since step6-checked)
  event_record '{"event":"RESET"}'
  assert_equal "$(cd "$RUN" && ls && cat step6-since step6-checked)" "$before"
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -c '[.step, .action, .scale_wait]' <<<"$output")" '["6","checks",true]'
  rm "$RUN/step6-checked"
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -c '[.step, .action, .scale_wait]' <<<"$output")" '["6","checks",null]'
  # A wrong answer moves the plan to step 5.
  setup_back5 allowlist 'The QEMU guest agent in Windows is missing its allow-list.' >/dev/null
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .step <<<"$output")" 5
}

@test "setup plan: a step6-checked that is not a number is not the scale wait" {
  ST=active
  state '{"snapshot":"declined","step5":true}'
  echo '{"setup":false}' >"$S/boot.json"
  local checked
  for checked in "" junk "1 boot-1" 12abc; do
    echo "$checked" >"$RUN/step6-checked"
    run setup_plan "$(shared_facts)"
    assert_equal "$(jq -c '[.step, .action, .scale_wait]' <<<"$output")" '["6","checks",null]'
  done
  checks_passed
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -c '[.step, .action, .scale_wait]' <<<"$output")" '["6","checks",true]'
}

@test "panel: stopping keeps Shut down enabled and only force_stop enables Force stop" {
  status_facts() { printf 'ActiveState=active\nLanaiStopAge=%s\n' "$age"; }
  local age
  for age in 1 120; do
    run cmd_panel
    assert_equal "$(jq -r .buttons.stop.enable <<<"$output")" true
    assert_equal "$(jq -r .buttons.force_stop.show <<<"$output")" "$([[ $age == 120 ]] && echo true || echo false)"
  done
}

@test "panel: restore pending overrides stopped setup and in-use guidance" {
  local fixture_status
  for fixture_status in stopped setup-needed in-use; do
    status_facts() { printf 'ActiveState=inactive\nLanaiRestorePending=true\n';
      [[ $fixture_status != stopped ]] || echo LanaiSetup=done
      [[ $fixture_status != in-use ]] || echo LanaiContainer=running; return 0; }
    run cmd_panel
    assert_equal "$(jq -r .buttons.start.enable <<<"$output")" false
    assert_equal "$(jq -r .buttons.finish_restore.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.finish_restore.enable <<<"$output")" "$([[ $fixture_status == in-use ]] && echo false || echo true)"
  done
}

@test "panel: setup reply is ignored and forced notice comes only from last-run" {
  ended forced
  run cmd_panel
  local before=$output
  echo '{"ok":true,"step":"7"}' >"$S/setup-reply.json"
  run cmd_panel
  assert_equal "$output" "$before"
  assert_equal "$(jq -r .notice <<<"$output")" ''
  echo forced >"$S/last-run"
  run cmd_panel
  assert_output --partial 'Windows was force-stopped'
}

@test "panel records: started following ended, interruption, launch timeout and read order" {
  local fd
  panel_result_write setup '{"token":"old","command":"setup","started":1}'
  run cmd_panel
  assert_equal "$(jq -r .busy.active <<<"$output")" false
  assert_output --partial 'interrupted'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  panel_result_write setup '{"token":"old","command":"setup","started":1,"reply":{"ok":true,"step":"6"}}'
  run cmd_panel
  assert_output --partial 'Checking Windows'
  exec {fd}>&-
  # Publish the end at the lock probe; it must be read afterwards.
  flock() { panel_result_write setup '{"token":"old","command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"7"}}'; command flock "$@"; }
  run cmd_panel
  refute_output --partial 'interrupted'
  run cmd_panel --pending never "$((EPOCHSECONDS - 11))"
  assert_output --partial 'did not start'
}

@test "panel words: failures, snapshot and restore outcomes persist but waits do not" {
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":true,"step":"5"}}'
  panel_result_write vm '{"command":"start","invocation":"old","ended":1,"reply":{"ok":true,"network":false}}'
  run cmd_panel
  assert_equal "$(jq -r '.result.setup + .result.vm' <<<"$output")" ''
  panel_result_write snapshots '{"command":"snapshot","ended":1,"reply":{"ok":true,"snapshot":"/copy"}}'
  run cmd_panel
  assert_output --partial 'grows as Windows changes'
  assert_output --partial 'use Delete beside the snapshot'
  panel_result_write snapshots '{"command":"restore","ended":1,"reply":{"ok":true}}'
  run cmd_panel
  assert_equal "$(jq -r .result.snapshots <<<"$output")" 'The snapshot was restored.'
  state '{"snapshot":"declined","done":true}'
  run cmd_panel
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .result.snapshots <<<"$output")" 'The snapshot was restored.'
  panel_result_write snapshots '{"command":"restore","ended":1,"reply":{"ok":false}}'
  run cmd_panel
  assert_output --partial 'could not restore'
  state '{"snapshot":"declined","step5":false}'
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"step":"5","reason":"idd-missing"}}'
  run cmd_panel
  assert_output --partial 'display driver'
}

@test "shared facts: builtin container scan recognizes both cgroups and skips active unit" {
  container_fact() { real_container_fact; }
  fake_proc 123 "$DOCKER_SCOPE" /usr/bin/qemu-system-x86_64
  run container_fact
  assert_output running
  fake_proc 123 /docker/abcdef /bin/bash /run/entry.sh
  run container_fact
  assert_output preparing
  container_fact() { echo preparing; touch "$T/scanned"; }
  ST=active
  run shared_facts
  refute_output --partial 'LanaiContainer=preparing'
  assert [ ! -e "$T/scanned" ]
}

@test "panel words: every reason and command branch uses structured keys, never CLI prose" {
  local reason command text
  for reason in busy session settings layout missing restore share container manager active record no-media nostart incomplete qmp guest-boot window-closed idd-missing mismatch allowlist agents scale-task client snapshot-unsupported invalid-reply; do
    text=$(panel_words setup "$(jq -nc --arg r "$reason" '{ok:false,step:"1",reason:$r,message:"UNTRUSTED",next:"UNTRUSTED"}')")
    assert [ -n "$text" ]
    refute [ "$text" = 'Setup could not finish. Check the setup log, then continue setup.' ]
    refute [ "$text" = UNTRUSTED ]
  done
  for command in start open stop force-stop notice-seen settings setup-host setup snapshot restore; do
    run panel_words "$command" '{"ok":false,"message":"UNTRUSTED","next":"UNTRUSTED"}'
    assert_success
    refute_output ''
    refute_output --partial UNTRUSTED
    run panel_words "$command" '{"ok":true,"step":"6"}'
    [[ $command == restore ]] || assert_output ''
  done
  run panel_words setup '{"ok":false,"step":"2","missing":["a"]}'
  assert_output ''
  run panel_words setup '{"ok":false,"step":"3"}'
  assert_output ''
}

@test "setup plan: each step and reason is detected; active setup skips container scan" {
  local fixture expected plan
  for fixture in settings layout restore share container manager packages snapshot base build setup-boot setup-wait scale-wait checking wait "done"; do
    ST=inactive
    state '{"snapshot":"declined"}'
    echo base >"$STORE/windows.base"
    rm -f "$S/restore-in-progress" "$S/boot.json" "$RUN/step6-checked"
    share_check() { return 0; }
    host_packages_missing() { :; }
    build_stamp_current() { return 0; }
    container_fact() { echo none; }
    local fixture_facts
    fixture_facts=$(shared_facts)
    case $fixture in
      settings|layout) expected=1; fixture_facts+=$'\nLanaiProblemReason='"$fixture" ;;
      restore) expected=1; fixture_facts+=$'\nLanaiRestorePending=true' ;;
      share) expected=1; share_check() { return 1; } ;;
      container) expected=1; fixture_facts+=$'\nLanaiContainer=preparing' ;;
      manager) expected=1; fixture_facts+=$'\nActiveState=unknown' ;;
      packages) expected=2; host_packages_missing() { echo package; } ;;
      snapshot) expected=3; state '{}' ;;
      base) expected=3a; rm "$STORE/windows.base" ;;
      build) expected=4; build_stamp_current() { return 1; } ;;
      setup-boot) expected=5 ;;
      setup-wait) expected=5; fixture_facts+=$'\nActiveState=active'; echo '{"setup":true}' >"$S/boot.json" ;;
      scale-wait|checking|wait) expected=6; state '{"snapshot":"declined","step5":true}'; fixture_facts+=$'\nActiveState=active'
        [[ $fixture != wait ]] || fixture_facts+=$'\nActiveState=activating'
        [[ $fixture != scale-wait ]] || checks_passed ;;
      done) expected=7; state "$CURRENT" ;;
    esac
    plan=$(setup_plan "$fixture_facts")
    assert_equal "$(jq -r .step <<<"$plan")" "$expected"
    if [[ $expected == 1 ]]; then assert_equal "$(jq -r .reason <<<"$plan")" "$fixture"; fi
  done
}

@test "panel: setup problem guidance comes from the current plan and completed setup survives in-use" {
  share_check() { return 1; }
  run cmd_panel
  assert_output --partial 'a real folder you own, not a link'
  state "$CURRENT"
  container_fact() { echo running; }
  run cmd_panel
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .state <<<"$output")" in-use
}

@test "panel: a matching no-network result shows only during its active invocation" {
  panel_result_write vm '{"command":"start","invocation":"inv","ended":1,"reply":{"ok":true,"network":false}}'
  ST=active
  run cmd_panel
  assert_output --partial 'without a network'
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .result.vm <<<"$output")" ''
  panel_result_write vm '{"command":"start","ended":1,"reply":{"ok":false}}'
  run cmd_panel
  assert_output --partial 'could not start'
}

@test "panel: a wait after Shut down and a setup failure after restore cannot revive old guidance" {
  state '{"snapshot":"declined","step5":false}'
  ended panel
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":true,"step":"5"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  assert_equal "$(jq -r .buttons.window.show <<<"$output")" true
  rm -f "$S/"{running,started,last-shutdown,stop-requested,setup.json}
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"step":"5","reason":"mismatch"}}'
  panel_result_write snapshots '{"command":"restore","ended":2,"reply":{"ok":true}}'
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 3
  assert_equal "$(jq -r .buttons.window.show <<<"$output")" false
  assert_output --partial 'restored'
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
}

@test "panel records: newest outstanding record owns progress, pending tokens do not time out after launch" {
  local fd
  panel_result_write setup '{"token":"old","command":"setup","started":1}'
  panel_result_write snapshots '{"token":"new","command":"restore","started":2}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel --pending new 1
  assert_output --partial 'Restoring Windows'
  refute_output --partial 'did not start'
  exec {fd}>&-
}

@test "panel records: each monitor acknowledges its launch before another replaces the group record" {
  local first=monitor-first second=monitor-second at
  at=$((EPOCHSECONDS - 11))
  run cmd_panel --pending "$first" "$at"
  assert_success
  assert_equal "$(jq -r .pending_ack <<<"$output")" ''
  assert_output --partial 'did not start'
  panel_result_write setup '{"token":"monitor-first","command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"7"}}'
  run cmd_panel --pending "$first" "$at"
  assert_success
  assert_equal "$(jq -r .pending_ack <<<"$output")" "$first"
  refute_output --partial 'did not start'
  # The renderer clears this monitor's pending token on acknowledgment.
  first=$(jq -r --arg t "$first" 'if .pending_ack == $t then "" else $t end' <<<"$output")
  panel_result_write setup '{"token":"monitor-second","command":"setup","started":3,"ended":4,"reply":{"ok":true,"step":"7"}}'
  run cmd_panel --pending "$second" "$at"
  assert_success
  assert_equal "$(jq -r .pending_ack <<<"$output")" "$second"
  refute_output --partial 'did not start'
  assert_equal "$first" ''
  run cmd_panel
  assert_success
  refute_output --partial 'did not start'
  # An unrelated launch still needs its own record; no blanket acknowledgment.
  run cmd_panel --pending never "$at"
  assert_output --partial 'did not start'
}

@test "client stamp: read-only stamp check does not execute binary and pruning removes stamps with builds" {
  unset -f build_stamp_current
  # Restore just the real function, keeping all fixtures isolated.
  source "$REPO/lib/client.sh"
  local d
  d=$(client_builds)/$LG_BUILD
  mkdir -p "$d/bin"
  printf '#!/bin/bash\ntouch "%s/executed"\n' "$T" >"$d/bin/looking-glass-client"
  chmod +x "$d/bin/looking-glass-client"
  run build_stamp_current
  assert_failure
  echo "$LG_BUILD" >"$d/build-stamp"
  run build_stamp_current
  assert_success
  assert [ ! -e "$T/executed" ]
  mkdir -p "$(client_builds)/old/bin"
  : >"$(client_builds)/old/build-stamp"
  guest_version_get() { echo "$LG_BUILD"; }
  builds_prune
  assert [ ! -e "$(client_builds)/old/build-stamp" ]
  rm "$d/build-stamp"
  run build_stamp_current
  assert_failure
}

@test "panel: helper client and old-driver warnings use status details from the same read" {
  # This override is called with the gathered facts by cmd_panel.
  # shellcheck disable=SC2120
  status_facts() { printf '%s\n' "$1" 'LanaiHelpersMissing=clock' 'LanaiClient=timeout' 'LanaiDriverOld=old'; }
  run cmd_panel
  assert_output --partial 'background services stopped'
  assert_output --partial 'window did not open in time'
  assert_output --partial 'display driver needs an update'
}

@test "panel: settings and snapshot read failures stay separate from operation outcomes" {
  printf broken >"$(settings_file)"
  run cmd_panel
  assert_output --partial 'could not read the VM settings'
  assert_output --partial 'could not read the snapshot list'
  printf '{"storage":"%s","memory_gib":8,"cores":4}\n' "$STORE" >"$(settings_file)"
  snapshot_list() { return 1; }
  run cmd_panel
  assert_output --partial 'could not read the snapshot list'
}

@test "setup plan and resume: agreement for early and active steps in both marker states" {
  local fixture marker plan acted
  for marker in present consumed; do
    for fixture in packages base active-setup checks scale-wait starting wrong-boot share layout restore done-container done-share failed-setup failed-normal; do
      ST=inactive RESULT=success
      state '{"snapshot":"declined"}'
      echo base >"$STORE/windows.base"
      rm -f "$S/"{running,started,forced,last-shutdown,stop-requested,boot.json,restore-in-progress} "$RUN/step6-checked"
      share_check() { return 0; }
      layout_check() { return 0; }
      container_fact() { echo none; }
      host_packages_missing() { :; }
      setup_step6() { setup_reply true 6 waiting '' '{"test_action":"checks"}'; }
      case $fixture in
        failed-setup|failed-normal)
          ST=failed RESULT=exit-code
          state '{"snapshot":"declined","step5":false}'
          [[ $fixture != failed-normal ]] || state '{"snapshot":"declined","step5":true}'
          ended; rm "$S/last-shutdown" ;;
        packages) host_packages_missing() { echo pkg; } ;;
        base) : >"$STORE/windows.base" ;;
        active-setup) ST=active; echo '{"setup":true}' >"$S/boot.json" ;;
        checks|scale-wait|starting) ST=active; state '{"snapshot":"declined","step5":true}';
          [[ $fixture != scale-wait ]] || checks_passed
          [[ $fixture != starting ]] || ST=activating ;;
        wrong-boot) ST=active ;;
        share) share_check() { return 1; } ;;
        layout) layout_check() { echo broken; return 1; } ;;
        restore) : >"$S/restore-in-progress" ;;
        done-container) state "$CURRENT"; container_fact() { echo running; } ;;
        done-share) state "$CURRENT"; share_check() { return 1; } ;;
      esac
      [[ $marker != consumed ]] || record_previous_run >/dev/null
      plan=$(setup_plan "$(shared_facts)")
      acted=$(setup_resume auto false) || true
      assert_plan_agreement "$plan" "$acted"
    done
  done
}

@test "setup command: client-mode setup boot opens its selected build; window mode does not" {
  setup_resume() { echo setup-boot; }
  setup_guest() { echo '{"ok":true,"window":false}'; }
  build_select() { echo "$T/client"; }
  client_start() { printf '%s\n' "$1" >"$T/client-started"; }
  run setup_command --no-window
  assert_success
  assert_equal "$(cat "$T/client-started")" "$T/client"
  rm "$T/client-started"
  setup_guest() { echo '{"ok":true,"window":true}'; }
  run setup_command --window
  assert_success
  assert [ ! -e "$T/client-started" ]
}

@test "run verdict: reads running last and consumes step5 before deleting running" {
  state '{"snapshot":"declined","step5":false}'
  ended clean
  jq() {
    if [[ $* == *last-shutdown* ]]; then
      command jq "$@"
      rm -f "$S/running"
    else command jq "$@"; fi
  }
  run run_verdict
  assert_equal "$(command jq -r .verdict <<<"$output")" none
  assert_equal "$(command jq -r .completes_step5 <<<"$output")" false
  unset -f jq
  ended clean
  rm() {
    if [[ $* == *running* ]]; then
      [[ $(command jq -r .step5 "$S/setup.json") == true ]] || return 1
    fi
    command rm "$@"
  }
  run record_previous_run
  assert_success
  assert [ ! -e "$S/running" ]
}

@test "step6: passing checks write step6-checked for the scale wait; a wrong answer replies step 5 and marks the stop" {
  ST=active
  state '{"snapshot":"declined","step5":true}'
  version_check() { echo match; }
  log_client_build() { echo "$LG_BUILD"; }
  qmp_call() { echo '{"return":[{"label":"qga0","frontend-open":true},{"label":"vdagent","frontend-open":true},{"label":"scale0","frontend-open":false}]}'; }
  qga_reply() { return 0; }
  client_active() { return 0; }
  guest_version_note() { :; }
  run setup_step6
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 6
  assert [ -s "$RUN/step6-checked" ]
  assert [ ! -e "$RUN/step6-stopped" ]
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .scale_wait <<<"$output")" true
  # The command the allow-list must refuse gets another reply.
  rm "$RUN/step6-checked"
  qga_reply() { [[ $2 != refusal ]] || return 2; }
  run setup_step6
  assert_failure
  assert_equal "$(jq -c '[.step, .reason, .stop]' <<<"$output")" '["5","allowlist",null]'
  assert [ -e "$RUN/step6-stopped" ]
  run setup_plan "$(shared_facts)"
  assert_equal "$(jq -r .step <<<"$output")" 5
}

@test "vm exec: stamps step 6's limits and clears its markers at start before running only stubbed helpers" {
  checks_passed
  : >"$RUN/step6-stopped"
  : >"$RUN/step6-qmp-failed"
  echo "lanai-scale 300 99" >"$RUN/scale-line"
  vm_plan() { echo arguments; }
  default_gateway() { echo gateway; }
  run_once() { :; }
  supervise() { :; }
  sleep() { :; }
  INVOCATION_ID=inv run vm_exec
  assert_failure
  assert [ ! -e "$RUN/step6-checked" ]
  assert [ ! -e "$RUN/step6-stopped" ]
  assert [ ! -e "$RUN/step6-qmp-failed" ]
  assert [ ! -e "$RUN/scale-line" ]
  local t
  t=$(<"$RUN/step6-since")
  ((EPOCHSECONDS - t <= 5)) || fail "step6-since is not this boot's start: $t"
}

@test "vm exec: a step 6 record it cannot write stops the start with a lanai: line, before any helper" {
  vm_plan() { echo arguments; }
  default_gateway() { echo gateway; }
  run_once() { echo "helper $1"; }
  supervise() { echo "helper $1"; }
  sleep() { :; }
  step6_stamp() { return 1; }
  INVOCATION_ID=inv run vm_exec
  assert_failure
  assert_line "lanai: cannot record setup's time limits in $RUN"
  refute_output --partial helper
  assert [ ! -e "$RUN/client.log" ]
}

@test "panel: interrupted setup always offers Continue setup, including the snapshot offer" {
  panel_result_write setup '{"token":"lost","command":"setup","started":1}'
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 3
  assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" true
}

@test "snapshot: unsupported filesystem replies have a reason for the panel backup advice" {
  snapshot_create() { echo unavailable; return 3; }
  run cmd_snapshot
  assert_failure
  assert_equal "$(jq -r .reason <<<"$output")" snapshot-unsupported
  run panel_words snapshot "$output"
  assert_output --partial 'Make a backup'
}

@test "shared facts: status and setup resume each gather once and setup does not rescan active containers" {
  eval "$(declare -f shared_facts | sed '1s/shared_facts/original_shared_facts/')"
  shared_facts() { echo read >>"$T/fact-reads"; original_shared_facts; }
  ST=active
  state '{"snapshot":"declined","step5":true}'
  setup_step6() { setup_wait waiting; }
  container_fact() { touch "$T/container-scanned"; echo running; }
  run status_facts
  assert_success
  assert_equal "$(wc -l <"$T/fact-reads")" 1
  run setup_resume auto false
  assert_success
  assert_equal "$(wc -l <"$T/fact-reads")" 2
  assert [ ! -e "$T/container-scanned" ]
}

@test "shared facts: value-only unit state lets an empty base resume after an existing snapshot" {
  systemctl() { echo inactive; }
  snapshot_list() { echo "$T/snapshot"; }
  state '{}'
  : >"$STORE/windows.base"
  local facts before
  before=$(cat "$S/setup.json")
  facts=$(shared_facts)
  run setup_plan "$facts"
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 3a
  assert_equal "$(cat "$S/setup.json")" "$before"
  run setup_resume auto false
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 3a
  assert_equal "$(cat "$STORE/windows.base")" fixture.iso
  assert_equal "$(jq -r .snapshot "$S/setup.json")" taken
  systemctl() { return 1; }
  run shared_facts
  assert_output --partial 'ActiveState=unknown'
}

@test "setup resume: running another location or without setup media asks for shutdown" {
  ST=active
  local fixture before
  for fixture in other-location no-media; do
    state '{"snapshot":"declined"}'
    [[ $fixture != other-location ]] || echo '{"location":"elsewhere","snapshot":"declined","step5":true}' >"$S/setup.json"
    before=$(cat "$S/setup.json")
    run setup_resume auto false
    assert_failure
    assert_equal "$(jq -r .reason <<<"$output")" "$([[ $fixture == other-location ]] && echo active || echo no-media)"
    assert_equal "$(jq -r .next <<<"$output")" 'shut Windows down, then run setup again'
    assert_equal "$(cat "$S/setup.json")" "$before"
  done
}

@test "client stamp: an installed unstamped client takes a quick build check before setup continues" {
  source "$REPO/lib/client.sh"
  # Sourcing lib/client.sh again replaces setup()'s package stub with the real
  # check, which depends on the host's packages (CI lacks them).
  host_packages_missing() { :; }
  local d
  d=$(client_builds)/$LG_BUILD
  mkdir -p "$d/bin"
  printf '#!/bin/bash\necho "00:00:00.000 [I] main.c:4303 | main | Looking Glass (%s)" >&2\n' "$LG_BUILD" >"$d/bin/looking-glass-client"
  chmod +x "$d/bin/looking-glass-client"
  patches_id >"$d/build-patches"
  state '{"snapshot":"declined"}'
  run setup_plan "$(shared_facts)"
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 4
  # Keep timeout/the executable in a fresh shell, outside Bats' trap state.
  # All paths still come from isolate_home, including HOME and TMPDIR.
  # shellcheck disable=SC2016
  run --separate-stderr bash -c '
    set -euo pipefail
    source "$1/lib/lanai.sh"
    fetch_verified() { echo "unexpected download" >&2; return 1; }
    build_client
  ' _ "$REPO"
  assert_success
  assert_output "$d/bin/looking-glass-client"
  assert_equal "$(cat "$d/build-stamp")" "$LG_BUILD"
  run setup_plan "$(shared_facts)"
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 5
}

@test "panel records: a launch at the lock probe is read as started and running" {
  exec {PANEL_RACE_FD}>"$S/panel-job.lock"
  flock() {
    panel_result_write setup '{"token":"racing-launch","command":"setup","started":1}'
    command flock "$PANEL_RACE_FD"
    return 1
  }
  run cmd_panel --pending racing-launch 1
  assert_success
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  refute_output --partial interrupted
  refute_output --partial 'did not start'
  exec {PANEL_RACE_FD}>&-
}

@test "panel: its reads leave durable files unchanged, never running a client" {
  state '{"snapshot":"declined","step5":false}'
  ended clean
  echo '{"step":"7"}' >"$S/setup-reply.json"
  local before after
  before=$(find "$S" "$RUN" "$STORE" -type f -exec sha256sum {} + | sort)
  client_version() { touch "$T/client-ran"; return 1; }
  run cmd_panel
  assert_success
  after=$(find "$S" "$RUN" "$STORE" -type f -exec sha256sum {} + | sort)
  assert_equal "$before" "$after"
  assert [ ! -e "$T/client-ran" ]
}

@test "setup follow: a step 6 stop after the worker check cannot boot Windows" {
  state '{"snapshot":"declined","step5":true}'
  ST=active
  unit_state() { echo "$ST"; }
  unit_invocation() { echo "$INV"; }
  ui_sleep() { :; }
  ui_now() { echo 110; }
  systemctl() { [[ $* == '--user is-active --quiet graphical-session.target' ]]; }
  ui_setup_next '{"ok":true,"step":"6"}' inv 100
  # The unit exits between the worker deciding and setup taking its lock.
  ST=inactive
  boot_vm() { touch "$T/booted"; echo '{"ok":true}'; }
  client_start() { touch "$T/client-started"; }
  run setup_command --follow 6 inv
  assert_success
  assert_equal "$(jq -r .follow_stopped <<<"$output")" true
  assert [ ! -e "$T/booted" ]
  assert [ ! -e "$T/client-started" ]
}

@test "setup follow: locked checks reject changed invocations and panel stop requests" {
  local fixture before
  for fixture in invocation stop consumed step5-panel; do
    rm -f "$S/"{running,started,last-shutdown,stop-requested}
    state '{"snapshot":"declined","step5":true}'
    ST=active INV=inv
    case $fixture in
      invocation) INV=other ;;
      stop) echo 'inv 1' >"$S/stop-requested" ;;
      consumed) ST=inactive ;;
      step5-panel) ST=inactive; ended panel ;;
    esac
    before=$(cat "$S/setup.json")
    run setup_command --follow "$([[ $fixture == consumed || $fixture == step5-panel ]] && echo 5 || echo 6)" inv
    assert_success
    assert_equal "$(jq -r .follow_stopped <<<"$output")" true
    assert_equal "$(cat "$S/setup.json")" "$before"
    [[ $fixture != step5-panel ]] || assert [ -f "$S/running" ]
  done
}

@test "setup follow: matching locked step 5 completion advances and active step 6 checks" {
  state '{"snapshot":"declined","step5":false}'
  ended clean
  run setup_resume auto false 5 inv
  assert_success
  assert_output normal-boot
  assert_equal "$(jq -r .step5 "$S/setup.json")" true
  ST=active
  echo '{"setup":false}' >"$S/boot.json"
  # Step 6 learns that this call follows the job's own click.
  setup_step6() { setup_reply true 6 "checked, following step ${1:-none}" ''; }
  run setup_command --follow 6 inv
  assert_success
  assert_equal "$(jq -r .message <<<"$output")" 'checked, following step 6'
  run setup_command
  assert_equal "$(jq -r .message <<<"$output")" 'checked, following step none'
}

@test "panel records: two concurrent readers without a worker both report no job" {
  : >"$S/panel-job.lock"
  # Pause reader one after it takes the real probe lock, before record reads.
  flock() {
    command flock "$@" || return
    : >"$T/reader-ready"
    local i
    for ((i=0; i<100; i++)); do
      [[ ! -e $T/reader-release ]] || return 0
      sleep 0.05
    done
    return 1
  }
  (panel_records >"$T/reader-one") 3>&- &
  local reader=$!
  wait_for_file "$T/reader-ready"
  unset -f flock
  panel_records >"$T/reader-two"
  : >"$T/reader-release"
  wait "$reader"
  assert_equal "$(jq -r .held "$T/reader-one")" false
  assert_equal "$(jq -r .held "$T/reader-two")" false
}

@test "panel: finished setup can run again only while Windows is off" {
  state '{"snapshot":"declined","done":true}'
  ST=active
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" false
  assert_equal "$(jq -r .buttons.continue_setup.hint <<<"$output")" 'Shut Windows down, then choose Run setup again in More actions.'
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" true
  assert_equal "$(jq -r .buttons.continue_setup.hint <<<"$output")" ''
}

@test "panel: setup results follow their step, keep stepless failures and suppress repeated reasons" {
  state '{"snapshot":"declined","step5":false}'
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"step":"5","reason":"incomplete"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  panel_result_write setup '{"command":"setup","ended":1,"reply":{"ok":false,"reason":"busy"}}'
  state '{}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" 'Lanai is busy with another task. Try again in a moment.'
  panel_result_write setup '{"command":"setup","ended":2,"reply":{"ok":true,"step":"3a"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
}

@test "panel: interruption words match the group operation" {
  local command group expected
  for command in snapshot restore setup; do
    group=$(panel_group "$command")
    panel_result_write "$group" "$(jq -nc --arg c "$command" '{command:$c,started:1}')"
    run cmd_panel
    case $command in
      snapshot) expected='The snapshot did not finish. Try again.' ;;
      restore) expected='The restore did not finish. Finish the unfinished restore or restore another snapshot before starting Windows.' ;;
      setup) expected='Setup was interrupted. Continue setup to try again.' ;;
    esac
    assert_equal "$(jq -r --arg g "$group" '.result[$g]' <<<"$output")" "$expected"
  done
  # Run setup again on a finished install: its step 4 build runs while the
  # plan is still finished, so the words name the button that shows.
  state "$CURRENT"
  panel_result_write setup '{"command":"setup","args":["--window"],"started":1}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" 'Setup was interrupted. Click Run setup again in More actions to try again.'
  assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Run setup again'
}

@test "panel: step 5 waits name the automatic shutdown and subsequent checks" {
  local fd
  ST=active
  state '{"snapshot":"declined"}'
  echo '{"setup":true}' >"$S/boot.json"
  panel_result_write setup '{"command":"setup","started":1,"reply":{"ok":true,"step":"5"}}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_equal "$(jq -r .busy.line <<<"$output")" 'Waiting for Windows to finish setup.'
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" "In Windows, open Lanai's setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Use Shut down only if setup.cmd stops responding, or when its shared-folder check tells you to."
  exec {fd}>&-
}

@test "panel: warnings have no leading space and mismatch already explains the old driver" {
  state "$CURRENT"
  status_facts() { printf 'ActiveState=active\nLanaiClient=timeout\nLanaiDriverOld=old\nLanaiVersion=mismatch\nLanaiSetup=done\n'; }
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" 'The Windows window did not open in time. Try Open window again.'
}

@test "panel: logs name the journal and omit an unavailable client path" {
  run_dir() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .logs.vm <<<"$output")" 'Windows VM log: in your user journal, under lanai-vm'
  run jq -e '.logs | has("client") | not' <<<"$output"
  assert_success
}

@test "panel: setup wait guidance requires the held setup job, not just an active VM" {
  local fixture fd expected step
  for step in 5 6; do
    for fixture in cli failed-client failed-check timed-out interrupted other-job following; do
      ST=active
      rm -f "$S/panel-result-setup.json" "$S/panel-result-snapshots.json"
      state '{"snapshot":"declined","step5":true}'
      if [[ $step == 5 ]]; then echo '{"setup":true}' >"$S/boot.json"
      else echo '{"setup":false}' >"$S/boot.json"; fi
      case $fixture in
        failed-client) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,ended:2,reply:{ok:false,step:$step,reason:"client"}}')" ;;
        failed-check) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,ended:2,reply:{ok:false,step:$step}}')" ;;
        timed-out) panel_result_write setup '{"command":"setup","started":1,"ended":2,"reply":{"ok":false,"step":"6","stop":"timeout","reason":"agents"}}' ;;
        interrupted) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,reply:{ok:true,step:$step}}')" ;;
        other-job) panel_result_write snapshots '{"command":"snapshot","started":3}'; exec {fd}>"$S/panel-job.lock"; flock "$fd" ;;
        following) panel_result_write setup "$(jq -nc --arg step "$step" '{command:"setup",started:1,reply:{ok:true,step:$step}}')"; exec {fd}>"$S/panel-job.lock"; flock "$fd" ;;
      esac
      run cmd_panel
      assert_success
      if [[ $step == 5 ]]; then
        expected="In Windows, open Lanai's setup drive and run setup.cmd. Then click Continue setup so Lanai can restart Windows and check it when setup.cmd finishes."
        [[ $fixture != following ]] || expected="In Windows, open Lanai's setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Use Shut down only if setup.cmd stops responding, or when its shared-folder check tells you to."
      else
        expected='Click Continue setup so Lanai can check Windows.'
        [[ $fixture != following ]] || expected='Windows is starting or being checked.'
      fi
      assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" "$expected"
      if [[ $fixture == other-job || $fixture == following ]]; then exec {fd}>&-; fi
    done
  done
}

@test "shared facts: no install has its own reason and setup words" {
  layout_check() { return 2; }
  local facts plan
  facts=$(shared_facts)
  assert [ "$facts" != '' ]
  assert_equal "$(sed -n 's/^LanaiProblemReason=//p' <<<"$facts")" missing
  plan=$(setup_plan "$facts")
  assert_equal "$(jq -r .reason <<<"$plan")" missing
  run setup_resume auto false
  assert_failure
  assert_equal "$(jq -r .reason <<<"$output")" missing
  run cmd_panel
  assert_success
  assert_equal "$(jq -c .setup.lines <<<"$output")" '[]'
  assert_equal "$(jq -r .next <<<"$output")" 'Install Windows with Omarchy, then continue setup.'
}

@test "panel: logs and reply guidance use the same names" {
  run cmd_panel
  assert_equal "$(jq -r .logs.client <<<"$output")" "Windows window log: $RUN/client.log"
  assert_equal "$(jq -r .logs.job <<<"$output")" "Setup, snapshot, restore and update log: $S/panel-job.log"
  assert_equal "$(jq -r .logs.command <<<"$output")" "Button actions log: $S/panel-run.log"
  run panel_words setup '{"ok":false,"reason":"client"}'
  assert_output 'The Windows window could not open. Check the Windows window log and try again.'
  run panel_words setup '{"ok":false}'
  assert_output 'Setup could not finish. Check the setup log, then continue setup.'
  run panel_words snapshot '{"ok":false}'
  assert_output 'Lanai could not take the snapshot. Check the snapshot log and try again.'
  run panel_words restore '{"ok":false}'
  assert_output 'Lanai could not restore the snapshot. Check the restore log before trying again.'
  run cmd_panel --pending never "$((EPOCHSECONDS - 11))"
  assert_equal "$(jq -r .result.launch <<<"$output")" 'The operation did not start. Check the setup, snapshot, restore and update log, then try again.'
}

@test "panel: repair prompt and named restore labels come from the backend" {
  state '{"snapshot":"declined","done":true}'
  snapshot_list() { printf '%s\n' "$T/holiday" "$T/school"; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.again_line <<<"$output")" 'Choose how Windows should show during setup.'
  assert_equal "$(jq -r .buttons.cancel.label <<<"$output")" Cancel
  assert_equal "$(jq -r '.buttons.restore_snapshot.labels.holiday' <<<"$output")" 'Restore snapshot holiday'
  assert_equal "$(jq -r '.buttons.restore_confirm.labels.holiday' <<<"$output")" 'Restore holiday and replace Windows'
  assert_equal "$(jq -r '.buttons.restore_confirm.labels.school' <<<"$output")" 'Restore school and replace Windows'
}

@test "panel: Continue setup is disabled for active and no-media problems at every step" {
  local reason step
  for step in 1 5 6; do
  for reason in active no-media; do
    setup_plan() { jq -nc --arg reason "$reason" --arg step "$step" '{step:$step,finished:false,action:"problem",reason:$reason,choices:[]}'; }
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .buttons.continue_setup.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" false
  done
  done
}

@test "panel: stopped step 6 without a setup worker asks for Continue setup" {
  state '{"snapshot":"declined","step5":true}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.step <<<"$output")" 6
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'Click Continue setup so Lanai can check Windows.'
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" true
}

@test "panel: stopping step 6 waits for shutdown before Continue setup" {
  state '{"snapshot":"declined","step5":true}'
  ST=deactivating
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .state <<<"$output")" stopping
  assert_equal "$(jq -r .setup.step <<<"$output")" 6
  assert_equal "$(jq -r '.setup.lines[0]' <<<"$output")" 'Wait for Windows to shut down, then click Continue setup.'
  assert_equal "$(jq -r .buttons.continue_setup.enable <<<"$output")" false
}

@test "panel words: shared folder guidance explains its ownership and link rules" {
  run panel_words setup '{"ok":false,"reason":"share"}'
  assert_success
  assert_output 'Lanai needs a folder named Windows in your home folder. It must be a real folder you own, not a link. Create or fix it, then continue setup.'
}

@test "panel: missing install guidance appears only in the top block" {
  layout_check() { return 2; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .state <<<"$output")" not-installed
  assert_equal "$(jq -c .setup.lines <<<"$output")" '[]'
  assert_equal "$(jq -r .next <<<"$output")" 'Install Windows with Omarchy, then continue setup.'
}


# Durable steps, with a running worker supplied without a service or process.
setup_worker() {
  panel_records() { echo '{"held":true,"records":{"setup":{"command":"setup","started":1}}}'; }
}

@test "panel: first-time setup hides Start and Open at every step and keeps settings" {
  local step
  for step in 1 2 3 3a 4 5 6; do
    setup_plan() { jq -nc --arg step "$step" '{finished:false,step:$step,action:"problem",reason:"",choices:[]}'; }
    for ST in inactive activating active deactivating reloading failed; do
      run cmd_panel
      assert_success
      assert_equal "$(jq -r '.buttons.start.show or .buttons.open.show' <<<"$output")" false
      assert_equal "$(jq -r .buttons.save_settings.show <<<"$output")" true
    done
  done
}

@test "panel: each setup step needs attention before its action and not while its worker runs" {
  local fixture expected
  for fixture in problem packages snapshot base build setup-boot normal-boot; do
    ST=inactive
    state '{"snapshot":"declined"}'
    echo base >"$STORE/windows.base"
    share_check() { [[ $fixture != problem ]]; }
    host_packages_missing() { [[ $fixture != packages ]] || echo package; }
    build_stamp_current() { [[ $fixture != build ]]; }
    case $fixture in
      problem) expected=1 ;;
      packages) expected=2 ;;
      snapshot) expected=3; state '{}' ;;
      base) expected=3a; rm "$STORE/windows.base" ;;
      build) expected=4 ;;
      setup-boot) expected=5 ;;
      normal-boot) expected=6; state '{"snapshot":"declined","step5":true}' ;;
    esac
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.step <<<"$output")" "$expected"
    assert_equal "$(jq -r .setup.attention <<<"$output")" true
    # Problems still need the user even while a worker winds down.
    if [[ $fixture != problem ]]; then
      setup_worker
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.attention <<<"$output")" false
      unset -f panel_records
      # Restore the real reader after the fixture worker.
      source "$REPO/lib/panel.sh"
    fi
  done
}

@test "panel: setup boot needs attention, checks wait quietly, time-outs and recovery need attention" {
  state '{"snapshot":"declined","step5":false}'
  ST=active
  echo '{"setup":true,"window":true}' >"$S/boot.json"
  setup_worker
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  state '{"snapshot":"declined","step5":true}'
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  client_active() { return 0; }
  for ST in active activating reloading deactivating; do
    run cmd_panel
    assert_equal "$(jq -r .setup.step <<<"$output")" 6
    assert_equal "$(jq -r .setup.attention <<<"$output")" false
  done
  ST=active
  # The scale wait waits quietly too; a time-out needs the user.
  checks_passed
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" false
  rm "$RUN/step6-checked"
  panel_records() { echo '{"held":false,"records":{"setup":{"command":"setup","started":1,"ended":2,"reply":{"ok":false,"step":"6","stop":"timeout","reason":"scale-task"}}}}'; }
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  setup_worker
  client_active() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" true
  client_active() { return 0; }
  panel_records() { echo '{"held":false,"records":{}}'; }
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  state '{"snapshot":"declined","step5":false}'
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .buttons.window.show <<<"$output")" true
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
}

@test "panel: failures, interrupted work and failed launches need attention, pending launches do not" {
  state '{"snapshot":"declined","step5":true}'
  ST=active
  client_active() { return 0; }
  setup_worker
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" false
  panel_records() { echo '{"held":true,"records":{"setup":{"command":"setup","started":1,"reply":{"ok":false,"step":"6","reason":"client"}}}}'; }
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  source "$REPO/lib/panel.sh"
  panel_result_write setup '{"command":"setup","started":1}'
  run cmd_panel
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
  rm "$S/panel-result-setup.json"
  run cmd_panel --pending missing "$EPOCHSECONDS"
  assert_equal "$(jq -r .setup.attention <<<"$output")" false
  run cmd_panel --pending missing "$((EPOCHSECONDS - 11))"
  assert_equal "$(jq -r .setup.attention <<<"$output")" true
}

@test "panel: reopen follows the unfinished running boot, never a basic window or shutdown" {
  local boot client window
  for boot in setup checks normal finished; do
    case $boot in
      setup) state '{"snapshot":"declined","step5":false}'; echo '{"setup":true}' >"$S/boot.json" ;;
      checks) state '{"snapshot":"declined","step5":true}'; echo '{"setup":false}' >"$S/boot.json" ;;
      normal) state '{"snapshot":"declined"}'; echo '{"setup":false}' >"$S/boot.json" ;;
      finished) state '{"snapshot":"declined","done":true}'; echo '{"setup":false}' >"$S/boot.json" ;;
    esac
    for ST in inactive active activating reloading deactivating; do
      for client in closed running; do
        client_active() { [[ $client == running ]]; }
        for window in false true; do
          jq --argjson w "$window" '.window=$w' "$S/boot.json" >"$S/new"; mv "$S/new" "$S/boot.json"
          run cmd_panel
          assert_success
          local expected=false
          if [[ $boot != finished && $ST == active && $client == closed && $window == false ]]; then expected=true; fi
          if [[ $(jq -r .buttons.reopen_window.show <<<"$output") != "$expected" ]]; then echo "$boot / $ST / $client / $window" >&3; fi
          assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" "$expected"
          assert_equal "$(jq -r .buttons.reopen_window.enable <<<"$output")" "$expected"
          assert_equal "$(jq -r .buttons.reopen_window.label <<<"$output")" 'Reopen the Windows window'
        done
      done
    done
  done
}

@test "panel: step 6 rollback keeps Reopen available when its normal boot's client closes" {
  local reason client
  ST=active
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  for reason in mismatch allowlist; do
    state '{"snapshot":"declined","step5":true}'
    setup_back5 "$reason" 'The final check failed.' >/dev/null
    for client in running closed; do
      client_active() { [[ $client == running ]]; }
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.step <<<"$output")" 5
      assert_output --partial 'Shut Windows down, then continue setup to attach the setup drive.'
      assert_equal "$(jq -r '.buttons.start.show or .buttons.open.show or .buttons.continue_setup.enable' <<<"$output")" false
      assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" "$([[ $client == closed ]] && echo true || echo false)"
      assert_equal "$(jq -r .buttons.reopen_window.enable <<<"$output")" "$([[ $client == closed ]] && echo true || echo false)"
    done
  done
}

@test "panel: rollback shutdown clears setup attention despite its reason, failure reply and failed launch" {
  local reason shutdown reply
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  client_active() { return 1; }
  for reason in mismatch allowlist; do
    ST=active
    state '{"snapshot":"declined","step5":true}'
    reply=$(setup_back5 "$reason" 'The final check failed.')
    panel_result_write setup "$(jq -nc --argjson r "$reply" '{command:"setup",ended:1,reply:$r}')"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.attention <<<"$output")" true
    for shutdown in deactivating requested guest; do
      ST=active
      qmp_call() { printf '{"return":{"status":"running"}}\n'; }
      case $shutdown in
        deactivating) ST=deactivating ;;
        requested) printf 'inv %s\n' "$EPOCHSECONDS" >"$S/stop-requested" ;;
        guest) qmp_call() { printf '{"return":{"status":"shutdown"}}\n'; } ;;
      esac
      run cmd_panel --pending missing "$((EPOCHSECONDS - 11))"
      assert_success
      assert_equal "$(jq -r .state <<<"$output")" stopping
      assert_equal "$(jq -r .setup.step <<<"$output")" 5
      assert_output --partial 'Shut Windows down, then continue setup to attach the setup drive.'
      assert [ -n "$(jq -r .result.setup <<<"$output")" ]
      assert [ -n "$(jq -r .result.launch <<<"$output")" ]
      assert_equal "$(jq -r .setup.attention <<<"$output")" false
      assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" false
      rm -f "$S/stop-requested"
    done
    qmp_call() { printf '{"return":{"status":"running"}}\n'; }
  done
}

@test "panel: Snapshots hide only for unfinished setup with an active unit" {
  local finished expected
  snapshot_list() { echo "$T/snapshot"; }
  for finished in false true; do
    state "{\"snapshot\":\"declined\",\"done\":$finished}"
    for ST in inactive failed activating active reloading deactivating; do
      run cmd_panel
      assert_success
      expected=true
      if [[ $finished == false && $ST != inactive && $ST != failed ]]; then expected=false; fi
      assert_equal "$(jq -r .snapshots.show <<<"$output")" "$expected"
      assert_equal "$(jq -r .buttons.take_snapshot.show <<<"$output")" "$expected"
      assert_equal "$(jq -r .buttons.restore_snapshot.show <<<"$output")" "$expected"
      assert_equal "$(jq -r .buttons.restore_confirm.show <<<"$output")" "$expected"
    done
  done
  # A working install with a pending update keeps Snapshots on ordinary boots.
  state '{"snapshot":"declined","done":true}'
  build_stamp_current() { return 1; }
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  for ST in activating active reloading deactivating; do
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.finished <<<"$output")" false
    assert_equal "$(jq -r .snapshots.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.take_snapshot.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.restore_snapshot.show <<<"$output")" true
    assert_equal "$(jq -r .buttons.restore_confirm.show <<<"$output")" true
  done
  state '{"snapshot":"declined"}'
  status_facts() { printf 'ActiveState=%s\nLanaiRestorePending=true\n' "$ST"; }
  for ST in active inactive; do
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .buttons.finish_restore.show <<<"$output")" "$([[ $ST == inactive ]] && echo true || echo false)"
  done
}

@test "panel: setup boot Shut down carries its second click and finished controls stay unchanged" {
  local boot finished
  for finished in false true; do
    state "{\"snapshot\":\"declined\",\"done\":$finished}"
    for boot in true false; do
      echo "{\"setup\":$boot}" >"$S/boot.json"
      for ST in inactive active activating reloading deactivating; do
        run cmd_panel
        assert_success
        local expected=false
        if [[ $finished == false && $boot == true && $ST != inactive && $ST != deactivating ]]; then expected=true; fi
        assert_equal "$(jq -r .buttons.stop.confirm <<<"$output")" "$expected"
        assert_equal "$(jq -r .buttons.stop_confirm.show <<<"$output")" "$expected"
        assert_equal "$(jq -r .buttons.stop_confirm.hint <<<"$output")" "Shutting down now stops setup. You'll choose how to continue."
        if [[ $finished == true ]]; then
          assert_equal "$(jq -r .setup.attention <<<"$output")" false
          assert_equal "$(jq -r .buttons.start.show <<<"$output")" "$([[ $ST == inactive ]] && echo true || echo false)"
          assert_equal "$(jq -r .buttons.open.show <<<"$output")" "$([[ $ST == inactive ]] && echo false || echo true)"
          assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Run setup again'
        fi
      done
    done
  done
}

@test "panel: working installs keep Start and Open beside each pending update step" {
  local pending
  client_active() { return 1; }
  qmp_call() { printf '{"return":{"status":"running"}}\n{"return":[{"label":"qga0","frontend-open":true}]}\n'; }
  for pending in stamp driver rerun; do
    state '{"snapshot":"declined","done":true}'
    build_stamp_current() { [[ $pending != stamp ]]; }
    guest_version_behind() { [[ $pending != driver ]] || echo old; }
    [[ $pending != rerun ]] || state '{"snapshot":"declined","done":true,"round":true,"step5":false}'
    for ST in inactive active; do
      echo '{"setup":false,"step6":true,"window":false}' >"$S/boot.json"
      [[ $pending != rerun ]] || echo '{"setup":false,"window":false}' >"$S/boot.json"
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.show <<<"$output")" true
      assert_equal "$(jq -r .setup.step <<<"$output")" "$([[ $pending == stamp ]] && echo 4 || echo 5)"
      assert_equal "$(jq -r '.buttons.start.show and .buttons.start.enable' <<<"$output")" "$([[ $ST == inactive ]] && echo true || echo false)"
      assert_equal "$(jq -r '.buttons.open.show and .buttons.open.enable' <<<"$output")" "$([[ $ST == active ]] && echo true || echo false)"
      assert_right_click panel
      assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" false
      assert_equal "$(jq -r .cause <<<"$output")" "$([[ $ST == inactive ]] && echo 'Windows is ready to start.' || echo 'Windows is available.')"
      assert_equal "$(jq -r .next <<<"$output")" "$([[ $ST == inactive ]] && echo 'Click Start Windows.' || echo 'Click Open window.')"
    done
  done
}

@test "panel: completing final checks restores the daily controls in the same boot" {
  ST=active
  state '{"snapshot":"declined","done":true}'
  echo '{"setup":false,"step6":true,"window":false}' >"$S/boot.json"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .buttons.open.show <<<"$output")" true
}

@test "panel: working installs hide daily controls only during setup or final check boots" {
  local boot
  state '{"snapshot":"declined","done":true,"round":true,"step5":true}'
  for boot in setup step6; do
    echo "{\"$boot\":true,\"window\":false}" >"$S/boot.json"
    for ST in activating active reloading deactivating; do
      run cmd_panel
      assert_success
      assert_equal "$(jq -r '.buttons.start.show or .buttons.open.show' <<<"$output")" false
    done
    ST=inactive
    run cmd_panel
    assert_equal "$(jq -r '.buttons.start.show and .buttons.start.enable' <<<"$output")" true
    assert_equal "$(jq -r .cause <<<"$output")" 'Windows is ready to start.'
  done
  echo '{"location":"elsewhere","done":true}' >"$S/setup.json"
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r .buttons.start.show <<<"$output")" false
  refute_output --partial 'Windows is ready to start.'
}

@test "panel: hidden Start has setup guidance even when status says stopped" {
  status_map() { echo '{"state":"stopped","active":false,"setup_done":false,"window":false,"force_stop":false,"restore_pending":false}'; }
  run cmd_panel
  assert_equal "$(jq -r .buttons.start.show <<<"$output")" false
  assert_equal "$(jq -r .cause <<<"$output")" 'Lanai setup has not finished for this Windows install.'
  assert_equal "$(jq -r .next <<<"$output")" 'Follow the Setup section below.'
}

@test "panel: client timeout guidance follows the available window control" {
  local boot client
  ST=active
  status_facts() { printf '%s\n' "$1" 'LanaiClient=timeout' 'LanaiQmp=running' 'LanaiQga=open' 'LanaiSetup=done'; }
  for boot in client basic; do
    state '{"snapshot":"declined","step5":false}'
    echo "{\"setup\":true,\"window\":$([[ $boot == basic ]] && echo true || echo false)}" >"$S/boot.json"
    for client in closed running; do
      client_active() { [[ $client == running ]]; }
      run cmd_panel
      assert_success
      local advice='Check the Windows window log, then shut down and continue setup.'
      if [[ $boot == client && $client == closed ]]; then advice='Try Reopen the Windows window in Setup.'; fi
      assert_equal "$(jq -r .warning <<<"$output")" "The Windows window did not open in time. $advice"
    done
  done
  state '{"snapshot":"declined","done":true,"round":true}'
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" 'The Windows window did not open in time. Try Open window again.'
}

@test "panel: an existing shutdown request never asks for another confirmation" {
  local request
  state '{"snapshot":"declined"}'
  echo '{"setup":true}' >"$S/boot.json"
  for request in current activating old stopping guest; do
    ST=active
    qmp_call() { echo '{"return":{"status":"running"}}'; }
    rm -f "$S/stop-requested"
    case $request in
      current) echo "inv $EPOCHSECONDS" >"$S/stop-requested" ;;
      activating) ST=activating; echo "inv $EPOCHSECONDS" >"$S/stop-requested" ;;
      old) echo "other $EPOCHSECONDS" >"$S/stop-requested" ;;
      stopping) ST=deactivating ;;
      guest) qmp_call() { echo '{"return":{"status":"shutdown"}}'; } ;;
    esac
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .buttons.stop.confirm <<<"$output")" "$([[ $request == old ]] && echo true || echo false)"
    assert_equal "$(jq -r .buttons.stop_confirm.show <<<"$output")" "$([[ $request == old ]] && echo true || echo false)"
    assert_equal "$(jq -r .buttons.stop.enable <<<"$output")" true
  done
}

@test "setup command: a Reopen in either boot gap keeps setup successful" {
  local boot running
  build_select() { echo "$T/selected"; }
  pinned_client() { echo "$T/pinned"; }
  client_start() { echo "$1" >"$T/client-started"; [[ $running == false ]]; }
  for boot in setup-boot normal-boot; do
    setup_resume() { echo "$boot"; }
    setup_guest() { echo '{"ok":true,"window":false}'; }
    boot_vm() { echo '{"ok":true,"window":false}'; }
    for running in true false; do
      rm -f "$T/client-started"
      client_active() { [[ $running == true ]]; }
      run setup_command
      assert_success
      assert_equal "$(jq -r .step <<<"$output")" "$([[ $boot == setup-boot ]] && echo 5 || echo 6)"
      if [[ $running == true ]]; then
        assert [ ! -e "$T/client-started" ]
      else
        assert_equal "$(cat "$T/client-started")" "$T/$([[ $boot == setup-boot ]] && echo selected || echo pinned)"
      fi
    done
  done
}

@test "setup command: Reopen while selecting the client does not fail the setup boot" {
  setup_resume() { echo setup-boot; }
  setup_guest() { echo '{"ok":true,"window":false}'; }
  build_select() { touch "$T/client-open"; echo "$T/selected"; }
  client_active() { [[ -e $T/client-open ]]; }
  client_start() { touch "$T/client-started"; return 1; }
  run setup_command
  assert_success
  assert_equal "$(jq -r .step <<<"$output")" 5
  assert [ ! -e "$T/client-started" ]
}

@test "boot mode: final checks are recorded and an ordinary start clears the flag" {
  state '{"snapshot":"declined","done":true,"round":true,"step5":true}'
  lanai_flock() { return 0; }
  preflight() { return 0; }
  vm_plan() { return 0; }
  runtime_refresh() { return 0; }
  host_monitors() { echo '[{"name":"DP-1","focused":true,"scale":1}]'; }
  default_gateway() { echo gateway; }
  local checks
  for checks in true false; do
    run boot_vm false auto "$checks"
    assert_success
    assert_equal "$(jq -r '.step6 // false' "$S/boot.json")" "$checks"
  done
}

@test "panel: automatic setup startup waits quietly until Windows can show its setup drive" {
  state '{"snapshot":"declined","step5":false}'
  echo '{"setup":true,"window":true}' >"$S/boot.json"
  setup_worker
  for ST in activating active; do
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.attention <<<"$output")" "$([[ $ST == activating ]] && echo false || echo true)"
  done
}

@test "panel progress: external flock owner advances without a job record and blocks controls" {
  local fd pid=$BASHPID
  exec {fd}>"$S/lock"
  flock -n "$fd"
  # flock exits; the live owner retains its open descriptor and lock.
  jq -nc --argjson p "$pid" '{operation:"snapshot",phase:"hashing",done:25,total:100,pid:$p}' >"$S/image-progress.json"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r '.progress.percent' <<<"$output")" 24
  assert_equal "$(jq -r '.busy.active' <<<"$output")" true
  assert_equal "$(jq -r '.buttons.take_snapshot.enable' <<<"$output")" false
  assert_equal "$(jq -r '.progress.label' <<<"$output")" "Taking a snapshot: reading the image"
  # The progress line and bar say what runs: no busy line beside them.
  assert_equal "$(jq -r '.busy.line' <<<"$output")" ''
  refute_output --partial '—'
  local phase label
  for phase in cloning checking; do
    jq --arg phase "$phase" '.phase=$phase' "$S/image-progress.json" >"$S/next.json"
    mv "$S/next.json" "$S/image-progress.json"
    lanai_run panel
    assert_success
    if [[ $phase == cloning ]]; then label='making an instant copy'; else label='checking the shared storage'; fi
    assert_equal "$(jq -r '.progress.label' <<<"$output")" "Taking a snapshot: $label"
    assert_equal "$(jq -r '.busy.line' <<<"$output")" ''
  done
  jq '.operation="restore"' "$S/image-progress.json" >"$S/next.json"
  mv "$S/next.json" "$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.busy.line' <<<"$output")" ''
  assert_equal "$(jq -r '.restore.warning' <<<"$output")" 'Keep Windows stopped until the restore finishes.'
  jq '.done=100 | .phase="replacing"' "$S/image-progress.json" >"$S/next.json"
  mv "$S/next.json" "$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress.percent' <<<"$output")" 99
  assert_equal "$(jq -r '.progress.label' <<<"$output")" "Restoring Windows: replacing the disk"
  exec {fd}>&-
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
}

@test "panel busy: job lines without progress name the job, never closing the panel" {
  local fd job group step
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  for job in setup snapshot delete-snapshot restore build-client setup:5 setup:6; do
    step=${job#*:}
    group=$(panel_group "${job%%:*}")
    rm -f "$S"/panel-result-*.json
    if [[ $job == *:* ]]; then
      panel_result_write "$group" "$(jq -nc --arg s "$step" '{command:"setup",started:1,reply:{ok:true,step:$s}}')"
    else
      panel_result_write "$group" "$(jq -nc --arg c "$job" '{command:$c,args:[],started:1}')"
    fi
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .busy.active <<<"$output")" true
    [[ $(jq -r .busy.line <<<"$output") != *"You can close this panel."* ]] || fail "$job: $(jq -r .busy.line <<<"$output")"
  done
  rm -f "$S"/panel-result-*.json
  panel_result_write snapshots '{"command":"delete-snapshot","args":["20261012T091200Z"],"started":1}'
  run cmd_panel
  assert_equal "$(jq -r .busy.line <<<"$output")" 'Deleting a snapshot.'
  exec {fd}>&-
  # Unheld, the record is an interrupted delete: a click waiting for its
  # record is not that job.
  run cmd_panel --pending next "$EPOCHSECONDS"
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  assert_equal "$(jq -r .busy.line <<<"$output")" 'Starting the operation.'
}

@test "panel busy: a running restore has no busy line, only its target and warning" {
  local fd
  state "$CURRENT"
  : >"$S/restore-in-progress"
  panel_result_write snapshots '{"command":"restore","args":[],"started":1}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .progress <<<"$output")" null
  assert_equal "$(jq -r .restore.active <<<"$output")" true
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  assert_equal "$(jq -r .busy.line <<<"$output")" ''
  assert_equal "$(jq -r .restore.warning <<<"$output")" 'Keep Windows stopped until the restore finishes.'
  exec {fd}>&-
  # Unheld, the record is an interrupted restore: nothing runs.
  run cmd_panel
  assert_equal "$(jq -r .restore.active <<<"$output")" false
  assert_equal "$(jq -r .restore.pending <<<"$output")" true
  assert_equal "$(jq -r .busy.line <<<"$output")" ''
  # A Finish click still waiting for its record is not yet the restore.
  run cmd_panel --pending finish "$EPOCHSECONDS"
  assert_equal "$(jq -r .restore.active <<<"$output")" false
  assert_equal "$(jq -r .busy.line <<<"$output")" 'Starting the operation.'
}

@test "panel progress: dead owners, unrelated open files, wrong lock inodes and malformed records are ignored" {
  local fd pid=$BASHPID
  exec {fd}>"$S/other-lock"
  flock -n "$fd"
  : >"$S/lock"
  jq -nc --argjson p "$pid" '{operation:"restore",phase:"checking",done:0,total:0,pid:$p}' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  exec {fd}>&-
  exec {fd}>"$S/lock"
  # An open descriptor without a FLOCK does not suffice.
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  flock -n "$fd"
  jq '.pid=2147483647' "$S/image-progress.json" >"$S/next.json"
  mv "$S/next.json" "$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  # A live owner which has no descriptor to this lock also fails.
  (exec {fd}>&-; sleep 30) &
  local live=$!
  BG_PIDS+=("$live")
  jq -nc --argjson p "$live" '{operation:"restore",phase:"checking",done:0,total:0,pid:$p}' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  echo '{broken' >"$S/image-progress.json"
  run cmd_panel
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  exec {fd}>&-
  kill "$live"
  wait "$live" || true
}

non_object_progress() {
  : >"$S/lock"
  printf '%s\n' "$1" >"$S/image-progress.json"
  shim systemctl 'echo inactive'
  export PATH=$T/shims:$PATH
  lanai_run panel
  assert_success
  assert_equal "$(jq -r '.progress' <<<"$output")" null
  assert_equal "$stderr" ""
}

@test "panel progress: null document is ignored through lanai panel" { non_object_progress null; }
@test "panel progress: array document is ignored through lanai panel" { non_object_progress '[]'; }
@test "panel progress: number document is ignored through lanai panel" { non_object_progress 42; }
@test "panel progress: string document is ignored through lanai panel" { non_object_progress '"hashing"'; }

# Check both the transport action and the words shown by the icon.
assert_right_click() {
  assert_equal "$(jq -r .right_click <<<"$output")" "$1"
  local words
  case $1 in
    start) words='Right-click: Start Windows.' ;;
    open) words='Right-click: Open the Windows window.' ;;
    panel) words='Right-click: Open the panel.' ;;
  esac
  assert_equal "$(jq -r .right_click_tooltip <<<"$output")" "$words"
}

@test "panel clicks: stopped requires current finished setup and no unfinished restore" {
  state "$CURRENT"
  run cmd_panel
  assert_success
  assert_right_click start
  state '{"snapshot":"declined"}'
  run cmd_panel
  assert_success
  assert_right_click panel
  state "$CURRENT"
  : >"$S/restore-in-progress"
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .buttons.start.enable <<<"$output")" false
  assert_right_click panel
}

@test "panel clicks: setup and final check boots open the panel" {
  local boot
  ST=active
  state '{"snapshot":"declined","done":true,"round":true,"step5":true}'
  for boot in setup step6; do
    echo "{\"$boot\":true,\"window\":false}" >"$S/boot.json"
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.finished <<<"$output")" false
    assert_right_click panel
  done
}

@test "panel clicks: finished running install opens only its closed window" {
  state "$CURRENT"
  ST=active
  local window
  for window in false true; do
    status_facts() { printf 'ActiveState=active\nLanaiSetup=done\nLanaiQmp=running\nLanaiQga=open\nLanaiWindow=%s\n' "$window"; }
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.finished <<<"$output")" true
    if [[ $window == false ]]; then assert_right_click open; else assert_right_click panel; fi
  done
}

@test "panel clicks: CLI and panel snapshot or restore block Start but allow Open" {
  local origin operation fd pid=$BASHPID
  state "$CURRENT"
  for origin in cli panel; do
    for operation in snapshot restore; do
      exec {fd}>"$S/lock"
      flock -n "$fd"
      jq -nc --argjson p "$pid" --arg op "$operation" '{operation:$op,phase:"checking",done:0,total:100,pid:$p}' >"$S/image-progress.json"
      if [[ $origin == panel ]]; then
        exec {PANEL_CLICK_FD}>"$S/panel-job.lock"
        flock -n "$PANEL_CLICK_FD"
        panel_result_write snapshots "$(jq -nc --arg op "$operation" '{command:$op,started:1}')"
      fi
      ST=inactive
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .busy.active <<<"$output")" true
      assert_equal "$(jq -r .buttons.start.enable <<<"$output")" false
      assert_right_click panel
      ST=active
      status_facts() { printf 'ActiveState=%s\nLanaiSetup=done\nLanaiQmp=running\nLanaiQga=open\n' "$ST"; }
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .buttons.open.enable <<<"$output")" true
      assert_right_click open
      exec {fd}>&-
      [[ $origin != panel ]] || exec {PANEL_CLICK_FD}>&-
      rm -f "$S/image-progress.json" "$S/panel-result-snapshots.json"
    done
  done
}

@test "panel clicks: pending panel launch opens the panel until it starts" {
  state "$CURRENT"
  run cmd_panel --pending click-job "$EPOCHSECONDS"
  assert_success
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  assert_right_click panel
}

@test "panel clicks: active panel setup work blocks the stopped shortcut" {
  state "$CURRENT"
  local fd
  exec {fd}>"$S/panel-job.lock"
  flock -n "$fd"
  panel_result_write setup '{"command":"setup","started":1}'
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .busy.active <<<"$output")" true
  assert_right_click panel
  exec {fd}>&-
}

@test "panel restore refusal: explains unsupported storage and how to continue" {
  local words reply
  reply='{"ok":false,"reason":"restore-unsupported"}'
  words='The restore was refused because Lanai cannot verify an instant copy in this storage location. Choose storage that supports verified instant copies, then try again.'
  run panel_words restore "$reply"
  assert_success
  assert_output "$words"
  state "$CURRENT"
  jq -nc --argjson reply "$reply" '{command:"restore",reply:$reply}' >"$S/panel-result-snapshots.json"
  shim systemctl 'printf "ActiveState=inactive\nResult=success\nInvocationID=\n"'
  export PATH=$T/shims:$PATH
  lanai_run panel
  assert_success
  assert_equal "$(jq -r .result.snapshots <<<"$output")" "$words"
}

@test "panel restore: unfinished recovery offers finishing or every other snapshot through lanai panel" {
  make_install "$STORE"
  local name snap root=$XDG_DATA_HOME/lanai/snapshots
  for name in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do
    snap=$root/$name
    mkdir -p "$snap"
    cp "$STORE/"* "$snap/"
    echo "$STORE" >"$snap/SOURCE"
    tree_manifest "$STORE" >"$snap/COMPLETE"
  done
  printf '%s\n%s\n' "$root/20260101T000000Z" "$STORE" >"$S/restore-in-progress"
  shim systemctl 'printf "ActiveState=inactive\nResult=success\nInvocationID=\n"'
  export PATH=$T/shims:$PATH
  lanai_run panel
  assert_success
  assert_equal "$(jq -r .buttons.finish_restore.enable <<<"$output")" true
  assert_equal "$(jq -r .buttons.restore_snapshot.enable <<<"$output")" true
  assert_equal "$(jq -r .buttons.restore_confirm.enable <<<"$output")" true
  for name in 20260102T000000Z 20260103T000000Z; do
    assert_equal "$(jq -r --arg n "$name" '.buttons.restore_snapshot.labels[$n]' <<<"$output")" "Restore snapshot $name"
  done
  assert_equal "$(jq -r .next <<<"$output")" 'When Windows is stopped, finish the unfinished restore or restore another snapshot.'
  refute_output --partial 'lanai restore'
  refute_output --partial '—'
}

@test "panel restore: a refusal during unfinished recovery never claims Windows was unchanged" {
  state "$CURRENT"
  : >"$S/restore-in-progress"
  panel_result_write snapshots '{"command":"restore","reply":{"ok":false,"reason":"restore-unsupported","message":"Lanai cannot verify the image. The restore is still unfinished."}}'
  shim systemctl 'printf "ActiveState=inactive\nResult=success\nInvocationID=\n"'
  export PATH=$T/shims:$PATH
  lanai_run panel
  assert_success
  refute_output --partial 'Nothing was changed.'
  assert_output --partial 'restore another snapshot'
}

@test "panel activity: gathers once and reuses the result for the storage check" {
  state "$CURRENT"
  shim python3 'if [[ $1 == */image-proof.py && $2 == activity ]]; then
  echo activity >>"$T/activity-calls"
  echo "{\"label\":\"Restoring Windows: replacing the disk\",\"percent\":99}"
  exit 0
fi
exec /usr/bin/python3 "$@"'
  export PATH=$T/shims:$PATH
  layout_check() { echo "${2:-full}" >>"$T/layout-calls"; }
  run cmd_panel
  assert_success
  assert_equal "$(cat "$T/activity-calls")" activity
  assert_equal "$(cat "$T/layout-calls")" structural
  assert_equal "$(jq -r .progress.label <<<"$output")" 'Restoring Windows: replacing the disk'
}

# --- the resize upgrade: a client built without the current patches, or a
# scale task without the sign-in step (req 12) ---

RESIZE_NEW='Windows may start at, or change to, the wrong size until you click Update the Windows window in More actions. Updating changes nothing in Windows.'
BOTH='Windows may start at the wrong size and stay there until you resize the window, and it may change to the wrong size while it runs.'
SIGNIN='After Windows starts, it may stay at its old size until you resize the window.'
SCALE='Scale saves apply only the next time Windows starts.'
LOCK='Running setup again also turns the Windows lock off again.'
CLIENT_DONE='The Windows window is updated. If the Windows window is open, close it and open it again.'
CLIENT_INTERRUPTED='The update did not finish. Click Update the Windows window in More actions again.'

# Assert the panel's warning is <stopped words> while Windows is stopped and
# <running words> while it runs, with no Update button and no note under
# the scale list (the warning names Run setup again once).
assert_rerun_warning() {
  ST=inactive
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .setup.finished <<<"$output")" true
  assert_equal "$(jq -r .warning <<<"$output")" "$1"
  assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" false
  assert_equal "$(jq -r .settings.note <<<"$output")" ''
  assert_equal "$(jq -c '.buttons.continue_setup | [.show,.enable,.label]' <<<"$output")" '[true,true,"Run setup again"]'
  ST=active
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" "$2"
  assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" false
  # The live task's pick note may show while Windows runs; it never names
  # Run setup again.
  assert_equal "$(jq -r '.settings.note | contains("Run setup again")' <<<"$output")" false
}

@test "panel resize: an old client with the live scale task and the sign-in step warns and offers the update, stopped or running" {
  state "$CURRENT"
  build_patches_current() { return 1; }
  for ST in inactive active; do
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.finished <<<"$output")" true
    # The warning is the bar tooltip's source too (LanaiModel.qml).
    assert_equal "$(jq -r .warning <<<"$output")" "$RESIZE_NEW"
    assert_equal "$(jq -c '.buttons.update_client | [.show,.enable,.label]' <<<"$output")" '[true,true,"Update the Windows window"]'
  done
  # Start stays available beside the warning.
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -r '.buttons.start.show and .buttons.start.enable' <<<"$output")" true
}

@test "panel resize: a current client without the sign-in step names Run setup again and the lock" {
  state '{"done":true,"scale_task":2}'
  assert_rerun_warning "$SIGNIN To fix this, click Run setup again in More actions. $LOCK" \
    "$SIGNIN To fix this, shut Windows down and click Run setup again in More actions. $LOCK"
  # A mark other than the current one counts as missing: 1 is phase F's
  # step in PowerShell, before the start program.
  state '{"done":true,"scale_task":2,"signin_step":1}'
  assert_rerun_warning "$SIGNIN To fix this, click Run setup again in More actions. $LOCK" \
    "$SIGNIN To fix this, shut Windows down and click Run setup again in More actions. $LOCK"
}

@test "panel resize: an old client without the sign-in step names only Run setup again, in one sentence for both" {
  state '{"done":true,"scale_task":2}'
  build_patches_current() { return 1; }
  assert_rerun_warning "$BOTH To fix this, click Run setup again in More actions. $LOCK" \
    "$BOTH To fix this, shut Windows down and click Run setup again in More actions. $LOCK"
}

@test "panel resize: the old scale task names Run setup again once, with the scale fix, and keeps the save words" {
  local oldtask='Until you run setup again, the old scale task undoes scales you pick in Windows, and “Match my monitor” does not follow the window. Running setup again also turns the Windows lock off again.'
  state '{"done":true}'
  assert_rerun_warning "$SIGNIN $SCALE To fix both, click Run setup again in More actions. $LOCK" \
    "$SIGNIN $SCALE To fix both, shut Windows down and click Run setup again in More actions. $LOCK"
  # A scale save's reply keeps its words: it answers the save.
  panel_result_write settings '{"command":"settings","invocation":"inv","ended":1,"reply":{"ok":true,"scale_saved":true,"running":true,"scale_task_kind":"old"}}'
  ST=active INV=inv
  run cmd_panel
  assert_equal "$(jq -r .result.settings <<<"$output")" "Saved. Windows uses the saved scale the next time it starts. $oldtask"
  # With an old client too: one message.
  build_patches_current() { return 1; }
  assert_rerun_warning "$BOTH $SCALE To fix both, click Run setup again in More actions. $LOCK" \
    "$BOTH $SCALE To fix both, shut Windows down and click Run setup again in More actions. $LOCK"
}

@test "panel resize: the live task's save words are the same with and without the sign-in step" {
  local live='Saved. Windows uses the saved scale within 5 seconds if you'"'"'re signed in, or when you next sign in.'
  panel_result_write settings '{"command":"settings","invocation":"inv","ended":1,"reply":{"ok":true,"scale_saved":true,"running":true,"scale_task_kind":"new"}}'
  ST=active INV=inv
  for doc in "$CURRENT" '{"done":true,"scale_task":2}'; do
    state "$doc"
    run cmd_panel
    assert_equal "$(jq -r .result.settings <<<"$output")" "$live"
    assert_equal "$(jq -r .settings.note <<<"$output")" 'Saving a scale replaces one you picked in Windows.'
  done
}

@test "panel resize: an older pin's build in use shows only the driver update words" {
  # No sign-in mark on purpose: req 8's words still replace the warning.
  state '{"done":true,"scale_task":2}'
  build_patches_current() { return 1; }
  guest_version_behind() { echo B7-801-g1a2b3c4d5e; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .warning <<<"$output")" 'The Windows display driver needs an update. Shut down and continue setup.'
  assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" false
  # With the old task, the note under the scale list names the scale fix
  # again, with the button that shows: the plan is not finished.
  state '{"done":true}'
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" 'The Windows display driver needs an update. Shut down and continue setup.'
  assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Continue setup'
  assert_equal "$(jq -r .settings.note <<<"$output")" 'Scale saves apply the next time Windows starts. To make them apply while Windows runs, click Continue setup.'
  ST=active
  run cmd_panel
  assert_equal "$(jq -r .settings.note <<<"$output")" 'Scale saves apply the next time Windows starts. To make them apply while Windows runs, shut Windows down and click Continue setup.'
}

@test "panel resize: an old client never names a hidden update button" {
  # A sign-in mark without the live task's record: no update button, so
  # no update warning either.
  state "$(jq -nc --argjson i "$LANAI_SIGNIN_STEP" '{done:true,signin_step:$i}')"
  build_patches_current() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" false
  assert_equal "$(jq -r '.warning | contains("Update the Windows window")' <<<"$output")" false
}

@test "panel resize: current patches with the sign-in step, or an unfinished setup, show neither the warning nor the button" {
  state "$CURRENT"
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" ''
  assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" false
  build_patches_current() { return 1; }
  state '{"snapshot":"declined"}'
  run cmd_panel
  assert_equal "$(jq -r .setup.finished <<<"$output")" false
  assert_equal "$(jq -r .warning <<<"$output")" ''
  assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" false
  # A setup round that has not recorded the step yet warns of nothing.
  state '{"snapshot":"declined","done":true,"scale_task":2,"round":true}'
  run cmd_panel
  assert_equal "$(jq -r .warning <<<"$output")" ''
}

@test "panel resize: the update button shows disabled while a panel job runs, and the busy line names the update" {
  local fd
  state "$CURRENT"
  build_patches_current() { return 1; }
  panel_result_write client '{"token":"t","command":"build-client","args":[],"started":5}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  ST=inactive
  run cmd_panel
  assert_equal "$(jq -c '.buttons.update_client | [.show,.enable]' <<<"$output")" '[true,false]'
  assert_equal "$(jq -r .buttons.start.enable <<<"$output")" false
  assert_equal "$(jq -r .busy.line <<<"$output")" 'Updating the Windows window. This may take several minutes. You can start Windows when it finishes.'
  # A running Windows has no Start button to wait for.
  ST=active
  run cmd_panel
  assert_equal "$(jq -r .busy.line <<<"$output")" 'Updating the Windows window. This may take several minutes.'
  exec {fd}>&-
}

@test "panel words: build-client replies, and the logs block names the build log" {
  run panel_words build-client '{"ok":true,"client":"/x","build":"B7"}'
  assert_output "$CLIENT_DONE"
  run panel_words build-client '{"ok":false,"message":"UNTRUSTED","next":"UNTRUSTED"}'
  assert_output 'The Windows window could not be updated. Check the Windows window build log (build-client.log), then try again.'
  run panel_words build-client '{"ok":false,"reason":"build-busy","message":"UNTRUSTED"}'
  assert_output 'Another build of the Windows window is running. Try again when it finishes.'
  # ui_call writes the CLI's stderr to the job log, not the build log.
  run panel_words build-client '{"ok":false,"reason":"invalid-reply"}'
  assert_output 'Lanai did not give a readable reply. Check the update log and try again.'
  run cmd_panel
  assert_equal "$(jq -r .logs.build <<<"$output")" "Windows window build log: $S/build-client.log"
}

@test "panel resize: the done words stay until a client starts after the update ended" {
  state "$CURRENT"
  panel_result_write client '{"token":"t","command":"build-client","args":[],"started":1000.25,"ended":1100.5,"reply":{"ok":true}}'
  # No client since: the window was closed when the update finished.
  rm -f "$RUN/client.log"
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" "$CLIENT_DONE"
  # The client that ran during the update is still the old one.
  printf '%s 1100\nlog\n' "$LANAI_CLIENT_START" >"$RUN/client.log"
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" "$CLIENT_DONE"
  # A VM start empties the log before its client starts.
  : >"$RUN/client.log"
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" "$CLIENT_DONE"
  printf '%s 1101\nlog\n' "$LANAI_CLIENT_START" >"$RUN/client.log"
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" ''
  # A reboot empties the runtime folder, so no client.log tells; an update
  # that ended before this boot is over too.
  rm -f "$RUN/client.log"
  printf 'cpu  1 2 3\nbtime 1100\n' >"$LANAI_PROC/stat"
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" "$CLIENT_DONE"
  printf 'cpu  1 2 3\nbtime 1101\n' >"$LANAI_PROC/stat"
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" ''
  # A client that is old again (new patches came with a Lanai update) ends
  # the done words at once: the warning names the update again.
  printf 'cpu  1 2 3\nbtime 1100\n' >"$LANAI_PROC/stat"
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" "$CLIENT_DONE"
  build_patches_current() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" ''
  assert_equal "$(jq -r .warning <<<"$output")" "$RESIZE_NEW"
}

@test "panel resize: an interrupted update has its own words and never arms Continue setup" {
  state "$CURRENT"
  build_patches_current() { return 1; }
  panel_result_write client '{"token":"t","command":"build-client","args":[],"started":1}'
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" "$CLIENT_INTERRUPTED"
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  assert_equal "$(jq -r .setup.attention <<<"$output")" false
  assert_equal "$(jq -r .buttons.update_client.enable <<<"$output")" true
  # On an unfinished setup the same record arms nothing either: setup's
  # interrupted words and its interrupted-setup button stay off.
  state '{"snapshot":"declined"}'
  build_stamp_current() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 4
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
}

@test "panel resize: failed and interrupted update words go once the client is current" {
  state "$CURRENT"
  build_patches_current() { return 1; }
  panel_result_write client '{"token":"t","command":"build-client","args":[],"started":1,"ended":2,"reply":{"ok":false}}'
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" 'The Windows window could not be updated. Check the Windows window build log (build-client.log), then try again.'
  build_patches_current() { return 0; }
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" ''
  panel_result_write client '{"token":"t","command":"build-client","args":[],"started":1}'
  run cmd_panel
  assert_equal "$(jq -r .result.client <<<"$output")" ''
}

@test "panel resize: failed and interrupted update words show only with the update button" {
  local doc st words
  build_patches_current() { return 1; }
  for doc in '{"token":"t","command":"build-client","args":[],"started":1,"ended":2,"reply":{"ok":false}}' \
    '{"token":"t","command":"build-client","args":[],"started":1}'; do
    panel_result_write client "$doc"
    # The button shows, so the words show.
    state "$CURRENT"
    run cmd_panel
    assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" true
    words=$(jq -r .result.client <<<"$output")
    [[ $words == "$CLIENT_INTERRUPTED" || $words == *"could not be updated"* ]] || fail "no update words: $words"
    # Without the sign-in step, or with the old task, Run setup again is
    # the one step: no button and no update words.
    for st in '{"done":true,"scale_task":2}' '{"done":true}'; do
      state "$st"
      run cmd_panel
      assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" false
      assert_equal "$(jq -r .result.client <<<"$output")" ''
    done
  done
}

@test "panel resize: a client build that fails in setup names the build log and the button it shows" {
  local again='Setup could not update the Windows window. Check the Windows window build log, then click Run setup again in More actions.'
  local cont='Setup could not prepare the Windows window. Check the Windows window build log, then click Continue setup.'
  local args
  run panel_words setup '{"ok":false,"step":"4","message":"UNTRUSTED"}' 7
  assert_output "$again"
  run panel_words setup '{"ok":false,"step":"4","message":"UNTRUSTED"}' 4
  assert_output "$cont"
  # Run setup again on an old client: the plan is finished (step 7), so
  # the step 4 failure holds while the client is still old. The panel's
  # Run setup again passes --window or --no-window.
  build_patches_current() { return 1; }
  for args in '["--window"]' '["--no-window"]'; do
    state '{"done":true,"scale_task":2}'
    panel_result_write setup "$(jq -nc --argjson a "$args" '{token:"t",command:"setup",args:$a,started:1,ended:2,reply:{ok:false,step:"4",message:"UNTRUSTED"}}')"
    run cmd_panel
    assert_equal "$(jq -r .result.setup <<<"$output")" "$again"
    assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Run setup again'
    # With the update button showing, the warning names the one step, so
    # the setup words go.
    state "$CURRENT"
    run cmd_panel
    assert_equal "$(jq -r .buttons.update_client.show <<<"$output")" true
    assert_equal "$(jq -r .result.setup <<<"$output")" ''
    assert_equal "$(jq -r .layout <<<"$output")" daily
    assert_equal "$(jq -r .bar.mode <<<"$output")" stopped
  done
  # A step 4 failure from a first setup (no display argument) is over once
  # the plan is finished, even with an old client.
  state '{"done":true,"scale_task":2}'
  panel_result_write setup '{"token":"t","command":"setup","args":[],"started":1,"ended":2,"reply":{"ok":false,"step":"4","message":"UNTRUSTED"}}'
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  assert_equal "$(jq -r .layout <<<"$output")" daily
  assert_equal "$(jq -r .bar.mode <<<"$output")" stopped
  # Once the client is current, the failure is over.
  panel_result_write setup '{"token":"t","command":"setup","args":["--window"],"started":1,"ended":2,"reply":{"ok":false,"step":"4","message":"UNTRUSTED"}}'
  build_patches_current() { return 0; }
  run cmd_panel
  assert_equal "$(jq -r .result.setup <<<"$output")" ''
  assert_equal "$(jq -r .layout <<<"$output")" daily
  assert_equal "$(jq -r .bar.mode <<<"$output")" stopped
  # A first setup stays at step 4 with Continue setup.
  build_patches_current() { return 1; }
  build_stamp_current() { return 1; }
  state '{"snapshot":"declined"}'
  run cmd_panel
  assert_equal "$(jq -r .setup.step <<<"$output")" 4
  assert_equal "$(jq -r .result.setup <<<"$output")" "$cont"
  assert_equal "$(jq -r .buttons.continue_setup.label <<<"$output")" 'Continue setup'
}


@test "redesign failure: a failed rerun client build opens Logs and marks the bar Failed" {
  local args
  build_patches_current() { return 1; }
  state '{"done":true,"scale_task":2}'
  for args in '["--window"]' '["--no-window"]'; do
    panel_result_write setup "$(jq -nc --argjson a "$args" '{command:"setup",args:$a,invocation:"inv",started:1,ended:2,reply:{ok:false,step:"4"}}')"
    for ST in inactive active; do
      run cmd_panel
      assert_success
      assert_equal "$(jq -r .setup.step <<<"$output")" 7
      assert_equal "$(jq -r .layout <<<"$output")" failed
      assert_equal "$(jq -r .header.badge <<<"$output")" Failed
      assert_equal "$(jq -r .sections.default <<<"$output")" logs
      assert_equal "$(jq -r .bar.mode <<<"$output")" failed
      assert_equal "$(jq -r .result.setup <<<"$output")" 'Setup could not update the Windows window. Check the Windows window build log, then click Run setup again in More actions.'
    done
  done
  # A failure from a previous VM invocation cannot mark this one Failed.
  INV=other
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .layout <<<"$output")" daily
  assert_equal "$(jq -r .bar.mode <<<"$output")" active
}

@test "redesign header: daily saved values include scale in Failed" {
  state "$CURRENT"
  jq '.memory_gib=12 | .cores=6 | .windows_scale=175' "$(settings_file)" >"$T/settings"
  mv "$T/settings" "$(settings_file)"
  for ST in inactive failed; do
    RESULT=exit-code
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .header.title <<<"$output")" Windows
    assert_equal "$(jq -r .header.meta <<<"$output")" '12 GiB · 6 cores · 175%'
    assert_equal "$(jq -r .header.badge <<<"$output")" "$([[ $ST == failed ]] && echo Failed || echo Stopped)"
    assert_equal "$(jq -r .layout <<<"$output")" "$([[ $ST == failed ]] && echo failed || echo daily)"
    assert_equal "$(jq -r .sections.default <<<"$output")" "$([[ $ST == failed ]] && echo logs || echo '')"
  done
  cmd_settings() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .header.meta <<<"$output")" ''
  assert_equal "$(jq -r .settings.baseline <<<"$output")" null
}

@test "redesign setup: Check through Verify map six steps and completion has no seventh step" {
  local step name number
  for step in 1 2 3 4 5 6 7; do
    setup_plan() { setup_decision "$step" "$([[ $step == 7 ]] && echo 'done' || echo checks)"; }
    case $step in
      1) name=Check ;; 2) name=Packages ;; 3) name=Snapshot ;; 4) name=Prepare ;;
      5) name=Drivers ;; 6) name=Verify ;; 7) name='' ;;
    esac
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .setup.name <<<"$output")" "$name"
    assert_equal "$(jq -r '.setup.steps | map(.name) | join(",")' <<<"$output")" 'Check,Packages,Snapshot,Prepare,Drivers,Verify'
    assert_equal "$(jq '[.setup.steps[] | select(.state == "current")] | length' <<<"$output")" "$([[ $step == 7 ]] && echo 0 || echo 1)"
    if [[ $step == 7 ]]; then
      assert_equal "$(jq -r .setup.number <<<"$output")" null
      assert_equal "$(jq -r .setup.step_line <<<"$output")" ''
      assert_equal "$(jq -r .layout <<<"$output")" daily
      assert_equal "$(jq '[.setup.steps[] | select(.state == "complete")] | length' <<<"$output")" 6
    else
      number=$step
      assert_equal "$(jq -r .header.meta <<<"$output")" "Step $number of 6 · $name"
      assert_equal "$(jq -r .header.badge <<<"$output")" Setup
      assert_equal "$(jq '[.setup.steps[] | select(.state == "complete")] | length' <<<"$output")" "$((step - 1))"
    fi
  done
}

@test "redesign setup: Prepare covers 3a and client build with their actual guidance" {
  state '{"snapshot":"declined"}'
  rm "$STORE/windows.base"
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.setup | [.number,.name,.step_line,.title]' <<<"$output")" '[4,"Prepare","Step 4 of 6","Prepare the Windows install"]'
  assert_equal "$(jq -r .header.meta <<<"$output")" 'Step 4 of 6 · Prepare'
  assert_equal "$(jq -r .setup.lines[0] <<<"$output")" 'Continue setup to prepare the Windows install.'
  echo base >"$STORE/windows.base"
  build_stamp_current() { return 1; }
  run cmd_panel
  assert_equal "$(jq -c '.setup | [.number,.name,.step_line,.title]' <<<"$output")" '[4,"Prepare","Step 4 of 6","Prepare the Windows window"]'
  assert_equal "$(jq -r .header.meta <<<"$output")" 'Step 4 of 6 · Prepare'
  assert_equal "$(jq -r .setup.lines[0] <<<"$output")" 'Continue setup to prepare the Windows window. This may take several minutes.'
}

@test "redesign verify: checklist labels and aggregate states follow actual outcomes" {
  state '{"snapshot":"declined","step5":true}'
  ST=active
  echo "$((EPOCHSECONDS - 10))" >"$RUN/step6-since"
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.setup.checks | map(.label)' <<<"$output")" '["Display driver","Windows agents","Scale task"]'
  assert_equal "$(jq -c '.setup.checks | map(.state)' <<<"$output")" '["not_checked","not_checked","not_checked"]'
  redesign_check_detail '{"idd":{"state":"done"},"spice":{"state":"done"},"clock":{"state":"waiting","reason":"clock"},"allowlist":{"state":"not_checked"},"scale":{"state":"not_checked"}}'
  run cmd_panel
  assert_equal "$(jq -c '.setup.checks | map(.state)' <<<"$output")" '["done","waiting","not_checked"]'
  assert_equal "$(jq -r .setup.checks[1].detail <<<"$output")" 'Waiting for the QEMU guest agent clock.'
  redesign_check_detail '{"idd":{"state":"failed","reason":"mismatch"},"spice":{"state":"not_checked"},"clock":{"state":"not_checked"},"allowlist":{"state":"failed","reason":"allowlist"},"scale":{"state":"not_checked"}}'
  run cmd_panel
  assert_equal "$(jq -r .setup.checks[0].status <<<"$output")" Failed
  assert_equal "$(jq -r .setup.checks[1].detail <<<"$output")" 'The QEMU guest agent allow-list failed.'
  echo "$((EPOCHSECONDS - 5))" >"$RUN/step6-checked"
  run cmd_panel
  assert_equal "$(jq -c '.setup.checks | map(.status)' <<<"$output")" '["Done","Done","Not checked"]'
  rm "$RUN/step6-checks.json"
  run cmd_panel
  assert_equal "$(jq -c '.setup.checks | map(.state)' <<<"$output")" '["done","done","not_checked"]'
}

@test "redesign countdown: active worker exposes remaining duration and stopped work hides it" {
  local fd before after started limit=180
  state '{"snapshot":"declined","step5":true}'
  ST=active
  export LANAI_SETUP_SCALE_LIMIT=$limit
  started=$((EPOCHSECONDS - 30))
  echo "$((started - 5))" >"$RUN/step6-since"
  echo "$started" >"$RUN/step6-checked"
  echo "$limit" >"$RUN/step6-scale-limit"
  redesign_check_detail '{"idd":{"state":"done"},"spice":{"state":"done"},"clock":{"state":"done"},"allowlist":{"state":"done"},"scale":{"state":"waiting","reason":"scale-task"}}'
  panel_result_write setup "$(jq -nc --argjson t "$started" '{command:"setup",invocation:"inv",started:$t,reply:{ok:true,step:"6"}}')"
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  before=$EPOCHSECONDS
  run cmd_panel
  after=$EPOCHSECONDS
  assert_success
  assert_equal "$(jq -r .setup.countdown.started_at <<<"$output")" "$started"
  assert_equal "$(jq -r .setup.countdown.limit_seconds <<<"$output")" "$limit"
  assert_equal "$(jq -r .setup.countdown.label <<<"$output")" 'Time remaining to sign in'
  assert_equal "$(jq -r .bar.mode <<<"$output")" attention
  assert [ "$(jq .setup.countdown.remaining_seconds <<<"$output")" -ge "$((limit - (after - started)))" ]
  assert [ "$(jq .setup.countdown.remaining_seconds <<<"$output")" -le "$((limit - (before - started)))" ]
  refute_output --partial 'within 2 minutes'
  : >"$RUN/step6-stopped"
  run cmd_panel
  assert_equal "$(jq .setup.countdown <<<"$output")" null
  rm "$RUN/step6-stopped"
  INV=other
  run cmd_panel
  assert_equal "$(jq .setup.countdown <<<"$output")" null
  INV=inv
  export LANAI_SETUP_SCALE_LIMIT=120
  run cmd_panel
  assert_equal "$(jq .setup.countdown.limit_seconds <<<"$output")" "$limit"
  export LANAI_SETUP_SCALE_LIMIT=invalid
  run cmd_panel
  assert_equal "$(jq .setup.countdown.limit_seconds <<<"$output")" "$limit"
  echo invalid >"$RUN/step6-scale-limit"
  run cmd_panel
  assert_equal "$(jq .setup.countdown <<<"$output")" null
  echo "$limit" >"$RUN/step6-scale-limit"
  export LANAI_SETUP_SCALE_LIMIT=$limit
  rm "$RUN/step6-checked"
  run cmd_panel
  assert_equal "$(jq .setup.countdown <<<"$output")" null
  echo "$((EPOCHSECONDS + 10))" >"$RUN/step6-checked"
  run cmd_panel
  assert_equal "$(jq .setup.countdown <<<"$output")" null
  echo "$((EPOCHSECONDS - 200))" >"$RUN/step6-since"
  echo "$((EPOCHSECONDS - 190))" >"$RUN/step6-checked"
  redesign_check_detail '{"idd":{"state":"done"},"spice":{"state":"done"},"clock":{"state":"done"},"allowlist":{"state":"done"},"scale":{"state":"waiting","reason":"scale-task"}}'
  run cmd_panel
  assert_equal "$(jq .setup.countdown.remaining_seconds <<<"$output")" 0
  assert_equal "$(cat "$RUN/step6-checked")" "$(jq .setup.countdown.started_at <<<"$output")"
  exec {fd}>&-
  run cmd_panel
  assert_equal "$(jq .setup.countdown <<<"$output")" null
}

@test "redesign logs: every available row has exact copy text and a short display name" {
  local id path
  run cmd_panel
  assert_success
  assert_equal "$(jq -c '.logs.rows | map(.id)' <<<"$output")" '["vm"]'
  assert_equal "$(jq -r .logs.rows[0].copy_text <<<"$output")" "$LANAI_LOGS"
  for path in "$RUN/client.log" "$S/build-client.log" "$S/panel-job.log" "$S/panel-run.log"; do : >"$path"; done
  run cmd_panel
  assert_equal "$(jq -c '.logs.rows | map(.label)' <<<"$output")" '["VM","Window","Build","Jobs","Actions"]'
  for id in client build job command; do
    case $id in client) path=$RUN/client.log ;; build) path=$S/build-client.log ;;
      job) path=$S/panel-job.log ;; command) path=$S/panel-run.log ;; esac
    assert_equal "$(jq -r --arg id "$id" '.logs.rows[] | select(.id == $id) | .copy_text' <<<"$output")" "$path"
    assert_equal "$(jq -r --arg id "$id" '.logs.rows[] | select(.id == $id) | .display' <<<"$output")" "${path##*/}"
  done
  assert_equal "$(jq -r .logs.copied <<<"$output")" Copied
  assert_equal "$(jq -r .logs.copy_error <<<"$output")" 'Could not copy. Try again.'
  assert_equal "$(jq -r .logs.copy_busy <<<"$output")" 'Another copy is in progress. Try again in a moment.'
  assert_equal "$(jq -r .logs.rows[0].copy_label <<<"$output")" 'Copy VM log command'
  rm "$S/panel-job.log"
  run cmd_panel
  assert_equal "$(jq '[.logs.rows[] | select(.id == "job")] | length' <<<"$output")" 0
  run_dir() { return 1; }
  run cmd_panel
  assert_equal "$(jq '[.logs.rows[] | select(.id == "client")] | length' <<<"$output")" 0
}

@test "redesign settings: baseline and Save Saved Reset Unsaved words come from backend" {
  run cmd_panel
  assert_success
  assert_equal "$(jq -c .settings.baseline <<<"$output")" '{"memory_gib":8,"cores":4,"windows_scale":"auto"}'
  assert_equal "$(jq -c .settings.labels <<<"$output")" '{"memory":"Memory (GiB)","cores":"CPU cores","scale":"Windows scale","save":"Save","saved":"Saved","reset":"Reset","unsaved":"Unsaved"}'
  assert_equal "$(jq -c .sections <<<"$output")" '{"settings":"Settings","snapshots":"Snapshots","logs":"Logs","more":"More actions","dismiss_click_notice":"Dismiss busy notice","default":""}'
  printf invalid >"$(settings_file)"
  run cmd_panel
  assert_success
  assert_equal "$(jq .settings.baseline <<<"$output")" null
  assert_equal "$(jq -r .buttons.save_settings.enable <<<"$output")" false
}

@test "redesign bar: failure attention busy active stopped priority and Drivers exception" {
  local fd image_fd pid=$BASHPID total
  state "$CURRENT"
  run cmd_panel
  assert_success
  assert_equal "$(jq -c .bar <<<"$output")" '{"mode":"stopped","percent":null,"label":"Stopped"}'
  ST=activating
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" active
  ST=deactivating
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" active
  ST=inactive
  exec {image_fd}>"$S/lock"; flock "$image_fd"
  for total in 0 100; do
    jq -nc --argjson p "$pid" --argjson t "$total" '{operation:"snapshot",phase:"hashing",done:0,total:$t,pid:$p}' >"$S/image-progress.json"
    run cmd_panel
    assert_equal "$(jq -r .bar.mode <<<"$output")" busy
    assert_equal "$(jq .bar.percent <<<"$output")" "$([[ $total == 0 ]] && echo null || echo 0)"
  done
  exec {image_fd}>&-
  rm "$S/image-progress.json"
  state '{"snapshot":"declined"}'
  ST=active
  echo '{"setup":true}' >"$S/boot.json"
  panel_result_write setup '{"command":"setup","started":1,"reply":{"ok":true,"step":"5"}}'
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" active
  exec {fd}>&-
  panel_result_write setup '{"command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"5"}}'
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" active
  panel_result_write vm '{"command":"stop","invocation":"inv","started":2,"ended":3,"reply":{"ok":false}}'
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
  rm "$S/panel-result-vm.json"
  : >"$S/restore-in-progress"
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
  assert_equal "$(jq -r .layout <<<"$output")" restoring
  rm "$S/restore-in-progress"
  ST=failed RESULT=exit-code
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
}

@test "redesign bar: setup timeout and user prompts request attention despite unsuccessful replies" {
  local fd
  state '{"snapshot":"declined","step5":true}'
  ST=active
  timeout_record scale-task
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .bar.mode <<<"$output")" attention
  assert_equal "$(jq -r .layout <<<"$output")" setup_timeout
  assert_equal "$(jq -r .header.meta <<<"$output")" 'Step 6 of 6 · Verify · Starting'
  # A newer attempt supersedes the old timeout even under the same invocation.
  echo "$EPOCHSECONDS" >"$RUN/step6-since"
  run cmd_panel
  assert_equal "$(jq -r .layout <<<"$output")" setup_verify
  state '{}'
  ST=inactive
  rm "$RUN/step6-since"
  panel_result_write setup '{"command":"setup","started":1,"ended":2,"reply":{"ok":false,"step":"3"}}'
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" attention
  host_packages_missing() { echo package; }
  panel_result_write setup '{"command":"setup","started":1,"ended":2,"reply":{"ok":false,"step":"2","missing":["package"]}}'
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" attention
  exec {fd}>"$S/panel-job.lock"; flock "$fd"
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" attention
  exec {fd}>&-
  state "$CURRENT"
  ST=active INV=new
  panel_result_write vm '{"command":"start","invocation":"old","started":1,"ended":2,"reply":{"ok":false}}'
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" active
}

@test "redesign header: first setup timeout reports the actual VM state" {
  local vm expected
  state '{"snapshot":"declined","step5":true}'
  timeout_record scale-task
  qmp_call() { printf '%s\n' '{"return":{"status":"running"}}' '{"return":[{"label":"qga0","frontend-open":true}]}'; }
  for vm in inactive active activating deactivating failed; do
    ST=$vm
    case $vm in
      active) expected=Running ;;
      inactive) expected=Stopped ;;
      activating) expected=Starting ;;
      deactivating) expected='Shutting down' ;;
      failed) expected=Failed ;;
    esac
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .layout <<<"$output")" setup_timeout
    assert_equal "$(jq -r .header.meta <<<"$output")" "Step 6 of 6 · Verify · $expected"
    assert_equal "$(jq -r .header.badge <<<"$output")" Setup
  done
  ST=active
  qmp_call() { printf '{"return":{"status":"running"}}\n'; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .header.meta <<<"$output")" 'Step 6 of 6 · Verify · Starting'
}

@test "redesign bar: Drivers active exception never hides failure or recovery" {
  local fd worker reason
  state '{"snapshot":"declined"}'
  ST=active
  echo '{"setup":true}' >"$S/boot.json"
  for worker in false true; do
    panel_result_write setup '{"command":"setup","started":1,"reply":{"ok":true,"step":"5"}}'
    if $worker; then
      exec {fd}>"$S/panel-job.lock"; flock "$fd"
    else
      panel_result_write setup '{"command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"5"}}'
    fi
    run cmd_panel
    assert_success
    assert_equal "$(jq -r .bar.mode <<<"$output")" active
    assert_equal "$(jq -r .bar.label <<<"$output")" Active
    assert_equal "$(jq .bar.percent <<<"$output")" null
    for reason in mismatch allowlist; do
      panel_result_write setup "$(jq -nc --arg r "$reason" '{command:"setup",started:1,ended:2,reply:{ok:false,step:"5",reason:$r}}')"
      run cmd_panel
      assert_equal "$(jq -r .bar.mode <<<"$output")" failed
      assert_equal "$(jq -r .bar.label <<<"$output")" Failed
    done
    panel_result_write setup '{"command":"setup","started":1,"ended":2,"reply":{"ok":true,"step":"5"}}'
    panel_result_write vm '{"command":"stop","invocation":"inv","started":2,"ended":3,"reply":{"ok":false}}'
    run cmd_panel
    assert_equal "$(jq -r .bar.mode <<<"$output")" failed
    rm "$S/panel-result-vm.json"
    : >"$S/restore-in-progress"
    run cmd_panel
    assert_equal "$(jq -r .bar.mode <<<"$output")" failed
    assert_equal "$(jq -r .layout <<<"$output")" restoring
    rm "$S/restore-in-progress"
    ST=failed RESULT=exit-code
    run cmd_panel
    assert_equal "$(jq -r .bar.mode <<<"$output")" failed
    ST=active RESULT=success
    if $worker; then exec {fd}>&-; fi
  done
}

@test "redesign actions: every existing guard survives the presentation choice" {
  local boot
  state "$CURRENT"
  build_patches_current() { return 1; }
  run cmd_panel
  assert_success
  assert_equal "$(jq -r .primary_action <<<"$output")" start
  assert_equal "$(jq -c '.buttons.start | [.show,.enable]' <<<"$output")" '[true,true]'
  ST=active
  qmp_call() { printf '{"return":{"status":"running"}}\n{"return":[{"label":"qga0","frontend-open":true}]}\n'; }
  run cmd_panel
  assert_equal "$(jq -r .primary_action <<<"$output")" open
  assert_equal "$(jq -c '.buttons.open | [.show,.enable]' <<<"$output")" '[true,true]'
  build_patches_current() { return 0; }
  state '{"snapshot":"declined","done":true,"round":true,"step5":true}'
  for boot in setup step6; do
    echo "{\"$boot\":true,\"window\":false}" >"$S/boot.json"
    run cmd_panel
    assert_equal "$(jq -r '.buttons.start.show or .buttons.open.show' <<<"$output")" false
    assert_equal "$(jq -r '.primary_action as $a | $a == null or .buttons[$a].show' <<<"$output")" true
    assert_equal "$(jq -r .buttons.stop.confirm <<<"$output")" "$([[ $boot == setup ]] && echo true || echo false)"
  done
  echo 'inv 1' >"$S/stop-requested"
  run cmd_panel
  assert_equal "$(jq -r .buttons.stop.confirm <<<"$output")" false
  assert_equal "$(jq -r .buttons.force_stop.enable <<<"$output")" true
  echo "inv $EPOCHSECONDS" >"$S/stop-requested"
  run cmd_panel
  assert_equal "$(jq -r .buttons.force_stop.show <<<"$output")" false
  assert_equal "$(jq -r .buttons.open.enable <<<"$output")" false
  ST=inactive
  : >"$S/restore-in-progress"
  run cmd_panel
  assert_equal "$(jq -c '[.buttons.start.enable,.buttons.take_snapshot.enable,.buttons.finish_restore.enable]' <<<"$output")" '[false,false,true]'
  assert_equal "$(jq -r .primary_action <<<"$output")" finish_restore
  container_fact() { echo running; }
  run cmd_panel
  assert_equal "$(jq -c '[.buttons.take_snapshot.enable,.buttons.finish_restore.enable,.buttons.restore_snapshot.enable]' <<<"$output")" '[false,false,false]'
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
  rm "$S/restore-in-progress"
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" attention
  container_fact() { echo none; }
  state '{"snapshot":"declined"}'
  ST=active
  echo '{"setup":true,"window":true}' >"$S/boot.json"
  rm "$S/stop-requested"
  client_active() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .buttons.reopen_window.show <<<"$output")" false
  assert_equal "$(jq -c '.buttons.stop | [.show,.enable,.confirm]' <<<"$output")" '[true,true,true]'
  echo '{"setup":true,"window":false}' >"$S/boot.json"
  run cmd_panel
  assert_equal "$(jq -c '.buttons.reopen_window | [.show,.enable]' <<<"$output")" '[true,true]'
  state "$CURRENT"
  echo '{"setup":false,"window":false}' >"$S/boot.json"
  helper_alive() { return 1; }
  run cmd_panel
  assert_equal "$(jq -r .layout <<<"$output")" failed
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
  assert_output --partial 'Some background services stopped.'
  assert_equal "$(jq -r .buttons.force_stop.show <<<"$output")" false
  helper_alive() { return 0; }
  ST=unknown
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
  assert_equal "$(jq -r .sections.default <<<"$output")" logs
  assert_equal "$(jq -r .buttons.force_stop.show <<<"$output")" false
  ST=inactive
  panel_result_write vm '{"command":"start","invocation":"inv","started":1,"ended":2,"reply":{"ok":false}}'
  run cmd_panel
  assert_equal "$(jq -c '[.layout,.header.badge,.sections.default,.bar.mode]' <<<"$output")" '["failed","Failed","logs","failed"]'
  assert_equal "$(jq -r .buttons.force_stop.show <<<"$output")" false
  panel_result_write vm '{"command":"start","invocation":"inv","started":3,"ended":4,"reply":{"ok":true}}'
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" stopped
  panel_result_write setup '{"command":"setup","started":1}'
  run cmd_panel
  assert_equal "$(jq -r .bar.mode <<<"$output")" failed
  assert_output --partial 'Setup was interrupted.'
  rm "$S/panel-result-setup.json"
  run cmd_panel --pending missing 1
  assert_equal "$(jq -c '[.layout,.sections.default,.bar.mode]' <<<"$output")" '["failed","logs","failed"]'
  assert_output --partial 'The operation did not start.'
}
