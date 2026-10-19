pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
// Qt 6.12 shadows a bare Color with a built-in, so Color is always read through
// this alias, as the Omarchy shell does.
import qs.Commons as Commons
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
  property bool stopArmed: false
  property string restoreArmed: ""
  property bool setupAgainArmed: false
  property string expandedSection: ""
  property bool moreActionsOpen: false
  property string previousLayout: ""
  property double countdownSeconds: -1
  property double countdownAt: 0
  property double countdownNow: Date.now()
  readonly property double countdownRemaining: Math.max(0, countdownSeconds - Math.max(0, Math.floor((countdownNow - countdownAt) / 1000)))
  readonly property var snapshotItems: root.model.view.snapshots.items || []
  readonly property bool hasMoreActions: root.model.control("force_stop").show === true
    || root.model.control("dismiss_notice").show === true || root.model.control("update_client").show === true
    || (root.model.view.setup.finished === true && setupSection.hasContent)
  property int memoryInput: root.model.view.settings.memory_gib || 1
  property int coresInput: root.model.view.settings.cores || 1
  property var windowsScaleInput: root.model.view.settings.windows_scale === undefined ? "auto" : root.model.view.settings.windows_scale
  // Set by any choice in the scale list, even the entry already shown, and
  // cleared by Reset or panel open: while set, Save settings is a scale
  // save (three arguments); otherwise it saves memory and cores only.
  property bool scaleTouched: false
  property bool scaleDirty: false
  property var savedBaseline: baselineFromView()
  readonly property var settingsLabels: root.model.view.settings.labels || {}
  readonly property bool settingsReadable: !root.model.view.settings.error
    && root.model.view.settings.memory_gib >= 1 && root.model.view.settings.memory_gib <= 512
    && root.model.view.settings.cores >= 1 && root.model.view.settings.cores <= 64
  readonly property bool settingsDirty: scaleDirty || (savedBaseline !== null
    && (memoryInput !== savedBaseline.memory_gib || coresInput !== savedBaseline.cores
      || windowsScaleInput !== savedBaseline.windows_scale))
  readonly property bool settingsSaveable: settingsDirty || scaleTouched || savedBaseline === null
  // The shell supplies bar/theme fields dynamically on QObject groups.
  // qmllint disable missing-property
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // qmllint enable missing-property

  // Only interpolate the backend duration. Polls re-anchor it; opening does not.
  Component.onCompleted: anchorCountdown()
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.countdownSeconds >= 0
    onTriggered: root.countdownNow = Date.now()
  }
  function anchorCountdown() {
    var setup = root.model.view.setup || {}, timing = setup.countdown, now = Date.now()
    countdownNow = now
    countdownAt = now
    countdownSeconds = root.model.view.layout === "setup_verify" && setup.show === true
      && setup.step === "6" && timing
      && typeof timing.started_at === "number" && isFinite(timing.started_at)
      && timing.started_at > 0 && timing.started_at % 1 === 0 && timing.started_at <= Math.floor(now / 1000)
      && typeof timing.limit_seconds === "number" && isFinite(timing.limit_seconds)
      && timing.limit_seconds > 0 && timing.limit_seconds % 1 === 0
      && typeof timing.remaining_seconds === "number" && isFinite(timing.remaining_seconds)
      && timing.remaining_seconds >= 0 && timing.remaining_seconds % 1 === 0
      && timing.remaining_seconds <= timing.limit_seconds ? timing.remaining_seconds : -1
  }

  onOpenedChanged: {
    countdownNow = Date.now()
    if (opened) {
      expandedSection = (root.model.view.sections || {}).default || ""
      previousLayout = root.model.view.layout || ""
      moreActionsOpen = false
      memoryInput = Qt.binding(function() { return root.model.view.settings.memory_gib || 1 })
      coresInput = Qt.binding(function() { return root.model.view.settings.cores || 1 })
      windowsScaleInput = Qt.binding(function() { return root.model.view.settings.windows_scale === undefined ? "auto" : root.model.view.settings.windows_scale })
      scaleTouched = false
      scaleDirty = false
      savedBaseline = baselineFromView()
      root.model.clearCopies()
    } else { stopArmed = false; forceArmed = false; restoreArmed = ""; setupAgainArmed = false; root.model.clickNotice = "" }
  }
  Connections {
    target: root.model
    function onViewChanged() {
      root.anchorCountdown()
      root.savedBaseline = root.baselineFromView()
      if (!root.model.control("stop").show || !root.model.control("stop_confirm").show || !root.model.control("stop").confirm || !root.model.control("stop").enable || !root.model.control("stop_confirm").enable) root.stopArmed = false
      if (!root.model.control("force_confirm").show || !root.model.control("force_stop").show || !root.model.control("force_stop").enable || !root.model.control("force_confirm").enable) root.forceArmed = false
      if (!root.model.control("restore_snapshot").show || !root.model.control("restore_snapshot").enable
          || !root.model.control("restore_confirm").show || !root.model.control("restore_confirm").enable
          || !root.snapshotItems.some(function(item) { return item.name === root.restoreArmed })) root.restoreArmed = ""
      var layout = root.model.view.layout || ""
      if (root.opened && layout === "failed" && root.previousLayout !== layout)
        root.expandedSection = (root.model.view.sections || {}).default || "logs"
      root.previousLayout = layout
      if (!root.model.view.setup.finished) root.setupAgainArmed = false
    }
    function onSettingsSaved(memoryGib: int, cores: int, windowsScale: var) {
      root.memoryInput = memoryGib
      root.coresInput = cores
      root.windowsScaleInput = windowsScale
      root.savedBaseline = {memory_gib: memoryGib, cores: cores, windows_scale: windowsScale}
      root.scaleDirty = false
    }
  }
  // SpinBox edits keep its value binding. Freeze the input that feeds it instead.
  Connections {
    target: memoryField.field
    function onActiveFocusChanged() { if (memoryField.field.activeFocus) root.reveal(memoryField) }
    function onValueModified() { root.detachDrafts(); root.memoryInput = memoryField.field.value }
  }
  Connections {
    target: coresField.field
    function onActiveFocusChanged() { if (coresField.field.activeFocus) root.reveal(coresField) }
    function onValueModified() { root.detachDrafts(); root.coresInput = coresField.field.value }
  }

  function baselineFromView() {
    var baseline = root.model.view.settings.baseline
    if (!baseline || root.model.view.settings.error
        || typeof baseline.memory_gib !== "number" || baseline.memory_gib % 1 !== 0
        || baseline.memory_gib < 1 || baseline.memory_gib > 512
        || typeof baseline.cores !== "number" || baseline.cores % 1 !== 0 || baseline.cores < 1 || baseline.cores > 64
        || !(baseline.windows_scale === "auto" || (typeof baseline.windows_scale === "number"
          && baseline.windows_scale % 1 === 0 && baseline.windows_scale >= 100 && baseline.windows_scale <= 500))) return null
    return baseline
  }
  function detachDrafts() {
    memoryInput = memoryInput
    coresInput = coresInput
    windowsScaleInput = windowsScaleInput
  }
  function resetSettings() {
    if (!root.model.control("save_settings").enable || !settingsReadable || !savedBaseline) return
    memoryInput = savedBaseline.memory_gib
    coresInput = savedBaseline.cores
    windowsScaleInput = savedBaseline.windows_scale
    scaleTouched = false
    scaleDirty = false
  }

  // Keep the keyboard-focused control visible on small screens.
  // The click notice, when shown, covers the bottom (flick.bottomMargin).
  function reveal(item) {
    var y = item.mapToItem(column, 0, 0).y
    var view = flick.height - flick.bottomMargin
    if (y < flick.contentY) flick.contentY = y
    else if (y + item.height > flick.contentY + view)
      flick.contentY = Math.min(Math.max(0, flick.contentHeight + flick.bottomMargin - flick.height), y + item.height - view)
  }

  KeyboardPanel {
    id: popup
    objectName: "panelPopup"
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
        objectName: "panelScroll"
        anchors.fill: parent
        contentWidth: width
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        contentHeight: column.implicitHeight
        // Room below the content while the click notice covers the bottom,
        // so covered lines can scroll into view; the controls never move.
        bottomMargin: clickNoticeBox.visible ? clickNoticeBox.height : 0
        clip: true
        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)
          PanelHero {
            objectName: "windowsHeader"
            title: (root.model.view.header || {}).title || ""
            meta: (root.model.view.header || {}).meta || ""
            detail: (root.model.view.header || {}).badge || ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Item {
                implicitWidth: Style.space(40)
                implicitHeight: Style.space(40)
                Rectangle {
                  x: Style.space(5); y: Style.space(5)
                  width: Style.space(30); height: Style.space(23)
                  color: "transparent"
                  border.color: root.foreground
                  border.width: 1
                  Text {
                    anchors.centerIn: parent
                    text: "L"
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                  }
                }
                Rectangle {
                  x: Style.space(13); y: Style.space(34)
                  width: Style.space(14); height: 1
                  color: root.foreground
                }
              }
            }
          }
          Flow {
            id: setupSteps
            objectName: "setupSteps"
            width: parent.width
            spacing: Style.space(4)
            visible: root.model.view.setup.show === true && root.model.view.setup.finished !== true
            Repeater {
              model: root.model.view.setup.steps || []
              delegate: Column {
                id: setupStep
                required property var modelData
                readonly property string stepState: modelData.state
                objectName: "setupStep-" + modelData.number
                width: (setupSteps.width - setupSteps.spacing * (setupSteps.width < Style.space(360) ? 2 : 5))
                  / (setupSteps.width < Style.space(360) ? 3 : 6)
                spacing: Style.space(4)
                Rectangle {
                  width: parent.width
                  height: Style.space(3)
                  color: setupStep.stepState === "current" ? Commons.Color.accent
                    : Util.alpha(root.foreground, setupStep.stepState === "complete" ? 0.6 : 0.15)
                }
                Note {
                  text: setupStep.modelData.name
                  horizontalAlignment: Text.AlignHCenter
                  color: setupStep.stepState === "current" ? Commons.Color.accent : root.foreground
                  opacity: setupStep.stepState === "pending" ? 0.6 : 1
                  // qmllint disable missing-property
                  font.pixelSize: Style.font.caption
                  // qmllint enable missing-property
                }
              }
            }
          }
          Note { text: root.model.view.headline || "" }
          Note { text: root.model.view.cause || "" }
          Note { text: root.model.view.next || "" }
          Note { text: root.model.view.notice || "" }
          Note { text: root.model.view.warning || "" }
          Note { text: root.model.view.result.client || "" }
          Note { text: root.model.view.setup.show === true ? "" : root.model.view.result.setup || "" }
          Note { text: root.model.control("setup_snapshot").show ? "" : root.model.view.result.snapshots || "" }
          Note { text: (root.model.view.busy || {}).line || "" }
          Note { text: root.model.view.result.launch || "" }
          Note { text: root.stopArmed ? root.model.control("stop_confirm").hint || "" : "" }
          Column {
            objectName: "operationProgress"
            width: parent.width
            spacing: Style.space(6)
            visible: root.model.view.progress != null || ((root.model.view.restore || {}).label || "") !== ""
            Note { objectName: "restoreTarget"; text: (root.model.view.restore || {}).label || "" }
            Note {
              objectName: "imageProgressText"
              text: root.model.view.progress ? root.model.view.progress.label
                + (root.model.view.progress.total > 0 ? ", " + root.model.view.progress.percent + "%" : "") : ""
            }
            QQC.ProgressBar {
              id: imageProgress
              objectName: "imageProgress"
              width: parent.width
              visible: root.model.view.progress != null
              from: 0
              to: 100
              value: root.model.view.progress ? root.model.view.progress.percent : 0
              indeterminate: root.model.view.progress != null && !(root.model.view.progress.total > 0)
              property real busyPosition: 0
              NumberAnimation on busyPosition {
                running: imageProgress.visible && imageProgress.indeterminate
                loops: Animation.Infinite
                from: 0
                to: 1
                duration: 1200
              }
              background: Rectangle { implicitHeight: Style.space(3); color: Util.alpha(root.foreground, 0.15) }
              contentItem: Item {
                implicitHeight: Style.space(3)
                clip: true
                Rectangle {
                  x: imageProgress.indeterminate ? imageProgress.busyPosition * parent.width : 0
                  width: imageProgress.indeterminate ? parent.width / 4 : parent.width * imageProgress.position
                  height: parent.height
                  color: Commons.Color.accent
                }
              }
            }
            Note { text: (root.model.view.restore || {}).warning || "" }
          }
          Flow {
            id: dailyActions
            readonly property real primaryWidth: Math.max(0, width
              - (shutdownAction.visible ? shutdownAction.width + spacing : 0)
              - (moreToggle.visible ? moreToggle.width + spacing : 0))
            objectName: "dailyActions"
            width: parent.width
            spacing: Style.space(6)
            Action { width: dailyActions.primaryWidth; control: "start"; onClicked: root.model.run(["start"], false) }
            Action { width: dailyActions.primaryWidth; control: "open"; onClicked: root.model.run(["open"], false) }
            PanelActionButton {
              id: shutdownAction
              property string control: root.stopArmed ? "stop_confirm" : "stop"
              readonly property var descriptor: root.model.control(control)
              readonly property string text: descriptor.label || ""
              objectName: "shutdownAction"
              iconText: "⏻"
              visible: descriptor.show === true
              enabled: descriptor.enable === true
              tooltipText: text
              Accessible.name: text
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onActiveFocusChanged: if (activeFocus) root.reveal(this)
              onClicked: {
                if (root.model.control("stop").confirm && !root.stopArmed) { root.forceArmed = false; root.stopArmed = true }
                else { root.stopArmed = false; root.model.run(["stop"], false) }
              }
            }
            Action { control: "cancel"; visible: root.stopArmed && descriptor.show; onClicked: root.stopArmed = false }
            PanelActionButton {
              id: moreToggle
              objectName: "moreActionsToggle"
              iconText: "⋯"
              tooltipText: (root.model.view.sections || {}).more || ""
              Accessible.name: tooltipText
              Accessible.expandable: true
              Accessible.expanded: root.moreActionsOpen
              visible: root.hasMoreActions
              focusable: true
              foreground: root.foreground
              onActiveFocusChanged: if (activeFocus) root.reveal(this)
              onClicked: {
                root.moreActionsOpen = !root.moreActionsOpen
                Qt.callLater(function() { root.reveal(dailyActions) })
              }
            }
          }
          Column {
            objectName: "moreActions"
            width: parent.width
            spacing: Style.space(6)
            visible: root.moreActionsOpen
            Action { control: root.forceArmed ? "force_confirm" : "force_stop"; onClicked: {
                if (root.forceArmed) { root.forceArmed = false; root.model.run(["force-stop", "--confirm"], false) }
                else { root.stopArmed = false; root.forceArmed = true }
              }
            }
            Note { text: root.forceArmed ? root.model.control("force_confirm").label || "" : "" }
            Action { control: "cancel"; visible: root.forceArmed && descriptor.show; onClicked: root.forceArmed = false }
            Action { control: "dismiss_notice"; onClicked: root.model.run(["notice-seen"], false) }
            Action { control: "update_client"; onClicked: root.model.run(["build-client"], true) }
          }
          Repeater {
            model: Object.keys(root.model.view.buttons || {}).filter(function(key) {
              var d = root.model.control(key)
              return d.show && !d.enable && d.hint
            })
            delegate: Note { required property string modelData; text: root.model.control(modelData).hint }
          }
          Note { text: root.model.view.result.vm || "" }

          PanelSeparator { visible: setupSection.visible; foreground: root.foreground }
          SetupCard { id: setupSection }

          PanelSeparator { foreground: root.foreground }
          DetailRow { section: "settings" }
          Column {
            objectName: "settingsDetails"
            width: parent.width
            spacing: Style.space(10)
            visible: root.expandedSection === "settings"
            Note { text: root.model.view.settings.error || "" }
            Note { text: root.model.view.settings.line || "" }
            Flow {
              width: parent.width
              spacing: Style.space(12)
              NumberField { id: memoryField; label: root.settingsLabels.memory || ""; from: 1; to: 512; value: root.memoryInput; onActiveFocusChanged: if (activeFocus) root.reveal(this); enabled: root.model.control("save_settings").enable && root.settingsReadable; foreground: root.foreground; fontFamily: root.fontFamily }
              NumberField { id: coresField; label: root.settingsLabels.cores || ""; from: 1; to: 64; value: root.coresInput; onActiveFocusChanged: if (activeFocus) root.reveal(this); enabled: root.model.control("save_settings").enable && root.settingsReadable; foreground: root.foreground; fontFamily: root.fontFamily }
              // The shell's themed dropdown, so it matches the number fields.
              // It works in strings; the setting is "auto" or a whole number.
              // The FocusScope sees focus on the dropdown's inner trigger, so
              // tabbing to it scrolls it into view.
              FocusScope {
                implicitWidth: scaleDropdown.implicitWidth
                implicitHeight: scaleDropdown.implicitHeight
                onActiveFocusChanged: if (activeFocus) root.reveal(this)
                Dropdown {
                  id: scaleDropdown
                  objectName: "windowsScale"
                  anchors.fill: parent
                  focus: true
                  label: root.settingsLabels.scale || ""
                  options: root.model.view.settings.scale_choices || []
                  value: String(root.windowsScaleInput)
                  enabled: root.model.control("save_settings").enable && root.settingsReadable
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  // Picking an option assigns value inside Dropdown, which
                  // breaks the binding; restore it so saves and reopens show.
                  onChanged: function(value) {
                    root.detachDrafts()
                    root.scaleTouched = true
                    root.scaleDirty = true
                    root.windowsScaleInput = value === "auto" ? "auto" : Number(value)
                    scaleDropdown.value = Qt.binding(function() { return String(root.windowsScaleInput) })
                  }
                }
              }
            }
            Note { text: root.model.view.settings.note || "" }
            // On its own line: a Flow aligns tops, so beside the labelled fields
            // the button lined up with their labels, not their inputs.
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Button {
                objectName: "resetSettings"
                text: root.settingsLabels.reset || ""
                visible: root.settingsSaveable
                enabled: root.model.control("save_settings").enable && root.settingsReadable && root.savedBaseline !== null
                focusable: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onActiveFocusChanged: if (activeFocus) root.reveal(this)
                onClicked: root.resetSettings()
              }
              Action {
                control: "save_settings"
                text: (root.settingsSaveable ? root.settingsLabels.save : root.settingsLabels.saved) || ""
                selected: root.settingsSaveable
                enabled: descriptor.enable && root.settingsReadable && root.settingsSaveable
                onClicked: if (enabled) root.model.run(["settings", String(memoryField.field.value), String(coresField.field.value)]
                  .concat(root.scaleTouched ? [String(root.windowsScaleInput)] : []), false)
              }
            }
            Note { text: root.model.view.result.settings || "" }
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.model.view.snapshots.show !== false
            PanelSeparator { foreground: root.foreground }
            DetailRow { section: "snapshots" }
            Column {
              objectName: "snapshotsDetails"
              width: parent.width
              spacing: Style.space(10)
              visible: root.expandedSection === "snapshots"
              Note { text: root.model.view.snapshots.line || "" }
              Note { text: root.model.view.snapshots.error || "" }
              Flow {
                width: parent.width
                spacing: Style.space(6)
                Action { control: "take_snapshot"; onClicked: root.model.run(["snapshot"], true) }
                Action { control: "finish_restore"; onClicked: root.model.run(["restore"], true) }
              }
              Repeater {
                model: root.snapshotItems
                delegate: Column {
                  id: snapshotRow
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(6)
                  Note { text: snapshotRow.modelData.date ? snapshotRow.modelData.date + " · " + snapshotRow.modelData.time : snapshotRow.modelData.label }
                  Action {
                    objectName: "restore-" + snapshotRow.modelData.name
                    control: root.restoreArmed === snapshotRow.modelData.name ? "restore_confirm" : "restore_snapshot"
                    text: root.restoreArmed === snapshotRow.modelData.name ? snapshotRow.modelData.confirm_label : snapshotRow.modelData.restore_label
                    onClicked: {
                      if (root.restoreArmed === snapshotRow.modelData.name) { root.restoreArmed = ""; root.model.run(["restore", snapshotRow.modelData.name], true) }
                      else root.restoreArmed = snapshotRow.modelData.name
                    }
                  }
                  Note { text: root.restoreArmed === snapshotRow.modelData.name ? snapshotRow.modelData.warning : "" }
                }
              }
              Action { objectName: "restoreCancel"; control: "cancel"; visible: root.restoreArmed !== "" && descriptor.show; onClicked: root.restoreArmed = "" }
            }
          }

          PanelSeparator { foreground: root.foreground }
          DetailRow { section: "logs" }
          Column {
            objectName: "logsDetails"
            width: parent.width
            spacing: Style.space(6)
            visible: root.expandedSection === "logs"
            Note { objectName: "copyBusy"; text: root.model.copyingId ? root.model.view.logs.copy_busy || "" : "" }
            Repeater {
              model: root.model.view.logs.rows || []
              delegate: Column {
                id: logRow
                required property var modelData
                width: parent.width
                spacing: Style.space(4)
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Note {
                    width: Style.space(64)
                    anchors.verticalCenter: parent.verticalCenter
                    text: logRow.modelData.label
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                  }
                  Note {
                    width: Math.max(0, parent.width - Style.space(64) - copyButton.width - parent.spacing * 2)
                    anchors.verticalCenter: parent.verticalCenter
                    text: logRow.modelData.display
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                  }
                  PanelActionButton {
                    id: copyButton
                    objectName: "copyLog-" + logRow.modelData.id
                    iconText: "󰆏"
                    tooltipText: root.model.copyingId ? root.model.view.logs.copy_busy || "" : logRow.modelData.copy_label
                    Accessible.name: logRow.modelData.copy_label
                    enabled: root.model.copyingId === ""
                    focusable: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onActiveFocusChanged: if (activeFocus) root.reveal(this)
                    onClicked: root.model.copyLog(logRow.modelData.id)
                  }
                }
                Note { objectName: "copyFeedback-" + logRow.modelData.id; text: root.model.copyFeedback(logRow.modelData.id) }
              }
            }
          }
        }
      }
      // A dropped click's notice, pinned over the bottom of the popup and
      // outside the scrolling content: always in view, and it never moves
      // the controls under it. A click on it dismisses it and reaches no
      // control below.
      Rectangle {
        id: clickNoticeBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.model.clickNotice !== ""
        height: Math.max(clickNote.implicitHeight, clickDismiss.implicitHeight) + 2 * Style.space(8)
        // The popup's background, opaque so covered text never shows
        // through. Commons.Color.popups is a grouped QtObject the lint
        // metadata does not type.
        // qmllint disable missing-property
        color: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g, Commons.Color.popups.background.b, 1)
        // qmllint enable missing-property
        border.color: Commons.Color.accent
        border.width: 1
        Note {
          id: clickNote
          objectName: "clickNotice"
          x: Style.space(8)
          y: Style.space(8)
          width: parent.width - 3 * Style.space(8) - clickDismiss.width
          text: root.model.clickNotice
        }
        MouseArea {
          anchors.fill: parent
          onClicked: root.model.clickNotice = ""
        }
        PanelActionButton {
          id: clickDismiss
          objectName: "clickNoticeDismiss"
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          iconText: "×"
          tooltipText: (root.model.view.sections || {}).dismiss_click_notice || ""
          Accessible.name: tooltipText
          focusable: true
          foreground: root.foreground
          onClicked: root.model.clickNotice = ""
        }
      }
    }
  }

  component SetupCard: BorderSurface {
    objectName: "setupSection"
    readonly property bool hasContent: root.model.view.setup.show === true || root.setupAgainArmed
      || root.model.control("continue_setup").show || root.model.control("reopen_window").show
      || root.model.control("install").show || root.model.control("setup_snapshot").show
      || root.model.control("skip_snapshot").show
      || (!root.model.view.setup.finished && (root.model.control("window").show || root.model.control("no_window").show))
      || (root.model.control("continue_setup").hint || "") !== ""
      || (root.model.view.result.setup || "") !== ""
    visible: hasContent && (root.model.view.setup.finished !== true || root.moreActionsOpen)
    width: parent.width
    implicitHeight: setupColumn.implicitHeight + 2 * setupColumn.y
    color: root.model.view.setup.attention === true
      ? (typeof Style.selectedAccentFill !== "undefined" ? Style.selectedAccentFill : Util.alpha(Commons.Color.accent, 0.10))
      : "transparent"
    borderSpec: root.model.view.setup.attention === true
      ? Border.controlSpec("normal", Commons.Color.accent, Commons.Color.accent) : Border.none()
    radius: Style.cornerRadius
    Column {
      id: setupColumn
      x: Style.space(8)
      y: x
      width: parent.width - 2 * x
      spacing: Style.space(10)
      PanelSectionHeader {
        objectName: "setupTitle"
        width: parent.width
        wrapMode: Text.Wrap
        visible: root.model.view.setup.show === true || root.setupAgainArmed || root.model.control("continue_setup").show
        text: root.model.view.setup.title || ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
      Repeater {
        model: root.model.view.setup.lines || []
        delegate: Note { required property string modelData; text: modelData; visible: root.model.view.setup.show === true }
      }
      Column {
        objectName: "setupChecks"
        width: parent.width
        spacing: Style.space(8)
        visible: root.model.view.setup.show === true && root.model.view.setup.step === "6"
        Repeater {
          model: root.model.view.setup.checks || []
          delegate: Column {
            id: checkRow
            required property var modelData
            readonly property string checkState: modelData.state
            objectName: "setupCheck-" + modelData.id
            width: parent.width
            spacing: Style.space(4)
            Row {
              width: parent.width
              spacing: Style.space(8)
              Note { width: (parent.width - parent.spacing) * 0.6; text: checkRow.modelData.label }
              Note {
                width: (parent.width - parent.spacing) * 0.4
                text: checkRow.modelData.status
                horizontalAlignment: Text.AlignRight
                color: checkRow.checkState === "failed" ? Commons.Color.urgent : root.foreground
              }
            }
            Note { text: checkRow.modelData.detail || "" }
          }
        }
      }
      Column {
        objectName: "setupCountdown"
        width: parent.width
        spacing: Style.space(4)
        visible: root.countdownSeconds >= 0
        Note { text: (root.model.view.setup.countdown || {}).label || "" }
        Note {
          objectName: "setupCountdownDuration"
          text: Math.floor(root.countdownRemaining / 60) + ":" + String(root.countdownRemaining % 60).padStart(2, "0")
        }
      }
      Flow {
        width: parent.width
        spacing: Style.space(6)
        Action { control: "continue_setup"; visible: descriptor.show && !root.setupAgainArmed; onClicked: {
            if (root.model.view.setup.finished) root.setupAgainArmed = true
            else root.model.run(["setup"], true)
          }
        }
        Action { control: "reopen_window"; onClicked: root.model.run(["open"], false) }
        Action { control: "install"; onClicked: root.model.run(["setup-host"], false) }
        Action { control: "setup_snapshot"; onClicked: root.model.run(["snapshot"], true) }
        Action { control: "skip_snapshot"; onClicked: root.model.run(["setup", "--no-snapshot"], true) }
      }
      Note { text: root.model.control("setup_snapshot").show ? root.model.view.result.snapshots || "" : "" }
      Note { text: root.model.control("continue_setup").hint || "" }
      Note { text: root.model.view.setup.again_line || ""; visible: root.setupAgainArmed }
      // After a step 6 time-out with Windows off, the display buttons
      // show directly: they repeat the Windows install, no arming. The
      // time-out's words below name them.
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.model.view.setup.finished || root.setupAgainArmed
        Action { control: "no_window"; onClicked: root.model.run(["setup", "--no-window"], true) }
        Note { text: root.model.control("no_window").show ? root.model.control("no_window").hint || "" : "" }
        Action { control: "window"; onClicked: root.model.run(["setup", "--window"], true) }
        Note { text: root.model.control("window").show ? root.model.control("window").hint || "" : "" }
      }
      Action { control: "cancel"; visible: root.setupAgainArmed && descriptor.show; onClicked: root.setupAgainArmed = false }
      Note { text: root.model.view.setup.show === true ? root.model.view.result.setup || "" : "" }
    }
  }

  component DetailRow: Button {
    id: detailRow
    required property string section
    objectName: section + "Toggle"
    width: parent.width
    leftAlign: true
    text: ((root.model.view.sections || {})[section] || "")
      + (section === "snapshots" ? " · " + (root.model.view.snapshots.count || 0) : "")
      + (section === "settings" && root.settingsDirty ? " · " + (root.settingsLabels.unsaved || "") : "")
      + (root.expandedSection === section ? "  ⌄" : "  ›")
    foreground: root.foreground
    fontFamily: root.fontFamily
    focusable: true
    Accessible.name: (root.model.view.sections || {})[section] || ""
    Accessible.expandable: true
    Accessible.expanded: root.expandedSection === section
    onActiveFocusChanged: if (activeFocus) root.reveal(this)
    onClicked: {
      root.expandedSection = root.expandedSection === section ? "" : section
      Qt.callLater(function() { root.reveal(detailRow) })
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
    objectName: control === root.model.view.primary_action ? "primaryAction" : "action-" + control
    text: descriptor.label
    selected: control === root.model.view.primary_action
    tooltipText: descriptor.hint || ""
    visible: descriptor.show
    enabled: descriptor.enable
    focusable: true
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    opacity: enabled ? 1.0 : 0.4
    onActiveFocusChanged: if (activeFocus) root.reveal(this)
  }
}
