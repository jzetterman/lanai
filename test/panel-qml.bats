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
  function execDetached(args) { lastCommand = args }
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
QML
  cat >"$T/qml/imports/TestCommons/Style.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property var font: ({family:"sans",bodySmall:12})
  function space(n) { return n }
}
QML
  echo 'pragma Singleton; import QtQuick; QtObject { property color foreground: "white" }' >"$T/qml/imports/TestCommons/Color.qml"
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
      window:{show:true,enable:true,label:"Set up in QEMU's screen",hint:'Use this if the Windows window is blank or the display driver needs repair.'}},
      setup:{finished:true,show:false,choices:['--no-window','--window']},settings:{},snapshots:{names:[]},result:{},logs:{}}
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
      panel.destroy(); wait(1)
    }
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
    model.view = {buttons:{restore_snapshot:{show:true,enable:true,label:'Restore'},restore_confirm:{show:true,enable:true,label:'Confirm'}},setup:{},settings:{},snapshots:{names:['snapshot']},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    wait(1)
    var restore = objects(panel, function(o) { return o.control === 'restore_snapshot' })[0]
    restore.clicked()
    compare(panel.restoreArmed, 'snapshot')
    compare(restore.control, 'restore_confirm')
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
