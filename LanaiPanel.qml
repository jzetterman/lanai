import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "SetupCalls.js" as SetupCalls

// Shared shell popup, theme tokens and Tab-focusable controls.
Panel {
  id: root
  moduleName: "io.github.jzetterman.lanai"
  manageIpc: false
  required property LanaiModel model
  property Item anchorItem: null
  property var hostWidget: null
  property bool forceArmed: false
  property string restoreArmed: ""
  property string shareAnswer: ""
  property string scaleAnswer: ""
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool displayChoices: model.fresh && model.status.active === false
    && (model.status.state === "setup-needed" || model.status.state === "failed")
    && (model.setupReply.choices || []).length > 0
  readonly property bool questions: model.fresh && model.status.active === true
    && model.status.state === "setup-needed" && model.status.window !== true
    && model.setupReply.step === "6" && (model.setupReply.questions || []).length > 0
  readonly property bool setupFinished: !model.setupBusy && ((model.setupReply.ok === true && model.setupReply.step === "7")
    || (model.fresh && model.status.setup_done === true && model.status.state !== "setup-needed"
      && Object.keys(model.setupReply).length === 0))
  readonly property bool setupStopped: model.setupReply.ok === true && model.setupReply.step === "5"
    && model.fresh && model.status.active === false
  readonly property bool waitingForBoot: model.setupWaiting && model.setupReply.step === "6"
    && (!model.setupBusy || model.automaticWait)
  readonly property bool setupBoot: model.setupReply.step === "5" && model.setupReply.ok === true
    && model.status.active === true && !model.setupBusy
  readonly property bool snapshotSaved: model.snapshotReply.ok === true
  readonly property string progressCommand: model.pendingToken !== "" ? model.pendingCommand
    : model.job.active === true ? model.job.command : ""
  readonly property string snapshotProgress: progressCommand === "snapshot"
    ? "Taking a snapshot… This can take several minutes. You can close this panel."
    : progressCommand === "restore"
      ? "Restoring the snapshot… This can take several minutes. Do not start Windows until it finishes." : ""
  readonly property var steps: ["Check the Windows install", "Install required software", "Offer a snapshot",
    "Prepare the Windows window", "Install drivers in Windows and shut down", "Restart and check Windows", "Ready"]

  onOpenedChanged: {
    if (opened) {
      memoryField.field.value = Qt.binding(function() { return root.model.memory })
      coresField.field.value = Qt.binding(function() { return root.model.cores })
    } else { forceArmed = false; restoreArmed = "" }
  }
  Connections {
    target: root.model
    function onCanForceChanged() { if (!root.model.canForce) root.forceArmed = false }
    function onSetupReplyChanged() { root.shareAnswer = ""; root.scaleAnswer = "" }
    function onStatusChanged() { if (root.model.status.active === true) root.restoreArmed = "" }
  }

  Connections {
    target: memoryField.field
    function onActiveFocusChanged() { if (memoryField.field.activeFocus) root.reveal(memoryField) }
  }
  Connections {
    target: coresField.field
    function onActiveFocusChanged() { if (coresField.field.activeFocus) root.reveal(coresField) }
  }

  // Keep a keyboard-focused control visible in a long or small-screen panel.
  function reveal(item) {
    var y = item.mapToItem(column, 0, 0).y
    if (y < flick.contentY) flick.contentY = y
    else if (y + item.height > flick.contentY + flick.height)
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), y + item.height - flick.height)
  }

  function setupNext() {
    var reply = model.setupReply
    if (model.autoPaused || setupBoot || reply.step === "7" || setupStopped || reply.step === "3a" || reply.step === "3" || displayChoices
        || (reply.step === "5" && reply.ok === false)) return ""
    if (reply.step === "2") return "Click Install in a terminal, type your password there, then click Continue setup."
    if (questions) return "Answer both questions, then click Send answers."
    if (waitingForBoot) return ""
    if (model.setupWaiting) return "Lanai checks again by itself every 10 seconds."
    var next = panelNext(reply, "setup")
    return next ? "Next step: " + next : ""
  }

  function panelNext(reply, command) {
    var next = reply.next || ""
    if (command === "setup" && reply.step === "4") return "Click Continue setup to build it again."
    if (reply.message === "The operation was interrupted.") return "Click Continue setup to resume."
    if (/lanai restore/.test(next) || (command === "restore" && reply.ok === false)) return "Click Finish the unfinished restore."
    if (/lanai snapshots/.test(next)) return "Choose a snapshot from the list below."
    if (/run (Lanai )?setup/.test(next)) return "Click Continue setup to try again."
    if (command === "setup" && /setup|journalctl/.test(next)) return "Click Continue setup to try again."
    if (/journalctl/.test(next)) return "Check the logs under Help, then try again."
    return next
  }

  function panelMessage(reply) {
    return (reply.message || "").replace(/\s*\(lanai snapshots lists them\)/g, "")
      .replace(/run lanai restore again(?: to finish it first)?/g, "click Finish the unfinished restore")
      .replace(/Restore another snapshot by name/g, "Choose another snapshot from the list below")
      .replace(/name a snapshot to restore/g, "Choose a snapshot from the list below")
  }

  // The panel has restore buttons and gives deletion guidance without commands.
  function snapshotMessage(reply) {
    return (reply.message || "").replace(/ Restore it with: lanai restore [\s\S]*$/, "")
      .replace(/Delete it with: rm -rf [\s\S]*$/, "To delete it, remove the snapshot folder in your file manager.")
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: focusScope
    contentWidth: fittedContentWidth(Style.space(420))
    contentHeight: fittedContentHeight(column.implicitHeight, Style.space(650))

    FocusScope {
      id: focusScope
      anchors.fill: parent
      Keys.onEscapePressed: root.close()

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          PanelSectionHeader { text: "Lanai"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { text: root.model.stateLabel }
          Note { text: root.model.status.message }
          Note {
            visible: text !== ""
            text: root.setupFinished ? "" : root.model.status.state === "setup-needed"
              ? Object.keys(root.model.setupReply).length === 0
                ? "Click Continue setup to see where setup stands." : "Follow the steps under Setup below."
              : root.model.status.next ? "Next step: " + root.model.status.next : ""
          }
          Note { visible: root.model.status.restore_pending === true; text: "Click Finish the unfinished restore under Snapshots." }
          Note { visible: text !== ""; text: root.model.status.warning || "" }
          Note { visible: text !== ""; text: root.model.status.notice || "" }
          Action { text: "Dismiss"; visible: !!root.model.status.notice; onClicked: root.model.run(["notice-seen"]) }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { text: "Start"; enabled: root.model.canStart; onClicked: root.model.run(["start"]) }
            Action { text: "Open window"; visible: root.model.status.window !== true; enabled: root.model.canOpen && !root.model.busy; onClicked: root.model.run(["open"]) }
            Action { text: "Shut down"; enabled: root.model.canStop; onClicked: root.model.run(["stop"]) }
          }
          ActionResult { commands: ["start", "open", "stop", "force-stop", "notice-seen"] }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.model.canForce
            Note { text: "A forced stop is like pulling the plug: anything unsaved in Windows is lost." }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Action {
                text: root.forceArmed ? "Confirm forced stop" : "Force stop…"
                onClicked: {
                  if (root.forceArmed && root.model.canForce) { root.forceArmed = false; root.model.run(["force-stop", "--confirm"]) }
                  else root.forceArmed = true
                }
              }
              Action { text: "Cancel"; visible: root.forceArmed; onClicked: root.forceArmed = false }
            }
          }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Setup"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { visible: root.model.status.state === "not-installed"; text: "Install Windows with omarchy-windows-vm first. Then click Continue setup." }
          Note { visible: root.setupFinished; text: "Setup is finished." }
          Action { visible: root.setupFinished; text: "Run setup again"; enabled: !root.model.busy && !root.model.longBusy; onClicked: root.model.launch(["setup"]) }
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: !root.setupFinished
            Repeater {
              model: root.steps
              delegate: Note {
                required property string modelData
                required property int index
                text: (index + 1) + ". " + modelData
                  + (parseInt(root.model.setupReply.step || "0", 10) === index + 1 ? " ← current step" : "")
                opacity: parseInt(root.model.setupReply.step || "0", 10) > index + 1 ? 0.6 : 1
              }
            }
            Note {
              visible: root.model.setupBusy && !root.model.automaticWait
              text: "Working… This may take a few minutes.\nDetails: " + root.model.stateDir + "/panel-job.log"
            }
            Note {
              visible: text !== ""
              text: root.model.autoPaused ? "Lanai stopped checking automatically. Click Continue setup to go on."
                : root.setupBoot ? ""
                : root.setupStopped
                ? SetupCalls.shouldAdvance(root.model.setupReply, root.model.status)
                  ? "Windows has shut down. Lanai continues setup in a few seconds." : "Windows has shut down. Click Continue setup."
                : root.model.setupWaiting && root.model.setupReply.step === "6" && root.model.status.active === false
                  ? "Windows is off, so setup cannot finish its checks. Click Continue setup to start Windows again."
                : root.waitingForBoot ? "Waiting for Windows to finish starting. Lanai checks again every 10 seconds."
                : root.model.setupReply.step === "3a" ? "Lanai filled in a missing file in the Windows install. Click Continue setup."
                : root.panelMessage(root.model.setupReply)
            }
            Note { visible: text !== ""; text: root.setupNext() }
            ActionResult { commands: ["setup-host"] }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Action { text: "Continue setup"; visible: !root.displayChoices && (root.model.setupReply.step !== "3" || root.snapshotSaved); enabled: !root.model.busy && (!root.model.longBusy || root.model.automaticWait); onClicked: root.model.launch(["setup"]) }
              Action { text: "Install in a terminal"; visible: root.model.setupReply.step === "2"; enabled: !root.model.busy; onClicked: root.model.run(["setup-host"]) }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.model.setupReply.step === "3" && root.model.status.active === false
              Note { text: "A snapshot saves a copy of Windows. It uses more space as Windows changes. Lanai shows where it is saved and how to delete it. If Lanai cannot take a snapshot, make a backup before continuing." }
              Note { visible: text !== ""; text: root.snapshotProgress }
              Flow {
                width: parent.width
                spacing: Style.space(6)
                visible: !root.snapshotSaved
                Action { text: "Take snapshot"; enabled: !root.model.busy; onClicked: root.model.launch(["snapshot"]) }
                Action { text: "Continue without snapshot"; enabled: !root.model.busy; onClicked: root.model.launch(["setup", "--no-snapshot"]) }
              }
              Note {
                visible: root.snapshotSaved
                text: root.snapshotMessage(root.model.snapshotReply) + "\nClick Continue setup."
              }
              ActionResult { commands: ["snapshot"]; visible: root.model.actionReply.ok !== true }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.displayChoices
              Note { text: "Setup stopped before it finished. Choose where to run setup.cmd next." }
              Column {
                width: parent.width
                spacing: Style.space(6)
                Action { text: "Set up in QEMU's screen"; onClicked: root.model.launch(["setup", "--window"]) }
                Note { text: "Use this the first time, or if the Windows window stayed empty." }
                Action { text: "Set up in the Windows window"; onClicked: root.model.launch(["setup", "--no-window"]) }
                Note { text: "Use this once Lanai's display driver is installed in Windows." }
              }
            }
            Note {
              visible: root.setupBoot
              text: "Windows is running the setup boot. "
                + (root.model.status.window !== true ? "If you cannot see Windows, click Open window. " : "")
                + "In Windows, open File Explorer, open Lanai's setup drive and run setup.cmd. When Windows asks to allow changes, click Yes. Do not sign in as a different user. Setup installs the drivers and shuts Windows down by itself. Shut down in this panel does not finish setup."
            }
            Note { visible: root.model.setupReply.step === "5" && root.model.setupReply.ok === false && root.model.status.active === true; text: "Setup needs another pass. Click Shut down, wait for Windows to stop, then click Continue setup." }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.questions
              Note { text: "In Windows, open File Explorer and select This PC. Do you see a drive with the files from your Linux ~/Windows folder?" }
              Flow {
                width: parent.width
                spacing: Style.space(6)
                Action { text: "Yes"; selected: root.shareAnswer === "yes"; onClicked: root.shareAnswer = "yes" }
                Action { text: "No"; selected: root.shareAnswer === "no"; onClicked: root.shareAnswer = "no" }
              }
              Note { text: "Does text in Windows look the right size?" }
              Flow {
                width: parent.width
                spacing: Style.space(6)
                Action { text: "Yes"; selected: root.scaleAnswer === "yes"; onClicked: root.scaleAnswer = "yes" }
                Action { text: "No"; selected: root.scaleAnswer === "no"; onClicked: root.scaleAnswer = "no" }
              }
              Action {
                text: "Send answers"
                enabled: root.shareAnswer !== "" && root.scaleAnswer !== "" && !root.model.busy
                onClicked: root.model.launch(["setup", "--share-ok", root.shareAnswer, "--scale-ok", root.scaleAnswer])
              }
            }
          }
          Note { visible: text !== ""; text: root.model.jobError.message || "" }
          Note { visible: text !== ""; text: root.model.jobError.next || "" }
          Note { visible: text !== ""; text: root.model.launchError.message || "" }
          Note { visible: text !== ""; text: root.model.launchError.next ? "Next step: " + root.model.launchError.next : "" }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Settings"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { visible: root.model.settingsReply.ok === false; text: root.model.settingsReply.message || "Lanai cannot read its settings file. Repair it, then reopen this panel." }
          Note { text: "Changes apply the next time Windows starts." }
          Flow {
            width: parent.width
            spacing: Style.space(12)
            NumberField { id: memoryField; label: "Memory (GiB)"; from: 1; to: 512; value: root.model.memory; enabled: root.model.settingsLoaded; foreground: root.foreground; fontFamily: root.fontFamily }
            NumberField { id: coresField; label: "CPU cores"; from: 1; to: 64; value: root.model.cores; enabled: root.model.settingsLoaded; foreground: root.foreground; fontFamily: root.fontFamily }
            Action { text: "Save settings"; enabled: root.model.settingsLoaded && !root.model.busy; onClicked: root.model.run(["settings", String(memoryField.field.value), String(coresField.field.value)]) }
          }
          ActionResult { commands: ["settings"]; successMessage: "Saved." }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Snapshots"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { text: "Restoring replaces Windows with the snapshot. Anything saved in Windows since then is lost. Shut Windows down in both Lanai and omarchy-windows-vm first, and run Lanai setup again afterward." }
          Note { visible: text !== ""; text: root.snapshotProgress }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { text: "Take snapshot"; visible: root.model.setupReply.step !== "3"; enabled: root.model.fresh && root.model.status.active === false && root.model.status.state !== "in-use" && !root.model.busy; onClicked: root.model.launch(["snapshot"]) }
            Action { text: "List snapshots"; enabled: !root.model.busy; onClicked: root.model.run(["snapshots"]) }
            Action { text: "Finish the unfinished restore"; visible: root.model.status.restore_pending === true && root.model.status.state !== "in-use"; enabled: root.model.fresh && root.model.status.active === false && !root.model.busy; onClicked: root.model.launch(["restore"]) }
          }
          Repeater {
            model: root.model.snapshots
            delegate: Action {
              required property string modelData
              readonly property string snapshotName: modelData.split("/").pop()
              text: root.restoreArmed === modelData ? "Confirm restore " + snapshotName : "Restore " + snapshotName + "…"
              tooltipText: modelData
              enabled: root.model.fresh && root.model.status.active === false && root.model.status.state !== "in-use" && !root.model.busy
              onClicked: {
                if (root.restoreArmed === modelData) { root.restoreArmed = ""; root.model.launch(["restore", snapshotName]) }
                else root.restoreArmed = modelData
              }
            }
          }
          Action { text: "Cancel restore"; visible: root.restoreArmed !== ""; onClicked: root.restoreArmed = "" }
          Note { visible: root.model.action === "snapshots" && root.model.actionReply.ok === true && root.model.snapshots.length === 0; text: "No snapshots yet." }

          ActionResult { commands: ["snapshot", "snapshots", "restore"]; visible: root.model.setupReply.step !== "3" || root.model.action !== "snapshot" }
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.model.status.state === "failed" || (root.model.setupReply.ok === false
              && root.model.setupReply.step !== "2" && root.model.setupReply.step !== "3")
              || (root.model.actionReply.ok === false && (root.model.action === "start" || root.model.action === "open"))
            PanelSectionHeader { text: "Help"; foreground: root.foreground; fontFamily: root.fontFamily }
            Note { text: "Logs: " + (root.model.status.logs || "journalctl --user -u lanai-vm -u lanai-client") + "\nSetup and snapshot log: " + root.model.stateDir + "/panel-job.log" }
            Note { text: "If the Windows screen is blank, shut Lanai down first. Then use omarchy-windows-vm to open Windows. Never start both together." }
          }
        }
      }
    }
  }

  component ActionResult: Column {
    required property var commands
    property string successMessage: ""
    readonly property bool showReply: commands.indexOf(root.model.action) >= 0
      && (["start", "open", "stop", "notice-seen"].indexOf(root.model.action) < 0
        || root.model.actionReply.ok === false
        || (root.model.action === "start" && root.model.actionReply.network === false))
    width: parent.width
    spacing: Style.space(6)
    Note {
      visible: text !== ""
      text: !showReply ? ""
        : root.model.action === "snapshot" && root.model.actionReply.ok === true ? root.snapshotMessage(root.model.actionReply)
        : root.model.action === "snapshots" && root.model.actionReply.ok === true && root.model.snapshots.length === 0 ? ""
        : successMessage && root.model.actionReply.ok === true ? successMessage : root.panelMessage(root.model.actionReply)
    }
    Note {
      visible: text !== ""
      text: showReply && root.panelNext(root.model.actionReply, root.model.action)
        ? "Next step: " + root.panelNext(root.model.actionReply, root.model.action) : ""
    }
  }

  // All dynamic text, including driver versions and logs, stays plain text.
  component Note: Text {
    width: parent.width
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // Shell buttons provide themed focus rings and Enter/Space activation.
  component Action: Button {
    focusable: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    enabled: !root.model.busy
    opacity: enabled ? 1.0 : 0.4
    onActiveFocusChanged: if (activeFocus) root.reveal(this)
  }
}
