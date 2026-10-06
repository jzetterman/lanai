import QtQuick
import Quickshell
import Quickshell.Io

// One view per bar instance. Only this instance's open panel polls quickly.
Item {
  id: root
  property bool panelOpen: false
  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/lanai").toString().replace(/^file:\/\//, ""))
  property var view: ({label: "Checking", headline: "Checking Windows", progress: null, buttons: {}, setup: {}, result: {}, settings: {}, snapshots: {names: []}, logs: {}})
  property string pendingToken: ""
  property double pendingAt: 0
  property bool refreshAgain: false
  signal panelRequested()
  signal settingsSaved(int memoryGib, int cores, var windowsScale)
  readonly property string tooltip: ["Lanai", view.label, view.headline, view.cause, view.next, view.notice, view.warning, view.right_click_tooltip].filter(function(s) { return !!s }).join("\n")

  function control(name) { return view.buttons[name] || {show: false, enable: false, label: ""} }
  function token() { return "panel-" + Date.now() + "-" + Math.floor(Math.random() * 1000000) }

  // Skip routine ticks in flight; an action requests exactly one fresh read.
  function refresh(afterAction) {
    if (panelProcess.running || actionProcess.running) {
      if (afterAction === true) refreshAgain = true
      return
    }
    var args = ["timeout", "--signal=KILL", "10", cli, "panel"]
    if (pendingToken) args = args.concat(["--pending", pendingToken, String(pendingAt)])
    panelProcess.command = args
    panelProcess.running = true
  }

  // Commands use literal argv and no deadline. Long work starts a session unit.
  function run(args, longJob) {
    if (actionProcess.running) return
    var now = Math.floor(Date.now() / 1000)
    if (longJob && pendingToken && now - pendingAt < 10) return
    var clickToken = token()
    if (longJob) {
      pendingToken = clickToken
      pendingAt = now
      Quickshell.execDetached([cli, "ui-job", clickToken].concat(args))
      refresh(true)
    } else {
      actionProcess.command = [cli, "ui-run", clickToken].concat(args)
      actionProcess.running = true
    }
  }

  Timer {
    interval: root.panelOpen ? 2000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  onPanelOpenChanged: if (panelOpen) refresh()

  // Quickshell omits the C++ exit-status enum from its lint metadata.
  // qmllint disable signal-handler-parameters
  Process {
    id: panelProcess
    stdout: StdioCollector { id: panelOutput; waitForEnd: true }
    onExited: function(code) {
      if (root.refreshAgain) {
        root.refreshAgain = false
        root.refresh()
        return
      }
      try {
        var reply = JSON.parse(panelOutput.text)
        if (code !== 0 || reply.ok !== true) throw new Error("unreadable view")
        if (reply.pending_ack === root.pendingToken) root.pendingToken = ""
        root.view = reply
      } catch (_) {
        root.view = {label: "Unavailable", headline: "Lanai could not check Windows", cause: "The status check did not finish or its reply could not be read.", next: "Try again in a few seconds, then check the logs if it continues.", progress: null, buttons: {}, setup: {}, result: {}, settings: {}, snapshots: {names: []}, logs: {}}
      }
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    onExited: function(code) {
      try {
        var reply = JSON.parse(actionOutput.text)
        if (reply.panel_requested === true) root.panelRequested()
        if (code === 0 && reply.ok === true && actionProcess.command[3] === "settings")
          root.settingsSaved(Number(actionProcess.command[4]), Number(actionProcess.command[5]),
            reply.windows_scale === undefined ? (actionProcess.command[6] === undefined || actionProcess.command[6] === "auto" ? "auto" : Number(actionProcess.command[6])) : reply.windows_scale)
      } catch (_) { root.panelRequested() }
      root.refresh(true)
    }
  }
  // qmllint enable signal-handler-parameters
}
