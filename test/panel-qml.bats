#!/usr/bin/env bats
# Real QML with inert shell/Process types: no compositor, services or subprocesses.
load helpers
setup() { isolate_home; T=$BATS_TEST_TMPDIR; }

@test "QML renderer: poll cadence, refresh races, literal actions and armed confirmations" {
  [[ -x /usr/lib/qt6/bin/qmltestrunner ]] || skip "qmltestrunner is unavailable"
  mkdir -p "$T/qml/imports/TestIo" "$T/qml/imports/TestShell" "$T/qml/imports/TestUi" "$T/qml/imports/TestCommons"
  cp "$REPO/LanaiModel.qml" "$REPO/LanaiPanel.qml" "$REPO/Widget.qml" "$T/qml/"
  sed -i 's/import Quickshell.Io/import TestIo/; s/import Quickshell$/import TestShell/; s/import qs.Commons/import TestCommons/; s/import qs.Ui/import TestUi/' "$T/qml/LanaiModel.qml" "$T/qml/LanaiPanel.qml" "$T/qml/Widget.qml"
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
  property bool stdinEnabled: false
  property string input: ""
  property bool wroteWithStdin: false
  signal started()
  signal exited(int code, int exitStatus)
  function begin() { input = ""; started() }
  function write(text) { wroteWithStdin = stdinEnabled; input += text }
  function failToStart() { running = false }
  function complete(text, code, status) {
    if (stdout) stdout.text = text
    running = false
    exited(code, status === undefined ? 0 : status)
  }
}
QML
  echo 'import QtQuick; QtObject { property bool waitForEnd: true; property string text: "" }' >"$T/qml/imports/TestIo/StdioCollector.qml"
  cat >"$T/qml/imports/TestCommons/qmldir" <<'QML'
module TestCommons
singleton Style 1.0 Style.qml
singleton Color 1.0 Color.qml
singleton Util 1.0 Util.qml
singleton Border 1.0 Border.qml
QML
  cat >"$T/qml/imports/TestCommons/Style.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property var selectedAccentFill
  property var bar: ({iconFont:16,statusSlot:24})
  property real cornerRadius: 0
  property var font: ({family:"sans",bodySmall:12,caption:10})
  function space(n) { return n }
}
QML
  echo 'pragma Singleton; import QtQuick; QtObject { property color foreground: "white"; property color urgent: "red"; property color accent: "#4080c0"; property color background: "black"; property QtObject popups: QtObject { property color background: "#80000000" } }' >"$T/qml/imports/TestCommons/Color.qml"
  cat >"$T/qml/imports/TestCommons/Border.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  function none() { return {width:0,color:"transparent"} }
  function controlSpec(state, foreground, accent) { return {width:1,color:foreground} }
}
QML
  echo 'pragma Singleton; import QtQuick; QtObject { function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) } }' >"$T/qml/imports/TestCommons/Util.qml"
  cat >"$T/qml/imports/TestUi/qmldir" <<'QML'
module TestUi
BarWidget 1.0 BarWidget.qml
BarIconButton 1.0 BarIconButton.qml
Panel 1.0 Panel.qml
KeyboardPanel 1.0 KeyboardPanel.qml
Button 1.0 Button.qml
NumberField 1.0 NumberField.qml
Dropdown 1.0 Dropdown.qml
PanelSectionHeader 1.0 PanelSectionHeader.qml
PanelSeparator 1.0 PanelSeparator.qml
PanelHero 1.0 PanelHero.qml
PanelActionButton 1.0 PanelActionButton.qml
BorderSurface 1.0 BorderSurface.qml
QML
  cat >"$T/qml/imports/TestUi/BorderSurface.qml" <<'QML'
import QtQuick
Rectangle {
  property var borderSpec: ({width:0,color:"transparent"})
  border.width: borderSpec.width
  border.color: borderSpec.color
}
QML
  cat >"$T/qml/imports/TestUi/BarWidget.qml" <<'QML'
import QtQuick
Item {
  property string moduleName
  property var bar: null
  property var settings: ({})
}
QML
  cat >"$T/qml/imports/TestUi/BarIconButton.qml" <<'QML'
import QtQuick
Item {
  property var bar
  property string text
  property Component iconComponent
  property real slotSize
  property string tooltipText
  property bool active
  property color activeColor: 'white'
  property color foreground: 'white'
  property string fontFamily: 'sans'
  signal pressed(int button)
  implicitWidth: 24
  implicitHeight: 24
}
QML
  cat >"$T/qml/imports/TestUi/Panel.qml" <<'QML'
import QtQuick
Item {
  property string moduleName
  property bool manageIpc
  property var settings
  property bool popoutSwitchClosing: false
  function toggle() { opened = !opened }
  function closeForPopoutSwitch() { close() }
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
  property bool bordered
  property bool leftAlign
  property bool selected
  property color foreground
  property string fontFamily
  property string tooltipText
  activeFocusOnTab: focusable
  Keys.onReturnPressed: clicked()
  Keys.onEnterPressed: clicked()
  Keys.onSpacePressed: clicked()
  signal clicked()
  implicitWidth: 100
  implicitHeight: 30
  MouseArea { anchors.fill: parent; onClicked: parent.clicked() }
}
QML
  cat >"$T/qml/imports/TestUi/PanelHero.qml" <<'QML'
import QtQuick
Item {
  property string title
  property string meta
  property string detail
  property color foreground
  property string fontFamily
  property Component iconComponent
  implicitHeight: 50
  Loader { sourceComponent: parent.iconComponent }
}
QML
  cat >"$T/qml/imports/TestUi/PanelActionButton.qml" <<'QML'
