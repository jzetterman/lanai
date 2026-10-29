#!/usr/bin/env bats
# Real QML with inert shell/Process types: no compositor, services or subprocesses.
# shellcheck disable=SC2034,SC2329
load helpers
load panel-fixtures
setup() { isolate_home; T=$BATS_TEST_TMPDIR; }

qml_renderer_fixture() {
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
  property bool reduceMotion: false
  property var font: ({family:"sans",bodySmall:12,caption:10})
  function space(n) { return n }
  function duration(ms) { return reduceMotion ? 0 : ms }
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
TextField 1.0 TextField.qml
QML
  # A real Qt Quick Controls field, so typing and paste behave as installed.
  cat >"$T/qml/imports/TestUi/TextField.qml" <<'QML'
import QtQuick
import QtQuick.Controls as QQC
QQC.TextField {
  property color foreground
  property color accent
  property bool hasCursor
}
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
  Loader { anchors.fill: parent; sourceComponent: parent.iconComponent }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) { parent.pressed(mouse.button) }
  }
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
  // Puts text on the test clipboard for a real paste.
  TextEdit { id: clipboardSource; visible: false }
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
  function barView(mode, percent, active) {
    var v = redesignView()
    v.active = active
    v.bar = {mode:mode,percent:percent,label:({stopped:'Stopped',active:'Active',busy:'Busy',attention:'Your turn',failed:'Failed'})[mode]}
    v.right_click = 'panel'
    v.right_click_tooltip = 'Right-click: Open the panel.'
    return v
  }
  function test_redesign_bar_modes_render_theme_badges_and_underlines() {
    var p = widgetParts()
    var original = [Commons.Color.foreground, Commons.Color.accent, Commons.Color.urgent]
    ;[['#dddddd','#4488cc','#cc4444'],['#222222','#886622','#992288']].forEach(function(colors) {
      Commons.Color.foreground = colors[0]; Commons.Color.accent = colors[1]; Commons.Color.urgent = colors[2]
      ;['stopped','active','busy','attention','failed'].forEach(function(mode) {
        // The supplied mode wins even if Windows is active in the background.
        p.model.view = barView(mode, 42, mode !== 'stopped')
        wait(1)
        var monitor = named(p.widget, 'barMonitor'), foot = named(p.widget, 'barFoot')
        var underline = named(p.widget, 'barUnderline'), badge = named(p.widget, 'barBadge')
        verify(monitor !== undefined && foot !== undefined && underline !== undefined && badge !== undefined)
        compare(monitor.border.color, mode === 'active' ? Commons.Color.accent : Commons.Color.foreground)
        compare(foot.color, monitor.border.color)
        compare(p.button.active, p.model.view.active)
        compare(underline.visible, mode === 'active' || mode === 'busy')
        if (underline.visible) {
          compare(underline.color, Commons.Color.accent)
          fuzzyCompare(underline.width / underline.parent.width, mode === 'active' ? 1 : 0.42, 0.001)
        }
        compare(badge.visible, mode === 'attention' || mode === 'failed')
        if (badge.visible) {
          compare(badge.color, mode === 'failed' ? Commons.Color.urgent : Commons.Color.accent)
          compare(badge.radius > 0, mode === 'attention')
        }
        compare(p.button.Accessible.name, p.button.tooltipText)
        compare(p.button.Accessible.role, Accessible.Button)
      })
    })
    Commons.Color.foreground = original[0]; Commons.Color.accent = original[1]; Commons.Color.urgent = original[2]
    ;[0,100].forEach(function(percent) {
      p.model.view = barView('busy', percent, false)
      var underline = named(p.widget, 'barUnderline')
      fuzzyCompare(underline.width / underline.parent.width, percent / 100, 0.001)
    })
  }
  function test_redesign_busy_without_progress_animates_a_fixed_segment() {
    var p = widgetParts()
    p.model.view = barView('busy', null, true)
    wait(1)
    var underline = named(p.widget, 'barUnderline'), animation = named(p.widget, 'barBusyAnimation')
    verify(underline !== undefined && animation !== undefined)
    verify(underline.visible && animation.running)
    var width = underline.width, x = underline.x
    verify(width > 0 && width < underline.parent.width)
    wait(100)
    compare(underline.width, width)
    verify(underline.x !== x)
    verify(underline.x >= 0 && underline.x + width <= underline.parent.width)
    p.model.view = barView('busy', 25, true)
    verify(!animation.running)
    compare(underline.x, 0)
    fuzzyCompare(underline.width / underline.parent.width, 0.25, 0.001)
    p.model.view = barView('busy', null, true)
    verify(animation.running)
    ;['attention','failed','active','stopped'].forEach(function(mode) {
      p.model.view = barView(mode, null, true)
      verify(!animation.running)
      compare(underline.x, 0)
    })
    p.model.view = barView('busy', null, true)
    Style.reduceMotion = true
    verify(!animation.running)
    compare(underline.width, width)
    compare(underline.x, 0)
    Style.reduceMotion = false
  }
  function test_redesign_bar_shortcuts_and_failure_panel_requests_survive() {
    var p = widgetParts(), keys = [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space, Qt.Key_Menu]
    ;['stopped','active','busy','attention','failed'].forEach(function(mode) {
      var v = barView(mode, null, true)
      p.model.view = v
      p.widget.close()
      mouseClick(p.button, 12, 12, Qt.LeftButton)
      verify(p.widget.opened)
      mouseClick(p.button, 12, 12, Qt.LeftButton)
      verify(!p.widget.opened)
      p.button.forceActiveFocus()
      verify(named(p.widget, 'barFocus').visible)
      keys.forEach(function(key) {
        keyClick(key); verify(p.widget.opened)
        keyClick(key); verify(!p.widget.opened)
      })
      ;['start','open'].forEach(function(action) {
        v = barView(mode, null, true); v.right_click = action
        p.model.view = v
        p.button.pressed(Qt.RightButton)
        var command = process(p.model, p.model.cli)
        compare(command.command.slice(3).join(' '), action)
        command.complete('{"ok":false,"panel_requested":true}', 1)
        verify(p.widget.opened)
        ready(p.model); p.widget.close()
      })
      p.model.view = barView(mode, null, true)
      p.button.pressed(Qt.RightButton)
      verify(p.widget.opened)
      p.widget.close()
      p.model.run(['force-stop','--confirm'], false)
      process(p.model, p.model.cli).complete('{"ok":true,"panel_requested":true,"forced":true}', 0)
      verify(p.widget.opened)
      ready(p.model); p.widget.close()
    })
  }
  function named(panel, name) { return objects(panel, function(o) { return o.objectName === name })[0] }
  function redesignView() {
    return {ok:true,layout:'daily',header:{title:'Windows',meta:'12 GiB · 6 cores · 175%',badge:'Stopped'},
      sections:{settings:'Settings',snapshots:'Snapshots',logs:'Logs',default:''},primary_action:'start',
      buttons:{start:{show:true,enable:true,label:'Start Windows'},cancel:{show:true,enable:true,label:'Cancel'},
        restore_snapshot:{show:true,enable:true,label:'Restore'},restore_confirm:{show:true,enable:true,label:'Restore now'},
        delete_snapshot:{show:true,enable:true,label:'Delete'},delete_confirm:{show:true,enable:true,label:'Delete snapshot'},
        save_settings:{show:true,enable:true,label:'Save settings'}},setup:{finished:true},
      settings:{memory_gib:12,cores:6,windows_scale:175,baseline:{memory_gib:12,cores:6,windows_scale:175},
        labels:{memory:'Memory (GiB)',cores:'CPU cores',scale:'Windows scale',save:'Save',saved:'Saved',reset:'Reset',unsaved:'Unsaved'}},
      result:{},logs:{copied:'Copied',copy_error:'Could not copy.',copy_busy:'Copying',
        rows:[{id:'vm',label:'VM',display:'journal: lanai-vm',copy_text:'journalctl --user -u lanai-vm',copy_label:'Copy VM log command'}]},
      snapshots:{show:true,count:1,names:['20261012T091200Z'],items:[{name:'20261012T091200Z',date:'Oct 12, 2026',time:'09:12 UTC',
        label:'Oct 12, 2026 at 09:12 UTC',restore_label:'Restore Oct 12, 2026 at 09:12 UTC',
        confirm_label:'Restore now: Oct 12, 2026 at 09:12 UTC and replace Windows',
        confirm_note:'Restore this snapshot and replace Windows?',warning:'Later changes are lost.',
        delete_label:'Delete Oct 12, 2026 at 09:12 UTC',delete_confirm_label:'Delete snapshot: Oct 12, 2026 at 09:12 UTC, permanently',
        delete_confirm_note:'Delete this snapshot permanently?',
        delete_warning:'Windows stays as it is.'}]},
      restore:{label:'',warning:''},progress:null,busy:{active:false,line:''}}
  }
  // redesignView with a second, older snapshot below the first.
  function twoSnapshotView() {
    var v = redesignView(), older = JSON.parse(JSON.stringify(v.snapshots.items[0]))
    older.name = '20261001T080000Z'; older.date = 'Oct 1, 2026'; older.time = '08:00 UTC'
    older.label = 'Oct 1, 2026 at 08:00 UTC'; older.restore_label = 'Restore ' + older.label
    older.confirm_label = 'Restore ' + older.label + ' and replace Windows'
    older.delete_label = 'Delete ' + older.label; older.delete_confirm_label = 'Delete snapshot: ' + older.label + ', permanently'
    v.snapshots.items.push(older); v.snapshots.names.push(older.name); v.snapshots.count = 2
    return v
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
  // True when <lower> starts at or below the bottom of <upper>, once the
  // layout has settled.
  function below(lower, upper) {
    verify(waitForPolish(lower.Window.window))
    return lower.mapToItem(null, 0, 0).y >= upper.mapToItem(null, 0, upper.height).y
  }
  // Waits until a confirming click on an armed row counts.
  function pastConfirmGuard(panel) { wait(panel.confirmGuardMs + 50) }
  function textVisible(panel, text) {
    return objects(panel, function(o) { return o.text === text && o.visible }).length > 0
  }
  function test_redesign_all_six_setup_steps_and_prepare_substep_render() {
    var p = redesignPanel()
    ;['1','2','3','3a','4','5','6'].forEach(function(step) {
      var v = setupView(step)
      named(p.panel, 'panelPopup').contentWidth = 420
      p.model.view = v
      var strip = named(p.panel, 'setupSteps')
      verify(strip !== undefined)
      verify(waitForPolish(strip.Window.window))
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
      verify(waitForPolish(strip.Window.window))
      entries.forEach(function(entry, i) {
        fuzzyCompare(entry.x, (i % 3) * (entry.width + strip.spacing), 1)
        fuzzyCompare(entry.y, i < 3 ? 0 : entries[0].height + strip.spacing, 1)
        verify(entry.x + entry.width <= strip.width + 1)
      })
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
  function test_main_keeps_routine_copy_out_of_collapsed_panel() {
    var p = redesignPanel(), v = redesignView()
    v.state = 'running'; v.header.badge = 'Running'; v.primary_action = 'open'
    v.headline = 'Windows is running'; v.cause = 'Windows is available.'; v.next = 'Click Open window.'
    v.buttons.start.show = false
    v.buttons.open = {show:true,enable:true,label:'Open window'}
    v.buttons.stop = {show:true,enable:true,label:'Shut down'}
    v.buttons.continue_setup = {show:true,enable:false,label:'Run setup again',hint:'Shut Windows down first.'}
    v.buttons.window = {show:true,enable:false,label:'Set up in a basic window',hint:'Use this if the window is blank.'}
    v.buttons.no_window = {show:true,enable:false,label:'Set up in the Windows window',hint:'Use this if the driver works.'}
    v.result.snapshots = 'Snapshot saved at /home/john/snapshots/example. It shares disk space at first.'
    v.snapshots.saved = {path:'/home/john/snapshots/example',path_line:'Snapshot saved at /home/john/snapshots/example',
      advice:'It shares disk space at first.',copy_label:'Copy snapshot path',
      show_label:'Show details',hide_label:'Hide details'}
    p.model.view = v
    verify(!textVisible(p.panel, v.headline))
    verify(!textVisible(p.panel, v.cause))
    verify(!textVisible(p.panel, v.next))
    compare(named(p.panel, 'primaryAction').tooltipText, v.cause + ' ' + v.next)
    verify(!textVisible(p.panel, v.result.snapshots))
    verify(!textVisible(p.panel, v.buttons.continue_setup.hint))
    named(p.panel, 'moreActionsToggle').clicked()
    verify(textVisible(p.panel, v.buttons.continue_setup.hint))
    verify(!textVisible(p.panel, v.buttons.window.hint))
    verify(!textVisible(p.panel, v.buttons.no_window.hint))
    named(p.panel, 'snapshotsToggle').clicked()
    verify(named(p.panel, 'snapshotLocationToggle').visible)
    verify(!textVisible(p.panel, v.result.snapshots))
    named(p.panel, 'snapshotLocationToggle').clicked()
    verify(textVisible(p.panel, v.snapshots.saved.path_line))
    verify(textVisible(p.panel, v.snapshots.saved.advice))
    verify(!textVisible(p.panel, v.result.snapshots))
    var copyButton = named(p.panel, 'copySnapshotPath')
    var pathRow = named(p.panel, 'snapshotPathRow'), pathText = named(p.panel, 'snapshotPathText')
    compare(copyButton.Accessible.name, v.snapshots.saved.copy_label)
    verify(copyButton.focusable)
    ;[420,260].forEach(function(width) {
      named(p.panel, 'panelPopup').contentWidth = width
      verify(waitForPolish(named(p.panel, 'panelScroll').Window.window))
      verify(Math.abs(copyButton.x - pathText.width - 6) <= 1)
      verify(copyButton.x + copyButton.width <= pathRow.width,
        'Snapshot copy icon overflows ' + width + 'px panel')
      verify(copyButton.y + copyButton.height <= pathRow.height)
    })
    copyButton.clicked()
    var copy = process(p.model, 'wl-copy')
    verify(copy.running)
    compare(copy.command.length, 1)
    copy.begin()
    compare(copy.input, v.snapshots.saved.path)
    verify(copy.wroteWithStdin)
    copy.complete('', 0)
    compare(named(p.panel, 'copySnapshotFeedback').text, 'Copied')
    copyButton.clicked(); copy.begin(); copy.complete('', 1)
    compare(named(p.panel, 'copySnapshotFeedback').text, v.logs.copy_error)
    v.snapshots.saved.path = '/home/john/snapshots/new'
    v.snapshots.saved.path_line = 'Snapshot saved at ' + v.snapshots.saved.path
    p.model.view = JSON.parse(JSON.stringify(v))
    compare(named(p.panel, 'copySnapshotFeedback').text, '')
    v.warning = 'The Windows window did not open in time.'
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(textVisible(p.panel, v.warning))
    v.layout = 'failed'; v.snapshots.saved = null; v.result.snapshots = 'Lanai could not take the snapshot.'
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(textVisible(p.panel, v.result.snapshots))
    p.panel.destroy()
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
  function test_redesign_typed_numbers_enable_save_and_commit_without_enter() {
    ;['Memory (GiB)', 'CPU cores'].forEach(function(label) {
      var p = settingsPanel(), save = named(p.panel, 'action-save_settings')
      var field = objects(p.panel, function(o) { return o.field !== undefined && o.label === label })[0].field
      field.contentItem.forceActiveFocus(); field.contentItem.selectAll()
      keyClick(Qt.Key_2); keyClick(Qt.Key_0)
      compare(field.contentItem.text, '20')
      compare(field.value, label === 'Memory (GiB)' ? 12 : 6)
      verify(save.enabled)
      compare(save.text, 'Save')
      verify(named(p.panel, 'resetSettings').visible)
      verify(named(p.panel, 'settingsToggle').text.indexOf('Unsaved') !== -1)
      // A poll must not overwrite the still uncommitted text or other drafts.
      p.model.view = settingsView(32, 16, 'auto')
      compare(field.contentItem.text, '20')
      save.clicked()
      var action = process(p.model, p.model.cli)
      compare(action.command.slice(3).join(' '), label === 'Memory (GiB)' ? 'settings 20 6' : 'settings 12 20')
      action.complete('{"ok":false}', 1)
      compare(field.value, 20)
      p.panel.destroy()
    })
  }
  function test_redesign_pending_number_reset_revert_and_reopen() {
    var p = settingsPanel(), save = named(p.panel, 'action-save_settings')
    var field = objects(p.panel, function(o) { return o.field !== undefined && o.label === 'Memory (GiB)' })[0].field
    field.contentItem.forceActiveFocus(); field.contentItem.selectAll()
    keyClick(Qt.Key_2); keyClick(Qt.Key_0)
    verify(save.enabled)
    named(p.panel, 'resetSettings').clicked()
    compare(field.contentItem.text, '12')
    verify(!save.enabled)
    field.contentItem.forceActiveFocus(); field.contentItem.selectAll()
    keyClick(Qt.Key_2); keyClick(Qt.Key_0)
    field.contentItem.selectAll(); keyClick(Qt.Key_1); keyClick(Qt.Key_2)
    verify(!save.enabled)
    field.contentItem.selectAll(); keyClick(Qt.Key_2); keyClick(Qt.Key_0)
    p.panel.close(); p.panel.open()
    compare(field.contentItem.text, '12')
    verify(!save.enabled)
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
    v.logs = {copied:'Copied',copy_error:'Could not copy. Try again.',copy_busy:'Another copy is in progress. Try again in a moment.',rows:[
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
    compare(restore.text, 'Restore')
    compare(restore.Accessible.name, p.model.view.snapshots.items[0].restore_label)
    compare(restore.Accessible.description, '')
    restore.clicked()
    compare(p.panel.restoreArmed, '20261012T091200Z')
    verify(objects(p.panel, function(o) { return o.text === 'Later changes are lost.' && o.visible }).length > 0)
    // Screen readers hear the armed warning with the button.
    compare(restore.Accessible.description, 'Later changes are lost.')
    var cancel = named(p.panel, 'restoreCancel-20261012T091200Z')
    // The armed row hides its Delete. Its own Cancel sits under it, and
    // gives focus back to Restore.
    verify(!named(p.panel, 'delete-20261012T091200Z').visible)
    verify(cancel.visible)
    verify(below(cancel, restore))
    cancel.forceActiveFocus(); cancel.clicked()
    compare(p.panel.restoreArmed, '')
    verify(!cancel.visible)
    verify(restore.activeFocus)
    restore.clicked()
    named(p.panel, 'logsToggle').clicked()
    compare(p.panel.restoreArmed, '20261012T091200Z')
    named(p.panel, 'snapshotsToggle').clicked()
    pastConfirmGuard(p.panel); restore.clicked()
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
  // Checks that <item> lies inside the panel's width and returns its left
  // and right edges in the scroll view.
  function horizontalEdges(item, flick, what) {
    var left = item.mapToItem(flick, 0, 0).x, right = item.mapToItem(flick, item.width, 0).x
    verify(left >= 0, what + ' starts left of the panel: ' + left)
    verify(right <= flick.width, what + ' overflows the ' + flick.width + 'px panel: ' + right)
    return {left:left, right:right}
  }
  function test_redesign_delete_snapshot_requires_named_confirmation_and_keeps_actions_in_bounds() {
    var p = redesignPanel(), v = redesignView(), item = v.snapshots.items[0]
    Quickshell.lastCommand = []
    named(p.panel, 'snapshotsToggle').clicked()
    var popup = named(p.panel, 'panelPopup'), flick = named(p.panel, 'panelScroll')
    var restore = named(p.panel, 'restore-' + item.name)
    var remove = named(p.panel, 'delete-' + item.name)
    var cancel = named(p.panel, 'deleteCancel-' + item.name)
    verify(remove !== undefined)
    compare(remove.text, v.buttons.delete_snapshot.label)
    compare(remove.Accessible.name, item.delete_label)
    compare(remove.Accessible.description, '')
    ;[420,360,260].forEach(function(width) {
      popup.contentWidth = width
      ;[false,true].forEach(function(armed) {
        p.panel.deleteArmed = armed ? item.name : ''
        verify(waitForPolish(flick.Window.window))
        var del = horizontalEdges(remove, flick, 'Delete at ' + width + 'px')
        if (armed) {
          verify(!restore.visible)
          verify(cancel.visible)
          horizontalEdges(cancel, flick, 'Cancel at ' + width + 'px')
        } else {
          verify(!cancel.visible)
          var res = horizontalEdges(restore, flick, 'Restore at ' + width + 'px')
          verify(res.left >= del.right + 6, 'Delete and Restore overlap at ' + width + 'px')
        }
      })
    })
    p.panel.deleteArmed = ''
    remove.clicked()
    compare(p.panel.deleteArmed, item.name)
    verify(!restore.visible)
    compare(remove.text, v.buttons.delete_confirm.label)
    compare(remove.Accessible.name, item.delete_confirm_label)
    compare(named(p.panel, 'deleteConfirm-' + item.name).text, item.delete_confirm_note)
    verify(named(p.panel, 'deleteConfirm-' + item.name).visible)
    // The visible words are inside the accessible name (label in name).
    remove.text.split(' ').forEach(function(word) { verify(remove.Accessible.name.indexOf(word) !== -1, word) })
    verify(textVisible(p.panel, item.delete_warning))
    compare(remove.Accessible.description, item.delete_warning)
    // The row's own Cancel sits under it, and gives focus back to Delete.
    verify(below(cancel, remove))
    cancel.forceActiveFocus(); cancel.clicked()
    verify(!named(p.panel, 'deleteConfirm-' + item.name).visible)
    compare(p.panel.deleteArmed, '')
    verify(!cancel.visible)
    verify(remove.activeFocus)
    compare(remove.Accessible.description, '')
    compare(Quickshell.lastCommand.length, 0)
    remove.clicked()
    pastConfirmGuard(p.panel); remove.clicked()
    compare(Quickshell.lastCommand.slice(3).join(' '), 'delete-snapshot ' + item.name)
    compare(p.panel.deleteArmed, '')
    // The button words come from the backend descriptors.
    v = redesignView(); v.buttons.delete_snapshot.label = 'Remove'; v.buttons.restore_snapshot.label = 'Bring back'
    p.model.view = v; wait(1)
    compare(named(p.panel, 'delete-' + item.name).text, 'Remove')
    compare(named(p.panel, 'restore-' + item.name).text, 'Bring back')
    // A poll that drops the armed snapshot clears the target.
    v = redesignView(); p.model.view = v; wait(1)
    named(p.panel, 'delete-' + item.name).clicked(); compare(p.panel.deleteArmed, item.name)
    v = redesignView(); v.snapshots.items = []; v.snapshots.names = []; v.snapshots.count = 0; p.model.view = v
    compare(p.panel.deleteArmed, '')
    // So does a poll that disables deletion.
    v = redesignView(); p.model.view = v; wait(1)
    named(p.panel, 'delete-' + item.name).clicked(); compare(p.panel.deleteArmed, item.name)
    v = redesignView(); v.buttons.delete_snapshot.enable = false; p.model.view = v
    compare(p.panel.deleteArmed, '')
    // A poll that keeps the target keeps it armed; closing the panel clears it.
    v = redesignView(); p.model.view = v; wait(1)
    named(p.panel, 'delete-' + item.name).clicked(); compare(p.panel.deleteArmed, item.name)
    p.model.view = redesignView(); compare(p.panel.deleteArmed, item.name)
    p.panel.close(); compare(p.panel.deleteArmed, '')
    p.panel.destroy()
  }
  // Holding Space repeats the key press on the one button that arms and
  // confirms. A click right after arming, or right after an ignored click,
  // does nothing; a click after a pause confirms.
  function test_redesign_confirm_ignores_clicks_right_after_arming() {
    var p = redesignPanel(), item = redesignView().snapshots.items[0], guard = p.panel.confirmGuardMs || 0
    named(p.panel, 'snapshotsToggle').clicked()
    ;[['delete-', 'deleteArmed', 'delete-snapshot'], ['restore-', 'restoreArmed', 'restore']].forEach(function(row) {
      p.model.pendingToken = ''; ready(p.model); p.model.view = redesignView(); wait(1)
      Quickshell.lastCommand = []
      var button = named(p.panel, row[0] + item.name)
      button.clicked(); compare(p.panel[row[1]], item.name)
      button.clicked()
      compare(Quickshell.lastCommand.length, 0, row[2] + ' confirmed right after arming')
      compare(p.panel[row[1]], item.name)
      wait(guard * 0.6); button.clicked()
      wait(guard * 0.6); button.clicked()
      compare(Quickshell.lastCommand.length, 0, row[2] + ' confirmed while clicks kept coming')
      compare(p.panel[row[1]], item.name)
      wait(guard + 50); button.clicked()
      compare(Quickshell.lastCommand.slice(3).join(' '), row[2] + ' ' + item.name)
      compare(p.panel[row[1]], '')
    })
    verify(guard >= 700, 'The guard must outlast common key repeat delays: ' + guard)
    p.panel.destroy()
  }
  function test_redesign_restore_and_delete_disarm_each_other_across_rows() {
    var p = redesignPanel(), v = twoSnapshotView(), first = v.snapshots.items[0].name, second = v.snapshots.items[1].name
    p.model.view = v; wait(1)
    named(p.panel, 'snapshotsToggle').clicked()
    named(p.panel, 'delete-' + first).clicked()
    compare(p.panel.deleteArmed, first)
    named(p.panel, 'restore-' + second).clicked()
    compare(p.panel.restoreArmed, second); compare(p.panel.deleteArmed, '')
    verify(named(p.panel, 'restoreCancel-' + second).visible)
    verify(!named(p.panel, 'deleteCancel-' + first).visible)
    named(p.panel, 'delete-' + first).clicked()
    compare(p.panel.deleteArmed, first); compare(p.panel.restoreArmed, '')
    verify(named(p.panel, 'deleteCancel-' + first).visible)
    verify(!named(p.panel, 'restoreCancel-' + second).visible)
    // Cancel sits under its own row, above the next one.
    verify(below(named(p.panel, 'restore-' + second), named(p.panel, 'deleteCancel-' + first)))
    p.panel.destroy()
  }
  function test_redesign_snapshot_results_show_inside_snapshots() {
    var p = redesignPanel(), v = redesignView()
    v.result.snapshots = 'The snapshot was restored.'
    p.model.view = v
    verify(!textVisible(p.panel, v.result.snapshots))
    named(p.panel, 'snapshotsToggle').clicked()
    var note = objects(named(p.panel, 'snapshotsDetails'), function(o) { return o.text === v.result.snapshots && o.visible })
    compare(note.length, 1)
    p.panel.destroy()
  }
  // Returns each line <note> lays out, from a TextEdit with the same text,
  // font, width and wrapping (Text cannot map characters to lines).
  function laidOutLines(note) {
    var mirror = Qt.createQmlObject('import QtQuick; TextEdit { textFormat: TextEdit.PlainText; readOnly: true }', note.parent)
    mirror.font = note.font; mirror.wrapMode = note.wrapMode; mirror.width = note.width; mirror.text = note.text
    compare(mirror.lineCount, note.lineCount, 'The mirror lays out the note differently')
    var lines = [], y = null
    for (var i = 0; i < mirror.length; i++) {
      var top = mirror.positionToRectangle(i).y
      if (y === null || top > y) { lines.push(''); y = top }
      lines[lines.length - 1] += mirror.getText(i, i + 1)
    }
    mirror.destroy()
    return lines
  }
  function test_redesign_snapshot_actions_fit_narrow_panel() {
    var p = redesignPanel()
    named(p.panel, 'snapshotsToggle').clicked()
    var popup = named(p.panel, 'panelPopup'), flick = named(p.panel, 'panelScroll')
    var restore = named(p.panel, 'restore-20261012T091200Z')
    ;[420,360,260].forEach(function(width) {
      popup.contentWidth = width
      verify(waitForPolish(flick.Window.window))
      ;[false,true].forEach(function(armed) {
        p.panel.restoreArmed = armed ? '20261012T091200Z' : ''
        var item = p.model.view.snapshots.items[0]
        // The armed caption stays short; the full wording is its name and a note.
        compare(restore.text, armed ? 'Restore now' : 'Restore')
        compare(restore.Accessible.name, armed ? item.confirm_label : item.restore_label)
        verify(waitForPolish(flick.Window.window))
        verify(restore.implicitWidth <= restore.width + 0.5, 'Restore caption does not fit its button at ' + width + 'px')
        var note = named(p.panel, 'restoreConfirm-' + item.name)
        compare(note.visible, armed)
        if (armed) {
          compare(note.text, item.confirm_note)
          verify(note.mapToItem(flick, 0, 0).x + note.width <= flick.width && note.contentWidth <= note.width + 0.5)
        }
        restore.forceActiveFocus()
        verify(waitForPolish(flick.Window.window))
        verify(restore.activeFocus)
        var point = restore.mapToItem(flick, 0, 0)
        verify(point.x >= 0)
        verify(point.x + restore.width <= flick.width, 'Snapshot action overflows ' + width + 'px panel: ' + restore.width)
        verify(point.y >= 0 && point.y + restore.height <= flick.height)
        if (!armed) {
          var date = objects(p.panel, function(o) {
            return typeof o.text === 'string' && o.text.replace(/\u00a0/g, ' ') === 'Oct 12, 2026 · 09:12 UTC' && o.visible })[0]
          // The date may wrap, but never leaves the separator at a line end.
          var lines = laidOutLines(date)
          if (width === 260) verify(lines.length > 1, 'The snapshot date fits one line at 260px, so the wrap goes untested')
          lines.forEach(function(line) {
            verify(!/·\s*$/.test(line), 'A snapshot date line ends with its separator at ' + width + 'px: ' + JSON.stringify(lines))
          })
          var datePoint = date.mapToItem(flick, 0, 0)
          verify(Math.abs(datePoint.y + date.height / 2 - (point.y + restore.height / 2)) <= 1,
            'Snapshot date and Restore label are not centered on the same line at ' + width + 'px')
          var row = restore.parent.parent
          verify(Math.abs(restore.mapToItem(row, restore.width, 0).x - row.width) <= 1,
            'Restore button is not at the right edge of the snapshot row at ' + width + 'px')
        }
      })
    })
    // Delete and its Cancel are in the Tab chain: Tab moves from Delete to
    // Restore, and from the armed Delete to its Cancel.
    p.panel.restoreArmed = ''
    var remove = named(p.panel, 'delete-20261012T091200Z'), cancel = named(p.panel, 'deleteCancel-20261012T091200Z')
    verify(remove.focusable && remove.activeFocusOnTab)
    remove.forceActiveFocus(); verify(remove.activeFocus)
    keyClick(Qt.Key_Tab); verify(restore.activeFocus, 'Tab from Delete does not reach Restore')
    p.panel.deleteArmed = '20261012T091200Z'
    verify(cancel.visible && cancel.focusable && cancel.activeFocusOnTab)
    remove.forceActiveFocus(); verify(remove.activeFocus)
    keyClick(Qt.Key_Tab); verify(cancel.activeFocus, 'Tab from the armed Delete does not reach Cancel')
    keyClick(Qt.Key_Space); compare(p.panel.deleteArmed, '')
    verify(remove.activeFocus)
    // With the installed Button, Space arms Delete, and a second Space
    // right after it (a held key repeats) does not confirm.
    Quickshell.lastCommand = []
    keyClick(Qt.Key_Space); compare(p.panel.deleteArmed, '20261012T091200Z')
    keyClick(Qt.Key_Space); compare(p.panel.deleteArmed, '20261012T091200Z')
    compare(Quickshell.lastCommand.length, 0)
    p.panel.destroy()
  }
  function test_redesign_snapshot_management_actions_share_a_row() {
    var p = redesignPanel(), v = redesignView()
    v.snapshots.saved = {path:'/copy',show_label:'Show details',hide_label:'Hide details'}
    v.buttons.take_snapshot = {show:true,enable:false,label:'Take a snapshot'}
    p.model.view = v
    named(p.panel, 'snapshotsToggle').clicked()
    var popup = named(p.panel, 'panelPopup'), flick = named(p.panel, 'panelScroll')
    var row = named(p.panel, 'snapshotActions'), details = named(p.panel, 'snapshotLocationToggle')
    var take = objects(p.panel, function(o) { return o.control === 'take_snapshot' })[0]
    verify(row !== undefined)
    verify(details.bordered)
    verify(take.visible && !take.enabled)
    ;[420,360,260].forEach(function(width) {
      popup.contentWidth = width
      verify(waitForPolish(flick.Window.window))
      var rowPoint = row.mapToItem(flick, 0, 0)
      var detailsPoint = details.mapToItem(flick, 0, 0)
      var takePoint = take.mapToItem(flick, 0, 0)
      verify(Math.abs(detailsPoint.x - rowPoint.x) <= 1)
      verify(Math.abs(take.mapToItem(row, take.width, 0).x - row.width) <= 1)
      verify(detailsPoint.x + details.width <= rowPoint.x + row.width)
      verify(takePoint.x >= rowPoint.x)
      if (width >= 360)
        verify(Math.abs(detailsPoint.y + details.height / 2 - (takePoint.y + take.height / 2)) <= 1,
          'Snapshot management actions should share a line at ' + width + 'px')
      if (Math.abs(detailsPoint.y + details.height / 2 - (takePoint.y + take.height / 2)) <= 1)
        verify(detailsPoint.x + details.width + 4 <= takePoint.x)
      else
        verify(takePoint.y >= detailsPoint.y + details.height)
    })
    // Too narrow for one line: Take a snapshot wraps under Show details,
    // at the right edge, and the row holds both.
    popup.contentWidth = 200
    verify(waitForPolish(flick.Window.window))
    verify(row.wrap)
    verify(below(take, details))
    verify(Math.abs(take.mapToItem(row, take.width, 0).x - row.width) <= 1)
    verify(take.mapToItem(row, 0, take.height).y <= row.height)
    popup.contentWidth = 420
    v.snapshots.saved = null
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(!details.visible)
    verify(take.visible)
    verify(Math.abs(take.mapToItem(row, take.width, 0).x - row.width) <= 1)
    p.panel.destroy()
  }
  function test_redesign_snapshot_details_collapse_on_reopen_and_when_saved_goes() {
    var p = redesignPanel(), v = redesignView()
    v.snapshots.saved = {path:'/copy',path_line:'Snapshot saved at /copy',advice:'Advice.',copy_label:'Copy snapshot path',
      show_label:'Show details',hide_label:'Hide details'}
    p.model.view = JSON.parse(JSON.stringify(v))
    named(p.panel, 'snapshotsToggle').clicked()
    var details = named(p.panel, 'snapshotLocationToggle'), pathRow = named(p.panel, 'snapshotPathRow')
    details.clicked(); verify(pathRow.visible)
    p.panel.close(); p.panel.open()
    named(p.panel, 'snapshotsToggle').clicked()
    verify(details.visible); verify(!pathRow.visible)
    compare(details.text, 'Show details')
    details.clicked(); verify(pathRow.visible)
    var gone = JSON.parse(JSON.stringify(v)); gone.snapshots.saved = null
    p.model.view = gone
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(details.visible); verify(!pathRow.visible)
    p.panel.destroy()
  }
  // A finished setup with Run setup again enabled needs no hint; disabled,
  // or before setup finishes, the hint shows under the buttons.
  function test_redesign_continue_setup_hint_only_while_it_helps() {
    var p = redesignPanel(), v = redesignView()
    v.buttons.continue_setup = {show:true,enable:true,label:'Run setup again',hint:'Backend continue hint.'}
    p.model.view = JSON.parse(JSON.stringify(v))
    named(p.panel, 'moreActionsToggle').clicked()
    verify(objects(p.panel, function(o) { return o.control === 'continue_setup' && o.visible }).length > 0)
    verify(!textVisible(p.panel, 'Backend continue hint.'))
    v.buttons.continue_setup.enable = false
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(textVisible(p.panel, 'Backend continue hint.'))
    v.buttons.continue_setup.enable = true; v.setup = {show:true,finished:false}
    p.model.view = JSON.parse(JSON.stringify(v))
    verify(textVisible(p.panel, 'Backend continue hint.'))
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
    var meter = named(p.panel, 'imageProgress')
    var position = meter.busyPosition
    wait(80)
    verify(meter.busyPosition !== position)
    Style.reduceMotion = true
    position = meter.busyPosition
    wait(80)
    compare(meter.busyPosition, position)
    Style.reduceMotion = false
    wait(80)
    verify(meter.busyPosition !== position)
    v.progress.total = 100; v.progress.percent = 0; p.model.view = JSON.parse(JSON.stringify(v))
    compare(named(p.panel, 'imageProgress').indeterminate,false)
    var fill = objects(named(p.panel, 'imageProgress').contentItem, function(o) { return o.color !== undefined })[0]
    compare(fill.x,0)
    compare(named(p.panel, 'imageProgressText').text,'Reading image, 0%')
    p.panel.destroy()
  }
  function test_redesign_restore_recovery_opens_primary_when_work_stops() {
    var p = redesignPanel(), v = redesignView()
    v.layout = 'restoring'
    v.buttons.finish_restore = {show:true,enable:false,label:'Finish the unfinished restore'}
    p.model.view = v
    named(p.panel, 'settingsToggle').clicked()
    compare(p.panel.expandedSection, 'settings')
    v.buttons.finish_restore.enable = true
    v.primary_action = 'finish_restore'
    v.sections.default = 'snapshots'
    p.model.view = JSON.parse(JSON.stringify(v))
    compare(p.panel.expandedSection, 'snapshots')
    verify(named(p.panel, 'snapshotsDetails').visible)
    verify(objects(p.panel, function(o) { return o.control === 'finish_restore' && o.visible && o.enabled })[0] !== undefined)
    // Polls preserve the user's subsequent section choice.
    named(p.panel, 'settingsToggle').clicked()
    p.model.view = JSON.parse(JSON.stringify(v))
    compare(p.panel.expandedSection, 'settings')
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
  function test_widget_tooltip_is_the_view_tooltip_with_default_and_error_views() {
    var p = widgetParts()
    // The view before the first poll's reply.
    var first = createTemporaryObject(modelComponent, tests)
    compare(first.tooltip, 'Lanai: Checking\nRight-click: Open the panel.')
    // lanai panel builds the words; the bar shows them as they are.
    var words = 'Lanai: Stopped\nOpen the panel for details.\nRight-click: Start Windows.'
    p.model.view = {label:'Stopped',headline:'Windows is stopped',notice:'Backend notice',warning:'Backend warning',right_click:'start',
      right_click_tooltip:'Right-click: Start Windows.',tooltip:words,buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
    compare(p.button.tooltipText, words)
    compare(p.button.Accessible.name, words)
    p.model.refresh(); var poll = process(p.model, 'timeout')
    poll.complete('invalid', 1)
    compare(p.button.tooltipText, 'Lanai: Unavailable\nRight-click: Open the panel for details.')
    compare(p.button.Accessible.name, p.button.tooltipText)
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
    // The poll says this model launches Lanai's own client update; an
    // older model's poll has no flag, and the backend offers the button.
    compare(poll.command.slice(3, 5).join(' '), 'env LANAI_AUTO_LAUNCHER=1')
    compare(poll.command.slice(5).join(' '), model.cli + ' panel')
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
  // A view with the backend's ask for Lanai's own client update.
  function autoView(launch, key) {
    return {ok:true,buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{},auto_update:{launch:launch,key:key}}
  }
  function compareAutoLaunch(model) {
    compare(Quickshell.lastCommand.length, 5)
    compare(Quickshell.lastCommand[0], model.cli)
    compare(Quickshell.lastCommand[1], 'ui-job')
    verify(/^auto-[0-9]+-[0-9]+$/.test(Quickshell.lastCommand[2]), Quickshell.lastCommand[2])
    compare(Quickshell.lastCommand.slice(3).join(' '), 'build-client --auto')
  }
  function test_auto_update_launches_once_per_key() {
    var model, count, poll
    for (var open = 0; open < 2; open++) {
      model = createTemporaryObject(modelComponent, tests)
      wait(1); ready(model)
      model.panelOpen = open === 1
      ready(model)
      count = Quickshell.launchCount
      model.view = autoView(true, 'a:0')
      compare(Quickshell.launchCount, count + 1)
      compareAutoLaunch(model)
      model.view = autoView(true, 'a:0')
      compare(Quickshell.launchCount, count + 1)
      // Its unit was seen, then ended before it counted a try.
      model.view = autoView(false, 'a:0')
      model.view = autoView(true, 'a:0')
      compare(Quickshell.launchCount, count + 2)
      // A unit that ended before any poll saw it: 30 s re-arms the key.
      model.autoAt = Date.now() - 29000
      model.view = autoView(true, 'a:0')
      compare(Quickshell.launchCount, count + 2)
      model.autoAt = Date.now() - 30000
      model.view = autoView(true, 'a:0')
      compare(Quickshell.launchCount, count + 3)
      // A counted try changes the key.
      model.view = autoView(true, 'a:1')
      compare(Quickshell.launchCount, count + 4)
      // An unreadable poll forgets nothing.
      model.refresh()
      poll = process(model, 'timeout')
      verify(poll.running)
      poll.complete('not a view', 0)
      compare(model.view.layout, 'failed')
      model.view = autoView(true, 'a:1')
      compare(Quickshell.launchCount, count + 4)
    }
    // A second bar item, or a shell restart, launches on its own once.
    var second = createTemporaryObject(modelComponent, tests)
    wait(1); ready(second)
    count = Quickshell.launchCount
    second.view = autoView(true, 'a:0')
    compare(Quickshell.launchCount, count + 1)
    compareAutoLaunch(second)
    second.view = autoView(true, 'a:0')
    compare(Quickshell.launchCount, count + 1)
  }
  function test_auto_update_has_no_pending_notice_or_blocked_click() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var count = Quickshell.launchCount
    model.view = autoView(true, 'b:0')
    compare(Quickshell.launchCount, count + 1)
    compareAutoLaunch(model)
    compare(model.pendingToken, '')
    compare(model.clickNotice, '')
    // The next poll names no pending click, so the view never says the
    // operation did not start.
    model.refresh()
    var poll = process(model, 'timeout')
    verify(poll.running)
    compare(poll.command.indexOf('--pending'), -1)
    poll.complete(JSON.stringify(autoView(true, 'b:0')), 0)
    // The user's clicks go at once.
    var token = model.run(['snapshot', 'x'], true)
    verify(token !== '')
    compare(Quickshell.lastCommand[1], 'ui-job')
    compare(Quickshell.lastCommand.slice(3).join(' '), 'snapshot x')
    compare(model.clickNotice, '')
    model.run(['start'], false)
    var action = objects(model, function(o) { return o.command && o.command[1] === 'ui-run' })[0]
    verify(action.running)
    compare(action.command.slice(3).join(' '), 'start')
    compare(model.clickNotice, '')
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
      compare(client.tooltipText, model.control('no_window').hint)
      compare(screen.tooltipText, model.control('window').hint)
      verify(!textVisible(panel, model.control('no_window').hint))
      verify(!textVisible(panel, model.control('window').hint))
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
    var warning = 'After the computer wakes from sleep, the mouse may reach only part of Windows. Windows may also start at, or change to, the wrong size. To fix both, click Update the Windows window in More actions. Updating changes nothing in Windows.'
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
  // Snapshot name prompts: the setup layout at step 3 shows both actions.
  // Views carry busy, as the real backend always sends it.
  function nameView(setup) {
    var v = setup ? setupView('3') : redesignView()
    if (setup) {
      v.buttons.continue_setup.show = false
      v.buttons.setup_snapshot = {show:true,enable:true,label:'Take a snapshot',save_label:'Save snapshot'}
      v.buttons.skip_snapshot = {show:true,enable:true,label:'Continue without a snapshot'}
    }
    v.buttons.take_snapshot = {show:true,enable:true,label:'Take a snapshot',save_label:'Save snapshot'}
    v.busy = {active:false,line:''}
    v.snapshots.job = null
    return v
  }
  function namePanel(setup) {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var v = nameView(setup)
    model.view = v
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    wait(1)
    named(panel, 'snapshotsToggle').clicked(); wait(1)
    return {model:model,panel:panel,view:v}
  }
  function nameParts(p, setup) {
    var prefix = setup ? 'setupSnapshotName' : 'snapshotName'
    return {field:named(p.panel, prefix + 'Field'), caption:named(p.panel, prefix + 'Caption'),
      error:named(p.panel, prefix + 'Error'), cancel:named(p.panel, prefix + 'Cancel'),
      take:objects(p.panel, function(o) { return o.control === (setup ? 'setup_snapshot' : 'take_snapshot') })[0]}
  }
  function copy(v) { return JSON.parse(JSON.stringify(v)) }
  // Clear the launch guard and show <view> again, as a later poll would.
  function nameSettle(p, v) {
    p.model.pendingToken = ''
    p.model.view = copy(v || p.view); wait(1)
  }
  function launched() { return JSON.stringify(Quickshell.lastCommand.slice(3)) }
  function typeInto(field, text) {
    field.forceActiveFocus()
    for (var i = 0; i < text.length; i++) keyClick(text[i])
  }
  function jobView(v, token, ok, message) {
    var w = copy(v)
    w.snapshots.job = {token:token,ended:ok !== null,ok:ok,message:message || ''}
    return w
  }
  // <v> while a job runs: the snapshot actions are disabled and the backend is busy.
  function runningView(v) {
    var w = copy(v)
    ;['take_snapshot','setup_snapshot','skip_snapshot'].forEach(function(key) { if (w.buttons[key]) w.buttons[key].enable = false })
    w.busy = {active:true,line:'Taking a snapshot.'}
    return w
  }
  // <v> in the Failed layout, which opens Logs by itself. Nothing is busy.
  function failedView(v) {
    var w = copy(v)
    w.layout = 'failed'; w.sections.default = 'logs'; w.busy = {active:false,line:''}
    return w
  }
  // An unreadable poll: the model shows its own Failed view, which has no busy key.
  function failPoll(p) {
    p.model.refresh()
    var poll = process(p.model, 'timeout')
    while (poll.running) poll.complete('unreadable', 1)
    compare(p.model.view.layout, 'failed')
    compare(p.model.view.busy, undefined)
  }
  // The panel's own focus scope, which takes focus when no control can.
  function panelFocus(p) { return named(p.panel, 'panelFocus') }
  function test_snapshot_prompt_opens_on_click_and_cancel_closes_it() {
    var p = namePanel(true), scope = panelFocus(p)
    ;[false,true].forEach(function(setup) {
      var n = nameParts(p, setup), count = Quickshell.launchCount, which = setup ? 'setup' : 'daily'
      verify(n.field !== undefined && n.cancel !== undefined, which)
      verify(!n.field.visible && !n.caption.visible && !n.cancel.visible, which)
      compare(n.take.text, 'Take a snapshot')
      // The first click starts nothing: it opens the field with focus in it.
      n.take.clicked(); wait(1)
      compare(Quickshell.launchCount, count)
      verify(n.field.visible && n.caption.visible, which)
      verify(n.field.activeFocus, which)
      compare(n.take.text, 'Save snapshot')
      // The open caption is the backend's word.
      var renamed = copy(p.view); renamed.buttons[setup ? 'setup_snapshot' : 'take_snapshot'].save_label = 'Save it'
      p.model.view = renamed; wait(1); compare(n.take.text, 'Save it')
      p.model.view = copy(p.view); wait(1); compare(n.take.text, 'Save snapshot')
      verify(n.cancel.visible && n.cancel.enabled); compare(n.cancel.text, 'Cancel')
      typeInto(n.field, 'Draft')
      // Cancel by mouse: focus in the field moves to Take a snapshot.
      n.cancel.clicked(); wait(1)
      verify(!n.field.visible && !n.cancel.visible, which)
      compare(n.take.text, 'Take a snapshot')
      verify(n.take.activeFocus, which)
      // Cancel by keyboard.
      n.take.clicked(); wait(1)
      compare(n.field.text, 'Draft'); verify(n.field.activeFocus)
      n.cancel.forceActiveFocus(); verify(n.cancel.activeFocus)
      keyClick(Qt.Key_Return); wait(1)
      verify(!n.field.visible && !n.cancel.visible, which)
      verify(n.take.activeFocus, which)
      // Closing the panel closes the prompt.
      n.take.clicked(); wait(1)
      p.panel.close(); wait(1)
      compare(p.panel.namePrompt, '')
      p.panel.open(); named(p.panel, 'snapshotsToggle').clicked(); wait(1)
      verify(!n.field.visible, which)
      // Escape in the open prompt closes only the prompt, from the field,
      // Save snapshot or Cancel, and focus moves as for any close. A second
      // Escape closes the panel.
      ;[n.field, n.take, n.cancel].forEach(function(item) {
        n.take.clicked(); wait(1); item.forceActiveFocus(); verify(item.activeFocus, which)
        keyClick(Qt.Key_Escape); wait(1)
        verify(p.panel.opened, which + ' ' + item.objectName); compare(p.panel.namePrompt, '')
        verify(!n.field.visible && !n.cancel.visible, which)
        verify(n.take.activeFocus, which + ' ' + item.objectName)
        compare(n.field.text, 'Draft')
      })
      keyClick(Qt.Key_Escape); wait(1)
      verify(!p.panel.opened, which)
      p.panel.open(); named(p.panel, 'snapshotsToggle').clicked(); wait(1)
      verify(!n.field.visible, which)
      n.take.clicked(); wait(1)
      compare(n.field.text, 'Draft')
      n.cancel.clicked(); wait(1)
      compare(Quickshell.launchCount, count)
    })
    // Collapsing Snapshots closes the daily prompt, not the setup one, and
    // focus moves to the panel because Take a snapshot is out of sight.
    var daily = nameParts(p, false), setup = nameParts(p, true)
    daily.take.clicked(); wait(1); verify(daily.field.activeFocus)
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    compare(p.panel.namePrompt, '')
    compare(scope.Window.activeFocusItem, scope)
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    verify(!daily.field.visible); compare(daily.take.text, 'Take a snapshot')
    daily.take.clicked(); wait(1); compare(daily.field.text, 'Draft')
    setup.take.clicked(); wait(1)
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    compare(p.panel.namePrompt, 'setup_snapshot'); verify(setup.field.visible)
    p.panel.destroy()
  }
  function test_snapshot_prompt_submits_exact_text_from_save_and_enter() {
    var p = namePanel(true)
    ;[false,true].forEach(function(setup) {
      var n = nameParts(p, setup)
      n.take.clicked(); wait(1)
      // Save snapshot from the keyboard: focus goes back to the field,
      // where a refusal will show.
      n.take.forceActiveFocus(); keyClick(Qt.Key_Return)
      compare(launched(), JSON.stringify(['snapshot','']))
      compare(Quickshell.lastCommand[2], p.model.pendingToken)
      verify(n.field.activeFocus)
      nameSettle(p)
      verify(n.field.visible)
      typeInto(n.field, '   ')
      n.take.clicked()
      compare(launched(), JSON.stringify(['snapshot','   ']))
      nameSettle(p)
      n.field.selectAll(); typeInto(n.field, 'Before update')
      keyClick(Qt.Key_Return)
      compare(launched(), JSON.stringify(['snapshot','Before update']))
      nameSettle(p)
      var count = Quickshell.launchCount
      n.field.forceActiveFocus(); keyClick(Qt.Key_Enter)
      compare(Quickshell.launchCount, count + 1)
      compare(launched(), JSON.stringify(['snapshot','Before update']))
      nameSettle(p)
      // The prompt closes while its action is disabled or hidden, and
      // neither Enter nor the action starts or opens anything then.
      var v = copy(p.view), action = v.buttons[setup ? 'setup_snapshot' : 'take_snapshot']
      count = Quickshell.launchCount
      action.enable = false
      p.model.view = copy(v); wait(1)
      verify(!n.field.visible && !n.caption.visible)
      n.field.accepted(); n.take.clicked()
      compare(Quickshell.launchCount, count); compare(p.panel.namePrompt, '')
      action.enable = true; action.show = false
      p.model.view = copy(v); wait(1)
      verify(!n.field.visible)
      n.field.accepted(); n.take.clicked()
      compare(Quickshell.launchCount, count); compare(p.panel.namePrompt, '')
      p.model.view = copy(p.view); wait(1)
      verify(!n.field.visible)
      n.take.clicked(); wait(1)
      verify(n.field.visible)
      compare(n.field.text, 'Before update')
      n.cancel.clicked()
    })
    p.panel.destroy()
  }
  // qmltestrunner cannot send a key repeat. heldReturn() hands the name
  // field's key handler a fake repeat, as the field's Keys handler would,
  // and lets the field take the key when the handler leaves it, as Qt does.
  function heldReturn(p, n) {
    var event = {key:Qt.Key_Return,isAutoRepeat:true,accepted:true}
    p.panel.nameFieldKey(event)
    if (!event.accepted) n.field.accepted()
  }
  function test_snapshot_name_field_takes_only_key_repeats() {
    var p = namePanel(false)
    ;[Qt.Key_Return, Qt.Key_Enter].forEach(function(key) {
      var held = {key:key,isAutoRepeat:true,accepted:false}, fresh = {key:key,isAutoRepeat:false,accepted:true}
      p.panel.nameFieldKey(held); verify(held.accepted, 'repeat of ' + key)
      p.panel.nameFieldKey(fresh); verify(!fresh.accepted, 'press of ' + key)
    })
    // The field's Return and Enter reach that decision. A test cannot send a
    // real repeat, so check the wiring with fresh presses.
    var n = nameParts(p, false), seen = []
    p.panel.nameFieldKeyHandled.connect(function(key) { seen.push(key) })
    n.take.clicked(); wait(1)
    n.field.forceActiveFocus(); keyClick(Qt.Key_Return); keyClick(Qt.Key_Enter)
    compare(JSON.stringify(seen), JSON.stringify([Qt.Key_Return, Qt.Key_Enter]))
    p.panel.destroy()
  }
  // A held key repeats its press. The press on Take a snapshot that opens
  // the prompt, or on Save snapshot that launches, moves focus into the
  // field, which gets the repeats. They start nothing and show no busy notice.
  function test_snapshot_prompt_ignores_a_held_key() {
    var p = namePanel(true)
    ;[false,true].forEach(function(setup) {
      var n = nameParts(p, setup), which = setup ? 'setup' : 'daily', count = Quickshell.launchCount
      p.model.clickNotice = ''
      n.take.forceActiveFocus(); keyClick(Qt.Key_Return); wait(1)
      compare(p.panel.namePrompt, setup ? 'setup_snapshot' : 'take_snapshot')
      verify(n.field.activeFocus, which)
      heldReturn(p, n); heldReturn(p, n)
      compare(Quickshell.launchCount, count, which + ' repeat after opening')
      n.take.forceActiveFocus(); keyClick(Qt.Key_Return)
      compare(Quickshell.launchCount, count + 1, which)
      verify(n.field.activeFocus, which)
      heldReturn(p, n); heldReturn(p, n)
      compare(Quickshell.launchCount, count + 1, which + ' repeat after launch')
      compare(p.model.clickNotice, '', which)
      nameSettle(p); n.cancel.clicked(); wait(1)
    })
    p.panel.destroy()
  }
  // Every deliberate press or click submits, however soon it follows the
  // one before.
  function test_snapshot_prompt_submits_quick_deliberate_presses() {
    var p = namePanel(true)
    ;[false,true].forEach(function(setup) {
      var n = nameParts(p, setup), which = setup ? 'setup' : 'daily', count = Quickshell.launchCount
      // Enter on Take a snapshot, then Enter in the field at once.
      n.take.forceActiveFocus(); keyClick(Qt.Key_Return); verify(n.field.activeFocus, which)
      keyClick(Qt.Key_Return)
      compare(Quickshell.launchCount, count + 1, which + ' double Enter')
      compare(launched(), JSON.stringify(['snapshot','']))
      nameSettle(p); n.cancel.clicked(); wait(1)
      // A name typed, then Enter at once.
      n.take.clicked(); wait(1); typeInto(n.field, 'v1'); keyClick(Qt.Key_Return)
      compare(Quickshell.launchCount, count + 2, which + ' typed name')
      compare(launched(), JSON.stringify(['snapshot','v1']))
      nameSettle(p); n.cancel.clicked(); wait(1)
      // A mouse click on Save snapshot right after the one that opened it.
      verify(waitForPolish(n.take.Window.window))
      mouseClick(n.take); compare(p.panel.namePrompt, setup ? 'setup_snapshot' : 'take_snapshot')
      mouseClick(n.take)
      compare(Quickshell.launchCount, count + 3, which + ' second click')
      compare(launched(), JSON.stringify(['snapshot','v1']))
      nameSettle(p); n.cancel.clicked(); wait(1)
    })
    p.panel.destroy()
  }
  function test_snapshot_prompt_runs_once_and_hides_cancel_while_its_snapshot_runs() {
    var p = namePanel(true)
    ;[false,true].forEach(function(setup) {
      var n = nameParts(p, setup), which = setup ? 'setup' : 'daily'
      n.take.clicked(); wait(1)
      typeInto(n.field, 'Mine')
      n.take.clicked()
      var token = Quickshell.lastCommand[2], count = Quickshell.launchCount
      compare(launched(), JSON.stringify(['snapshot','Mine']))
      verify(!n.cancel.visible, which)
      // A poll before the job record appears still shows the older record,
      // whose refusal is not this draft's.
      p.model.pendingToken = ''
      ;[jobView(runningView(p.view), 'panel-older', true), jobView(runningView(p.view), 'panel-older', false, 'Use one line.'),
        jobView(runningView(p.view), token, null)].forEach(function(v) {
        p.model.view = copy(v); wait(1)
        verify(n.field.visible && !n.field.readOnly, which)
        compare(n.take.text, 'Save snapshot'); verify(!n.take.enabled)
        verify(!n.cancel.visible && !n.error.visible, which)
        n.take.clicked(); n.field.forceActiveFocus(); keyClick(Qt.Key_Return)
        compare(Quickshell.launchCount, count)
      })
      // The field stays editable; a newer draft outlasts the success.
      typeInto(n.field, '!')
      compare(n.field.text, 'Mine!')
      p.model.view = jobView(p.view, token, true); wait(1)
      compare(p.panel.namePrompt, '')
      verify(!n.field.visible); compare(n.field.text, 'Mine!')
      verify(n.take.activeFocus, which)
      // Escape closes the prompt while its snapshot runs, and a second one
      // the panel; the snapshot still clears the unchanged draft when it succeeds.
      n.take.clicked(); wait(1); n.take.clicked()
      token = Quickshell.lastCommand[2]
      nameSettle(p, jobView(runningView(p.view), token, null))
      n.field.forceActiveFocus(); keyClick(Qt.Key_Escape); wait(1)
      verify(p.panel.opened); compare(p.panel.namePrompt, '')
      keyClick(Qt.Key_Escape); wait(1)
      verify(!p.panel.opened)
      p.panel.open(); named(p.panel, 'snapshotsToggle').clicked(); wait(1)
      p.model.view = jobView(p.view, token, true); wait(1)
      compare(n.field.text, '')
      // Its own job ended, but something else keeps busy, as a CLI restore
      // holding the lock: Cancel shows again; the action stays disabled.
      n.take.clicked(); wait(1); typeInto(n.field, 'Busy'); n.take.clicked()
      token = Quickshell.lastCommand[2]
      nameSettle(p, jobView(runningView(p.view), token, null)); verify(!n.cancel.visible, which)
      p.model.view = jobView(runningView(p.view), token, false); wait(1)
      compare(p.panel.namePrompt, setup ? 'setup_snapshot' : 'take_snapshot')
      verify(n.field.visible && n.cancel.visible && !n.take.enabled, which)
      n.cancel.clicked(); wait(1)
      compare(p.panel.namePrompt, ''); compare(n.field.text, 'Busy')
      nameSettle(p)
    })
    p.panel.destroy()
  }
  function test_snapshot_prompt_stays_open_after_failures_and_closes_after_success() {
    var p = namePanel(false), n = nameParts(p, false)
    function reexpand() {
      compare(p.panel.expandedSection, 'logs')
      compare(p.panel.namePrompt, 'take_snapshot')
      named(p.panel, 'snapshotsToggle').clicked(); wait(1)
      verify(n.field.visible && n.cancel.visible)
      compare(n.take.text, 'Save snapshot')
    }
    n.take.clicked(); wait(1); typeInto(n.field, 'a<b'); n.take.clicked()
    var token = Quickshell.lastCommand[2]
    // The worker records the end before it releases its lock, so a poll can
    // see the refusal while still busy. The prompt stays open with it, and
    // Cancel shows because its own job has ended.
    nameSettle(p, jobView(runningView(p.view), token, false, 'Remove < and >.'))
    compare(p.panel.namePrompt, 'take_snapshot')
    verify(n.field.visible && n.error.visible && n.cancel.visible)
    // A name refusal shows beside the open field, and Cancel comes back.
    nameSettle(p, jobView(p.view, token, false, 'Remove < and >.'))
    verify(n.field.visible && n.error.visible && n.cancel.visible)
    compare(n.error.text, 'Remove < and >.'); compare(n.field.text, 'a<b')
    // A failed job without a message.
    n.field.selectAll(); typeInto(n.field, 'Fine'); n.take.clicked()
    token = Quickshell.lastCommand[2]
    verify(!n.error.visible)
    nameSettle(p, jobView(runningView(p.view), token, null))
    p.model.view = jobView(p.view, token, false); wait(1)
    verify(n.field.visible && n.cancel.visible); compare(n.field.text, 'Fine')
    // A failed job that brings the Failed layout opens Logs; the prompt stays open.
    n.take.clicked(); token = Quickshell.lastCommand[2]
    nameSettle(p, jobView(runningView(p.view), token, null))
    p.model.view = jobView(failedView(p.view), token, false); wait(1)
    reexpand()
    // An interrupted job: its record never ends, but nothing is busy, so Cancel shows again.
    n.take.clicked(); token = Quickshell.lastCommand[2]
    nameSettle(p, jobView(runningView(p.view), token, null)); verify(!n.cancel.visible)
    p.model.view = jobView(failedView(p.view), token, null); wait(1)
    reexpand()
    // A failed launch: no record of it, nothing busy.
    n.take.clicked(); token = Quickshell.lastCommand[2]
    nameSettle(p, jobView(runningView(p.view), 'panel-older', true)); verify(!n.cancel.visible)
    var failed = failedView(p.view); failed.result.launch = 'Lanai could not start the snapshot.'
    p.model.view = jobView(failed, 'panel-older', true); wait(1)
    reexpand()
    compare(n.field.text, 'Fine')
    // Success closes the prompt and clears the unchanged draft.
    n.take.clicked(); token = Quickshell.lastCommand[2]
    nameSettle(p, jobView(runningView(p.view), token, null))
    p.model.view = jobView(p.view, token, true); wait(1)
    compare(p.panel.namePrompt, ''); verify(!n.field.visible && !n.cancel.visible)
    compare(n.take.text, 'Take a snapshot'); compare(n.field.text, '')
    p.panel.destroy()
  }
  function test_snapshot_prompt_closes_with_its_draft_when_its_action_turns_off() {
    var p = namePanel(true), scope = panelFocus(p)
    ;[false,true].forEach(function(setup) {
      var n = nameParts(p, setup), key = setup ? 'setup_snapshot' : 'take_snapshot', which = setup ? 'setup' : 'daily'
      function reopen() {
        nameSettle(p)
        if (!setup && p.panel.expandedSection !== 'snapshots') named(p.panel, 'snapshotsToggle').clicked()
        n.take.clicked(); wait(1)
        verify(n.field.visible && n.field.activeFocus, which)
        compare(n.field.text, 'Kept')
      }
      n.take.clicked(); wait(1); typeInto(n.field, 'Kept')
      // Hidden: the prompt closes, and focus in it moves to the panel.
      var v = copy(p.view); v.buttons[key].show = false
      p.model.view = v; wait(1)
      compare(p.panel.namePrompt, '', which)
      compare(scope.Window.activeFocusItem, scope)
      reopen()
      // Windows starts: the action is disabled with no snapshot of the prompt's own.
      v = copy(p.view); v.buttons[key].enable = false
      p.model.view = v; wait(1)
      compare(p.panel.namePrompt, '', which)
      compare(scope.Window.activeFocusItem, scope)
      reopen()
      // The same with focus on Cancel.
      n.cancel.forceActiveFocus(); verify(n.cancel.activeFocus, which)
      p.model.view = copy(v); wait(1)
      compare(p.panel.namePrompt, '', which)
      compare(scope.Window.activeFocusItem, scope)
      reopen()
      // Another job begins.
      p.model.view = jobView(runningView(p.view), 'panel-other', null); wait(1)
      compare(p.panel.namePrompt, '', which)
      reopen()
      // An interrupted job, then Windows starts before the next poll.
      n.take.clicked(); var token = Quickshell.lastCommand[2]
      nameSettle(p, jobView(runningView(p.view), token, null))
      v = jobView(p.view, token, null); v.buttons[key].enable = false
      p.model.view = v; wait(1)
      compare(p.panel.namePrompt, '', which)
      reopen(); verify(n.cancel.visible)
      // The unreadable-poll view during its own snapshot closes the prompt
      // but keeps the launch, so a later success clears the unchanged draft.
      n.take.clicked(); token = Quickshell.lastCommand[2]
      nameSettle(p, jobView(runningView(p.view), token, null))
      failPoll(p)
      compare(p.panel.namePrompt, '', which)
      compare(n.field.text, 'Kept')
      p.model.view = jobView(p.view, token, true); wait(1)
      compare(n.field.text, '', which)
      compare(p.panel.namePrompt, '')
    })
    p.panel.destroy()
  }
  function test_snapshot_prompt_is_one_open_prompt_or_armed_action() {
    var p = namePanel(true), daily = nameParts(p, false), setup = nameParts(p, true)
    ;['restore_snapshot','restore_confirm','delete_snapshot','delete_confirm'].forEach(function(key) { p.view.buttons[key] = redesignView().buttons[key] })
    nameSettle(p)
    var name = p.view.snapshots.items[0].name, count = Quickshell.launchCount
    var restore = named(p.panel, 'restore-' + name), remove = named(p.panel, 'delete-' + name)
    verify(restore.visible && remove.visible)
    daily.take.clicked(); wait(1)
    setup.take.clicked(); wait(1)
    compare(p.panel.namePrompt, 'setup_snapshot')
    verify(!daily.field.visible && !daily.cancel.visible && setup.field.visible && setup.field.activeFocus)
    compare(daily.take.text, 'Take a snapshot')
    daily.take.clicked(); wait(1)
    verify(daily.field.visible && !setup.field.visible && !setup.cancel.visible)
    compare(setup.take.text, 'Take a snapshot')
    // Arming Restore or Delete closes the prompt; opening a prompt disarms them.
    restore.clicked(); compare(p.panel.restoreArmed, name); compare(p.panel.namePrompt, '')
    daily.take.clicked(); compare(p.panel.restoreArmed, ''); compare(p.panel.namePrompt, 'take_snapshot')
    remove.clicked(); compare(p.panel.deleteArmed, name); compare(p.panel.namePrompt, '')
    setup.take.clicked(); compare(p.panel.deleteArmed, ''); compare(p.panel.namePrompt, 'setup_snapshot')
    restore.clicked(); compare(p.panel.restoreArmed, name); compare(p.panel.namePrompt, '')
    setup.take.clicked(); compare(p.panel.restoreArmed, '')
    remove.clicked(); compare(p.panel.namePrompt, '')
    daily.take.clicked(); compare(p.panel.deleteArmed, '')
    // Focus outside the prompt stays where it is when the prompt closes.
    restore.forceActiveFocus(); keyClick(Qt.Key_Return)
    compare(p.panel.restoreArmed, name); compare(p.panel.namePrompt, '')
    verify(restore.activeFocus)
    compare(Quickshell.launchCount, count)
    p.panel.destroy()
  }
  function test_snapshot_prompt_reopens_for_a_refusal_that_settled_while_it_was_closed() {
    var p = namePanel(false), n = nameParts(p, false), scope = panelFocus(p)
    var name = p.view.snapshots.items[0].name, count
    function submit(text) {
      if (p.panel.namePrompt !== 'take_snapshot') { n.take.clicked(); wait(1) }
      n.field.forceActiveFocus(); n.field.selectAll(); typeInto(n.field, text); n.take.clicked()
      var token = Quickshell.lastCommand[2]
      nameSettle(p, jobView(runningView(p.view), token, null))
      return token
    }
    // The panel closes before the refusal settles. The refusal reopens the
    // prompt, which starts nothing and moves no focus, and opening the
    // panel keeps it open.
    var token = submit('a<b')
    p.panel.close(); wait(1); compare(p.panel.namePrompt, '')
    var focused = scope.Window.activeFocusItem
    count = Quickshell.launchCount
    p.model.view = jobView(p.view, token, false, 'Remove < and >.'); wait(1)
    compare(p.panel.namePrompt, 'take_snapshot')
    compare(scope.Window.activeFocusItem, focused); compare(Quickshell.launchCount, count)
    // Opening the panel shows it: Snapshots opens with the prompt.
    p.panel.open(); wait(1)
    compare(p.panel.namePrompt, 'take_snapshot'); compare(p.panel.expandedSection, 'snapshots')
    verify(n.field.visible && n.error.visible); compare(n.error.text, 'Remove < and >.')
    compare(n.field.Accessible.description, 'Remove < and >.'); compare(n.field.text, 'a<b')
    // The next attempt clears it. A refusal that settles while busy waits
    // for the action to turn on, here on the first poll after the panel opens.
    token = submit('c>d')
    verify(!n.error.visible); compare(n.field.Accessible.description, '')
    p.panel.close(); wait(1)
    p.model.view = jobView(runningView(p.view), token, false, 'Remove < and >.'); wait(1)
    compare(p.panel.namePrompt, '')
    p.panel.open(); wait(1); compare(p.panel.expandedSection, '')
    p.model.view = jobView(p.view, token, false, 'Remove < and >.'); wait(1)
    compare(p.panel.namePrompt, 'take_snapshot'); compare(p.panel.expandedSection, 'snapshots')
    verify(n.field.visible && n.error.visible)
    // A refusal seen in the open prompt does not reopen it after Cancel.
    token = submit('e<f')
    p.model.view = jobView(runningView(p.view), token, false, 'Remove < and >.'); wait(1)
    verify(n.error.visible); n.cancel.clicked(); wait(1)
    p.model.view = jobView(p.view, token, false, 'Remove < and >.'); wait(1)
    compare(p.panel.namePrompt, '')
    // Nor does one that settles while Restore or Delete is armed, or while the action is off.
    ;['restore','delete'].forEach(function(kind) {
      function armed() { return kind === 'restore' ? p.panel.restoreArmed : p.panel.deleteArmed }
      token = submit('g<h')
      named(p.panel, kind + '-' + name).clicked(); compare(armed(), name, kind)
      p.model.view = jobView(p.view, token, false, 'Remove < and >.'); wait(1)
      compare(p.panel.namePrompt, '', kind); compare(armed(), name, kind)
      named(p.panel, kind + 'Cancel-' + name).clicked(); compare(armed(), '', kind)
    })
    token = submit('i<j')
    p.panel.close(); wait(1)
    var off = jobView(p.view, token, false, 'Remove < and >.'); off.buttons.take_snapshot.enable = false
    p.model.view = off; wait(1)
    compare(p.panel.namePrompt, '')
    p.model.view = jobView(p.view, token, false, 'Remove < and >.'); wait(1)
    compare(p.panel.namePrompt, '')
    p.panel.open(); named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    n.take.clicked(); wait(1)
    verify(n.error.visible); compare(n.field.text, 'i<j')
    // That refusal's reopen is dropped, not kept for later: a successful
    // snapshot after it closes the prompt for good.
    token = submit('Fine')
    p.model.view = jobView(p.view, token, true); wait(1)
    compare(p.panel.namePrompt, ''); compare(n.field.text, '')
    p.panel.destroy()
  }
  // The setup prompt reopens the same way and leaves the sections as they
  // are. A refusal never reopens its prompt over the other open prompt.
  function test_snapshot_setup_prompt_reopens_and_yields_to_the_other_prompt() {
    var p = namePanel(true), daily = nameParts(p, false), setup = nameParts(p, true)
    // Collapse Snapshots, so a reopen that opened it would show.
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    var section = p.panel.expandedSection
    verify(section !== 'snapshots')
    setup.take.clicked(); wait(1); typeInto(setup.field, 'a<b')
    setup.take.clicked()
    var token = Quickshell.lastCommand[2]
    nameSettle(p, jobView(runningView(p.view), token, null))
    setup.field.forceActiveFocus(); keyClick(Qt.Key_Escape); wait(1)
    verify(p.panel.opened); compare(p.panel.namePrompt, '')
    p.model.view = jobView(p.view, token, false, 'Remove < and >.'); wait(1)
    compare(p.panel.namePrompt, 'setup_snapshot')
    verify(setup.field.visible && setup.error.visible); compare(setup.error.text, 'Remove < and >.')
    compare(p.panel.expandedSection, section)
    // A daily refusal that lands while the setup prompt is open leaves it
    // open; the daily prompt shows the refusal when the user opens it.
    setup.cancel.clicked(); wait(1)
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    daily.take.clicked(); wait(1); typeInto(daily.field, 'c<d')
    daily.take.clicked()
    token = Quickshell.lastCommand[2]
    setup.take.clicked(); wait(1); compare(p.panel.namePrompt, 'setup_snapshot')
    nameSettle(p, jobView(p.view, token, false, 'Remove < and >.'))
    compare(p.panel.namePrompt, 'setup_snapshot')
    verify(setup.field.visible && !daily.field.visible)
    daily.take.clicked(); wait(1)
    verify(daily.error.visible); compare(daily.field.text, 'c<d')
    p.panel.destroy()
  }
  function test_snapshot_prompts_fit_and_keep_their_tab_order() {
    ;[false,true].forEach(function(setup) {
      var p = namePanel(setup), n = nameParts(p, setup), which = setup ? 'setup' : 'daily'
      if (!setup) {
        p.view.snapshots.saved = {path:'/copy',path_line:'Snapshot saved at /copy',advice:'',
          copy_label:'Copy snapshot path',show_label:'Show details',hide_label:'Hide details'}
        nameSettle(p)
      }
      // Show details in the daily row; Continue without a snapshot in the setup row.
      var next = setup ? objects(p.panel, function(o) { return o.control === 'skip_snapshot' })[0]
        : named(p.panel, 'snapshotLocationToggle')
      var popup = named(p.panel, 'panelPopup'), flick = named(p.panel, 'panelScroll')
      verify(next.visible, which)
      n.take.clicked(); wait(1)
      compare(n.caption.text, 'Snapshot name (optional)')
      compare(n.field.Accessible.name, setup ? 'Setup snapshot name (optional)' : 'Snapshot name (optional)')
      compare(n.field.validator, null); compare(n.field.inputMask, '')
      if (setup) compare(nameParts(p, false).field.Accessible.name, 'Snapshot name (optional)')
      ;[420,360,260].forEach(function(width) {
        popup.contentWidth = width
        n.field.forceActiveFocus()
        verify(waitForPolish(flick.Window.window))
        ;[n.caption, n.field, n.take, n.cancel, next].forEach(function(item) {
          verify(item.visible && inBounds(item, flick), which + ' ' + item.objectName + ' at ' + width)
        })
        var caption = n.caption.mapToItem(flick, 0, 0), field = n.field.mapToItem(flick, 0, 0)
        var take = n.take.mapToItem(flick, 0, 0), cancel = n.cancel.mapToItem(flick, 0, 0), other = next.mapToItem(flick, 0, 0)
        verify(caption.y + n.caption.height <= field.y, 'caption above its field at ' + width)
        verify(field.y + n.field.height <= take.y && field.y + n.field.height <= cancel.y, 'field above its buttons at ' + width)
        // Save snapshot, then Cancel, and neither overlaps the row's other button.
        verify(take.x + n.take.width <= cancel.x || take.y + n.take.height <= cancel.y, which + ' Cancel follows Save at ' + width)
        ;[[n.take, take], [n.cancel, cancel]].forEach(function(pair) {
          var item = pair[0], at = pair[1]
          verify(at.x + item.width <= other.x || other.x + next.width <= at.x
            || at.y + item.height <= other.y || other.y + next.height <= at.y, which + ' ' + item.objectName + ' overlaps at ' + width)
        })
        // Tab goes field, Save snapshot, Cancel, then the row's other button.
        ;[n.take, n.cancel, next].forEach(function(item) {
          keyClick(Qt.Key_Tab)
          verify(item.activeFocus, which + ' Tab to ' + item.objectName + ' at ' + width)
        })
      })
      // Save snapshot stays put when Cancel hides at submission.
      n.field.forceActiveFocus()
      verify(waitForPolish(flick.Window.window))
      // The busy line shows above the rows then, so compare offsets from Save snapshot.
      var x = n.take.mapToItem(flick, 0, 0).x, at = next.mapToItem(n.take, 0, 0)
      n.take.clicked()
      nameSettle(p, jobView(runningView(p.view), Quickshell.lastCommand[2], null))
      verify(waitForPolish(flick.Window.window))
      verify(n.field.visible && !n.cancel.visible)
      compare(n.take.mapToItem(flick, 0, 0).x, x)
      // Nor does the row's other button move.
      compare(next.mapToItem(n.take, 0, 0).x, at.x, which); compare(next.mapToItem(n.take, 0, 0).y, at.y, which)
      p.panel.destroy()
    })
  }
  function test_snapshot_name_hidden_prompt_takes_no_keys_or_enter() {
    var p = namePanel(false), daily = nameParts(p, false)
    daily.take.clicked(); wait(1)
    typeInto(daily.field, 'Hidden'); verify(daily.field.activeFocus)
    // A failure opens Logs by itself; the prompt stays open out of sight.
    p.model.view = failedView(p.view); wait(1)
    compare(p.panel.expandedSection, 'logs'); compare(p.panel.namePrompt, 'take_snapshot')
    verify(!daily.field.visible)
    var action = p.model.control('take_snapshot')
    verify(action.show === true && action.enable === true)
    var count = Quickshell.launchCount
    // The hidden field keeps focus, but neither keys nor Enter reach it.
    verify(daily.field.activeFocus)
    keyClick('x'); keyClick(Qt.Key_Return)
    compare(Quickshell.launchCount, count)
    // Nor does Save snapshot take the hidden draft: by key or by click.
    verify(!daily.take.visible)
    daily.take.forceActiveFocus(); keyClick(Qt.Key_Return); daily.take.clicked()
    compare(Quickshell.launchCount, count); compare(p.panel.namePrompt, 'take_snapshot')
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    verify(daily.field.visible); compare(daily.field.text, 'Hidden')
    // Escape from a hidden prompt closes the panel, as no prompt shows.
    p.panel.expandedSection = 'logs'; wait(1)
    daily.field.forceActiveFocus(); verify(!daily.field.visible); compare(p.panel.namePrompt, 'take_snapshot')
    keyClick(Qt.Key_Escape); wait(1)
    verify(!p.panel.opened)
    p.panel.destroy()
  }
  function test_snapshot_name_refusal_shows_beside_its_field_and_keeps_the_draft() {
    var p = namePanel(true), daily = nameParts(p, false), setup = nameParts(p, true)
    daily.take.clicked(); wait(1)
    typeInto(daily.field, 'a<b')
    daily.take.clicked()
    compare(launched(), JSON.stringify(['snapshot','a<b']))
    var dailyToken = Quickshell.lastCommand[2]
    nameSettle(p, jobView(p.view, dailyToken, false, 'Remove < and >.'))
    verify(daily.field.visible)
    compare(daily.error.text, 'Remove < and >.'); verify(daily.error.visible)
    compare(daily.field.Accessible.description, 'Remove < and >.')
    var siblings = Array.from(daily.field.parent.children)
    compare(siblings.indexOf(daily.error), siblings.indexOf(daily.field) + 1)
    compare(daily.field.text, 'a<b')
    compare(setup.field.Accessible.description, '')
    verify(daily.take.visible && daily.take.enabled); verify(setup.take.visible && setup.take.enabled)
    // A real multiline paste reaches the backend unchanged.
    setup.take.clicked(); wait(1)
    verify(!daily.field.visible && setup.field.visible && !setup.error.visible)
    clipboardSource.text = 'first\nsecond'; clipboardSource.selectAll(); clipboardSource.copy()
    setup.field.forceActiveFocus(); setup.field.paste()
    compare(setup.field.text, 'first\nsecond')
    setup.take.clicked()
    compare(launched(), JSON.stringify(['snapshot','first\nsecond']))
    var setupToken = Quickshell.lastCommand[2]
    nameSettle(p, jobView(p.view, setupToken, false, 'Use one line.'))
    compare(setup.error.text, 'Use one line.'); verify(setup.error.visible)
    compare(setup.field.Accessible.description, 'Use one line.')
    compare(setup.field.text, 'first\nsecond')
    compare(daily.error.text, 'Remove < and >.')
    verify(daily.take.enabled && setup.take.enabled)
    // A refusal for another launch reaches neither field; the next submission clears its own note.
    p.model.view = jobView(p.view, 'panel-other', false, 'Use 64 characters or fewer.'); wait(1)
    compare(daily.error.text, 'Remove < and >.'); compare(setup.error.text, 'Use one line.')
    daily.take.clicked(); wait(1)
    verify(daily.error.visible)
    daily.take.clicked()
    verify(!daily.error.visible); compare(daily.field.Accessible.description, '')
    compare(setup.error.text, 'Use one line.')
    p.panel.destroy()
  }
  function test_snapshot_name_drafts_survive_polls_sections_and_failures() {
    var p = namePanel(true), daily = nameParts(p, false), setup = nameParts(p, true)
    daily.take.clicked(); wait(1); typeInto(daily.field, 'Keep me')
    setup.take.clicked(); wait(1); typeInto(setup.field, 'Setup draft')
    p.model.view = copy(p.view); wait(1)
    verify(setup.field.visible); compare(setup.field.text, 'Setup draft')
    daily.take.clicked(); wait(1)
    compare(daily.field.text, 'Keep me')
    named(p.panel, 'snapshotsToggle').clicked(); verify(!daily.field.visible)
    named(p.panel, 'snapshotsToggle').clicked()
    daily.take.clicked(); wait(1); verify(daily.field.visible)
    compare(daily.field.text, 'Keep me')
    daily.take.clicked()
    var token = Quickshell.lastCommand[2]
    nameSettle(p, jobView(p.view, token, false))
    verify(daily.field.visible); compare(daily.field.text, 'Keep me'); verify(!daily.error.visible)
    // An unreadable poll shows the Failed view, which closes the prompt; the drafts outlast it.
    failPoll(p)
    compare(p.panel.namePrompt, '')
    p.model.view = copy(p.view); wait(1)
    named(p.panel, 'snapshotsToggle').clicked(); wait(1)
    daily.take.clicked(); wait(1); compare(daily.field.text, 'Keep me')
    setup.take.clicked(); wait(1); compare(setup.field.text, 'Setup draft')
    // A dropped click keeps the draft and the prompt, and sends nothing.
    p.model.run(['setup'], true)
    var count = Quickshell.launchCount
    setup.take.clicked()
    compare(Quickshell.launchCount, count); verify(p.model.clickNotice !== '')
    verify(setup.field.visible); compare(setup.field.text, 'Setup draft')
    p.panel.destroy()
  }
  function test_snapshot_name_success_clears_only_its_unchanged_draft() {
    var p = namePanel(true), daily = nameParts(p, false), setup = nameParts(p, true)
    daily.take.clicked(); wait(1); typeInto(daily.field, 'One'); daily.take.clicked()
    var dailyToken = Quickshell.lastCommand[2]
    nameSettle(p, jobView(runningView(p.view), dailyToken, null))
    p.model.view = jobView(runningView(p.view), 'panel-other', true); wait(1)
    compare(daily.field.text, 'One'); compare(p.panel.namePrompt, 'take_snapshot')
    p.model.view = jobView(p.view, dailyToken, true); wait(1)
    compare(daily.field.text, ''); compare(p.panel.namePrompt, '')
    // A draft edited while its own snapshot runs stays after that success.
    setup.take.clicked(); wait(1); typeInto(setup.field, 'Two'); setup.take.clicked()
    var setupToken = Quickshell.lastCommand[2]
    nameSettle(p, jobView(runningView(p.view), setupToken, null))
    setup.field.cursorPosition = 3; typeInto(setup.field, '!')
    p.model.view = jobView(p.view, setupToken, true); wait(1)
    compare(setup.field.text, 'Two!'); compare(p.panel.namePrompt, '')
    // An unchanged setup draft clears on its own success; daily's draft stays.
    daily.take.clicked(); wait(1); typeInto(daily.field, 'Three')
    setup.take.clicked(); wait(1); setup.take.clicked()
    var againToken = Quickshell.lastCommand[2]
    compare(launched(), JSON.stringify(['snapshot','Two!']))
    nameSettle(p, jobView(runningView(p.view), againToken, null))
    p.model.view = jobView(p.view, againToken, true); wait(1)
    compare(setup.field.text, ''); compare(daily.field.text, 'Three')
    p.panel.destroy()
  }
  function test_run_returns_the_launch_token_or_empty_for_a_dropped_click() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var token = model.run(['snapshot', 'a b'], true)
    verify(token !== '')
    compare(token, model.pendingToken); compare(token, Quickshell.lastCommand[2])
    compare(model.run(['snapshot', 'again'], true), '')
    model.pendingToken = ''; ready(model)
    token = model.run(['open'], false)
    compare(token, process(model, model.cli).command[2])
    compare(model.run(['open'], false), '')
  }
  function labeledView() {
    var v = redesignView(), meta = 'Before ${HOME} $(id) ../x', long = new Array(65).join('W')
    function item(name, date, time, user) {
      var when = date + ' at ' + time, full = user ? '“' + user + '” from ' + when : when
      return {name:name,date:date,time:time,label:when,user_label:user,full_label:full,
        restore_label:'Restore ' + full,confirm_label:'Restore now: ' + full + ' and replace Windows',
        confirm_note:'Restore this snapshot and replace Windows?',
        warning:'Changes since this snapshot are lost.',delete_label:'Delete ' + full,
        delete_confirm_label:'Delete snapshot: ' + full + ', permanently',delete_confirm_note:'Delete this snapshot permanently?',
        delete_warning:'Windows stays as it is.'}
    }
    v.snapshots.items = [item('20261012T091230Z','Oct 12, 2026','09:12:30 UTC',meta),
      item('20261011T080000Z','Oct 11, 2026','08:00 UTC',long), item('20261010T070000Z','Oct 10, 2026','07:00 UTC',null)]
    v.snapshots.names = v.snapshots.items.map(function(i) { return i.name })
    v.snapshots.count = 3
    return v
  }
  function inBounds(item, flick) {
    var point = item.mapToItem(flick, 0, 0)
    return point.x >= 0 && point.x + item.width <= flick.width + 0.5
  }
  function test_snapshot_labels_wrap_above_dates_and_confirmations_stay_in_bounds() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    var v = labeledView()
    model.view = v
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    wait(1)
    named(panel, 'snapshotsToggle').clicked()
    var popup = named(panel, 'panelPopup'), flick = named(panel, 'panelScroll')
    ;[420,360,260].forEach(function(width) {
      popup.contentWidth = width
      v.snapshots.items.forEach(function(item) {
        var restore = named(panel, 'restore-' + item.name), remove = named(panel, 'delete-' + item.name)
        var label = named(panel, 'snapshotLabel-' + item.name)
        var date = objects(panel, function(o) { return typeof o.text === 'string' && o.text.replace(/\u00a0/g, ' ') === item.date + ' · ' + item.time && o.visible })[0]
        ;['','restore','delete'].forEach(function(armed) {
          panel.restoreArmed = armed === 'restore' ? item.name : ''
          panel.deleteArmed = armed === 'delete' ? item.name : ''
          verify(waitForPolish(flick.Window.window))
          verify(date !== undefined && inBounds(date, flick), item.name + ' date at ' + width)
          if (item.user_label) {
            verify(label.visible); compare(label.text, item.user_label)
            compare(label.font.weight, Font.DemiBold)
            verify(inBounds(label, flick) && label.contentWidth <= label.width + 0.5, item.name + ' label at ' + width)
            verify(label.mapToItem(flick, 0, 0).y + label.height <= date.mapToItem(flick, 0, 0).y, 'label above date at ' + width)
          } else {
            verify(!label.visible)
            // A legacy row starts with its date line, as before.
            compare(date.parent.mapToItem(date.parent.parent.parent, 0, 0).y, 0)
          }
          if (armed !== 'delete') {
            verify(restore.visible && inBounds(restore, flick), item.name + ' Restore at ' + width)
            verify(restore.implicitWidth <= restore.width + 0.5, 'Restore caption does not fit at ' + width)
          }
          if (armed !== 'restore') verify(remove.visible && inBounds(remove, flick), item.name + ' Delete at ' + width)
          if (armed === '') {
            compare(restore.text, 'Restore'); compare(restore.Accessible.name, item.restore_label)
            var row = restore.parent.parent
            verify(Math.abs(restore.mapToItem(row, restore.width, 0).x - row.width) <= 1, 'Restore is not right-aligned at ' + width)
          } else if (armed === 'restore') {
            compare(restore.text, 'Restore now'); compare(restore.Accessible.name, item.confirm_label)
            var note = named(panel, 'restoreConfirm-' + item.name)
            verify(note.visible); compare(note.text, item.confirm_note)
            verify(inBounds(note, flick) && note.contentWidth <= note.width + 0.5)
            verify(textVisible(panel, item.warning))
          } else {
            compare(remove.text, 'Delete snapshot'); compare(remove.Accessible.name, item.delete_confirm_label)
            var deleteNote = named(panel, 'deleteConfirm-' + item.name)
            verify(deleteNote.visible); compare(deleteNote.text, item.delete_confirm_note)
            verify(inBounds(deleteNote, flick) && deleteNote.contentWidth <= deleteNote.width + 0.5,
              item.name + ' Delete note at ' + width)
            verify(textVisible(panel, item.delete_warning))
          }
        })
      })
    })
    panel.restoreArmed = ''; panel.deleteArmed = ''
    // Actions target the UTC identifier, never the saved label.
    var name = v.snapshots.items[0].name
    named(panel, 'restore-' + name).clicked(); pastConfirmGuard(panel); named(panel, 'restore-' + name).clicked()
    compare(launched(), JSON.stringify(['restore', name]))
    model.pendingToken = ''; ready(model); model.view = JSON.parse(JSON.stringify(v)); wait(1)
    named(panel, 'delete-' + name).clicked(); pastConfirmGuard(panel); named(panel, 'delete-' + name).clicked()
    compare(launched(), JSON.stringify(['delete-snapshot', name]))
    panel.destroy()
  }
  function test_restore_and_controls() {
    var model = createTemporaryObject(modelComponent, tests)
    wait(1); ready(model)
    model.view = {buttons:{restore_snapshot:{show:true,enable:true,label:'Restore',labels:{snapshot:'Restore snapshot snapshot'}},restore_confirm:{show:true,enable:true,label:'Restore now',labels:{snapshot:'Restore snapshot and replace Windows'}}},setup:{},settings:{},snapshots:{names:['snapshot'],items:[{name:'snapshot',label:'snapshot',restore_label:'Restore snapshot snapshot',confirm_label:'Restore snapshot and replace Windows',confirm_note:'Restore snapshot and replace Windows?'}]},result:{},logs:{}}
    var panel = createTemporaryObject(panelComponent, tests, {model:model})
    wait(1)
    named(panel, 'snapshotsToggle').clicked()
    var restore = objects(panel, function(o) { return o.control === 'restore_snapshot' })[0]
    compare(restore.text, 'Restore')
    compare(restore.Accessible.name, 'Restore snapshot snapshot')
    restore.clicked()
    compare(panel.restoreArmed, 'snapshot')
    compare(restore.control, 'restore_confirm')
    compare(restore.text, 'Restore now')
    compare(restore.Accessible.name, 'Restore snapshot and replace Windows')
    verify(textVisible(panel, 'Restore snapshot and replace Windows?'))
    pastConfirmGuard(panel); restore.clicked()
    compare(Quickshell.lastCommand[1], 'ui-job')
    compare(Quickshell.lastCommand.slice(3).join(' '), 'restore snapshot')
    model.view = {buttons:{},setup:{},settings:{},snapshots:{names:[]},result:{},logs:{}}
    compare(panel.restoreArmed, '')
    panel.destroy(); wait(1)
  }
}
QML
}

qml_renderer_run() {
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME='' QT_STYLE_OVERRIDE=Basic QML_DISABLE_DISK_CACHE=1 run /usr/lib/qt6/bin/qmltestrunner -input "$T/qml" -import "$T/qml/imports" "$@"
  assert_success
  refute_output --partial 'FAIL!'
}

@test "QML renderer: poll cadence, refresh races, literal actions and armed confirmations" {
  qml_renderer_fixture
  qml_renderer_run
}

@test "QML settings: typed drafts commit with the installed NumberField" {
  local field=/usr/share/omarchy/shell/Ui/NumberField.qml
  [[ -r $field ]] || skip "installed NumberField is unavailable"
  qml_renderer_fixture
  sed 's/import qs.Commons/import TestCommons/' "$field" >"$T/qml/imports/TestUi/NumberField.qml"
  # Supply the installed field's theme tokens without loading the desktop shell.
  sed -i '/property real cornerRadius/a\
  property var spacing: ({md:4,numberFieldWidth:120,controlHeight:30,controlPaddingY:4,controlPaddingX:4})\
  function controlFill(focus, hot, foreground, accent) { return "transparent" }\
  function selectionFillFor(foreground, accent) { return accent }' "$T/qml/imports/TestCommons/Style.qml"
  sed -i '/function controlSpec/a\
  function left(spec) { return spec.width }\
  function right(spec) { return spec.width }\
  function top(spec) { return spec.width }\
  function bottom(spec) { return spec.width }' "$T/qml/imports/TestCommons/Border.qml"
  sed -i 's/family:"sans",bodySmall:12/family:"sans",body:14,bodySmall:12/' "$T/qml/imports/TestCommons/Style.qml"
  qml_renderer_run PanelRenderer::test_redesign_typed_numbers_enable_save_and_commit_without_enter \
    PanelRenderer::test_redesign_pending_number_reset_revert_and_reopen
}

@test "QML snapshots: narrow actions fit with the installed Button and TextField" {
  local button=/usr/share/omarchy/shell/Ui/Button.qml field=/usr/share/omarchy/shell/Ui/TextField.qml
  [[ -r $button && -r $field ]] || skip "installed Button or TextField is unavailable"
  qml_renderer_fixture
  sed 's/import qs.Commons/import TestCommons/' "$button" >"$T/qml/imports/TestUi/Button.qml"
  sed 's/import qs.Commons/import TestCommons/' "$field" >"$T/qml/imports/TestUi/TextField.qml"
  # Keep the installed controls' sizing and text fitting with inert theme tokens.
  sed -i '/property real cornerRadius/a\
  property var spacing: ({controlGap:8,controlPaddingX:10,controlPaddingY:6,inputPaddingY:4})\
  property real normalBorderWidth: 1\
  function controlFill(focus, hot, foreground, accent) { return "transparent" }\
  function selectionFillFor(foreground, accent) { return accent }\
  function selectedStateColor(foreground, accent) { return foreground }\
  function pressedFillFor(foreground, accent) { return "transparent" }\
  function focusFillFor(foreground, accent) { return "transparent" }\
  function hoverFillFor(foreground, accent) { return "transparent" }\
  function selectedFillFor(foreground, accent) { return "transparent" }' "$T/qml/imports/TestCommons/Style.qml"
  sed -i 's/family:"sans",bodySmall:12,caption:10/family:"monospace",body:12,bodySmall:11,caption:10,icon:16/' "$T/qml/imports/TestCommons/Style.qml"
  sed -i '/function controlSpec/a\
  function localOrSurfaceSpec() { return {width:1,color:"white"} }\
  function controlHasWidth() { return true }\
  function left(spec) { return spec.width }\
  function right(spec) { return spec.width }\
  function top(spec) { return spec.width }\
  function bottom(spec) { return spec.width }' "$T/qml/imports/TestCommons/Border.qml"
  sed -i '/property var borderSpec/a\
  property real leftPadding: 0\
  property real rightPadding: 0\
  property real topPadding: 0\
  property real bottomPadding: 0' "$T/qml/imports/TestUi/BorderSurface.qml"
  sed -i 's/property color background: "black"/property color background: "black"; property var tooltip: ({background:"black",text:"white",border:"white"})/' "$T/qml/imports/TestCommons/Color.qml"
  qml_renderer_run PanelRenderer::test_redesign_snapshot_actions_fit_narrow_panel \
    PanelRenderer::test_redesign_snapshot_management_actions_share_a_row \
    PanelRenderer::test_redesign_delete_snapshot_requires_named_confirmation_and_keeps_actions_in_bounds \
    PanelRenderer::test_redesign_restore_dates_identity_cancel_and_invalidated_target \
    PanelRenderer::test_snapshot_labels_wrap_above_dates_and_confirmations_stay_in_bounds \
    PanelRenderer::test_snapshot_prompts_fit_and_keep_their_tab_order \
    PanelRenderer::test_snapshot_prompt_ignores_a_held_key \
    PanelRenderer::test_snapshot_prompt_submits_quick_deliberate_presses \
    PanelRenderer::test_snapshot_name_refusal_shows_beside_its_field_and_keeps_the_draft
}

panel_board_view() {
  cmd_panel | jq -c --arg name "$1" '{key:$name,value:.}' >>"$T/boards.jsonl"
}

@test "QML redesign: all ten board views render from backend fixtures" {
  [[ -x /usr/lib/qt6/bin/qmltestrunner ]] || skip "qmltestrunner is unavailable"
  panel_fixture_setup
  # Restore real snapshot validation after the shared fixture's empty list stub.
  # shellcheck source-path=SCRIPTDIR source=../lib/snapshot.sh
  source "$REPO/lib/snapshot.sh"
  local name snap label image_fd job_fd started pid=$BASHPID
  jq '.memory_gib=12 | .cores=6 | .windows_scale=175' "$(settings_file)" >"$T/settings"
  mv "$T/settings" "$(settings_file)"
  for name in 20260902T070500Z 20261012T091200Z 20260930T184700Z; do
    display_snapshot "$(data_dir)/snapshots/$name"
  done
  for name in "$RUN/client.log" "$S/build-client.log" "$S/panel-job.log" "$S/panel-run.log"; do : >"$name"; done
  state "$CURRENT"
  qmp_call() { printf '{"return":{"status":"running"}}\n{"return":[{"label":"qga0","frontend-open":true}]}\n'; }
  ST=active
  panel_board_view Main
  panel_board_view Settings
  ST=inactive
  panel_board_view Stopped
  # Saved labels: one label twice in one minute, with path and shell
  # metacharacters, a 64-code-point label with no spaces, and a legacy row.
  snap=$(data_dir)/snapshots
  display_snapshot "$snap/20261012T091230Z"
  # shellcheck disable=SC2016
  label='Before ${HOME} $(id) ../x'
  printf '%s\n' "$label" >"$snap/20261012T091200Z/LABEL"
  printf '%s\n' "$label" >"$snap/20261012T091230Z/LABEL"
  printf 'W%.0s' {1..64} >"$snap/20260930T184700Z/LABEL"
  panel_board_view Labeled
  printf '%s\n%s\n' "$snap/20261012T091230Z" "$STORE" >"$S/restore-in-progress"
  panel_board_view LabeledRecovery
  exec {image_fd}>"$S/lock"; flock "$image_fd"
  jq -nc --argjson p "$pid" '{operation:"restore",phase:"hashing",done:37,total:100,pid:$p}' >"$S/image-progress.json"
  panel_board_view LabeledRestoring
  exec {image_fd}>&-
  rm "$S/image-progress.json" "$S/restore-in-progress" "$snap"/*/LABEL
  rm -r "$snap/20261012T091230Z"
  snap=$(data_dir)/snapshots/20261012T091200Z
  printf '%s\n%s\n' "$snap" "$STORE" >"$S/restore-in-progress"
  exec {image_fd}>"$S/lock"; flock "$image_fd"
  jq -nc --argjson p "$pid" '{operation:"restore",phase:"hashing",done:37,total:100,pid:$p}' >"$S/image-progress.json"
  panel_board_view Restoring
  exec {image_fd}>&-
  rm "$S/image-progress.json"
  panel_board_view RestoreRecovery
  printf 'invalid\n%s\n' "$STORE" >"$S/restore-in-progress"
  panel_board_view RestoreGeneric
  rm "$S/restore-in-progress"
  ST=failed RESULT=exit-code
  panel_board_view Failed
  ST=unknown RESULT=success
  panel_board_view FailedRead
  ST=inactive
  for name in activating deactivating; do
    ST=$name
    panel_board_view "Bar-$name"
  done
  ST=inactive
  container_fact() { echo running; }
  panel_board_view Bar-in-use
  container_fact() { echo none; }
  cp "$FIX/client-logs/incompatible.log" "$RUN/client.log"
  ST=active
  panel_board_view Bar-version-mismatch
  : >"$RUN/client.log"
  ST=inactive
  exec {image_fd}>"$S/lock"; flock "$image_fd"
  for name in 0 100; do
    jq -nc --argjson p "$pid" --argjson t "$name" '{operation:"snapshot",phase:"hashing",done:0,total:$t,pid:$p}' >"$S/image-progress.json"
    panel_board_view "Bar-busy-$name"
  done
  exec {image_fd}>&-
  rm "$S/image-progress.json"
  # Setup's snapshot offer must have no existing snapshot for this location.
  mv "$(data_dir)/snapshots" "$T/saved-snapshots"
  state '{}'
  panel_board_view SetupSnapshot
  panel_result_write snapshots '{"command":"snapshot","started":1,"ended":2,"reply":{"ok":false,"reason":"snapshot-unsupported"}}'
  panel_board_view SnapshotUnsupported
  rm "$S/panel-result-snapshots.json"
  state '{"snapshot":"declined"}'
  ST=active
  echo '{"setup":true,"window":false}' >"$S/boot.json"
  panel_board_view SetupDrivers
  panel_result_write setup '{"command":"setup","started":1,"reply":{"ok":true,"step":"5"}}'
  exec {job_fd}>"$S/panel-job.lock"; flock "$job_fd"
  panel_board_view DriversWorker
  state '{"snapshot":"declined","step5":true}'
  echo '{"step6":true,"window":false}' >"$S/boot.json"
  started=$((EPOCHSECONDS - 30))
  echo "$((started - 5))" >"$RUN/step6-since"
  redesign_check_detail '{"idd":{"state":"done"},"spice":{"state":"done"},"clock":{"state":"waiting","reason":"clock"},"allowlist":{"state":"not_checked"},"scale":{"state":"not_checked"}}'
  panel_result_write setup '{"command":"setup","invocation":"inv","started":1,"reply":{"ok":true,"step":"6"}}'
  panel_board_view VerifyPartial
  echo "$started" >"$RUN/step6-checked"
  redesign_check_detail '{"idd":{"state":"done"},"spice":{"state":"done"},"clock":{"state":"done"},"allowlist":{"state":"done"},"scale":{"state":"waiting","reason":"scale-task"}}'
  echo 180 >"$RUN/step6-scale-limit"
  panel_board_view SetupVerify
  echo 120 >"$RUN/step6-scale-limit"
  panel_board_view VerifyDefaultLimit
  echo invalid >"$RUN/step6-scale-limit"
  panel_board_view InvalidTiming
  exec {job_fd}>&-
  ST=inactive
  timeout_record scale-task
  panel_result_write setup "$(jq --argjson t "$EPOCHSECONDS" '.started=$t | .ended=$t' "$S/panel-result-setup.json")"
  panel_board_view SetupTimeout
  rm "$S/panel-result-setup.json" "$RUN/step6-since" "$RUN/step6-checked" "$RUN/step6-scale-limit" "$RUN/step6-checks.json"
  state '{}'
  host_packages_missing() { echo package; }
  panel_board_view SetupPackages
  host_packages_missing() { :; }
  share_check() { return 1; }
  panel_board_view SetupCheck
  share_check() { return 0; }
  state '{"snapshot":"declined"}'
  rm "$STORE/windows.base"
  panel_board_view PrepareStorage
  echo base >"$STORE/windows.base"
  build_stamp_current() { return 1; }
  panel_board_view PrepareClient
  build_stamp_current() { return 0; }
  state "$CURRENT"
  cmd_snapshots() { return 1; }
  panel_board_view SnapshotReadFailure
  cp "$(settings_file)" "$T/saved-settings"
  printf invalid >"$(settings_file)"
  panel_board_view SettingsReadFailure
  mv "$T/saved-settings" "$(settings_file)"
  layout_check() { return 2; }
  panel_board_view Bar-not-installed

  qml_renderer_fixture
  printf 'var views = ' >"$T/qml/BackendViews.js"
  jq -sc from_entries "$T/boards.jsonl" >>"$T/qml/BackendViews.js"
  sed -i '/import QtTest/a import "BackendViews.js" as Backend' "$T/qml/tst_renderer.qml"
  sed -i '$d' "$T/qml/tst_renderer.qml"
  cat >>"$T/qml/tst_renderer.qml" <<'QML'
  function backendPanel(name) {
    var v = Backend.views[name]
    verify(v !== undefined, name)
    compare(v.ok, true, name)
    var model = createTemporaryObject(modelComponent, tests)
    wait(1)
    process(model, 'timeout').complete(JSON.stringify(v), 0)
    var panel = createTemporaryObject(panelComponent, tests, {model:model,opened:true})
    wait(1)
    compare(named(panel, 'windowsHeader').title, 'Windows', name)
    compare(named(panel, 'windowsHeader').meta, v.header.meta, name)
    compare(named(panel, 'windowsHeader').detail, v.header.badge, name)
    compare(named(panel, 'panelPopup').contentWidth, 420)
    verify(named(panel, 'panelPopup').contentHeight <= 650)
    verify(named(panel, 'settingsToggle').visible, name)
    return {model:model,panel:panel}
  }
  function backendControl(p, control, enabled) {
    var items = objects(p.panel, function(o) { return o.control === control && o.visible })
    verify(items.length > 0, control)
    compare(items[0].enabled, enabled, control)
    return items[0]
  }
  function finishBackendPanel(p) { p.panel.destroy(); p.model.destroy(); wait(1) }
  // Checks that the status lines and disabled-action hints show, or are
  // quiet, together. Returns how many disabled hints the view offers.
  function statusAndHints(p, name, shown) {
    var v = p.model.view
    ;[v.headline, v.cause, v.next].forEach(function(line) {
      verify(line, name); compare(textVisible(p.panel, line), shown, name + ': ' + line)
    })
    var hints = Object.keys(v.buttons).filter(function(key) {
      var d = v.buttons[key]; return d.show && !d.enable && d.hint
    })
    hints.forEach(function(key) { compare(textVisible(p.panel, v.buttons[key].hint), shown, name + ': ' + key) })
    return hints.length
  }
  function test_backend_boards() {
    var count = Quickshell.launchCount, p = backendPanel('Main'), v = p.model.view
    compare(v.layout, 'daily'); compare(v.state, 'running')
    compare(v.header.meta, '12 GiB · 6 cores · 175%')
    compare(v.primary_action, 'open'); backendControl(p, 'open', true); backendControl(p, 'stop', true)
    compare(v.buttons.force_stop.show, false)
    ;['settings','snapshots','logs'].forEach(function(section) {
      named(p.panel, section + 'Toggle').clicked()
      compare(p.panel.expandedSection, section)
      verify(named(p.panel, section + 'Details').visible)
    })
    compare(v.logs.rows.map(function(row) { return row.label }).join(','), 'VM,Window,Build,Jobs,Actions')
    v.logs.rows.forEach(function(row) {
      named(p.panel, 'copyLog-' + row.id).clicked()
      var copy = process(p.model, 'wl-copy'); copy.begin()
      compare(copy.input, row.copy_text); compare(copy.command.length, 1)
      copy.complete('', 1)
      compare(named(p.panel, 'copyFeedback-' + row.id).text, v.logs.copy_error)
      verify(named(p.panel, 'copyLog-' + row.id).enabled)
      named(p.panel, 'copyLog-' + row.id).clicked(); copy.begin(); copy.complete('', 0)
      compare(named(p.panel, 'copyFeedback-' + row.id).text, v.logs.copied)
    })
    finishBackendPanel(p)

    p = backendPanel('Settings'); v = p.model.view
    named(p.panel, 'settingsToggle').clicked()
    var save = backendControl(p, 'save_settings', false)
    compare(save.text, 'Saved'); verify(!named(p.panel, 'resetSettings').visible)
    var scale = named(p.panel, 'windowsScale')
    compare(scale.options.length, 13); compare(scale.options[12].value, 500)
    scale.select('175'); verify(p.panel.scaleDirty)
    verify(named(p.panel, 'settingsToggle').text.indexOf(v.settings.labels.unsaved) !== -1)
    named(p.panel, 'resetSettings').clicked(); verify(!p.panel.scaleTouched)
    p.panel.memoryInput = 20
    compare(named(p.panel, 'windowsHeader').meta, v.header.meta)
    p.panel.close(); p.panel.open(); compare(p.panel.memoryInput, 12)
    finishBackendPanel(p)

    p = backendPanel('Stopped'); v = p.model.view
    compare(v.state, 'stopped'); backendControl(p, 'start', true)
    // The badge and Start Windows say it all. Idle, no hint shows today;
    // this guards the quiet rule.
    compare(v.layout, 'daily'); statusAndHints(p, 'Stopped', false)
    compare(backendControl(p, 'start', true).tooltipText, '')
    named(p.panel, 'snapshotsToggle').clicked()
    compare(v.snapshots.count, 3)
    compare(v.snapshots.items.map(function(item) { return item.name }).join(','), '20261012T091200Z,20260930T184700Z,20260902T070500Z')
    var item = v.snapshots.items[0], restore = named(p.panel, 'restore-' + item.name)
    compare(item.time, '09:12 UTC'); compare(item.date, 'Oct 12, 2026')
    restore.clicked(); compare(p.panel.restoreArmed, item.name)
    compare(restore.text, 'Restore now'); compare(restore.Accessible.name, item.confirm_label)
    verify(textVisible(p.panel, item.confirm_note)); verify(textVisible(p.panel, item.warning))
    named(p.panel, 'restoreCancel-' + item.name).clicked(); compare(p.panel.restoreArmed, '')
    restore.clicked(); p.panel.close(); compare(p.panel.restoreArmed, '')
    finishBackendPanel(p)

    // Saved labels show above their dates; equal labels in one minute get seconds.
    var saved = 'Before ${HOME} $(id) ../x', when = 'Oct 12, 2026 at 09:12:30 UTC'
    p = backendPanel('Labeled'); v = p.model.view
    named(p.panel, 'snapshotsToggle').clicked()
    compare(v.snapshots.items.map(function(item) { return [item.name, item.time, item.user_label].join('|') }).join(','),
      '20261012T091230Z|09:12:30 UTC|' + saved + ',20261012T091200Z|09:12:00 UTC|' + saved
      + ',20260930T184700Z|18:47 UTC|' + new Array(65).join('W') + ',20260902T070500Z|07:05 UTC|')
    v.snapshots.items.forEach(function(item) {
      var label = named(p.panel, 'snapshotLabel-' + item.name), restore = named(p.panel, 'restore-' + item.name)
      var remove = named(p.panel, 'delete-' + item.name)
      compare(label.visible, item.user_label !== null, item.name)
      if (item.user_label !== null) compare(label.text, item.user_label)
      verify(objects(p.panel, function(o) { return typeof o.text === 'string' && o.text.replace(/\u00a0/g, ' ') === item.date + ' · ' + item.time && o.visible }).length > 0, item.name)
      compare(restore.Accessible.name, item.restore_label); compare(remove.Accessible.name, item.delete_label)
      restore.clicked()
      compare(restore.text, 'Restore now'); compare(restore.Accessible.name, item.confirm_label)
      compare(named(p.panel, 'restoreConfirm-' + item.name).text, item.confirm_note)
      verify(named(p.panel, 'restoreConfirm-' + item.name).visible)
      pastConfirmGuard(p.panel); restore.clicked()
      compare(launched(), JSON.stringify(['restore', item.name]))
      // The poll's empty view rebuilds the rows, so look the button up again.
      p.model.pendingToken = ''; ready(p.model); p.model.view = Backend.views['Labeled']; wait(1)
      remove = named(p.panel, 'delete-' + item.name)
      remove.clicked(); compare(remove.Accessible.name, item.delete_confirm_label)
      compare(named(p.panel, 'deleteConfirm-' + item.name).text, item.delete_confirm_note); pastConfirmGuard(p.panel); remove.clicked()
      compare(launched(), JSON.stringify(['delete-snapshot', item.name]))
      p.model.pendingToken = ''; ready(p.model); p.model.view = Backend.views['Labeled']; wait(1)
    })
    var first = v.snapshots.items[0]
    compare(first.restore_label, 'Restore “' + saved + '” from ' + when)
    compare(first.confirm_label, 'Restore now: “' + saved + '” from ' + when + ' and replace Windows')
    compare(first.delete_confirm_label, 'Delete snapshot: “' + saved + '” from ' + when + ', permanently')
    finishBackendPanel(p)
    // Only the Labeled board's Restore and Delete clicks above launch anything.
    compare(Quickshell.launchCount, count + 2 * v.snapshots.items.length)
    count = Quickshell.launchCount
    p = backendPanel('LabeledRecovery')
    compare(named(p.panel, 'restoreTarget').text, 'Unfinished restore of “' + saved + '” from ' + when)
    finishBackendPanel(p)
    p = backendPanel('LabeledRestoring')
    compare(named(p.panel, 'restoreTarget').text, 'Restoring “' + saved + '” from ' + when)
    finishBackendPanel(p)

    p = backendPanel('Restoring'); v = p.model.view
    compare(v.layout, 'restoring'); compare(v.restore.name, '20261012T091200Z')
    compare(v.restore.label, 'Restoring Oct 12, 2026 at 09:12 UTC')
    compare(named(p.panel, 'restoreTarget').text, v.restore.label)
    verify(textVisible(p.panel, v.restore.warning))
    compare(named(p.panel, 'imageProgress').value, v.progress.percent)
    verify(v.progress.percent > 0 && v.progress.percent < 100)
    compare(named(p.panel, 'imageProgressText').text, v.progress.label + ', ' + v.progress.percent + '%')
    compare(v.restore.active, true); compare(v.busy.line, '')
    verify(statusAndHints(p, 'Restoring', false) > 0)
    backendControl(p, 'start', false)
    named(p.panel, 'snapshotsToggle').clicked(); backendControl(p, 'take_snapshot', false)
    // Positions are valid only after the window lays the panel out.
    verify(waitForPolish(named(p.panel, 'panelScroll').Window.window))
    verify(named(p.panel, 'operationProgress').mapToItem(p.panel,0,0).y < named(p.panel, 'dailyActions').mapToItem(p.panel,0,0).y)
    finishBackendPanel(p)
    ;['RestoreRecovery','RestoreGeneric'].forEach(function(name) {
      p = backendPanel(name); v = p.model.view
      compare(v.layout, 'restoring'); compare(v.progress, null)
      backendControl(p, 'start', false)
      compare(p.panel.expandedSection, 'snapshots')
      verify(named(p.panel, 'snapshotsDetails').visible)
      backendControl(p, 'finish_restore', true); backendControl(p, 'restore_snapshot', true)
      compare(named(p.panel, 'restoreTarget').text, name === 'RestoreGeneric' ? 'Unfinished restore' : 'Unfinished restore of Oct 12, 2026 at 09:12 UTC')
      // Nothing runs, so the status lines and hints say what to do.
      compare(v.restore.active, false); verify(statusAndHints(p, name, true) > 0)
      finishBackendPanel(p)
    })
    ;['Bar-busy-0','Bar-busy-100'].forEach(function(name) {
      p = backendPanel(name); v = p.model.view
      compare(v.layout, 'daily'); compare(v.state, 'stopped'); compare(v.busy.line, '')
      verify(statusAndHints(p, name, false) > 0)
      compare(backendControl(p, 'start', false).tooltipText, '')
      finishBackendPanel(p)
    })
    // In the daily layout only stopped and running are quiet: starting keeps its lines.
    p = backendPanel('Bar-activating'); v = p.model.view
    compare(v.layout, 'daily'); compare(v.state, 'starting')
    statusAndHints(p, 'Bar-activating', true)
    finishBackendPanel(p)

    ;['Failed','FailedRead'].forEach(function(name) {
      p = backendPanel(name); v = p.model.view
      compare(v.layout, 'failed'); compare(v.bar.mode, 'failed')
      compare(p.panel.expandedSection, 'logs'); verify(named(p.panel, 'logsDetails').visible)
      statusAndHints(p, name, true)
      compare(v.buttons.force_stop.show, false)
      finishBackendPanel(p)
    })

    ;[['SetupCheck',1,'Check'],['SetupPackages',2,'Packages'],['SetupSnapshot',3,'Snapshot'],
      ['PrepareStorage',4,'Prepare'],['PrepareClient',4,'Prepare'],['SetupDrivers',5,'Drivers'],
      ['SetupVerify',6,'Verify'],['SetupTimeout',6,'Verify']].forEach(function(row) {
      p = backendPanel(row[0]); v = p.model.view
      compare(v.setup.number, row[1]); compare(v.setup.name, row[2]); compare(v.header.badge, 'Setup')
      verify(v.header.meta.indexOf('Step ' + row[1] + ' of 6 · ' + row[2]) === 0)
      verify(named(p.panel, 'setupSteps').visible); compare(v.setup.steps.length, 6)
      compare(named(p.panel, 'setupTitle').text, v.setup.title)
      v.setup.lines.forEach(function(line) { verify(textVisible(p.panel, line), line) })
      compare(v.buttons.start.show, false); compare(v.buttons.open.show, false)
      if (row[0] === 'SetupSnapshot') {
        backendControl(p, 'setup_snapshot', true); backendControl(p, 'skip_snapshot', true)
        verify(v.setup.lines.join(' ').indexOf('backup') !== -1)
        // Neither name field shows until its prompt opens; their accessible names differ.
        named(p.panel, 'snapshotsToggle').clicked(); backendControl(p, 'take_snapshot', true)
        var setupField = named(p.panel, 'setupSnapshotNameField'), dailyField = named(p.panel, 'snapshotNameField')
        verify(!setupField.visible && !dailyField.visible)
        backendControl(p, 'setup_snapshot', true).clicked(); wait(1)
        verify(setupField.visible && !dailyField.visible)
        compare(setupField.Accessible.name, 'Setup snapshot name (optional)')
        compare(backendControl(p, 'setup_snapshot', true).text, 'Save snapshot')
        backendControl(p, 'take_snapshot', true).clicked(); wait(1)
        verify(dailyField.visible && !setupField.visible)
        compare(dailyField.Accessible.name, 'Snapshot name (optional)')
        compare(backendControl(p, 'take_snapshot', true).text, 'Save snapshot')
        compare(Quickshell.launchCount, count)
      } else if (row[0] === 'SetupPackages') backendControl(p, 'install', true)
      else if (row[0] === 'SetupDrivers') {
        verify(v.setup.lines.join(' ').indexOf('setup.cmd') !== -1)
        verify(v.setup.lines.join(' ').indexOf('Continue setup') !== -1)
        backendControl(p, 'stop', true).clicked(); verify(p.panel.stopArmed)
        backendControl(p, 'cancel', true).clicked(); verify(!p.panel.stopArmed)
      } else if (row[0] === 'SetupVerify') {
        compare(v.setup.checks.map(function(check) { return check.state }).join(','), 'done,done,waiting')
        verify(v.setup.lines.join(' ').indexOf('If Windows is at its sign-in screen') !== -1)
        compare(v.setup.countdown.limit_seconds, 180)
        verify(named(p.panel, 'setupCountdown').visible)
        v.setup.checks.forEach(function(check) { compare(named(p.panel, 'setupCheck-' + check.id).checkState, check.state) })
        var duration = named(p.panel, 'setupCountdownDuration').text
        p.panel.close(); p.panel.open(); compare(named(p.panel, 'setupCountdownDuration').text, duration)
      } else if (row[0] === 'SetupTimeout') {
        compare(v.layout, 'setup_timeout'); compare(v.setup.countdown, null)
        verify(!named(p.panel, 'setupCountdown').visible)
        backendControl(p, 'continue_setup', true); backendControl(p, 'window', true); backendControl(p, 'no_window', true)
        verify(textVisible(p.panel, v.result.setup)); verify(v.result.setup.indexOf('setup.cmd') !== -1)
      }
      finishBackendPanel(p)
    })
    ;['DriversWorker','SnapshotUnsupported','VerifyPartial','VerifyDefaultLimit','InvalidTiming','SettingsReadFailure','SnapshotReadFailure'].forEach(function(name) {
      p = backendPanel(name); v = p.model.view
      if (name === 'DriversWorker') {
        compare(v.bar.mode, 'active'); verify(v.setup.lines[0].indexOf('then Lanai starts it again') !== -1)
      } else if (name === 'SnapshotUnsupported') verify(textVisible(p.panel, v.result.snapshots))
      else if (name === 'VerifyPartial') {
        compare(v.setup.checks.map(function(check) { return check.state }).join(','), 'done,waiting,not_checked')
        verify(textVisible(p.panel, 'Waiting for the QEMU guest agent clock.'))
        verify(!named(p.panel, 'setupCountdown').visible)
      } else if (name === 'VerifyDefaultLimit') {
        compare(v.setup.countdown.limit_seconds, 120); verify(named(p.panel, 'setupCountdown').visible)
      } else if (name === 'InvalidTiming') {
        compare(v.setup.countdown, null); verify(!named(p.panel, 'setupCountdown').visible)
      } else if (name === 'SettingsReadFailure') {
        named(p.panel, 'settingsToggle').clicked(); compare(v.settings.baseline, null)
        backendControl(p, 'save_settings', false); verify(textVisible(p.panel, v.settings.error))
      } else {
        named(p.panel, 'snapshotsToggle').clicked(); compare(v.snapshots.count, 0)
        verify(textVisible(p.panel, v.snapshots.error))
      }
      finishBackendPanel(p)
    })
    var w = widgetParts()
    ;[['Stopped','stopped','stopped'],['Main','active','running'],['Bar-activating','active','starting'],['Bar-deactivating','active','stopping'],
      ['Bar-busy-0','busy','stopped'],['Bar-busy-100','busy','stopped'],['SetupSnapshot','attention'],['SetupVerify','attention'],
      ['Bar-in-use','attention','in-use'],['Bar-version-mismatch','attention','version-mismatch'],['Bar-not-installed','attention','not-installed'],
      ['SetupDrivers','active'],['DriversWorker','active'],['Failed','failed','failed'],['FailedRead','failed','failed']].forEach(function(row) {
      w.model.view = Backend.views[row[0]]; wait(1)
      compare(w.model.view.bar.mode, row[1], row[0])
      if (row[2]) compare(w.model.view.state, row[2], row[0])
      compare(named(w.widget, 'barBadge').visible, row[1] === 'attention' || row[1] === 'failed', row[0])
      var underline = named(w.widget, 'barUnderline')
      compare(underline.visible, row[1] === 'active' || row[1] === 'busy', row[0])
      if (row[0] === 'Bar-busy-0') {
        compare(w.model.view.bar.percent, null); verify(named(w.widget, 'barBusyAnimation').running)
        verify(underline.width > 0 && underline.width < underline.parent.width)
      } else if (row[0] === 'Bar-busy-100') {
        compare(w.model.view.bar.percent, 0); compare(underline.width, 0)
        verify(!named(w.widget, 'barBusyAnimation').running)
      }
      compare(w.button.tooltipText, w.model.view.tooltip, row[0])
      var title = {'Bar-not-installed':'Not installed','Bar-version-mismatch':'Display driver needs an update','Bar-in-use':'In use'}[row[0]]
      if (title) compare(w.button.tooltipText, 'Lanai: ' + title + ' (your turn)\nRight-click: Open the panel for details.', row[0])
    })
    compare(Quickshell.launchCount, count)
    verify(!process(w.model, w.model.cli))
  }
}
QML
  qml_renderer_run PanelRenderer::test_backend_boards
}
