import QtQuick
import Quickshell
import Quickshell.Io

// One view per bar instance. Only this instance's open panel polls quickly.
Item {
  id: root
  property bool panelOpen: false
  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/lanai").toString().replace(/^file:\/\//, ""))
  property var view: ({label: "Checking", headline: "Checking Windows", layout: "daily",
    header: {title: "Windows", meta: "", badge: "Checking"},
    sections: {settings: "Settings", snapshots: "Snapshots", logs: "Logs", more: "More actions", dismiss_click_notice: "Dismiss busy notice", default: ""},
    primary_action: null, bar: {mode: "stopped", percent: null}, restore: {label: "", warning: ""},
    progress: null, buttons: {}, setup: {steps: [], checks: [], countdown: null}, result: {},
    settings: {baseline: null, labels: {}, scale_choices: []}, snapshots: {names: [], items: [], count: 0}, logs: {rows: []}})
  property string pendingToken: ""
  property double pendingAt: 0
  property bool refreshAgain: false
  // Set when run() drops a click because the last action still runs; shown
  // for at least 2 s (clickNoticeAt, ms) and at most 5 s.
  property string clickNotice: ""
  property double clickNoticeAt: 0
  property var copyResults: ({})
  property string copyingId: ""
  property string copyingText: ""
  property bool copyStarted: false
  property int copyGeneration: 0
  property int copyingGeneration: 0
  signal panelRequested()
  signal settingsSaved(int memoryGib, int cores, var windowsScale)
  readonly property string tooltip: ["Lanai", view.label, view.headline, view.cause, view.next, view.notice, view.warning, view.right_click_tooltip].filter(function(s) { return !!s }).join("\n")

  function control(name) { return view.buttons[name] || {show: false, enable: false, label: ""} }
  function token() { return "panel-" + Date.now() + "-" + Math.floor(Math.random() * 1000000) }

  function logRow(id) {
    return (view.logs.rows || []).find(function(row) { return row.id === id })
  }
  function clearCopies() { copyResults = ({}); copyGeneration++ }
  function copyFeedback(id) {
    var result = copyResults[id], row = logRow(id)
    return result && row && result.target === row.copy_text ? result.text : ""
  }
  onViewChanged: {
    var kept = ({})
    Object.keys(copyResults).forEach(function(id) {
      var row = root.logRow(id)
      if (row && row.copy_text === root.copyResults[id].target) kept[id] = root.copyResults[id]
    })
    copyResults = kept
  }
  function copyFinished(success) {
    if (!copyingId) return
    var row = logRow(copyingId), results
    if (copyingGeneration === copyGeneration && row && row.copy_text === copyingText) {
      results = Object.assign({}, copyResults)
      results[copyingId] = {target: copyingText, text: success ? view.logs.copied : view.logs.copy_error}
      copyResults = results
    }
    copyingId = ""
    copyingText = ""
  }
  function copyStopped() {
    var generation = copyingGeneration
    // Failed starts have no exited signal. Let normal exit handling run first.
    Qt.callLater(function() {
      if (root.copyingId && root.copyingGeneration === generation && !copyProcess.running && !root.copyStarted)
        root.copyFinished(false)
    })
  }
  function copyLog(id) {
    var row = logRow(id)
    if (copyingId || !row || typeof row.copy_text !== "string" || !row.copy_text) return
    copyingId = id
    copyingText = row.copy_text
    copyingGeneration = ++copyGeneration
    copyStarted = false
    var results = Object.assign({}, copyResults)
    delete results[id]
    copyResults = results
    copyProcess.stdinEnabled = true
    copyProcess.running = true
    copyStopped()
  }

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
  // A click while the last action runs is dropped, and clickNotice says so.
  function run(args, longJob) {
    var now = Math.floor(Date.now() / 1000)
    if (actionProcess.running || (longJob && pendingToken && now - pendingAt < 10)) {
      clickNotice = "Your previous action is still running. Try again in a moment."
      clickNoticeAt = Date.now()
      clickNoticeTimer.interval = 5000
      clickNoticeTimer.restart()
      return
    }
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
  // A dropped-click notice lasts at most 5 s. A quick action that ends
  // sooner clears it, but not before it has shown 2 s; a dropped long job
  // shows it the full 5 s. Closing the panel or clicking the notice clears
  // it at once.
  Timer {
    id: clickNoticeTimer
    interval: 5000
    onTriggered: root.clickNotice = ""
  }

  // Quickshell omits the C++ exit-status enum from its lint metadata.
  // qmllint disable signal-handler-parameters
  Process {
    id: copyProcess
    command: ["wl-copy"]
    stdinEnabled: true
    onStarted: {
      root.copyStarted = true
      write(root.copyingText)
      stdinEnabled = false
    }
    onExited: function(code, status) { root.copyFinished(code === 0 && status === 0) }
    onRunningChanged: if (!running) root.copyStopped()
  }

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
        root.view = {layout: "failed", header: {title: "Windows", meta: "", badge: "Failed"},
          sections: {settings: "Settings", snapshots: "Snapshots", logs: "Logs", more: "More actions", dismiss_click_notice: "Dismiss busy notice", default: "logs"},
          primary_action: null, bar: {mode: "failed", percent: null}, restore: {label: "", warning: ""},
          label: "Unavailable", headline: "Lanai could not check Windows",
          cause: "The status check did not finish or its reply could not be read.",
          next: "Try again in a few seconds, then check the logs if it continues.",
          progress: null, buttons: {}, setup: {steps: [], checks: [], countdown: null}, result: {},
          settings: {baseline: null, labels: {}, scale_choices: []}, snapshots: {names: [], items: [], count: 0}, logs: {rows: []}}
      }
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    onExited: function(code) {
      if (root.clickNotice !== "") {
        var left = 2000 - (Date.now() - root.clickNoticeAt)
        if (left > 0) {
          clickNoticeTimer.interval = left
          clickNoticeTimer.restart()
        } else root.clickNotice = ""
      }
      try {
        var reply = JSON.parse(actionOutput.text)
        if (reply.panel_requested === true) root.panelRequested()
        if (code === 0 && reply.ok === true && actionProcess.command[3] === "settings")
          root.settingsSaved(Number(reply.memory_gib === undefined ? actionProcess.command[4] : reply.memory_gib),
            Number(reply.cores === undefined ? actionProcess.command[5] : reply.cores),
            reply.windows_scale === undefined ? (actionProcess.command[6] === undefined || actionProcess.command[6] === "auto" ? "auto" : Number(actionProcess.command[6])) : reply.windows_scale)
      } catch (_) { root.panelRequested() }
      root.refresh(true)
    }
  }
  // qmllint enable signal-handler-parameters
}
