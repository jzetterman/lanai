#!/usr/bin/env bats
# Real QML with inert shell/Process types: no compositor, services or subprocesses.
load helpers
setup() { isolate_home; T=$BATS_TEST_TMPDIR; }

@test "QML renderer: poll cadence, refresh races, literal actions and armed confirmations" {
  [[ -x /usr/lib/qt6/bin/qmltestrunner ]] || skip "qmltestrunner is unavailable"
  mkdir -p "$T/qml/imports/TestIo" "$T/qml/imports/TestShell" "$T/qml/imports/TestUi" "$T/qml/imports/TestCommons"
  cp "$REPO/LanaiModel.qml" "$REPO/LanaiPanel.qml" "$T/qml/"
  sed -i 's/import Quickshell.Io/import TestIo/; s/import Quickshell$/import TestShell/; s/import qs.Commons/import TestCommons/; s/import qs.Ui/import TestUi/' "$T/qml/LanaiModel.qml" "$T/qml/LanaiPanel.qml"
  cat >"$T/qml/imports/TestShell/qmldir" <<'QML'
module TestShell
singleton Quickshell 1.0 Quickshell.qml
QML
  cat >"$T/qml/imports/TestShell/Quickshell.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property var lastCommand: []
  property int launchCount: 0
  function execDetached(args) { lastCommand = args; launchCount++ }
}
QML
  cat >"$T/qml/imports/TestIo/qmldir" <<'QML'
module TestIo
Process 1.0 Process.qml
StdioCollector 1.0 StdioCollector.qml
QML
  cat >"$T/qml/imports/TestIo/Process.qml" <<'QML'
import QtQuick
Item {
  property var command: []
  property bool running: false
  property QtObject stdout
  signal exited(int code)
  function complete(text, code) { stdout.text = text; running = false; exited(code) }
}
QML
  echo 'import QtQuick; QtObject { property bool waitForEnd: true; property string text: "" }' >"$T/qml/imports/TestIo/StdioCollector.qml"
  cat >"$T/qml/imports/TestCommons/qmldir" <<'QML'
module TestCommons
singleton Style 1.0 Style.qml
singleton Color 1.0 Color.qml
singleton Util 1.0 Util.qml
QML
  cat >"$T/qml/imports/TestCommons/Style.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property var selectedAccentFill
  property var font: ({family:"sans",bodySmall:12})
  function space(n) { return n }
}
QML
  echo 'pragma Singleton; import QtQuick; QtObject { property color foreground: "white"; property color accent: "#4080c0" }' >"$T/qml/imports/TestCommons/Color.qml"
  echo 'pragma Singleton; import QtQuick; QtObject { function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) } }' >"$T/qml/imports/TestCommons/Util.qml"
  cat >"$T/qml/imports/TestUi/qmldir" <<'QML'
module TestUi
Panel 1.0 Panel.qml
KeyboardPanel 1.0 KeyboardPanel.qml
Button 1.0 Button.qml
NumberField 1.0 NumberField.qml
PanelSectionHeader 1.0 PanelSectionHeader.qml
PanelSeparator 1.0 PanelSeparator.qml
QML
  cat >"$T/qml/imports/TestUi/Panel.qml" <<'QML'
import QtQuick
Item {
  property string moduleName
  property bool manageIpc
  property var bar: null
  property bool opened: false
  function open() { opened = true }
  function close() { opened = false }
}
QML
  cat >"$T/qml/imports/TestUi/KeyboardPanel.qml" <<'QML'
import QtQuick
Item {
  property Item anchorItem
  property var owner
  property var bar
  property bool open
  property Item focusTarget
  property real contentWidth
  property real contentHeight
  width: contentWidth
  height: contentHeight
  function fittedContentWidth(n) { return n }
  function fittedContentHeight(n, max) { return Math.min(n, max) }
}
QML
  cat >"$T/qml/imports/TestUi/Button.qml" <<'QML'
