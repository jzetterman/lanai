pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Backend fields decide all guidance and controls. Only unsaved input lives here.
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
  property bool setupAgainArmed: false
  property int memoryInput: root.model.view.settings.memory_gib || 1
  property int coresInput: root.model.view.settings.cores || 1
  // The shell supplies bar/theme fields dynamically on QObject groups.
  // qmllint disable missing-property
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // qmllint enable missing-property

  onOpenedChanged: {
    if (opened) {
      memoryInput = Qt.binding(function() { return root.model.view.settings.memory_gib || 1 })
      coresInput = Qt.binding(function() { return root.model.view.settings.cores || 1 })
    } else { forceArmed = false; restoreArmed = ""; setupAgainArmed = false }
  }
  Connections {
    target: root.model
    function onViewChanged() {
      if (!root.model.control("force_stop").show) root.forceArmed = false
      if (!root.model.control("restore_snapshot").enable) root.restoreArmed = ""
      if (!root.model.control("send_answers").show) { root.shareAnswer = ""; root.scaleAnswer = "" }
      if (!root.model.view.setup.finished) root.setupAgainArmed = false
    }
    function onSettingsSaved(memoryGib: int, cores: int) {
      root.memoryInput = memoryGib
      root.coresInput = cores
    }
  }
  // SpinBox edits keep its value binding. Freeze the input that feeds it instead.
  Connections {
    target: memoryField.field
    function onValueModified() { root.memoryInput = memoryField.field.value }
  }
  Connections {
    target: coresField.field
    function onValueModified() { root.coresInput = coresField.field.value }
  }

  // Keep the keyboard-focused control visible on small screens.
  function reveal(item) {
    var y = item.mapToItem(column, 0, 0).y
    if (y < flick.contentY) flick.contentY = y
    else if (y + item.height > flick.contentY + flick.height)
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), y + item.height - flick.height)
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
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        contentHeight: column.implicitHeight
        clip: true
        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)
          PanelSectionHeader { text: root.model.view.headline || ""; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { text: root.model.view.cause || "" }
          Note { text: root.model.view.next || "" }
          Note { text: root.model.view.notice || "" }
          Note { text: root.model.view.warning || "" }
          Note { text: (root.model.view.busy || {}).line || "" }
          Note { text: root.model.view.result.launch || "" }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { control: "start"; onClicked: root.model.run(["start"], false) }
            Action { control: "open"; onClicked: root.model.run(["open"], false) }
            Action { control: "stop"; onClicked: root.model.run(["stop"], false) }
            Action { control: root.forceArmed ? "force_confirm" : "force_stop"; onClicked: {
                if (root.forceArmed) { root.forceArmed = false; root.model.run(["force-stop", "--confirm"], false) }
                else root.forceArmed = true
              }
            }
            Action { control: "cancel"; visible: root.forceArmed && descriptor.show; onClicked: root.forceArmed = false }
            Action { control: "dismiss_notice"; onClicked: root.model.run(["notice-seen"], false) }
          }
          Note { text: root.model.view.result.vm || "" }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { visible: root.model.view.setup.show === true || root.setupAgainArmed || root.model.control("continue_setup").show; text: "Setup"; foreground: root.foreground; fontFamily: root.fontFamily }
          Repeater {
            model: root.model.view.setup.lines || []
            delegate: Note { required property string modelData; text: modelData; visible: root.model.view.setup.show === true }
          }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { control: "continue_setup"; visible: descriptor.show && !root.setupAgainArmed; onClicked: {
                if (root.model.view.setup.finished) root.setupAgainArmed = true
                else root.model.run(["setup"], true)
              }
            }
            Action { control: "install"; onClicked: root.model.run(["setup-host"], false) }
            Action { control: "setup_snapshot"; onClicked: root.model.run(["snapshot"], true) }
            Action { control: "skip_snapshot"; onClicked: root.model.run(["setup", "--no-snapshot"], true) }
          }
          Note { text: root.model.control("setup_snapshot").show ? root.model.view.result.snapshots || "" : "" }
          Note { text: root.model.control("continue_setup").hint || "" }
          Note { text: root.model.view.setup.again_line || ""; visible: root.setupAgainArmed }
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.model.view.setup.finished || root.setupAgainArmed
            Action { control: "no_window"; onClicked: root.model.run(["setup", "--no-window"], true) }
            Note { text: root.model.control("no_window").show ? root.model.control("no_window").hint || "" : "" }
            Action { control: "window"; onClicked: root.model.run(["setup", "--window"], true) }
            Note { text: root.model.control("window").show ? root.model.control("window").hint || "" : "" }
          }
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.model.control("send_answers").show
            Note { text: root.model.view.setup.share_question || "" }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Action { control: "answer_yes"; selected: root.shareAnswer === "yes"; onClicked: root.shareAnswer = "yes" }
              Action { control: "answer_no"; selected: root.shareAnswer === "no"; onClicked: root.shareAnswer = "no" }
            }
            Note { text: root.model.view.setup.scale_question || "" }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Action { control: "answer_yes"; selected: root.scaleAnswer === "yes"; onClicked: root.scaleAnswer = "yes" }
              Action { control: "answer_no"; selected: root.scaleAnswer === "no"; onClicked: root.scaleAnswer = "no" }
            }
            Action {
              control: "send_answers"
              enabled: descriptor.enable && root.shareAnswer !== "" && root.scaleAnswer !== ""
              onClicked: root.model.run(["setup", "--share-ok", root.shareAnswer, "--scale-ok", root.scaleAnswer], true)
            }
          }
          Action { control: "cancel"; visible: root.setupAgainArmed && descriptor.show; onClicked: root.setupAgainArmed = false }
          Note { text: root.model.view.result.setup || "" }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Settings"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { text: root.model.view.settings.error || "" }
          Note { text: root.model.view.settings.line || "" }
          Flow {
            width: parent.width
            spacing: Style.space(12)
            NumberField { id: memoryField; label: "Memory (GiB)"; from: 1; to: 512; value: root.memoryInput; enabled: root.model.control("save_settings").enable; foreground: root.foreground; fontFamily: root.fontFamily }
            NumberField { id: coresField; label: "CPU cores"; from: 1; to: 64; value: root.coresInput; enabled: root.model.control("save_settings").enable; foreground: root.foreground; fontFamily: root.fontFamily }
            Action { control: "save_settings"; onClicked: root.model.run(["settings", String(memoryField.field.value), String(coresField.field.value)], false) }
          }
          Note { text: root.model.view.result.settings || "" }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Snapshots"; foreground: root.foreground; fontFamily: root.fontFamily }
          Note { text: root.model.view.snapshots.line || "" }
          Note { text: root.model.view.snapshots.error || "" }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Action { control: "take_snapshot"; onClicked: root.model.run(["snapshot"], true) }
            Action { control: "finish_restore"; onClicked: root.model.run(["restore"], true) }
          }
          Repeater {
            model: root.model.view.snapshots.names || []
            delegate: Action {
              required property string modelData
              control: root.restoreArmed === modelData ? "restore_confirm" : "restore_snapshot"
              text: (descriptor.labels || {})[modelData] || descriptor.label
              onClicked: {
                if (root.restoreArmed === modelData) { root.restoreArmed = ""; root.model.run(["restore", modelData], true) }
                else root.restoreArmed = modelData
              }
            }
          }
          Action { control: "cancel"; visible: root.restoreArmed !== "" && descriptor.show; onClicked: root.restoreArmed = "" }
          Note { text: root.model.view.result.snapshots || "" }

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader { text: "Logs"; foreground: root.foreground; fontFamily: root.fontFamily }
          Repeater {
            model: [root.model.view.logs.vm, root.model.view.logs.client, root.model.view.logs.job, root.model.view.logs.command]
            delegate: Note { required property var modelData; text: modelData || "" }
          }
        }
      }
    }
  }

  component Note: Text {
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: root.foreground
    font.family: root.fontFamily
    // qmllint disable missing-property
    font.pixelSize: Style.font.bodySmall
    // qmllint enable missing-property
  }

  component Action: Button {
    required property string control
    readonly property var descriptor: root.model.control(control)
    text: descriptor.label
    visible: descriptor.show
    enabled: descriptor.enable
    focusable: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    opacity: enabled ? 1.0 : 0.4
    onActiveFocusChanged: if (activeFocus) root.reveal(this)
  }
}
