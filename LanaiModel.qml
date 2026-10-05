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
  property bool refreshAgain: false
  property var setupReply: ({})
  property var actionReply: ({})
  property var snapshotReply: ({})
  property var settingsReply: ({})
  property var jobError: ({})
  property var launchError: ({})
  property var job: ({active: false})
  property string pendingToken: ""
  property string pendingCommand: ""
  property string seenToken: ""
  property bool jobAttached: false
  property string action: ""
  property bool glyphAction: false
  signal panelRequested()
  property bool autoPaused: false
  property bool automaticJob: false
  property double lastSetupAt: 0
  property double pendingAt: 0
  property var completedSetup: null
  property int memory: 1
  property int cores: 1
  property bool settingsLoaded: false
  property var snapshots: []
  property bool snapshotsAgain: false
  readonly property bool longBusy: pendingToken !== "" || job.active === true
  readonly property bool setupWaiting: SetupCalls.waiting(setupReply)
  readonly property bool automaticWait: automaticJob && setupWaiting
  readonly property bool setupBusy: (pendingToken !== "" && pendingCommand === "setup") || (job.active === true && job.command === "setup")
  readonly property bool busy: actionProcess.running || (longBusy && !automaticWait)
  readonly property bool canOpen: fresh && status.active === true && status.window !== true && status.state !== "stopping" && status.state !== "starting"
  readonly property bool canStart: fresh && status.active === false && status.restore_pending !== true && (status.state === "stopped" || status.state === "failed") && !busy
  readonly property bool canStop: fresh && status.active === true && !actionProcess.running
  readonly property bool canForce: fresh && status.state === "stopping" && status.force_stop === true && !actionProcess.running
  readonly property int pollInterval: panelOpen || status.state === "starting" || status.state === "stopping" ? 2000 : 15000
  readonly property string stateLabel: ({
    "checking": "Checking", "setup-needed": "Setup needed", "not-installed": "Not installed",
    "in-use": "Running under omarchy-windows-vm", "version-mismatch": "Display driver needs an update",
    "starting": "Starting", "running": "Running", "stopping": "Shutting down",
    "stopped": "Stopped", "failed": "Failed"
  })[status.state] || "Status unavailable"
  readonly property string tooltip: "Lanai\n" + stateLabel + "\n" + status.message
    + (status.next ? "\nNext step: " + (status.force_stop === true ? "wait, or open the Lanai panel to force a stop" : status.next) : "")
    + (status.notice ? "\n" + status.notice : "")
    + (status.warning ? "\n" + status.warning : "")
    + (status.logs ? "\nLogs: " + status.logs : "")

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
    if (statusProcess.running) { refreshAgain = true; return }
    statusProcess.command = command(["status"])
    statusProcess.running = true
  }

  function loadSettings() {
    if (settingsProcess.running) return
    settingsProcess.command = command(["settings"])
    settingsProcess.running = true
  }

  function run(args, fromGlyph) {
    if (actionProcess.running) return
    action = args[0]
    glyphAction = fromGlyph === true
    actionReply = {}
    actionProcess.command = command(args)
    actionProcess.running = true
  }

  // Refresh the list without replacing a snapshot or restore's action reply.
  function loadSnapshots() {
    if (snapshotsProcess.running) { snapshotsAgain = true; return }
    snapshotsProcess.command = command(["snapshots"])
    snapshotsProcess.running = true
  }

  // Long operations survive panel/plugin unloading. The helper publishes progress.
  function launch(args, automatic) {
    if (actionProcess.running || longBusy) return
    launchError = {}
    automaticJob = automatic === true
    if (args[0] === "setup" && setupReply.step !== "3") snapshotReply = {}
    if (!automaticJob) { action = args[0]; actionReply = {} }
    autoPaused = false
    if (args[0] === "setup") { lastSetupAt = Date.now(); SetupCalls.record(lastSetupAt) }
    pendingToken = "job-" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
    pendingCommand = args[0]
    pendingAt = Date.now()
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
      jobError = {}
      job = reply
      // Attach to running work, but do not replay a previous session's completion.
      if (!jobAttached) {
        jobAttached = true
        if (job.active !== true && (!pendingToken || job.token !== pendingToken)) seenToken = job.token || ""
      }
      if (pendingToken && job.token === pendingToken) pendingToken = ""
    } else jobError = reply
    if (pendingToken && Date.now() - pendingAt >= 10000 && (reply.ok !== true || job.active !== true)) {
      pendingToken = ""
      autoPaused = true
      launchError = {ok: false, message: "The operation did not start.", next: "try again; see " + stateDir + "/panel-job.log"}
    }
    if (reply.ok !== true) return
    if (job.active === true || !job.reply || job.token === seenToken) return
    seenToken = job.token
    if (job.command === "setup") {
      lastSetupAt = Date.now()
      if (job.reply.ok === false) setupReply = job.reply
      else { completedSetup = job.reply; setupFile.reload() }
    } else {
      action = job.command
      actionReply = job.reply
      if (job.command === "snapshot" && job.reply.ok === true) snapshotReply = job.reply
      if (job.command === "restore" && job.reply.ok === true) setupReply = {}
      if (job.command === "snapshot" || job.command === "restore") loadSnapshots()
    }
    refresh()
  }

  // Only successful wait replies authorize another setup call, at most every 10 s.
  function advanceSetup() {
    if (!fresh || actionProcess.running || longBusy || autoPaused || Date.now() - lastSetupAt < 10000 || !SetupCalls.due(Date.now())) return
    if (SetupCalls.shouldAdvance(setupReply, status)) launch(["setup"], true)
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
    onTriggered: {
      if (root.panelOpen || root.longBusy) root.pollJob()
      root.advanceSetup()
    }
  }

  onPanelOpenChanged: if (panelOpen) { refresh(); loadSettings(); pollJob() }

  // Reads must neither wait for user actions nor replace their results.
  Process {
    id: settingsProcess
    stdout: StdioCollector { id: settingsOutput; waitForEnd: true }
    onExited: function(code) {
      var reply = root.parse(settingsOutput.text)
      if (code !== 0) reply.ok = false
      root.settingsReply = reply
      root.settingsLoaded = code === 0 && reply.ok === true
      if (code === 0 && reply.ok === true) {
        root.memory = reply.memory_gib
        root.cores = reply.cores
        root.settingsLoaded = true
      }
    }
  }

  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    onExited: function(code) {
      if (root.refreshAgain) {
        root.refreshAgain = false
        root.refresh()
        return
      }
      var reply = root.parse(statusOutput.text)
      root.fresh = code === 0 && reply.ok === true
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
      if (root.glyphAction && (root.action === "start" || root.action === "open")
          && (reply.ok !== true || (root.action === "start" && reply.last_run === "forced"))) root.panelRequested()
      if (reply.ok === true && root.action === "settings") {
        root.memory = reply.memory_gib
        root.cores = reply.cores
        root.settingsLoaded = true
        root.settingsReply = reply
      }
      if (reply.ok === true && root.action === "snapshots") root.snapshots = reply.snapshots || []
      if (reply.ok === true && (root.action === "start" || root.action === "stop"))
        root.status = Object.assign({}, root.status, reply, {active: true})
      if (reply.ok === true && root.action === "notice-seen")
        root.status = Object.assign({}, root.status, {notice: null})
      if (root.action !== "settings" && root.action !== "snapshots") root.refresh()
    }
  }

  Process {
    id: snapshotsProcess
    stdout: StdioCollector { id: snapshotsOutput; waitForEnd: true }
    onExited: function(code) {
      if (root.snapshotsAgain) {
        root.snapshotsAgain = false
        root.loadSnapshots()
        return
      }
      var reply = root.parse(snapshotsOutput.text)
      if (code === 0 && reply.ok === true) root.snapshots = reply.snapshots || []
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