import QtQuick
Item {
  property string text
  property bool focusable
  property bool selected
  property color foreground
  property string fontFamily
  signal clicked()
  implicitWidth: 100
  implicitHeight: 30
}
QML
  cat >"$T/qml/imports/TestUi/NumberField.qml" <<'QML'
import QtQuick
import QtQuick.Controls as QQC
Item {
  property alias field: spin
  property string label
  property int from
  property int to
  property int value
  property color foreground
  property string fontFamily
  implicitWidth: 120
  implicitHeight: 40
  QQC.SpinBox {
    id: spin
    anchors.fill: parent
    from: parent.from
    to: parent.to
    value: parent.value
    editable: true
  }
}
QML
  echo 'import QtQuick; Text { property color foreground; property string fontFamily }' >"$T/qml/imports/TestUi/PanelSectionHeader.qml"
  echo 'import QtQuick; Item { property color foreground; height: 1 }' >"$T/qml/imports/TestUi/PanelSeparator.qml"
  cat >"$T/qml/tst_renderer.qml" <<'QML'
import QtQuick
import QtTest
import TestShell
import TestCommons
TestCase {
  id: tests
  name: "PanelRenderer"
  when: windowShown
  visible: true
  width: 800
  height: 800
  Component { id: modelComponent; LanaiModel {} }
  Component { id: panelComponent; LanaiPanel {} }
  function objects(item, predicate) {
    var found = []
    if (predicate(item)) found.push(item)
    var children = item.data || item.children || []
    for (var i = 0; i < children.length; i++) found = found.concat(objects(children[i], predicate))
    return found
  }
  function process(model, first) { return objects(model, function(o) { return o.command && o.command[0] === first })[0] }
  function ready(model) {
    var poll = process(model, "timeout")
    if (poll && poll.running) poll.complete(JSON.stringify({ok:true,buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}), 0)
  }
  function test_cadence_and_refresh() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1)
    var timers = objects(model, function(o) { return o.interval !== undefined })
    compare(timers[0].interval, 15000)
    model.panelOpen = true
    compare(timers[0].interval, 2000)
    var poll = process(model, "timeout")
    verify(poll.running)
    model.refresh()
    compare(model.refreshAgain, false)
    model.refresh(true)
    compare(model.refreshAgain, true)
    poll.complete('{}', 0)
    verify(poll.running)
    compare(model.refreshAgain, false)
    compare(poll.command.slice(0, 3).join(' '), 'timeout --signal=KILL 10')
    ready(model)
    model.run(['settings', '8', '4'], false)
    var action = objects(model, function(o) { return o.command && o.command[1] === 'ui-run' })[0]
    verify(action.running)
    compare(action.command.slice(3).join(' '), 'settings 8 4')
    model.refresh()
    verify(!poll.running)
    action.complete('{"ok":true}', 0)
    verify(poll.running)
  }
  function test_each_monitor_polls_its_own_panel() {
    var first = createTemporaryObject(modelComponent, tests)
    var second = createTemporaryObject(modelComponent, tests)
    wait(1)
    first.panelOpen = true
    compare(objects(first, function(o) { return o.interval !== undefined })[0].interval, 2000)
    compare(objects(second, function(o) { return o.interval !== undefined })[0].interval, 15000)
  }
  function test_unsaved_settings_survive_polls_and_reset_on_reopen() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    function view(memory, cores) {
      return {buttons:{save_settings:{show:true,enable:true,label:'Save settings'}},setup:{},settings:{memory_gib:memory,cores:cores},snapshots:{names:[]},result:{},logs:{}}
    }
    model.view = view(8, 4)
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    var memory = objects(panel, function(o) { return o.label === "Memory (GiB)" })[0]
    var cores = objects(panel, function(o) { return o.label === "CPU cores" })[0]
    compare(memory.field.value, 8)
    memory.field.forceActiveFocus()
    keyClick(Qt.Key_Up)
    compare(memory.field.value, 9)
    cores.field.forceActiveFocus()
    keyClick(Qt.Key_Down)
    compare(cores.field.value, 3)
    model.view = view(16, 8)
    compare(memory.field.value, 9)
    compare(cores.field.value, 3)
    model.view = view(32, 16)
    compare(memory.field.value, 9)
    compare(cores.field.value, 3)
    var save = objects(panel, function(o) { return o.control === 'save_settings' })[0]
    save.clicked()
    var action = objects(model, function(o) { return o.command && o.command[1] === 'ui-run' })[0]
    compare(action.command.slice(3).join(' '), 'settings 9 3')
    action.complete('{"ok":false}', 0)
    model.view = view(16, 8)
    compare(memory.field.value, 9)
    compare(cores.field.value, 3)
    save.clicked()
    memory.field.forceActiveFocus()
    keyClick(Qt.Key_Up)
    cores.field.forceActiveFocus()
    keyClick(Qt.Key_Up)
    compare(memory.field.value, 10)
    compare(cores.field.value, 4)
    action.complete('{"ok":true,"memory_gib":9,"cores":3}', 0)
    compare(memory.field.value, 9)
    compare(cores.field.value, 3)
    panel.close(); panel.open()
    compare(memory.field.value, 16)
    compare(cores.field.value, 8)
    panel.destroy(); wait(1)
  }
  function test_finished_setup_reveals_both_display_choices_without_a_bare_job() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{continue_setup:{show:true,enable:true,label:'Run setup again'},
      no_window:{show:true,enable:true,label:'Set up in the Windows window',hint:'Use this if the Windows display driver already works.'},
      cancel:{show:true,enable:true,label:'Cancel'},
      window:{show:true,enable:true,label:"Set up in a basic window",hint:'Use a basic window if the Windows window is blank or the display driver needs repair.'}},
      setup:{finished:true,show:false,again_line:'Choose how Windows should show during setup.',choices:['--no-window','--window']},settings:{},snapshots:{names:[]},result:{},logs:{}}
    for (var i = 0; i < 2; i++) {
      var panel = createTemporaryObject(panelComponent, tests, {model:model})
      panel.open()
      var again = objects(panel, function(o) { return o.control === 'continue_setup' })[0]
      var client = objects(panel, function(o) { return o.control === 'no_window' })[0]
      var screen = objects(panel, function(o) { return o.control === 'window' })[0]
      verify(again.visible)
      verify(!client.visible)
      verify(!screen.visible)
      Quickshell.lastCommand = []
      again.clicked()
      compare(Quickshell.lastCommand.length, 0)
      verify(client.visible)
      verify(screen.visible)
      verify(objects(panel, function(o) { return o.text === model.view.setup.again_line && o.visible }).length > 0)
      var cancel = objects(panel, function(o) { return o.control === 'cancel' && o.visible })[0]
      verify(cancel !== undefined)
      cancel.clicked()
      compare(panel.setupAgainArmed, false)
      verify(again.visible)
      verify(!client.visible)
      compare(Quickshell.lastCommand.length, 0)
      again.clicked()
      verify(objects(panel, function(o) { return o.text === model.control('no_window').hint && o.visible }).length > 0)
      verify(objects(panel, function(o) { return o.text === model.control('window').hint && o.visible }).length > 0)
      panel.close(); panel.open()
      verify(!client.visible)
      verify(!screen.visible)
      again.clicked()
      var choice = i === 0 ? client : screen
      choice.clicked()
      compare(Quickshell.lastCommand[1], 'ui-job')
      compare(Quickshell.lastCommand.slice(3).join(' '), i === 0 ? 'setup --no-window' : 'setup --window')
      var poll = process(model, 'timeout')
      var reply = model.view
      reply.ok = true; reply.pending_ack = model.pendingToken
      poll.complete(JSON.stringify(reply), 0)
      compare(model.pendingToken, '')
      panel.destroy(); wait(1)
    }
  }
  function test_finished_setup_shows_the_disabled_button_reason() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{continue_setup:{show:true,enable:false,label:'Run setup again',hint:'Shut Windows down to run setup again.'}},
      setup:{finished:true,show:false},settings:{},snapshots:{names:[]},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    var again = objects(panel, function(o) { return o.control === 'continue_setup' })[0]
    verify(again.visible)
    verify(!again.enabled)
    verify(objects(panel, function(o) { return o.text === model.control('continue_setup').hint && o.visible }).length > 0)
    panel.destroy(); wait(1)
  }
  function test_long_job_pending_and_no_deadline() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.run(['setup', '--window'], true)
    verify(model.pendingToken !== '')
    compare(Quickshell.lastCommand[1], 'ui-job')
    compare(Quickshell.lastCommand[2], model.pendingToken)
    compare(Quickshell.lastCommand.slice(3).join(' '), 'setup --window')
    verify(Quickshell.lastCommand.indexOf('timeout') === -1)
    var poll = process(model, 'timeout')
    compare(poll.command.slice(-3)[0], '--pending')
    compare(poll.command.slice(-2)[0], model.pendingToken)
  }
  function test_two_rapid_long_job_clicks_keep_the_first_launch() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var count = Quickshell.launchCount
    model.run(['setup'], true)
    var firstToken = model.pendingToken
    var firstAt = model.pendingAt
    model.run(['snapshot'], true)
    compare(Quickshell.launchCount, count + 1)
    compare(model.pendingToken, firstToken)
    compare(model.pendingAt, firstAt)
    compare(Quickshell.lastCommand.slice(3).join(' '), 'setup')
  }
  function test_short_action_preserves_a_failed_launch_until_the_next_long_job() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.run(['setup'], true)
    var firstToken = model.pendingToken
    model.pendingAt -= 11
    var firstAt = model.pendingAt
    ready(model)
    model.run(['open'], false)
    compare(model.pendingToken, firstToken)
    compare(model.pendingAt, firstAt)
    var action = process(model, model.cli)
    action.complete('{"ok":true}', 0)
    var poll = process(model, 'timeout')
    compare(poll.command.slice(-2)[0], firstToken)
    model.run(['snapshot'], true)
    verify(model.pendingToken !== firstToken)
    compare(Quickshell.lastCommand[2], model.pendingToken)
  }
  function test_snapshot_advice_is_beside_the_step_three_controls() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var advice = 'This filesystem cannot make an instant snapshot. Make a backup before continuing without a snapshot.'
    model.view = {buttons:{setup_snapshot:{show:true,enable:true,label:'Take a snapshot'},skip_snapshot:{show:true,enable:true,label:'Continue without a snapshot'}},
      setup:{show:true,finished:false,step:'3'},settings:{},snapshots:{names:[]},result:{snapshots:advice},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    wait(1)
    var control = objects(panel, function(o) { return o.control === 'setup_snapshot' })[0]
    var notes = objects(panel, function(o) { return o.text === advice && o.visible })
    var siblings = Array.from(control.parent.parent.children)
    verify(notes.some(function(o) { return siblings.indexOf(o) === siblings.indexOf(control.parent) + 1 }))
    model.view = {buttons:{continue_setup:{show:true,enable:true,label:'Run setup again'}},setup:{show:false,finished:true},settings:{},snapshots:{names:[]},result:{snapshots:advice},logs:{}}
    wait(1)
    compare(objects(panel, function(o) { return o.text === advice && o.visible }).length, 1)
    verify(objects(panel, function(o) { return o.text === 'Setup' && o.visible }).length > 0)
    panel.destroy(); wait(1)
  }
  function test_both_monitors_acknowledge_launches_before_record_replacement() {
    var first = createTemporaryObject(modelComponent, tests)
    var second = createTemporaryObject(modelComponent, tests)
    wait(1); ready(first); ready(second)
    first.run(['setup', '--window'], true)
    var firstToken = first.pendingToken
    var firstPoll = process(first, 'timeout')
    firstPoll.complete(JSON.stringify({ok:true,pending_ack:firstToken,buttons:{}}), 0)
    compare(first.pendingToken, '')
    second.run(['setup', '--no-window'], true)
    var secondToken = second.pendingToken
    var secondPoll = process(second, 'timeout')
    // Seeing another bar's record does not acknowledge this launch.
    secondPoll.complete(JSON.stringify({ok:true,pending_ack:firstToken,buttons:{}}), 0)
    compare(second.pendingToken, secondToken)
    second.refresh()
    secondPoll.complete(JSON.stringify({ok:true,pending_ack:secondToken,buttons:{}}), 0)
    compare(second.pendingToken, '')
    // The group's record now belongs to the second launch. Neither monitor
    // keeps asking whether its acknowledged token is still on disk.
    first.refresh(); second.refresh()
    compare(firstPoll.command.indexOf('--pending'), -1)
    compare(secondPoll.command.indexOf('--pending'), -1)
    firstPoll.complete(JSON.stringify({ok:true,pending_ack:'',buttons:{}}), 0)
    secondPoll.complete(JSON.stringify({ok:true,pending_ack:'',buttons:{}}), 0)
    compare(first.pendingToken, '')
    compare(second.pendingToken, '')
  }
  function test_setup_shutdown_confirmation_cancel_reset_and_daily_stop() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    function view(confirm) {
      return {buttons:{stop:{show:true,enable:true,label:'Shut down',confirm:confirm},
        stop_confirm:{show:confirm,enable:confirm,label:"Shut down and stop setup",hint:"Shutting down now stops setup. You'll choose how to continue."},
        cancel:{show:true,enable:true,label:'Cancel'}},setup:{show:true,attention:true},settings:{},snapshots:{names:[]},result:{},logs:{}}
    }
    model.view = view(true)
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    var stop = objects(panel, function(o) { return o.control === 'stop' })[0]
    stop.clicked()
    compare(panel.stopArmed, true)
    compare(stop.control, 'stop_confirm')
    compare(stop.text, "Shut down and stop setup")
    verify(objects(panel, function(o) { return o.text === model.control('stop_confirm').hint && o.visible }).length > 0)
    verify(!process(model, model.cli))
    var cancel = objects(panel, function(o) { return o.control === 'cancel' && o.visible })[0]
    cancel.clicked()
    compare(panel.stopArmed, false)
    stop.clicked()
    panel.close(); panel.open()
    compare(panel.stopArmed, false)
    stop.clicked()
    model.view = view(false)
    compare(panel.stopArmed, false)
    compare(stop.control, 'stop')
    model.view = view(true)
    stop.clicked(); stop.clicked()
    compare(panel.stopArmed, false)
    var action = process(model, model.cli)
    compare(action.command[1], 'ui-run')
    compare(action.command.slice(3).join(' '), 'stop')
    action.complete('{"ok":true}', 0); ready(model)
    model.view = view(false)
    stop.clicked()
    compare(action.command.slice(3).join(' '), 'stop')
    verify(action.running)
    panel.destroy(); wait(1)
  }
  function test_shutdown_and_force_confirmation_are_mutually_exclusive() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{stop:{show:true,enable:true,label:'Shut down',confirm:true},
      stop_confirm:{show:true,enable:true,label:'Shut down and stop setup'},
      force_stop:{show:true,enable:true,label:'Force stop'},force_confirm:{show:true,enable:true,label:'Force stop and lose unsaved work'},
      cancel:{show:true,enable:true,label:'Cancel'}},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    var stop = objects(panel, function(o) { return o.control === 'stop' })[0]
    var force = objects(panel, function(o) { return o.control === 'force_stop' })[0]
    stop.clicked(); force.clicked()
    compare(panel.stopArmed, false)
    compare(panel.forceArmed, true)
    compare(objects(panel, function(o) { return o.control === 'cancel' && o.visible }).length, 1)
    stop.clicked()
    compare(panel.stopArmed, true)
    compare(panel.forceArmed, false)
    compare(objects(panel, function(o) { return o.control === 'cancel' && o.visible }).length, 1)
    verify(!process(model, model.cli))
    panel.destroy(); wait(1)
  }
  function test_setup_accent_follows_theme_and_reopen_uses_ui_run() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    function view(attention, snapshots) {
      return {buttons:{reopen_window:{show:true,enable:true,label:'Reopen the Windows window'}},
        setup:{show:true,attention:attention},settings:{},snapshots:{show:snapshots,names:[]},result:{},logs:{}}
    }
    model.view = view(true, false)
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    var section = objects(panel, function(o) { return o.objectName === 'setupSection' })[0]
    verify(section !== undefined)
    var column = section.children[0]
    compare(column.x, Style.space(8))
    compare(column.y, Style.space(8))
    var sectionHeight = section.implicitHeight
    var columnWidth = column.width
    compare(section.border.width, 1)
    compare(section.border.color, Color.accent)
    compare(section.color, Util.alpha(Color.accent, 0.10))
    Style.selectedAccentFill = '#336699'
    compare(section.color, Style.selectedAccentFill)
    Style.selectedAccentFill = undefined
    Color.accent = '#c06030'
    compare(section.border.color, Color.accent)
    compare(section.color, Util.alpha(Color.accent, 0.10))
    compare(objects(panel, function(o) { return o.text === 'Snapshots' && o.visible }).length, 0)
    var reopen = objects(section, function(o) { return o.control === 'reopen_window' })[0]
    verify(reopen.visible)
    reopen.clicked()
    var action = process(model, model.cli)
    compare(action.command[1], 'ui-run')
    compare(action.command.slice(3).join(' '), 'open')
    model.view = view(false, true)
    compare(column.x, Style.space(8))
    compare(column.y, Style.space(8))
    compare(column.width, columnWidth)
    compare(section.implicitHeight, sectionHeight)
    compare(section.border.width, 0)
    compare(section.color, Qt.rgba(0, 0, 0, 0))
    verify(objects(panel, function(o) { return o.text === 'Snapshots' && o.visible }).length > 0)
    panel.destroy(); wait(1)
  }
  function test_force_stop_two_clicks() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{force_stop:{show:true,enable:true,label:'Force stop'},force_confirm:{show:true,enable:true,label:'Confirm'}},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    verify(panel !== null)
    var force = objects(panel, function(o) { return o.control === 'force_stop' })[0]
    verify(force !== undefined)
    force.clicked()
    compare(panel.forceArmed, true)
    compare(force.control, 'force_confirm')
    verify(objects(model, function(o) { return o.command && o.command[1] === 'ui-run' }).length === 0)
    force.clicked()
    compare(panel.forceArmed, false)
    var action = objects(model, function(o) { return o.command && o.command[1] === 'ui-run' })[0]
    compare(action.command.slice(3).join(' '), 'force-stop --confirm')
    panel.destroy(); wait(1)
  }
  function test_restore_and_controls() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{restore_snapshot:{show:true,enable:true,label:'Restore',labels:{snapshot:'Restore snapshot snapshot'}},restore_confirm:{show:true,enable:true,label:'Confirm',labels:{snapshot:'Restore snapshot and replace Windows'}}},setup:{},settings:{},snapshots:{names:['snapshot']},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    wait(1)
    var restore = objects(panel, function(o) { return o.control === 'restore_snapshot' })[0]
    compare(restore.text, 'Restore snapshot snapshot')
    restore.clicked()
    compare(panel.restoreArmed, 'snapshot')
    compare(restore.control, 'restore_confirm')
    compare(restore.text, 'Restore snapshot and replace Windows')
    restore.clicked()
    compare(Quickshell.lastCommand[1], 'ui-job')
    compare(Quickshell.lastCommand.slice(3).join(' '), 'restore snapshot')
    model.view = {buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
    compare(panel.restoreArmed, '')
    panel.destroy(); wait(1)
  }
}
QML
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME='' QT_STYLE_OVERRIDE=Basic QML_DISABLE_DISK_CACHE=1 run /usr/lib/qt6/bin/qmltestrunner -input "$T/qml" -import "$T/qml/imports"
  assert_success
  refute_output --partial 'FAIL!'
}
