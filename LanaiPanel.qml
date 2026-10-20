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
  property string deleteArmed: ""
  property bool snapshotDetailsOpen: false
  property bool setupAgainArmed: false
  property string expandedSection: ""
  property bool moreActionsOpen: false
  property string previousDefaultSection: ""
  property double countdownSeconds: -1
  property double countdownAt: 0
  property double countdownNow: Date.now()
  readonly property double countdownRemaining: Math.max(0, countdownSeconds - Math.max(0, Math.floor((countdownNow - countdownAt) / 1000)))
  readonly property var snapshotItems: root.model.view.snapshots.items || []
  readonly property var snapshotSaved: root.model.view.snapshots.saved || {}
  // Hides the status lines and disabled-action hints where the badge,
  // buttons, or a running restore's target and warning already say it.
  readonly property bool quietMain: (root.model.view.layout === "daily"
      && (root.model.view.state === "running" || root.model.view.state === "stopped"))
    || (root.model.view.restore || {}).active === true
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
  property bool memoryTextEdited: false
  property bool coresTextEdited: false
  readonly property bool numberTextDirty: (memoryTextEdited && numberTextChanged(memoryField.field))
    || (coresTextEdited && numberTextChanged(coresField.field))
  property var savedBaseline: baselineFromView()
  readonly property var settingsLabels: root.model.view.settings.labels || {}
  readonly property bool settingsReadable: !root.model.view.settings.error
    && root.model.view.settings.memory_gib >= 1 && root.model.view.settings.memory_gib <= 512
    && root.model.view.settings.cores >= 1 && root.model.view.settings.cores <= 64
  readonly property bool settingsDirty: scaleDirty || numberTextDirty || (savedBaseline !== null
    && (memoryInput !== savedBaseline.memory_gib || coresInput !== savedBaseline.cores
      || windowsScaleInput !== savedBaseline.windows_scale))
  readonly property bool settingsSaveable: settingsDirty || scaleTouched || savedBaseline === null
  // The shell supplies bar/theme fields dynamically on QObject groups.
  // qmllint disable missing-property
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // qmllint enable missing-property

  // Each snapshot name field's draft, its last launch and the backend's
  // refusal of it. They live here so polls, collapsed sections and failed
  // jobs keep them.
  NameDraft { id: dailyName }
  NameDraft { id: setupName }

  // Take a snapshot with a name field's exact text. Enter calls this too, so
  // it starts only while the adjacent action is shown and enabled.
  function takeSnapshot(draft: NameDraft, control: string) {
    var action = root.model.control(control)
    if (action.show !== true || action.enable !== true) return
    var text = draft.text, token = root.model.run(["snapshot", text], true)
    if (token === "") return
    draft.sentToken = token
    draft.sentText = text
    draft.error = ""
  }
  // Give the latest snapshot job to the field that launched it: a name
  // refusal shows beside that field, and success clears an unchanged draft.
  function settleSnapshotJob(draft: NameDraft) {
    var job = (root.model.view.snapshots || {}).job
    if (!job || draft.sentToken === "" || job.token !== draft.sentToken) return
    if (job.reason === "invalid-label") draft.error = job.message || ""
    else if (job.ended === true && job.ok === true) {
      if (draft.text === draft.sentText) draft.text = ""
      draft.sentToken = ""
    }
  }

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
      previousDefaultSection = expandedSection
      moreActionsOpen = false
      snapshotDetailsOpen = false
      memoryInput = Qt.binding(function() { return root.model.view.settings.memory_gib || 1 })
      coresInput = Qt.binding(function() { return root.model.view.settings.cores || 1 })
      windowsScaleInput = Qt.binding(function() { return root.model.view.settings.windows_scale === undefined ? "auto" : root.model.view.settings.windows_scale })
      scaleTouched = false
      scaleDirty = false
      root.resetNumberText()
      savedBaseline = baselineFromView()
      root.model.clearCopies()
    } else { stopArmed = false; forceArmed = false; restoreArmed = ""; deleteArmed = ""; setupAgainArmed = false; root.model.clickNotice = "" }
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
      if (!root.model.control("delete_snapshot").show || !root.model.control("delete_snapshot").enable
          || !root.model.control("delete_confirm").show || !root.model.control("delete_confirm").enable
          || !root.snapshotItems.some(function(item) { return item.name === root.deleteArmed })) root.deleteArmed = ""
      var section = (root.model.view.sections || {}).default || (root.model.view.layout === "failed" ? "logs" : "")
      if (root.opened && section !== "" && root.previousDefaultSection !== section)
        root.expandedSection = section
      root.previousDefaultSection = section
      if (!root.model.view.setup.finished) root.setupAgainArmed = false
      if (!root.model.view.snapshots.saved) root.snapshotDetailsOpen = false
      root.settleSnapshotJob(dailyName)
      root.settleSnapshotJob(setupName)
    }
    function onSettingsSaved(memoryGib: int, cores: int, windowsScale: var) {
      root.memoryInput = memoryGib
      root.coresInput = cores
      root.windowsScaleInput = windowsScale
      root.savedBaseline = {memory_gib: memoryGib, cores: cores, windows_scale: windowsScale}
      root.scaleDirty = false
      root.resetNumberText()
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
  // The installed SpinBox commits typed text only on Enter or focus loss.
  // Detach drafts immediately so a poll cannot replace pending input.
  Connections {
    target: memoryField.field.contentItem
    function onTextEdited() { root.detachDrafts(); root.memoryTextEdited = true }
  }
  Connections {
    target: coresField.field.contentItem
    function onTextEdited() { root.detachDrafts(); root.coresTextEdited = true }
  }

  function numberTextChanged(field) {
    return field.contentItem.text !== field.textFromValue(field.value, field.locale)
  }
  function resetNumberText() {
    memoryTextEdited = false
    coresTextEdited = false
    // The installed NumberField uses TextInput; Qt exposes contentItem as Item.
    // qmllint disable missing-property
    memoryField.field.contentItem.text = Qt.binding(function() { return memoryField.field.textFromValue(memoryField.field.value, memoryField.field.locale) })
    coresField.field.contentItem.text = Qt.binding(function() { return coresField.field.textFromValue(coresField.field.value, coresField.field.locale) })
    // qmllint enable missing-property
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
    root.resetNumberText()
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
          Note { text: root.quietMain ? "" : root.model.view.headline || "" }
          Note { text: root.quietMain ? "" : root.model.view.cause || "" }
          Note { text: root.quietMain ? "" : root.model.view.next || "" }
          Note { text: root.model.view.notice || "" }
          Note { text: root.model.view.warning || "" }
          Note { text: root.model.view.result.client || "" }
          Note { text: root.model.view.setup.show === true ? "" : root.model.view.result.setup || "" }
          // Successful daily snapshot details belong with the snapshot list.
          // Failed operations use the Failed layout and keep their result in view.
          Note { text: root.model.control("setup_snapshot").show || root.model.view.layout === "daily"
            ? "" : root.model.view.result.snapshots || "" }
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
                running: imageProgress.visible && imageProgress.indeterminate && duration > 0
                loops: Animation.Infinite
                from: 0
                to: 1
                duration: Style.duration(1200)
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
            model: root.quietMain ? [] : Object.keys(root.model.view.buttons || {}).filter(function(key) {
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
                onClicked: if (enabled) {
                  // Commit pending SpinBox text before reading its value.
                  forceActiveFocus()
                  root.model.run(["settings", String(memoryField.field.value), String(coresField.field.value)]
                    .concat(root.scaleTouched ? [String(root.windowsScaleInput)] : []), false)
                }
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
              NameField {
                name: "snapshotName"
                accessibleName: "Snapshot name (optional)"
                draft: dailyName
                actionControl: "take_snapshot"
              }
              Item {
                id: snapshotActions
                objectName: "snapshotActions"
                width: parent.width
                readonly property real gap: Style.space(6)
                readonly property bool wrap: snapshotDetailsButton.visible && takeSnapshotAction.visible
                  && snapshotDetailsButton.implicitWidth + takeSnapshotAction.implicitWidth + gap > width
                visible: (root.model.view.layout === "daily" && !!root.model.view.snapshots.saved)
                  || root.model.control("take_snapshot").show
                height: wrap ? snapshotDetailsButton.height + gap + takeSnapshotAction.height
                  : Math.max(snapshotDetailsButton.visible ? snapshotDetailsButton.height : 0,
                    takeSnapshotAction.visible ? takeSnapshotAction.height : 0)
                Button {
                  id: snapshotDetailsButton
                  objectName: "snapshotLocationToggle"
                  width: Math.min(implicitWidth, parent.width)
                  y: snapshotActions.wrap ? 0 : (parent.height - height) / 2
                  text: root.snapshotDetailsOpen ? root.snapshotSaved.hide_label || "" : root.snapshotSaved.show_label || ""
                  visible: root.model.view.layout === "daily" && !!root.model.view.snapshots.saved
                  bordered: true
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Accessible.name: text
                  Accessible.expandable: true
                  Accessible.expanded: root.snapshotDetailsOpen
                  onActiveFocusChanged: if (activeFocus) root.reveal(this)
                  onClicked: root.snapshotDetailsOpen = !root.snapshotDetailsOpen
                }
                Action {
                  id: takeSnapshotAction
                  control: "take_snapshot"
                  width: Math.min(implicitWidth, parent.width)
                  x: Math.max(0, parent.width - width)
                  y: snapshotActions.wrap ? snapshotDetailsButton.height + snapshotActions.gap : (parent.height - height) / 2
                  onClicked: root.takeSnapshot(dailyName, "take_snapshot")
                }
              }
              Item {
                id: snapshotPathRow
                objectName: "snapshotPathRow"
                width: parent.width
                visible: root.model.view.layout === "daily" && !!root.model.view.snapshots.saved && root.snapshotDetailsOpen
                height: Math.max(snapshotPathText.implicitHeight, snapshotCopyButton.height)
                Note {
                  id: snapshotPathText
                  objectName: "snapshotPathText"
                  width: Math.min(implicitWidth, Math.max(0, parent.width - snapshotCopyButton.width - Style.space(6)))
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.snapshotSaved.path_line || ""
                }
                PanelActionButton {
                  id: snapshotCopyButton
                  objectName: "copySnapshotPath"
                  x: snapshotPathText.width + Style.space(6)
                  anchors.bottom: parent.bottom
                  iconText: "󰆏"
                  tooltipText: root.model.copyingId ? root.model.view.logs.copy_busy || "" : root.snapshotSaved.copy_label || ""
                  Accessible.name: root.snapshotSaved.copy_label || ""
                  enabled: root.model.copyingId === ""
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onActiveFocusChanged: if (activeFocus) root.reveal(this)
                  onClicked: root.model.copySnapshotPath()
                }
              }
              Note { objectName: "copySnapshotFeedback"; text: snapshotPathRow.visible ? root.model.copyFeedback("snapshot") : "" }
              Note { objectName: "snapshotAdvice"; text: snapshotPathRow.visible ? root.snapshotSaved.advice || "" : "" }
              Note { text: root.model.view.layout === "daily" && !root.model.view.snapshots.saved
                ? root.model.view.result.snapshots || "" : "" }
              Action { control: "finish_restore"; width: Math.min(implicitWidth, parent.width)
                onClicked: root.model.run(["restore"], true) }
              Repeater {
                model: root.snapshotItems
                delegate: Column {
                  id: snapshotRow
                  required property var modelData
                  readonly property bool armed: root.restoreArmed === modelData.name
                  readonly property bool deleting: root.deleteArmed === modelData.name
                  width: parent.width
                  spacing: Style.space(6)
                  // The saved name, when there is one, wraps above its date.
                  Note { objectName: "snapshotLabel-" + snapshotRow.modelData.name; text: snapshotRow.modelData.user_label || ""
                    font.weight: Font.DemiBold }
                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    Item {
                      id: snapshotDateCell
                      width: snapshotRow.armed || snapshotRow.deleting ? parent.width
                        : Math.max(0, parent.width - restoreCell.width - parent.spacing)
                      height: snapshotRow.armed || snapshotRow.deleting ? snapshotDate.implicitHeight
                        : Math.max(snapshotDate.implicitHeight, restoreButton.implicitHeight, deleteButton.implicitHeight)
                      Note {
                        id: snapshotDate
                        width: parent.width
                        anchors.verticalCenter: parent.verticalCenter
                        text: snapshotRow.modelData.date ? snapshotRow.modelData.date + " · " + snapshotRow.modelData.time : snapshotRow.modelData.label
                      }
                    }
                    Item {
                      id: restoreCell
                      width: Math.min(parent.width, (deleteButton.visible ? deleteButton.implicitWidth : 0)
                        + (deleteButton.visible && restoreButton.visible ? Style.space(6) : 0)
                        + (restoreButton.visible ? restoreButton.implicitWidth : 0))
                      height: snapshotRow.armed || snapshotRow.deleting
                        ? Math.max(restoreButton.implicitHeight, deleteButton.implicitHeight) : snapshotDateCell.height
                      Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)
                        Action {
                          id: deleteButton
                          objectName: "delete-" + snapshotRow.modelData.name
                          width: Math.min(implicitWidth, restoreCell.width)
                          control: snapshotRow.deleting ? "delete_confirm" : "delete_snapshot"
                          text: snapshotRow.deleting ? "Delete snapshot" : "Delete"
                          Accessible.name: snapshotRow.deleting ? snapshotRow.modelData.delete_confirm_label : snapshotRow.modelData.delete_label
                          visible: !snapshotRow.armed && descriptor.show
                          onClicked: {
                            if (snapshotRow.deleting) { root.deleteArmed = ""; root.model.run(["delete-snapshot", snapshotRow.modelData.name], true) }
                            else { root.restoreArmed = ""; root.deleteArmed = snapshotRow.modelData.name }
                          }
                        }
                        Action {
                          id: restoreButton
                          objectName: "restore-" + snapshotRow.modelData.name
                          width: Math.min(implicitWidth, restoreCell.width)
                          control: snapshotRow.armed ? "restore_confirm" : "restore_snapshot"
                          // The full confirmation wording is the note below the row,
                          // as it is for Delete.
                          text: snapshotRow.armed ? "Restore now" : "Restore"
                          Accessible.name: snapshotRow.armed ? snapshotRow.modelData.confirm_label : snapshotRow.modelData.restore_label
                          visible: !snapshotRow.deleting && descriptor.show
                          onClicked: {
                            if (snapshotRow.armed) { root.restoreArmed = ""; root.model.run(["restore", snapshotRow.modelData.name], true) }
                            else { root.deleteArmed = ""; root.restoreArmed = snapshotRow.modelData.name }
                          }
                        }
                      }
                    }
                  }
                  Note { objectName: "restoreConfirm-" + snapshotRow.modelData.name; text: snapshotRow.armed ? snapshotRow.modelData.confirm_note : "" }
                  Note { objectName: "deleteConfirm-" + snapshotRow.modelData.name; text: snapshotRow.deleting ? snapshotRow.modelData.delete_confirm_note : "" }
                  Note { text: snapshotRow.armed ? snapshotRow.modelData.warning : snapshotRow.deleting ? snapshotRow.modelData.delete_warning : "" }
                  Action { objectName: "deleteCancel-" + snapshotRow.modelData.name; control: "cancel"
                    visible: snapshotRow.deleting && descriptor.show; onClicked: root.deleteArmed = "" }
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
      NameField {
        name: "setupSnapshotName"
        accessibleName: "Setup snapshot name (optional)"
        draft: setupName
        actionControl: "setup_snapshot"
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
        Action { control: "setup_snapshot"; onClicked: root.takeSnapshot(setupName, "setup_snapshot") }
        Action { control: "skip_snapshot"; onClicked: root.model.run(["setup", "--no-snapshot"], true) }
      }
      Note { text: root.model.control("setup_snapshot").show ? root.model.view.result.snapshots || "" : "" }
      // Disabled buttons cannot expose their tooltips in the installed shell.
      Note { text: root.model.view.setup.finished && root.model.control("continue_setup").enable
        ? "" : root.model.control("continue_setup").hint || "" }
      Note { text: root.model.view.setup.again_line || ""; visible: root.setupAgainArmed }
      // After a step 6 time-out with Windows off, the display buttons
      // show directly: they repeat the Windows install, no arming. The
      // time-out's words below name them.
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.model.view.setup.finished || root.setupAgainArmed
        Action { control: "no_window"; onClicked: root.model.run(["setup", "--no-window"], true) }
        Note { text: root.model.control("no_window").show && (!root.model.view.setup.finished || !root.model.control("no_window").enable)
          ? root.model.control("no_window").hint || "" : "" }
        Action { control: "window"; onClicked: root.model.run(["setup", "--window"], true) }
        Note { text: root.model.control("window").show && (!root.model.view.setup.finished || !root.model.control("window").enable)
          ? root.model.control("window").hint || "" : "" }
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

  // One name field's state; see dailyName and setupName.
  component NameDraft: QtObject {
    property string text: ""
    property string sentToken: ""
    property string sentText: ""
    property string error: ""
  }

  // A labelled single-line snapshot name above its Take a snapshot action.
  // It submits its exact text: no validator, mask or trimming. The backend
  // checks the name, and its refusal shows below the field. It shows only
  // while its action is usable; the draft lives on in its NameDraft.
  component NameField: Column {
    id: nameField
    required property string name
    required property string accessibleName
    required property NameDraft draft
    required property string actionControl
    readonly property var action: root.model.control(actionControl)
    width: parent.width
    spacing: Style.space(4)
    visible: action.show === true && action.enable === true
    Note {
      objectName: nameField.name + "Caption"
      text: "Snapshot name (optional)"
      color: Qt.darker(root.foreground, 1.4)
    }
    TextField {
      objectName: nameField.name + "Field"
      width: parent.width
      clip: true
      text: nameField.draft.text
      foreground: root.foreground
      font.family: root.fontFamily
      Accessible.name: nameField.accessibleName
      Accessible.description: nameField.draft.error
      onTextChanged: nameField.draft.text = text
      // A focused field still gets Enter after a section above hides it.
      onAccepted: if (nameField.visible) root.takeSnapshot(nameField.draft, nameField.actionControl)
      onActiveFocusChanged: if (activeFocus) root.reveal(nameField)
    }
    Note {
      objectName: nameField.name + "Error"
      text: nameField.draft.error
      color: Commons.Color.urgent
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
    tooltipText: descriptor.hint || (root.quietMain && control === "open"
      ? [root.model.view.cause || "", root.model.view.next || ""].filter(function(line) { return line !== "" }).join(" ") : "")
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