import QtQuick
Item {
  id: root
  property string iconText
  property string tooltipText
  property color foreground
  property string fontFamily
  property bool focusable
  signal clicked()
  activeFocusOnTab: focusable
  Keys.onReturnPressed: root.clicked()
  Keys.onEnterPressed: root.clicked()
  Keys.onSpacePressed: root.clicked()
  implicitWidth: 30
  implicitHeight: 30
  MouseArea { anchors.fill: parent; onClicked: root.clicked() }
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
  cat >"$T/qml/imports/TestUi/Dropdown.qml" <<'QML'
import QtQuick
Item {
  property string label
  property string value
  property var options: []
  activeFocusOnTab: true
  property color foreground
  property string fontFamily
  signal changed(string value)
  // As the real Dropdown does: assign value, then emit changed.
  function select(v) { value = v; changed(v) }
  function currentLabel() {
    for (var i = 0; i < options.length; i++)
      if (String(options[i].value) === value) return String(options[i].label)
    return value
  }
  implicitWidth: 200
  implicitHeight: 40
}
QML
  echo 'import QtQuick; Text { property color foreground; property string fontFamily }' >"$T/qml/imports/TestUi/PanelSectionHeader.qml"
  echo 'import QtQuick; Item { property color foreground; height: 1 }' >"$T/qml/imports/TestUi/PanelSeparator.qml"
  cat >"$T/qml/tst_renderer.qml" <<'QML'
import QtQuick
import QtTest
import TestShell
import TestCommons
import TestCommons as Commons
TestCase {
  id: tests
  name: "PanelRenderer"
  when: windowShown
  visible: true
  width: 800
  height: 800
  Component { id: modelComponent; LanaiModel {} }
  Component { id: panelComponent; LanaiPanel {} }
  Component { id: widgetComponent; Widget {} }
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
  function widgetParts() {
    var widget = createTemporaryObject(widgetComponent, tests)
    verify(widget !== null)
    wait(1)
    var model = objects(widget, function(o) { return o.cli !== undefined })[0]
    var button = objects(widget, function(o) { return typeof o.pressed === "function" && o.tooltipText !== undefined })[0]
    ready(model)
    return {widget:widget, model:model, button:button}
  }
  function named(panel, name) { return objects(panel, function(o) { return o.objectName === name })[0] }
  function redesignView() {
    return {ok:true,layout:'daily',header:{title:'Windows',meta:'12 GiB · 6 cores · 175%',badge:'Stopped'},
      sections:{settings:'Settings',snapshots:'Snapshots',logs:'Logs',default:''},primary_action:'start',
      buttons:{start:{show:true,enable:true,label:'Start Windows'},cancel:{show:true,enable:true,label:'Cancel'},
        restore_snapshot:{show:true,enable:true,label:'Restore'},restore_confirm:{show:true,enable:true,label:'Confirm'},
        save_settings:{show:true,enable:true,label:'Save settings'}},setup:{finished:true},
      settings:{memory_gib:12,cores:6,windows_scale:175,baseline:{memory_gib:12,cores:6,windows_scale:175},
        labels:{memory:'Memory (GiB)',cores:'CPU cores',scale:'Windows scale',save:'Save',saved:'Saved',reset:'Reset',unsaved:'Unsaved'}},
      result:{},logs:{rows:[{id:'vm',label:'VM',display:'journal: lanai-vm',copy_text:'journalctl --user -u lanai-vm',copy_label:'Copy VM log command'}]},
      snapshots:{show:true,count:1,names:['20261012T091200Z'],items:[{name:'20261012T091200Z',date:'Oct 12, 2026',time:'09:12 UTC',
        label:'Oct 12, 2026 at 09:12 UTC',restore_label:'Restore Oct 12, 2026 at 09:12 UTC',
        confirm_label:'Restore Oct 12, 2026 at 09:12 UTC and replace Windows',warning:'Later changes are lost.'}]},
      restore:{label:'',warning:''},progress:null}
  }
  function redesignPanel() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = redesignView()
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    wait(1)
    return {model:model,panel:panel}
  }
  function setupView(step, layout) {
    var v = redesignView(), number = step === '3a' ? 4 : Number(step)
    var names = ['Check','Packages','Snapshot','Prepare','Drivers','Verify']
    v.layout = layout || (step === '6' ? 'setup_verify' : 'setup')
    v.active = true
    v.header = {title:'Windows',meta:'Step ' + number + ' of 6 · ' + names[number - 1],badge:'Setup'}
    v.buttons = {cancel:{show:true,enable:true,label:'Cancel'},continue_setup:{show:true,enable:true,label:'Continue setup'}}
    v.setup = {show:true,finished:false,step:step,number:number,name:names[number - 1],
      step_line:'Step ' + number + ' of 6',title:'Backend title for ' + step,lines:['Backend guidance for ' + step],
      steps:names.map(function(name, i) { return {number:i + 1,name:name,state:i + 1 < number ? 'complete' : i + 1 === number ? 'current' : 'pending'} }),
      checks:[{id:'idd',label:'Display driver',state:'not_checked',status:'Not checked',detail:''},
        {id:'agents',label:'Windows agents',state:'not_checked',status:'Not checked',detail:''},
        {id:'scale',label:'Scale task',state:'not_checked',status:'Not checked',detail:''}],countdown:null}
    return v
  }
  function textVisible(panel, text) {
    return objects(panel, function(o) { return o.text === text && o.visible }).length > 0
  }
  function test_redesign_all_six_setup_steps_and_prepare_substep_render() {
    var p = redesignPanel()
    ;['1','2','3','3a','4','5','6'].forEach(function(step) {
      var v = setupView(step)
      p.model.view = v
      wait(1)
      var strip = named(p.panel, 'setupSteps')
      verify(strip !== undefined)
      verify(strip.visible)
      var entries = objects(strip, function(o) { return o.objectName.indexOf('setupStep-') === 0 })
      compare(entries.length, 6)
      entries.forEach(function(entry, i) {
        compare(entry.stepState, v.setup.steps[i].state)
        verify(textVisible(entry, v.setup.steps[i].name))
        verify(!entry.activeFocusOnTab)
      })
      compare(named(p.panel, 'setupTitle').text, v.setup.title)
      verify(textVisible(p.panel, v.setup.lines[0]))
      verify(named(p.panel, 'settingsToggle').visible)
      verify(named(p.panel, 'snapshotsToggle').visible)
      // Narrow fitting wraps the strip, with no horizontal overflow.
      named(p.panel, 'panelPopup').contentWidth = 260
      wait(1)
      entries.forEach(function(entry) { verify(entry.x + entry.width <= strip.width + 1) })
    })
  }
  function test_redesign_setup_headers_override_running_settings_and_finish_returns_daily() {
    var p = redesignPanel(), v = setupView('5')
    p.model.view = v
    var hero = named(p.panel, 'windowsHeader')
    compare(hero.title, 'Windows')
    compare(hero.meta, 'Step 5 of 6 · Drivers')
    compare(hero.detail, 'Setup')
    verify(named(p.panel, 'setupSteps').visible)
    p.model.view = redesignView()
    compare(hero.meta, '12 GiB · 6 cores · 175%')
    compare(hero.detail, 'Stopped')
    verify(!named(p.panel, 'setupSteps').visible)
    verify(!textVisible(p.panel, 'Step 7 of 6'))
  }
  function test_redesign_snapshot_skip_keeps_backup_and_filesystem_advice() {
    var p = redesignPanel(), v = setupView('3')
    v.setup.title = 'Snapshot before first boot'
    v.setup.lines = ['Before the first boot, take a snapshot so you can undo changes, or make a backup and continue without one.']
    v.buttons.setup_snapshot = {show:true,enable:true,label:'Take a snapshot'}
    v.buttons.skip_snapshot = {show:true,enable:true,label:'Continue without a snapshot'}
    v.result.snapshots = 'This filesystem cannot make an instant snapshot. Make a backup before continuing without a snapshot.'
    p.model.view = v
    compare(named(p.panel, 'setupTitle').text, v.setup.title)
    verify(textVisible(p.panel, v.setup.lines[0]))
    verify(textVisible(p.panel, v.result.snapshots))
    var skip = objects(named(p.panel, 'setupSection'), function(o) { return o.control === 'skip_snapshot' })[0]
    verify(skip.visible && skip.enabled)
    skip.clicked()
    compare(Quickshell.lastCommand.slice(3).join(' '), 'setup --no-snapshot')
  }
  function test_redesign_drivers_guidance_follows_worker_and_keeps_shutdown() {
    var p = redesignPanel(), v = setupView('5')
    v.setup.title = 'Finish in Windows'
    v.setup.lines = ["In Windows, open Lanai's setup drive and run setup.cmd. Windows shuts down by itself when it finishes, then Lanai starts it again to check it. Use Shut down only if setup.cmd stops responding, or when its shared-folder check tells you to."]
    v.buttons.reopen_window = {show:true,enable:true,label:'Reopen the Windows window'}
    v.buttons.stop = {show:true,enable:true,label:'Shut down',confirm:true}
    v.buttons.stop_confirm = {show:true,enable:true,label:'Shut down and stop setup',hint:"Shutting down now stops setup. You'll choose how to continue."}
    p.model.view = v
    compare(named(p.panel, 'setupTitle').text, 'Finish in Windows')
    verify(textVisible(p.panel, v.setup.lines[0]))
    verify(objects(p.panel, function(o) { return o.control === 'reopen_window' && o.visible }).length > 0)
    var stop = named(p.panel, 'shutdownAction')
    verify(stop.visible)
    stop.clicked()
    verify(p.panel.stopArmed)
    objects(p.panel, function(o) { return o.control === 'cancel' && o.visible })[0].clicked()
    verify(!p.panel.stopArmed)
    v = setupView('5')
    v.setup.lines = ["In Windows, open Lanai's setup drive and run setup.cmd. Then click Continue setup so Lanai can restart Windows and check it when setup.cmd finishes."]
    p.model.view = v
    verify(textVisible(p.panel, v.setup.lines[0]))
    verify(objects(p.panel, function(o) { return o.control === 'continue_setup' && o.visible }).length > 0)
    verify(!named(p.panel, 'setupChecks').visible)
  }
  function test_redesign_verify_renders_actual_partial_checks_and_conditional_signin() {
    var p = redesignPanel(), v = setupView('6')
    p.model.view = v
    verify(named(p.panel, 'setupChecks') !== undefined)
    v.setup.checks.forEach(function(check) {
      var row = named(p.panel, 'setupCheck-' + check.id)
      compare(row.checkState, 'not_checked')
      verify(textVisible(row, check.label))
      verify(textVisible(row, 'Not checked'))
    })
    v.setup.checks[0] = {id:'idd',label:'Display driver',state:'done',status:'Done',detail:''}
    v.setup.checks[1] = {id:'agents',label:'Windows agents',state:'waiting',status:'Waiting',detail:'Waiting for the SPICE agent.'}
    v.setup.lines = ['Windows is starting or being checked.']
    p.model.view = JSON.parse(JSON.stringify(v))
    compare(named(p.panel, 'setupCheck-idd').checkState, 'done')
    compare(named(p.panel, 'setupCheck-agents').checkState, 'waiting')
    compare(named(p.panel, 'setupCheck-scale').checkState, 'not_checked')
    verify(textVisible(named(p.panel, 'setupCheck-agents'), 'Waiting for the SPICE agent.'))
    verify(textVisible(named(p.panel, 'setupCheck-scale'), 'Not checked'))
    verify(!named(p.panel, 'setupCountdown').visible)
    v.setup.lines = ['Waiting for the display scale task. If Windows is at its sign-in screen, or another user is signed in, sign in as the Windows user who ran setup.']
    v.setup.checks[1] = {id:'agents',label:'Windows agents',state:'done',status:'Done',detail:''}
    v.setup.checks[2] = {id:'scale',label:'Scale task',state:'waiting',status:'Waiting',detail:'Waiting for the display scale task.'}
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(textVisible(p.panel, v.setup.lines[0]))
    compare(named(p.panel, 'setupCheck-agents').checkState, 'done')
    ;['The pinned display driver build failed.', 'The QEMU guest agent allow-list failed.'].forEach(function(cause) {
      v = setupView('5')
      v.result.setup = cause + ' Install the Windows parts again.'
      p.model.view = v
      verify(!named(p.panel, 'setupChecks').visible)
      verify(!named(p.panel, 'setupCountdown').visible)
      verify(textVisible(p.panel, v.result.setup))
      compare(p.model.view.layout, 'setup')
    })
  }
  function test_redesign_countdown_reopen_preserves_deadline_and_hides_invalid_timing() {
    var p = redesignPanel(), v = setupView('6'), now = Math.floor(Date.now() / 1000)
    v.setup.countdown = {started_at:now - 36,limit_seconds:120,remaining_seconds:84,label:'Time remaining to sign in'}
    p.model.view = v
    verify(named(p.panel, 'setupCountdown') !== undefined)
    verify(named(p.panel, 'setupCountdown').visible)
    verify(textVisible(p.panel, 'Time remaining to sign in'))
    compare(named(p.panel, 'setupCountdownDuration').text, '1:24')
    tryCompare(named(p.panel, 'setupCountdownDuration'), 'text', '1:23', 1500)
    p.panel.close(); p.panel.open()
    compare(named(p.panel, 'setupCountdownDuration').text, '1:23')
    p.panel.destroy(); p.model.destroy(); wait(1)
    // Both shell objects restart; a fresh backend poll supplies the same deadline.
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    v.setup.countdown.remaining_seconds = 82
    model.view = v
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    compare(named(panel, 'setupCountdownDuration').text, '1:22')
    v.setup.countdown = {started_at:now - 36,limit_seconds:900,remaining_seconds:864,label:'Time remaining to sign in'}
    model.view = JSON.parse(JSON.stringify(v))
    compare(named(panel, 'setupCountdownDuration').text, '14:24')
    ;[null,{}, {started_at:now + 30,limit_seconds:120,remaining_seconds:120},
      {started_at:now,limit_seconds:0,remaining_seconds:0},
      {started_at:now,limit_seconds:120,remaining_seconds:-1},
      {started_at:now,limit_seconds:120,remaining_seconds:'84'},
      {started_at:now,limit_seconds:120,remaining_seconds:121}].forEach(function(timing) {
      v.setup.countdown = timing; model.view = JSON.parse(JSON.stringify(v))
      verify(!named(panel, 'setupCountdown').visible)
    })
    v.setup.countdown = {started_at:now - 120,limit_seconds:120,remaining_seconds:0,label:'Time remaining to sign in'}
    model.view = JSON.parse(JSON.stringify(v))
    verify(named(panel, 'setupCountdown').visible)
    compare(named(panel, 'setupCountdownDuration').text, '0:00')
    wait(1100)
    compare(named(panel, 'setupCountdownDuration').text, '0:00')
    compare(model.view.layout, 'setup_verify')
    v.layout = 'setup_timeout'; model.view = JSON.parse(JSON.stringify(v))
    verify(!named(panel, 'setupCountdown').visible)
  }
  function test_redesign_timeout_keeps_continue_and_both_stopped_display_choices() {
    var p = redesignPanel(), v = setupView('6', 'setup_timeout')
    v.header.meta += ' · Stopped'
    v.setup.title = 'Windows checks timed out'
    v.setup.lines = ['Click Continue setup so Lanai can check Windows.']
    v.result.setup = 'In Windows, the SPICE agent did not answer. Click Continue setup to check again. If setup.cmd stopped with a message, shut down and repeat the Windows install.'
    v.setup.checks[1] = {id:'agents',label:'Windows agents',state:'failed',status:'Failed',detail:'The SPICE agent failed.'}
    v.buttons.window = {show:true,enable:true,label:'Set up in a basic window'}
    v.buttons.no_window = {show:true,enable:true,label:'Set up in the Windows window'}
    p.model.view = v
    compare(named(p.panel, 'setupTitle').text, v.setup.title)
    compare(named(p.panel, 'windowsHeader').meta, v.header.meta)
    verify(textVisible(p.panel, v.result.setup))
    verify(textVisible(named(p.panel, 'setupCheck-agents'), 'Failed'))
    ;['continue_setup','window','no_window'].forEach(function(key) {
      var action = objects(p.panel, function(o) { return o.control === key && o.visible })[0]
      verify(action !== undefined && action.enabled)
      action.clicked()
      compare(p.panel.setupAgainArmed, false)
      compare(Quickshell.lastCommand.slice(3).join(' '), key === 'continue_setup' ? 'setup' : key === 'window' ? 'setup --window' : 'setup --no-window')
      var reply = JSON.parse(JSON.stringify(v)); reply.pending_ack = p.model.pendingToken
      process(p.model, 'timeout').complete(JSON.stringify(reply), 0)
    })
    v.setup.lines = ['Wait for Windows to shut down, then click Continue setup.']
    v.buttons.window.show = false; v.buttons.no_window.show = false; v.buttons.continue_setup.enable = false
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(textVisible(p.panel, v.setup.lines[0]))
    verify(!objects(p.panel, function(o) { return o.control === 'window' && o.visible }).length)
  }
  function settingsView(memory, cores, scale) {
    var v = redesignView()
    v.settings = {memory_gib:memory,cores:cores,windows_scale:scale,error:'',
      baseline:{memory_gib:memory,cores:cores,windows_scale:scale},
      labels:{memory:'Memory (GiB)',cores:'CPU cores',scale:'Windows scale',save:'Save',saved:'Saved',reset:'Reset',unsaved:'Unsaved'},
      scale_choices:[{value:'auto',label:'Match my monitor'},{value:175,label:'175%'},{value:500,label:'500%'}]}
    return v
  }
  function settingsPanel() {
    var p = redesignPanel()
    p.model.view = settingsView(12, 6, 175)
    p.panel.close(); p.panel.open()
    named(p.panel, 'settingsToggle').clicked()
    return p
  }
  function test_redesign_clean_settings_show_disabled_saved_only() {
    var p = settingsPanel(), save = named(p.panel, 'action-save_settings')
    compare(save.text, 'Saved')
    verify(!save.enabled)
    verify(!named(p.panel, 'resetSettings').visible)
    verify(named(p.panel, 'settingsToggle').text.indexOf('Unsaved') === -1)
    var scale = named(p.panel, 'windowsScale')
    compare(scale.options[scale.options.length - 1].value, 500)
    var fields = objects(p.panel, function(o) { return o.field !== undefined })
    compare(fields[0].from, 1); compare(fields[0].to, 512)
    compare(fields[1].from, 1); compare(fields[1].to, 64)
    // Suggested values without a saved baseline must still be saveable.
    var v = settingsView(12, 6, 175); v.settings.baseline = null
    p.model.view = v
    compare(save.text, 'Save'); verify(save.enabled)
    verify(!named(p.panel, 'resetSettings').enabled)
    p.panel.destroy()
  }
  function test_redesign_reset_is_local_and_restores_latest_saved_baseline() {
    var p = settingsPanel(), scale = named(p.panel, 'windowsScale')
    p.panel.memoryInput = 20; p.panel.coresInput = 10; scale.select('auto')
    p.model.view = settingsView(24, 8, 500)
    var count = Quickshell.launchCount
    named(p.panel, 'resetSettings').clicked()
    compare(p.panel.memoryInput, 24); compare(p.panel.coresInput, 8)
    compare(p.panel.windowsScaleInput, 500); compare(scale.currentLabel(), '500%')
    compare(p.panel.scaleTouched, false); compare(p.panel.scaleDirty, false)
    compare(Quickshell.launchCount, count)
    verify(!process(p.model, p.model.cli))
    compare(named(p.panel, 'action-save_settings').text, 'Saved')
    p.panel.memoryInput = 25
    named(p.panel, 'action-save_settings').clicked()
    compare(process(p.model, p.model.cli).command.slice(3).join(' '), 'settings 25 8')
    process(p.model, p.model.cli).complete('{"ok":false}', 1)
    var v = settingsView(24, 8, 500); v.settings.error = 'Unreadable settings'; v.settings.baseline = null
    p.model.view = v
    verify(!named(p.panel, 'action-save_settings').enabled)
    verify(!named(p.panel, 'resetSettings').enabled)
    named(p.panel, 'resetSettings').clicked()
    compare(p.panel.memoryInput, 25)
    p.panel.close(); p.model.view = settingsView(32, 16, 'auto'); p.panel.open()
    compare(p.panel.memoryInput, 32); compare(p.panel.coresInput, 16)
    compare(p.panel.windowsScaleInput, 'auto')
    verify(!p.panel.scaleTouched); verify(!p.panel.scaleDirty)
    p.panel.destroy()
  }
  function test_redesign_drafts_survive_polls_sections_and_failed_saves() {
    var p = settingsPanel()
    var memory = objects(p.panel, function(o) { return o.field !== undefined && o.label === 'Memory (GiB)' })[0]
    memory.field.forceActiveFocus(); keyClick(Qt.Key_Up)
    named(p.panel, 'windowsScale').select('500')
    named(p.panel, 'logsToggle').clicked(); named(p.panel, 'settingsToggle').clicked()
    p.model.view = settingsView(32, 16, 'auto')
    compare(p.panel.memoryInput, 13); compare(p.panel.coresInput, 6)
    compare(p.panel.windowsScaleInput, 500)
    named(p.panel, 'action-save_settings').clicked()
    var action = process(p.model, p.model.cli)
    compare(action.command.slice(3).join(' '), 'settings 13 6 500')
    action.complete('{"ok":false}', 1)
    p.model.view = settingsView(32, 16, 'auto')
    compare(p.panel.memoryInput, 13); compare(p.panel.coresInput, 6)
    compare(p.panel.windowsScaleInput, 500)
    verify(named(p.panel, 'settingsToggle').text.indexOf('Unsaved') !== -1)
    verify(named(p.panel, 'resetSettings').visible)
    var v = settingsView(32, 16, 'auto'); v.buttons.save_settings.enable = false
    p.model.view = v
    verify(!named(p.panel, 'action-save_settings').enabled)
    verify(!named(p.panel, 'resetSettings').enabled)
    p.panel.destroy()
  }
  function test_redesign_scale_selection_is_dirty_even_when_unchanged() {
    var p = settingsPanel(), scale = named(p.panel, 'windowsScale')
    scale.select('175')
    compare(p.panel.windowsScaleInput, 175)
    verify(p.panel.scaleTouched); verify(p.panel.scaleDirty)
    verify(named(p.panel, 'settingsToggle').text.indexOf('Unsaved') !== -1)
    verify(named(p.panel, 'action-save_settings').enabled)
    verify(named(p.panel, 'resetSettings').visible)
    named(p.panel, 'resetSettings').clicked()
    verify(!p.panel.scaleTouched); verify(!p.panel.scaleDirty)
    compare(named(p.panel, 'action-save_settings').text, 'Saved')
    p.panel.destroy()
  }
  function test_redesign_success_clears_dirty_but_keeps_scale_save_intent() {
    var p = settingsPanel(), save = named(p.panel, 'action-save_settings')
    named(p.panel, 'windowsScale').select('500')
    save.clicked()
    var action = process(p.model, p.model.cli)
    compare(action.command.slice(3).join(' '), 'settings 12 6 500')
    // Use accepted values immediately, before the following poll can arrive.
    action.complete('{"ok":true,"memory_gib":14,"cores":7,"windows_scale":500}', 0)
    compare(p.panel.memoryInput, 14); compare(p.panel.coresInput, 7)
    compare(p.panel.windowsScaleInput, 500)
    verify(!p.panel.scaleDirty); verify(p.panel.scaleTouched)
    verify(named(p.panel, 'settingsToggle').text.indexOf('Unsaved') === -1)
    compare(save.text, 'Save'); verify(save.enabled)
    verify(named(p.panel, 'resetSettings').visible)
    process(p.model, 'timeout').complete(JSON.stringify(settingsView(14, 7, 500)), 0)
    save.clicked()
    compare(action.command.slice(3).join(' '), 'settings 14 7 500')
    action.complete('{"ok":true,"memory_gib":14,"cores":7,"windows_scale":500}', 0)
    verify(!p.panel.scaleDirty); verify(p.panel.scaleTouched)
    process(p.model, 'timeout').complete(JSON.stringify(settingsView(14, 7, 500)), 0)
    named(p.panel, 'resetSettings').clicked()
    p.panel.memoryInput = 15; save.clicked()
    compare(action.command.slice(3).join(' '), 'settings 15 7')
    action.complete('{"ok":true,"memory_gib":15,"cores":7,"windows_scale":500}', 0)
    compare(save.text, 'Saved'); verify(!save.enabled)
    verify(!named(p.panel, 'resetSettings').visible)
    p.panel.destroy()
  }
  function logView() {
    var v = redesignView()
    v.logs = {copied:'Copied',copy_error:'Could not copy. Try again.',copy_busy:'Another log is being copied. Try again in a moment.',rows:[
      {id:'vm',label:'VM',display:'journal: lanai-vm',copy_text:'journalctl --user -u lanai-vm; $(touch NEVER)\n"literal"',copy_label:'Copy VM log command'},
      {id:'client',label:'Window',display:'client.log',copy_text:'/state with spaces/client.log',copy_label:'Copy Window log path'},
      {id:'build',label:'Build',display:'build-client.log',copy_text:'/state/build-client.log',copy_label:'Copy Build log path'},
      {id:'job',label:'Jobs',display:'panel-job.log',copy_text:'/state/panel-job.log',copy_label:'Copy Jobs log path'},
      {id:'command',label:'Actions',display:'panel-run.log',copy_text:'/state/panel-run.log',copy_label:'Copy Actions log path'}]}
    return v
  }
  function logsPanel() {
    var p = redesignPanel(); p.model.view = logView()
    named(p.panel, 'logsToggle').clicked()
    return p
  }
  function test_redesign_copy_uses_literal_stdin_and_reports_each_rows_exit() {
    var p = logsPanel(), count = Quickshell.launchCount
    for (var i = 0; i < p.model.view.logs.rows.length; i++) {
      var row = p.model.view.logs.rows[i], button = named(p.panel, 'copyLog-' + row.id)
      verify(button !== undefined)
      compare(button.Accessible.name, row.copy_label); verify(button.focusable)
      button.forceActiveFocus(); keyClick(Qt.Key_Return)
      var copy = process(p.model, 'wl-copy')
      verify(copy !== undefined); verify(copy.running)
      compare(copy.command.length, 1); verify(copy.stdinEnabled)
      p.model.copyLog('client')
      compare(p.model.copyingId, row.id)
      copy.begin()
      compare(copy.input, row.copy_text); verify(copy.wroteWithStdin)
      compare(copy.stdinEnabled, false)
      compare(named(p.panel, 'copyFeedback-' + row.id).text, '')
      // Polls can reorder rows without moving the completion to another row.
      var v = logView(); v.logs.rows.reverse(); p.model.view = v
      compare(named(p.panel, 'copyBusy').text, v.logs.copy_busy)
      verify(named(p.panel, 'copyBusy').visible)
      for (var j = 0; j < v.logs.rows.length; j++) {
        var other = named(p.panel, 'copyLog-' + v.logs.rows[j].id)
        verify(!other.enabled); compare(other.tooltipText, v.logs.copy_busy)
      }
      copy.complete('', 0); wait(1)
      compare(named(p.panel, 'copyFeedback-' + row.id).text, 'Copied')
      verify(named(p.panel, 'copyLog-' + row.id).enabled)
      p.model.view = logView()
    }
    compare(Quickshell.launchCount, count)
    verify(!process(p.model, p.model.cli)); compare(p.model.pendingToken, '')
    p.panel.close(); p.panel.open()
    compare(named(p.panel, 'copyFeedback-vm').text, '')
    p.panel.destroy()
  }
  function test_redesign_copy_failure_can_retry_and_cannot_run_the_vm_command() {
    var p = logsPanel(), count = Quickshell.launchCount
    for (var status = 0; status < 3; status++) {
      var button = named(p.panel, 'copyLog-vm'); button.clicked()
      var copy = process(p.model, 'wl-copy')
      if (status === 0) copy.failToStart()
      else { copy.begin(); copy.complete('', status === 1 ? 1 : 0, status === 2 ? 1 : 0) }
      wait(1)
      compare(named(p.panel, 'copyFeedback-vm').text, p.model.view.logs.copy_error)
      verify(named(p.panel, 'copyLog-vm').enabled)
    }
    named(p.panel, 'copyLog-vm').clicked(); copy.begin()
    compare(copy.input, p.model.view.logs.rows[0].copy_text)
    var v = logView(); v.logs.rows[0].copy_text = 'different target'; p.model.view = v
    copy.complete('', 0); wait(1)
    compare(named(p.panel, 'copyFeedback-vm').text, '')
    named(p.panel, 'copyLog-vm').clicked(); copy.begin(); copy.complete('', 0)
    compare(named(p.panel, 'copyFeedback-vm').text, 'Copied')
    v.logs.rows[0].copy_text = 'another target'; p.model.view = JSON.parse(JSON.stringify(v))
    compare(named(p.panel, 'copyFeedback-vm').text, '')
    // Reopening during a copy must not resurrect feedback from the old panel.
    named(p.panel, 'copyLog-vm').clicked(); copy.begin()
    p.panel.close(); p.panel.open(); copy.complete('', 0); wait(1)
    compare(named(p.panel, 'copyFeedback-vm').text, '')
    compare(Quickshell.launchCount, count)
    verify(!process(p.model, p.model.cli)); compare(p.model.pendingToken, '')
    p.model.copyLog('missing')
    verify(!copy.running)
    p.panel.destroy()
  }
  function test_redesign_header_uses_saved_view_and_theme_roles() {
    var p = redesignPanel(), hero = named(p.panel, 'windowsHeader')
    verify(hero !== undefined)
    compare(hero.title, p.model.view.header.title)
    compare(hero.meta, p.model.view.header.meta)
    compare(hero.detail, p.model.view.header.badge)
    p.panel.memoryInput = 24; p.panel.windowsScaleInput = 250
    compare(hero.meta, '12 GiB · 6 cores · 175%')
    compare(hero.foreground, Commons.Color.foreground)
    verify(hero.iconComponent !== null)
    p.panel.destroy()
  }
  function test_redesign_only_one_detail_section_opens_and_failed_defaults_to_logs() {
    var p = redesignPanel()
    compare(p.panel.expandedSection, '')
    verify(!objects(p.panel,function(o) { return o.control === 'force_stop' && o.visible }).length)
    named(p.panel, 'settingsToggle').clicked()
    compare(p.panel.expandedSection, 'settings')
    verify(named(p.panel, 'settingsToggle').Accessible.expanded)
    p.panel.memoryInput = 24
    named(p.panel, 'snapshotsToggle').clicked()
    compare(p.panel.expandedSection, 'snapshots')
    verify(!named(p.panel, 'settingsDetails').visible)
    compare(p.panel.memoryInput, 24)
    named(p.panel, 'snapshotsToggle').clicked()
    compare(p.panel.expandedSection, '')
    var v = redesignView(); v.layout = 'failed'; v.sections.default = 'logs'
    v.result.setup = 'Setup could not update the window.'
    v.buttons.continue_setup = {show:true,enable:false,label:'Run setup again',hint:'Shut down first.'}
    p.model.view = v
    verify(objects(p.panel,function(o) { return o.text === v.result.setup && o.visible }).length > 0)
    verify(objects(p.panel,function(o) { return o.text === v.buttons.continue_setup.hint && o.visible }).length > 0)
    compare(p.panel.expandedSection, 'logs')
    named(p.panel, 'settingsToggle').clicked()
    p.model.view = JSON.parse(JSON.stringify(v))
    compare(p.panel.expandedSection, 'settings')
    p.panel.close(); p.panel.open()
    compare(p.panel.expandedSection, 'logs')
    p.panel.destroy()
  }
  function test_redesign_all_offered_controls_remain_reachable() {
    var p = redesignPanel(), v = redesignView()
    var keys = ['stop','force_stop','force_confirm','dismiss_notice','update_client','continue_setup','reopen_window','install','setup_snapshot','skip_snapshot','window','no_window','take_snapshot','finish_restore']
    keys.forEach(function(k) { v.buttons[k] = {show:true,enable:true,label:k} })
    v.setup = {show:true,finished:false}; p.model.view = v
    verify(named(p.panel, 'primaryAction').visible)
    verify(named(p.panel, 'moreActionsToggle').visible)
    named(p.panel, 'moreActionsToggle').clicked()
    named(p.panel, 'snapshotsToggle').clicked()
    keys.filter(function(k) { return k !== 'force_confirm' }).forEach(function(k) {
      verify(objects(p.panel, function(o) { return o.control === k && o.visible }).length > 0, k)
    })
    p.panel.destroy()
  }
  function test_redesign_restore_dates_identity_cancel_and_invalidated_target() {
    var p = redesignPanel()
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    var restore = named(p.panel, 'restore-20261012T091200Z')
    verify(restore !== undefined)
    compare(restore.text, p.model.view.snapshots.items[0].restore_label)
    restore.clicked()
    compare(p.panel.restoreArmed, '20261012T091200Z')
    verify(objects(p.panel, function(o) { return o.text === 'Later changes are lost.' && o.visible }).length > 0)
    named(p.panel, 'restoreCancel').clicked()
    compare(p.panel.restoreArmed, '')
    restore.clicked()
    named(p.panel, 'logsToggle').clicked()
    compare(p.panel.restoreArmed, '20261012T091200Z')
    named(p.panel, 'snapshotsToggle').clicked()
    restore.clicked()
    compare(Quickshell.lastCommand.slice(3).join(' '), 'restore 20261012T091200Z')
    p.model.pendingToken = ''; ready(p.model)
    restore.clicked()
    var v = redesignView(); v.snapshots.items = []; v.snapshots.names = []; p.model.view = v
    compare(p.panel.restoreArmed, '')
    p.model.view = redesignView(); wait(1)
    named(p.panel, 'restore-20261012T091200Z').clicked()
    v = redesignView(); v.buttons.restore_snapshot.enable = false; p.model.view = v
    compare(p.panel.restoreArmed, '')
    p.panel.destroy()
  }
  function test_redesign_progress_stays_above_actions_for_snapshot_and_restore() {
    var p = redesignPanel()
    for (var i = 0; i < 2; i++) {
      var v = redesignView()
      v.progress = {operation:i ? 'restore':'snapshot',label:'Reading image',percent:37,total:100}
      v.restore = {label:i ? 'Restoring Oct 12, 2026 at 09:12 UTC':'',warning:i ? 'Keep Windows stopped.':''}
      p.model.view = v; wait(1)
      var progress = named(p.panel, 'operationProgress'), actions = named(p.panel, 'dailyActions')
      verify(progress !== undefined)
      verify(progress.visible)
      verify(progress.mapToItem(p.panel,0,0).y + progress.height <= actions.mapToItem(p.panel,0,0).y)
      compare(named(p.panel, 'imageProgress').value,37)
      compare(named(p.panel, 'restoreTarget').text,v.restore.label)
    }
    v.progress.total = 0; p.model.view = JSON.parse(JSON.stringify(v))
    compare(named(p.panel, 'imageProgress').indeterminate,true)
    wait(80)
    compare(named(p.panel, 'imageProgressText').text,'Reading image')
    v.progress.total = 100; v.progress.percent = 0; p.model.view = JSON.parse(JSON.stringify(v))
    compare(named(p.panel, 'imageProgress').indeterminate,false)
    var fill = objects(named(p.panel, 'imageProgress').contentItem, function(o) { return o.color !== undefined })[0]
    compare(fill.x,0)
    compare(named(p.panel, 'imageProgressText').text,'Reading image, 0%')
    p.panel.destroy()
  }
  function test_redesign_focus_reveals_expanded_rows_and_notice_covered_controls() {
    var p = redesignPanel(), popup = named(p.panel,'panelPopup'), flick = named(p.panel,'panelScroll')
    verify(popup !== undefined)
    popup.contentHeight = 180
    p.model.clickNotice = 'Previous action is running.'
    named(p.panel,'settingsToggle').clicked(); wait(50)
    var field = objects(p.panel,function(o) { return o.label === 'Memory (GiB)' })[0]
    field.field.forceActiveFocus(); wait(1)
    verify(field.mapToItem(flick,0,0).y >= 0)
    verify(field.mapToItem(flick,0,0).y + field.height <= flick.height - flick.bottomMargin + 1)
    var save = objects(p.panel,function(o) { return o.control === 'save_settings' })[0]
    p.panel.memoryInput = 13
    save.forceActiveFocus(); wait(1)
    verify(save.mapToItem(flick,0,0).y + save.height <= flick.height - flick.bottomMargin + 1)
    verify(flick.contentY > 0)
    var count = Quickshell.launchCount
    named(p.panel,'clickNoticeDismiss').forceActiveFocus()
    keyClick(Qt.Key_Space)
    compare(p.model.clickNotice,'')
    compare(Quickshell.launchCount,count)
    verify(!process(p.model,p.model.cli))
    var sections = ['settings','snapshots','logs']
    for (var i = 0; i < sections.length; i++) {
      var toggle = named(p.panel,sections[i] + 'Toggle')
      if (p.panel.expandedSection !== sections[i]) toggle.clicked()
      p.model.clickNotice = 'Previous action is running.'
      toggle.forceActiveFocus(); wait(50)
      keyClick(Qt.Key_Tab); wait(50)
      verify(!toggle.activeFocus)
      keyClick(Qt.Key_Backtab); wait(50)
      verify(toggle.activeFocus)
      verify(toggle.mapToItem(flick,0,0).y >= 0)
      verify(toggle.mapToItem(flick,0,0).y + toggle.height <= flick.height - flick.bottomMargin + 1)
    }
    p.panel.expandedSection = 'settings'; wait(50)
    save.forceActiveFocus(); wait(50)
    flick.contentY -= flick.height - flick.bottomMargin - save.mapToItem(flick,0,0).y + 8
    var notice = named(p.panel,'clickNotice').parent
    verify(save.mapToItem(flick,0,0).y >= flick.height - flick.bottomMargin)
    mouseClick(notice, 10, 10)
    compare(p.model.clickNotice,'')
    verify(!process(p.model,p.model.cli))
    p.panel.destroy()
  }
  function test_redesign_failed_polls_have_safe_presentation_and_recover() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    for (var i = 0; i < 2; i++) {
      model.refresh()
      process(model,'timeout').complete(i ? JSON.stringify(redesignView()) : 'invalid', i ? 1 : 0)
      compare(model.view.layout,'failed')
      compare(model.view.bar.mode,'failed')
      compare(model.view.sections.default,'logs')
      compare(model.view.snapshots.items.length,0)
      compare(model.view.logs.rows.length,0)
      compare(model.control('start').show,false)
      verify(model.view.cause.length > 0)
      model.refresh(); process(model,'timeout').complete(JSON.stringify(redesignView()),0)
      compare(model.view.header.meta,redesignView().header.meta)
    }
  }
  function test_widget_panel_toggles_from_left_and_all_keyboard_keys_in_every_state() {
    var p = widgetParts()
    var states = ['not-installed','setup-needed','stopped','starting','running','stopping','in-use','version-mismatch','failed']
    var keys = [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space, Qt.Key_Menu]
    for (var i = 0; i < states.length; i++) {
      p.model.view = {state:states[i],right_click:'start',buttons:{start:{enable:true},open:{enable:true}},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
      p.widget.close()
      p.button.pressed(Qt.LeftButton)
      compare(p.widget.opened, true)
      p.button.pressed(Qt.LeftButton)
      compare(p.widget.opened, false)
      for (var k = 0; k < keys.length; k++) {
        p.button.forceActiveFocus()
        keyClick(keys[k])
        compare(p.widget.opened, true)
        keyClick(keys[k])
        compare(p.widget.opened, false)
      }
      verify(!process(p.model, p.model.cli))
    }
    p.widget.destroy(); wait(1)
  }
  function test_widget_right_click_uses_backend_action_and_literal_ui_run_argv() {
    var p = widgetParts()
    for (var i = 0; i < 2; i++) {
      var actionName = i === 0 ? 'start' : 'open'
      // Deliberately contradictory status/controls catch frontend decisions.
      p.model.view = {state:'failed',right_click:actionName,buttons:{start:{enable:false},open:{enable:false}},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
      p.button.pressed(Qt.RightButton)
      compare(p.widget.opened, false)
      var action = process(p.model, p.model.cli)
      verify(action.running)
      compare(action.command.length, 4)
      compare(action.command[0], p.model.cli)
      compare(action.command[1], 'ui-run')
      verify(/^panel-[0-9]+-[0-9]+$/.test(action.command[2]))
      compare(action.command[3], actionName)
      action.complete('{"ok":false,"panel_requested":true}', 1)
      compare(p.widget.opened, true)
      ready(p.model); p.widget.close()
    }
    p.widget.destroy(); wait(1)
  }
  function test_widget_unknown_missing_and_panel_actions_open_without_toggling() {
    var p = widgetParts()
    var actions = ['panel', 'unknown', 'start; touch sentinel', '', null, undefined]
    for (var i = 0; i < actions.length; i++) {
      var v = {state:'stopped',buttons:{start:{enable:true},open:{enable:true}},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
      if (actions[i] !== undefined) v.right_click = actions[i]
      p.model.view = v
      p.widget.close()
      p.button.pressed(Qt.RightButton)
      compare(p.widget.opened, true)
      p.button.pressed(Qt.RightButton)
      compare(p.widget.opened, true)
      verify(!process(p.model, p.model.cli))
    }
    p.widget.destroy(); wait(1)
  }
  function test_widget_tooltip_includes_backend_right_click_words_and_error_fallback() {
    var p = widgetParts()
    p.model.view = {label:'Stopped',headline:'Windows is stopped',right_click:'start',right_click_tooltip:'Right-click: Start Windows.',buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
    compare(p.button.tooltipText, 'Lanai\nStopped\nWindows is stopped\nRight-click: Start Windows.')
    p.model.refresh(); var poll = process(p.model, 'timeout')
    poll.complete('invalid', 1)
    p.button.pressed(Qt.RightButton)
    compare(p.widget.opened, true)
    verify(!process(p.model, p.model.cli))
    p.widget.destroy(); wait(1)
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
  function test_progress_renders_backend_percentage_and_clears() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    compare(model.view.progress || null, null)
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    var v = {buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{},
             progress:{label:"Restoring Windows: reading image",percent:37,total:100}}
    model.view = v
    var bar = objects(panel, function(o) { return o.objectName === "imageProgress" })[0]
    var words = objects(panel, function(o) { return o.objectName === "imageProgressText" })[0]
    verify(bar !== undefined)
    compare(bar.value, 37)
    compare(words.text, "Restoring Windows: reading image, 37%")
    model.view = {buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{},progress:null}
    compare(bar.visible, false)
    compare(words.text, "")
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
      return settingsView(memory, cores, 'auto')
    }
    model.view = view(8, 4)
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    named(panel, 'settingsToggle').clicked()
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
  function test_scale_edits_survive_polls_and_save_result_transport() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    function view(scale) {
      var v = settingsView(8, 4, scale)
      v.settings.scale_choices = [{value:'auto',label:'Match my monitor'},{value:125,label:'125%'},{value:250,label:'250%'}]
      return v
    }
    model.view = view('auto')
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    named(panel, 'settingsToggle').clicked()
    var scale = objects(panel, function(o) { return o.objectName === 'windowsScale' })[0]
    verify(scale !== undefined)
    compare(scale.currentLabel(), 'Match my monitor')
    scale.select('125')
    compare(panel.windowsScaleInput, 125)
    model.view = view(250)
    compare(scale.currentLabel(), '125%')
    var save = objects(panel, function(o) { return o.control === 'save_settings' })[0]
    save.clicked()
    var action = process(model, model.cli)
    compare(action.command.slice(3).join(' '), 'settings 8 4 125')
    action.complete('{"ok":false}', 0); ready(model)
    model.view = view(250)
    compare(panel.windowsScaleInput, 125)
    save.clicked()
    panel.windowsScaleInput = 250
    action.complete('{"ok":true,"windows_scale":125}', 0); ready(model)
    compare(panel.windowsScaleInput, 125)
    model.view = view(250)
    compare(panel.windowsScaleInput, 125)
    panel.close(); panel.open()
    compare(panel.windowsScaleInput, 250)
    compare(scale.currentLabel(), '250%')
    scale.select('auto')
    compare(panel.windowsScaleInput, 'auto')
    model.view = view(125)
    panel.close(); panel.open()
    compare(scale.currentLabel(), '125%')
    panel.destroy(); wait(1)
  }
  function test_scale_list_touch_decides_a_scale_save() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var v = {ok:true,buttons:{save_settings:{show:true,enable:true,label:'Save settings'}},setup:{},
      settings:{memory_gib:8,cores:4,windows_scale:'auto',baseline:{memory_gib:8,cores:4,windows_scale:'auto'},
        labels:{memory:'Memory (GiB)',cores:'CPU cores',scale:'Windows scale',save:'Save',saved:'Saved',reset:'Reset',unsaved:'Unsaved'},note:'Saving a scale replaces one you picked in Windows.',
        scale_choices:[{value:'auto',label:'Match my monitor'},{value:125,label:'125%'}]},
      snapshots:{names:[]},result:{},logs:{}}
    // Finish the action, then answer the refresh it asks for with the same view.
    function finish(action) {
      action.complete('{"ok":true}', 0)
      var poll = process(model, 'timeout')
      if (poll && poll.running) poll.complete(JSON.stringify(v), 0)
    }
    model.view = v
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    named(panel, 'settingsToggle').clicked()
    var scale = objects(panel, function(o) { return o.objectName === 'windowsScale' })[0]
    var save = objects(panel, function(o) { return o.control === 'save_settings' })[0]
    verify(objects(panel, function(o) { return o.text === v.settings.note && o.visible }).length > 0)
    // An untouched list saves changed memory and cores only.
    panel.memoryInput = 9
    save.clicked()
    var action = process(model, model.cli)
    compare(action.command.slice(3).join(' '), 'settings 9 4')
    finish(action)
    // Choosing the entry already shown is a scale save, and so is each save after it.
    scale.select('auto')
    save.clicked()
    compare(action.command.slice(3).join(' '), 'settings 9 4 auto')
    finish(action)
    save.clicked()
    compare(action.command.slice(3).join(' '), 'settings 9 4 auto')
    finish(action)
    // Reopening the panel clears the touch.
    panel.close(); panel.open()
    panel.memoryInput = 9
    save.clicked()
    compare(action.command.slice(3).join(' '), 'settings 9 4')
    finish(action)
    panel.destroy(); wait(1)
  }
  function test_a_dropped_click_says_the_last_action_still_runs() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var panel = createTemporaryObject(panelComponent, tests, {model:model, opened:true})
    var words = 'Your previous action is still running. Try again in a moment.'
    model.run(['stop'], false)
    var action = process(model, model.cli)
    verify(action.running)
    compare(model.clickNotice, '')
    model.run(['open'], false)
    compare(action.command.slice(3).join(' '), 'stop')
    compare(model.clickNotice, words)
    // Pinned outside the scrolling content, so it is always in view and
    // never moves the controls.
    var note = objects(panel, function(o) { return o.objectName === 'clickNotice' })[0]
    verify(note !== undefined)
    verify(note.visible)
    for (var p = note.parent; p; p = p.parent) verify(p.contentY === undefined)
    // The notice's box is the popup's background, made opaque, and its
    // border the accent.
    var bg = Commons.Color.popups.background
    compare(note.parent.color, Qt.rgba(bg.r, bg.g, bg.b, 1))
    compare(note.parent.border.color, Commons.Color.accent)
    // The scrolling content gets room below, so nothing stays covered.
    var flick = objects(panel, function(o) { return o.contentY !== undefined })[0]
    compare(flick.bottomMargin, note.parent.height)
    // It stays at least 2 s, even when the action ends sooner.
    action.complete('{"ok":true}', 0)
    wait(1500)
    compare(model.clickNotice, words)
    tryCompare(model, 'clickNotice', '', 1500)
    verify(!note.visible)
    compare(flick.bottomMargin, 0)
    ready(model)
    // A long job launched moments ago drops a second one, and says so too.
    model.run(['setup'], true)
    model.run(['snapshot'], true)
    compare(model.clickNotice, words)
    compare(Quickshell.lastCommand.slice(3).join(' '), 'setup')
    // A click on the notice dismisses it and reaches nothing under it.
    mouseClick(note.parent)
    compare(model.clickNotice, '')
    // Closing the panel clears it too.
    model.run(['open'], false)
    model.run(['open'], false)
    verify(model.clickNotice !== '')
    panel.close()
    compare(model.clickNotice, '')
    // Its fill is opaque, whatever the popup's alpha.
    compare(note.parent.color.a, 1)
    panel.destroy(); wait(1)
  }
  function test_a_dropped_click_notice_goes_after_5_s_while_the_action_still_runs() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.run(['stop'], false)
    var action = process(model, model.cli)
    model.run(['open'], false)
    verify(model.clickNotice !== '')
    wait(4500)
    verify(model.clickNotice !== '')
    tryCompare(model, 'clickNotice', '', 1500)
    verify(action.running)
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
      if (model.view.setup.finished) named(panel, 'moreActionsToggle').clicked()
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
      named(panel, 'moreActionsToggle').clicked()
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
    if (model.view.setup.finished) named(panel, 'moreActionsToggle').clicked()
    var again = objects(panel, function(o) { return o.control === 'continue_setup' })[0]
    verify(again.visible)
    verify(!again.enabled)
    verify(objects(panel, function(o) { return o.text === model.control('continue_setup').hint && o.visible }).length > 0)
    panel.destroy(); wait(1)
  }
  function test_a_step6_timeout_with_windows_off_sends_either_display_choice_without_arming() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{continue_setup:{show:true,enable:true,label:'Continue setup'},
      no_window:{show:true,enable:true,label:'Set up in the Windows window',hint:'Use this if the Windows display driver already works.'},
      window:{show:true,enable:true,label:'Set up in a basic window',hint:'Use a basic window if the Windows window is blank or the display driver needs repair.'}},
      setup:{finished:false,show:true,step:'6',lines:['Click Continue setup so Lanai can check Windows.']},
      settings:{},snapshots:{names:[]},result:{setup:'In Windows, the SPICE agent did not answer.'},logs:{}}
    // Answer each launch's refresh, so the next click is not dropped.
    function settle() {
      var poll = process(model, 'timeout')
      var reply = model.view
      reply.ok = true; reply.pending_ack = model.pendingToken
      poll.complete(JSON.stringify(reply), 0)
      compare(model.pendingToken, '')
    }
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    panel.open()
    if (model.view.setup.finished) named(panel, 'moreActionsToggle').clicked()
    var again = objects(panel, function(o) { return o.control === 'continue_setup' })[0]
    var client = objects(panel, function(o) { return o.control === 'no_window' })[0]
    var screen = objects(panel, function(o) { return o.control === 'window' })[0]
    verify(again.visible)
    verify(client.visible)
    verify(screen.visible)
    client.clicked()
    compare(panel.setupAgainArmed, false)
    compare(Quickshell.lastCommand[1], 'ui-job')
    compare(Quickshell.lastCommand.slice(3).join(' '), 'setup --no-window')
    settle()
    screen.clicked()
    compare(Quickshell.lastCommand.slice(3).join(' '), 'setup --window')
    settle()
    again.clicked()
    compare(Quickshell.lastCommand.slice(3).join(' '), 'setup')
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
    model.view = {buttons:{continue_setup:{show:true,enable:true,label:'Run setup again'}},setup:{show:false,finished:true,title:'Setup is finished'},settings:{},snapshots:{names:[]},result:{snapshots:advice},logs:{}}
    wait(1)
    compare(objects(panel, function(o) { return o.text === advice && o.visible }).length, 1)
    named(panel, 'moreActionsToggle').clicked()
    verify(textVisible(panel, 'Setup is finished'))
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
    named(panel, 'moreActionsToggle').clicked()
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
    compare(panel.foreground, Commons.Color.foreground)
    compare(section.border.color, Commons.Color.accent)
    compare(section.color, Util.alpha(Commons.Color.accent, 0.10))
    Style.selectedAccentFill = '#336699'
    compare(section.color, Style.selectedAccentFill)
    Style.selectedAccentFill = undefined
    Commons.Color.accent = '#c06030'
    compare(section.border.color, Commons.Color.accent)
    compare(section.color, Util.alpha(Commons.Color.accent, 0.10))
    compare(objects(panel, function(o) { return o.objectName === 'snapshotsToggle' && o.visible }).length, 0)
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
    verify(objects(panel, function(o) { return o.objectName === 'snapshotsToggle' && o.visible }).length > 0)
    panel.destroy(); wait(1)
  }
  function test_empty_setup_section_hides_and_returns_with_content() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    function view(buttons, result) {
      return {buttons:buttons,setup:{show:false,finished:true},settings:{},snapshots:{names:[]},result:result,logs:{}}
    }
    model.view = view({}, {})
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    wait(1)
    var section = objects(panel, function(o) { return o.objectName === 'setupSection' })[0]
    verify(section !== undefined)
    compare(section.visible, false)
    model.view = view({continue_setup:{show:true,enable:true,label:'Run setup again'}}, {})
    wait(1)
    named(panel, 'moreActionsToggle').clicked()
    compare(section.visible, true)
    verify(objects(section, function(o) { return o.text === 'Run setup again' && o.visible }).length > 0)
    model.view = view({}, {})
    wait(1)
    compare(section.visible, false)
    model.view = view({}, {setup:'Setup was interrupted. Continue setup to try again.'})
    wait(1)
    compare(section.visible, true)
    verify(objects(panel, function(o) { return o.text === model.view.result.setup && o.visible }).length > 0)
    panel.destroy(); wait(1)
  }
  function test_update_button_runs_build_client_as_a_long_job_with_its_result_and_log() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var warning = 'Windows may start at, or change to, the wrong size until you click Update the Windows window. Updating changes nothing in Windows.'
    var done = 'The Windows window is updated. If the Windows window is open, close it and open it again.'
    function view(enable) {
      return {warning:warning,buttons:{update_client:{show:true,enable:enable,label:'Update the Windows window'}},
        setup:{},settings:{},snapshots:{names:[]},result:{client:done},
        logs:{rows:[{id:'vm',label:'VM',display:'journal: lanai-vm',copy_text:'journalctl --user -u lanai-vm',copy_label:'Copy VM log command'},
          {id:'build',label:'Build',display:'build-client.log',copy_text:'/state/build-client.log',copy_label:'Copy Build log path'}]}}
    }
    model.view = view(true)
    var panel = createTemporaryObject(panelComponent, tests, {model:model, opened:true})
    wait(1)
    verify(model.tooltip.indexOf(warning) !== -1)
    named(panel, 'moreActionsToggle').clicked()
    named(panel, 'logsToggle').clicked()
    var update = objects(panel, function(o) { return o.control === 'update_client' })[0]
    verify(update !== undefined)
    verify(update.visible)
    verify(update.enabled)
    compare(update.text, 'Update the Windows window')
    verify(objects(panel, function(o) { return o.text === done && o.visible }).length > 0)
    verify(objects(panel, function(o) { return o.text === model.view.logs.rows[1].display && o.visible }).length > 0)
    var count = Quickshell.launchCount
    update.clicked()
    compare(Quickshell.launchCount, count + 1)
    compare(Quickshell.lastCommand[1], 'ui-job')
    compare(Quickshell.lastCommand[2], model.pendingToken)
    compare(Quickshell.lastCommand.slice(3).join(' '), 'build-client')
    verify(!process(model, model.cli))
    model.view = view(false)
    verify(update.visible)
    verify(!update.enabled)
    panel.destroy(); wait(1)
  }
  function test_force_stop_two_clicks() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{force_stop:{show:true,enable:true,label:'Force stop'},force_confirm:{show:true,enable:true,label:'Confirm'}},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    verify(panel !== null)
    named(panel, 'moreActionsToggle').clicked()
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
    model.view = {buttons:{restore_snapshot:{show:true,enable:true,label:'Restore',labels:{snapshot:'Restore snapshot snapshot'}},restore_confirm:{show:true,enable:true,label:'Confirm',labels:{snapshot:'Restore snapshot and replace Windows'}}},setup:{},settings:{},snapshots:{names:['snapshot'],items:[{name:'snapshot',label:'snapshot',restore_label:'Restore snapshot snapshot',confirm_label:'Restore snapshot and replace Windows'}]},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    wait(1)
    named(panel, 'snapshotsToggle').clicked()
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
