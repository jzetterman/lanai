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
Item {
  property alias field: spin
  property string label
  property int from
  property int to
  property int value
  property color foreground
  property string fontFamily
  Item { id: spin; property int value: parent.value }
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
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    model.view = {buttons:{},setup:{},settings:{memory_gib:8,cores:4},snapshots:{names:[]},result:{},logs:{}}
    var memory = objects(panel, function(o) { return o.label === "Memory (GiB)" })[0]
    compare(memory.field.value, 8)
    memory.field.value = 9
    model.view = {buttons:{},setup:{},settings:{memory_gib:16,cores:4},snapshots:{names:[]},result:{},logs:{}}
    compare(memory.field.value, 9)
    panel.close(); panel.open()
    compare(memory.field.value, 16)
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
