import QtQuick
import Quickshell
import Quickshell.Io
import "SetupCalls.js" as SetupCalls

// One model per bar instance; the CLI job lock also covers other monitors.
Item {
  id: root
  property bool panelOpen: false
  readonly property string cli: Qt.resolvedUrl("bin/lanai").toString().replace(/^file:\/\//, "")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/lanai"
  property var status: ({state: "checking", message: "Checking Windows…", next: ""})
  property bool fresh: false
  property var setupReply: ({})
  property var actionReply: ({})
  property var job: ({active: false})
  property string pendingToken: ""
  property string seenToken: ""
  property bool jobAttached: false
  property string action: ""
  property bool autoPaused: false
  property double lastSetupAt: 0
  property double lastStatusAt: 0
  property double pendingAt: 0
  property var completedSetup: null
  property int memory: 1
  property int cores: 1
  property bool settingsLoaded: false
  property var snapshots: []
  readonly property bool longBusy: pendingToken !== "" || job.active === true
  readonly property bool busy: actionProcess.running || longBusy
  readonly property bool canOpen: fresh && status.active === true && status.window !== true && status.state !== "stopping" && status.state !== "starting"
  readonly property bool canStart: fresh && status.active === false && (status.state === "stopped" || status.state === "failed") && !busy
  readonly property bool canStop: fresh && status.active === true && !actionProcess.running
  readonly property bool canForce: fresh && status.state === "stopping" && status.force_stop === true && !actionProcess.running
  readonly property int pollInterval: panelOpen || status.state === "starting" || status.state === "stopping" ? 2000 : 15000
  readonly property string stateLabel: ({
    "checking": "Checking", "setup-needed": "Setup needed", "not-installed": "Not installed",
    "in-use": "Running under omarchy-windows-vm", "version-mismatch": "Driver version mismatch",
    "starting": "Starting", "running": "Running", "stopping": "Shutting down",
    "stopped": "Stopped", "failed": "Failed"
  })[status.state] || "Status unavailable"
  readonly property string tooltip: "Lanai\n" + stateLabel + "\n" + status.message
    + (status.next ? "\nNext: " + status.next : "")
    + (status.logs ? "\nLogs: " + status.logs : "")
    + (status.state === "failed" ? "\nShut Lanai down, then use omarchy-windows-vm." : "")

  // All ordinary commands have a hard ten-second deadline and use literal argv.
  function command(args) {
    return ["timeout", "--signal=KILL", "10", decodeURIComponent(cli)].concat(args)
  }

  function parse(raw) {
    try { return JSON.parse(raw) } catch (_) {
      return {ok: false, message: "Lanai did not respond, or its reply could not be read.",
        next: "check the logs, then try again", logs: "journalctl --user -u lanai-vm.service -u lanai-client.service"}
    }
  }

  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = command(["status"])
    statusProcess.running = true
  }

  function run(args) {
    if (actionProcess.running) return
    action = args[0]
    actionProcess.command = command(args)
    actionProcess.running = true
  }

  // Long operations survive panel/plugin unloading. The helper publishes progress.
  function launch(args) {
    if (busy) return
    autoPaused = args.indexOf("--window") >= 0 || args.indexOf("--no-window") >= 0
    if (args[0] === "setup") { lastSetupAt = Date.now(); SetupCalls.record(lastSetupAt) }
    pendingToken = "job-" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
    pendingAt = Date.now()
    actionReply = {}
    Quickshell.execDetached([decodeURIComponent(cli), "ui-job", pendingToken].concat(args))
    pollJob()
  }

  function pollJob() {
    if (jobProcess.running) return
    jobProcess.command = command(["ui-job-status"])
    jobProcess.running = true
  }

  // Read setup's atomic reply only for the matching completed job, never on load.
  function acceptJob(reply) {
    if (reply.ok === true) {
      job = reply
      // Attach to running work, but do not replay a previous session's completion.
      if (!jobAttached) {
        jobAttached = true
        if (job.active !== true && (!pendingToken || job.token !== pendingToken)) seenToken = job.token || ""
      }
      if (pendingToken && job.token === pendingToken) pendingToken = ""
    } else actionReply = reply
    if (pendingToken && Date.now() - pendingAt >= 10000 && (reply.ok !== true || job.active !== true)) {
      pendingToken = ""
      actionReply = {ok: false, message: "The operation did not start.", next: "try again; see " + stateDir + "/panel-job.log"}
    }
    if (reply.ok !== true) return
    if (job.active === true || !job.reply || job.token === seenToken) return
    seenToken = job.token
    autoPaused = (job.args || []).indexOf("--window") >= 0 || (job.args || []).indexOf("--no-window") >= 0
    if (job.command === "setup") {
      lastSetupAt = Date.now()
      completedSetup = job.reply
      setupFile.reload()
    } else {
      actionReply = job.reply
      if (job.command === "restore" && job.reply.ok === true) setupReply = {}

    }
    refresh()
  }

  // Only successful wait replies authorize another setup call, at most every 10 s.
  function advanceSetup() {
    if (!fresh || busy || autoPaused || setupReply.ok !== true || Date.now() - lastSetupAt < 10000 || !SetupCalls.due(Date.now())) return
    var waiting = /\bwait\b|once Windows has shut down/i.test(String(setupReply.next || ""))
    if (!waiting) return
    if (setupReply.step === "5" && status.active === false && status.state === "setup-needed") launch(["setup"])
    else if (setupReply.step === "6" && status.active === true && status.state !== "stopping") launch(["setup"])
  }

  Timer {
    interval: root.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // File/job checks are cheap; status keeps its separate 2 s / 15 s cadence.
  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.pollJob(); root.advanceSetup() }
  }

  onPanelOpenChanged: if (panelOpen) { refresh(); run(["settings"]) }

  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    onExited: function(code) {
      var reply = root.parse(statusOutput.text)
      root.fresh = code === 0 && reply.ok === true
      root.lastStatusAt = Date.now()
      if (!root.fresh) reply.state = "failed"
      root.status = reply
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    onExited: function(code) {
      var reply = root.parse(actionOutput.text)
      if (code !== 0) reply.ok = false
      root.actionReply = reply
      if (reply.ok === true && root.action === "settings") {
        root.memory = reply.memory_gib
        root.cores = reply.cores
        root.settingsLoaded = true
      }
      if (reply.ok === true && root.action === "snapshots") root.snapshots = reply.snapshots || []
      if (reply.ok === true && (root.action === "start" || root.action === "stop"))
        root.status = Object.assign({}, root.status, reply, {active: true})
      if (root.action !== "settings" && root.action !== "snapshots") root.refresh()
    }
  }

  Process {
    id: jobProcess
    stdout: StdioCollector { id: jobOutput; waitForEnd: true }
    onExited: function() { root.acceptJob(root.parse(jobOutput.text)) }
  }

  FileView {
    id: setupFile
    path: root.stateDir + "/setup-reply.json"
    printErrors: false
    onLoaded: {
      if (!root.completedSetup) return
      var reply = root.parse(text())
      // A simultaneous outside CLI caller may replace the file. Require agreement.
      if (JSON.stringify(reply) === JSON.stringify(root.completedSetup)) root.setupReply = reply
      else root.setupReply = {ok: false, message: "Setup changed outside this panel.", next: "click Continue setup to check it again"}
      root.completedSetup = null
    }
    onLoadFailed: {
      if (!root.completedSetup) return
      root.setupReply = {ok: false, message: "Lanai could not read the setup result.", next: "try setup again; see " + root.stateDir + "/panel-job.log"}
      root.completedSetup = null
    }
  }
}
