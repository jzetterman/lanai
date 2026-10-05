import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Shared shell popup, theme tokens and Tab-focusable controls.
Panel {
  id: root
  moduleName: "io.github.jzetterman.lanai"
  manageIpc: false
  required property LanaiModel model
  property Item anchorItem: null
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
  readonly property var steps: ["Check the Windows install", "Install required software", "Offer a snapshot",
    "Prepare the Windows window", "Install drivers in Windows and shut down", "Restart and check Windows", "Ready"]

  onOpenedChanged: if (!opened) { forceArmed = false; restoreArmed = "" }
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

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root
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
          Note { visible: text !== ""; text: root.model.status.next ? "Next: " + root.model.status.next : "" }
          Note { visible: text !== ""; text: root.model.status.warning || "" }
          Note { visible: text !== ""; text: root.model.status.notice || "" }
          Note { visible: root.model.status.window === true; text: "Windows is open in QEMU's screen. Run setup.cmd there." }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { text: "Start"; enabled: root.model.canStart; onClicked: root.model.run(["start"]) }
            Action { text: "Open window"; visible: root.model.status.window !== true; enabled: root.model.canOpen && !root.model.busy; onClicked: root.model.run(["open"]) }
            Action { text: "Shut down"; enabled: root.model.canStop; onClicked: root.model.run(["stop"]) }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.model.canForce
            Note { text: "Windows has not shut down after 2 minutes. Updates may still be running. A forced stop loses unsaved work." }
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
            visible: root.model.longBusy
            text: "Working… This may take a few minutes.\nDetails: " + root.model.stateDir + "/panel-job.log"
          }
          Note { visible: text !== ""; text: root.model.setupReply.message || "" }
          Note { visible: text !== ""; text: root.model.setupReply.next ? "Next: " + root.model.setupReply.next : "" }
          Note {
            visible: root.model.setupReply.step === "2"
            text: "Software needed: " + (root.model.setupReply.missing || []).join(", ") + "\nInstall command: " + (root.model.setupReply.command || "")
          }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { text: "Continue setup"; enabled: !root.model.busy; onClicked: root.model.launch(["setup"]) }
            Action { text: "Install in a terminal"; visible: root.model.setupReply.step === "2"; enabled: !root.model.busy; onClicked: root.model.run(["setup-host"]) }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.model.setupReply.step === "3" && root.model.status.active === false
            Note { text: "A snapshot saves a copy of Windows. It uses more space as Windows changes. Lanai shows where it is saved and how to delete it. If Lanai cannot take a snapshot, make a backup before continuing." }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Action { text: "Take snapshot"; enabled: !root.model.busy; onClicked: root.model.launch(["snapshot"]) }
              Action { text: "Continue without snapshot"; enabled: !root.model.busy; onClicked: root.model.launch(["setup", "--no-snapshot"]) }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.displayChoices
            Note { text: "Setup stopped before finishing. Use QEMU's screen until the Lanai display driver is installed. After that, use the Looking Glass window." }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Action { text: "Use QEMU's screen"; enabled: !root.model.busy; onClicked: root.model.launch(["setup", "--window"]) }
              Action { text: "Use the Looking Glass window"; enabled: !root.model.busy; onClicked: root.model.launch(["setup", "--no-window"]) }
            }
          }
          Note { visible: root.model.setupReply.step === "5" && root.model.status.active === true; text: "In Windows, open Lanai's setup drive and run setup.cmd. Approve as the same Windows user. Let setup install the drivers and shut Windows down. Using Shut down here does not finish setup." }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.questions
            Note { text: "Does ~/Windows show in Windows Explorer?" }
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
              Action {
                text: "Send answers"
                enabled: root.shareAnswer !== "" && root.scaleAnswer !== "" && !root.model.busy
                onClicked: root.model.launch(["setup", "--share-ok", root.shareAnswer, "--scale-ok", root.scaleAnswer])
              }
            }
          }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Settings"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { text: "Changes apply the next time Windows starts." }
          Flow {
            width: parent.width
            spacing: Style.space(12)
            NumberField { id: memoryField; label: "Memory (GiB)"; from: 1; to: 512; value: root.model.memory; enabled: root.model.settingsLoaded; foreground: root.foreground; fontFamily: root.fontFamily }
            NumberField { id: coresField; label: "CPU cores"; from: 1; to: 64; value: root.model.cores; enabled: root.model.settingsLoaded; foreground: root.foreground; fontFamily: root.fontFamily }
            Action { text: "Save settings"; enabled: root.model.settingsLoaded && !root.model.busy; onClicked: root.model.run(["settings", String(memoryField.field.value), String(coresField.field.value)]) }
          }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Snapshots"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { text: "Shut Windows down in both Lanai and omarchy-windows-vm first. Restoring replaces Windows' current data. Run Lanai setup again afterward." }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { text: "Take snapshot"; enabled: root.model.fresh && root.model.status.active === false && root.model.status.state !== "in-use" && !root.model.busy; onClicked: root.model.launch(["snapshot"]) }
            Action { text: "List snapshots"; enabled: !root.model.busy; onClicked: root.model.run(["snapshots"]) }
            Action { text: "Resume interrupted restore"; enabled: root.model.fresh && root.model.status.active === false && !root.model.busy; onClicked: root.model.launch(["restore"]) }
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

          Note { visible: text !== ""; text: root.model.actionReply.message || "" }
          Note { visible: text !== ""; text: root.model.actionReply.next ? "Next: " + root.model.actionReply.next : "" }
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.model.status.state === "failed" || root.model.status.state === "version-mismatch"
              || root.model.actionReply.ok === false || root.model.setupReply.ok === false
            PanelSectionHeader { text: "Help"; foreground: root.foreground; fontFamily: root.fontFamily }
            Note { text: "Logs: " + (root.model.status.logs || root.model.actionReply.logs || "journalctl --user -u lanai-vm.service -u lanai-client.service") + "\nSetup and snapshot log: " + root.model.stateDir + "/panel-job.log" }
            Note { text: "If the Windows screen is blank, shut Lanai down first. Then use omarchy-windows-vm to open Windows. Never start both together." }
          }
        }
      }
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
    onActiveFocusChanged: if (activeFocus) root.reveal(this)
  }
}
