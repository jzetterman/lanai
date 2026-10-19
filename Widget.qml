pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bar widget owns the popout, as in the bundled weather widget.
BarWidget {
  id: root
  moduleName: "io.github.jzetterman.lanai"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property bool opened: panel.opened
  readonly property bool popoutSwitchClosing: panel.popoutSwitchClosing
  readonly property var barState: model.view.bar || ({mode: "stopped", percent: null})
  readonly property bool busyUnmeasured: barState.mode === "busy" && barState.percent == null
  readonly property color glyphColor: barState.mode === "active" ? Commons.Color.accent : Commons.Color.foreground

  function open() { panel.open() }
  function close() { panel.close() }
  function togglePanel() { panel.toggle() }
  function closeForPopoutSwitch() { panel.closeForPopoutSwitch() }
  function refresh() { model.refresh() }

  // Bash supplies the shortcut; stale decisions still pass command-side guards.
  function rightClick() {
    var action = model.view.right_click
    if (action === "start" || action === "open") model.run([action], false)
    else panel.open()
  }

  LanaiModel { id: model; panelOpen: panel.opened; onPanelRequested: panel.open() }
  LanaiPanel { id: panel; bar: root.bar; settings: root.settings; anchorItem: button; hostWidget: root; model: model }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "L"
    // Lanai's own L-in-a-monitor mark, using the shell's iconComponent slot.
    iconComponent: Component {
      // A fixed optical canvas keeps changing indicators from moving the mark.
      Rectangle {
        id: mark
        color: "transparent"
        property real busyPhase: 0
        Rectangle {
          objectName: "barMonitor"
          x: parent.width * 0.12; y: parent.height * 0.08
          width: parent.width * 0.76; height: parent.height * 0.67
          color: "transparent"
          border.width: 1
          border.color: root.glyphColor
          Text {
            anchors.centerIn: parent
            text: "L"
            textFormat: Text.PlainText
            color: parent.border.color
            font.family: button.fontFamily
            // Shell style groups expose their fields dynamically.
            // qmllint disable missing-property
            font.pixelSize: Style.bar.iconFont * 0.7
            // qmllint enable missing-property
          }
        }
        Rectangle {
          objectName: "barFoot"
          x: parent.width * 0.33; y: parent.height * 0.84
          width: parent.width * 0.34; height: 1
          color: root.glyphColor
        }
        Rectangle {
          objectName: "barUnderline"
          visible: root.barState.mode === "active" || root.barState.mode === "busy"
          x: root.busyUnmeasured && Style.duration(1200) > 0 ? mark.busyPhase * (parent.width - width) : 0
          anchors.bottom: parent.bottom
          height: Style.space(2)
          width: parent.width * (root.barState.mode === "active" ? 1
            : root.busyUnmeasured ? 0.3 : (root.barState.percent || 0) / 100)
          color: Commons.Color.accent
        }
        NumberAnimation {
          objectName: "barBusyAnimation"
          target: mark
          property: "busyPhase"
          from: 0; to: 1
          duration: Style.duration(1200)
          running: root.busyUnmeasured && duration > 0
          loops: Animation.Infinite
        }
        Rectangle {
          objectName: "barBadge"
          visible: root.barState.mode === "attention" || root.barState.mode === "failed"
          x: parent.width * 0.7; y: parent.height * 0.02
          width: Style.space(6); height: width
          radius: root.barState.mode === "attention" ? width / 2 : 0
          color: root.barState.mode === "failed" ? Commons.Color.urgent : Commons.Color.accent
        }
      }
    }
    Rectangle {
      objectName: "barFocus"
      anchors.fill: parent
      visible: button.activeFocus
      color: "transparent"
      border.width: 1
      border.color: Commons.Color.accent
    }
    // qmllint disable missing-property
    slotSize: Style.bar.statusSlot
    // qmllint enable missing-property
    tooltipText: model.tooltip
    Accessible.role: Accessible.Button
    Accessible.name: tooltipText
    Accessible.onPressAction: root.togglePanel()
    active: model.view.active === true
    activeFocusOnTab: true
    Keys.onReturnPressed: root.togglePanel()
    Keys.onEnterPressed: root.togglePanel()
    Keys.onSpacePressed: root.togglePanel()
    Keys.onMenuPressed: root.togglePanel()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.rightClick()
      else if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
