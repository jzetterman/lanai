pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

// The bar widget owns the popout, as in the bundled weather widget.
BarWidget {
  id: root
  moduleName: "io.github.jzetterman.lanai"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property bool opened: panel.opened
  readonly property bool popoutSwitchClosing: panel.popoutSwitchClosing

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
      Item {
        Rectangle {
          x: parent.width * 0.12; y: parent.height * 0.08
          width: parent.width * 0.76; height: parent.height * 0.67
          color: "transparent"
          border.width: 1
          border.color: button.active ? button.activeColor : button.foreground
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
          x: parent.width * 0.33; y: parent.height * 0.84
          width: parent.width * 0.34; height: 1
          color: button.active ? button.activeColor : button.foreground
        }
      }
    }
    // qmllint disable missing-property
    slotSize: Style.bar.statusSlot
    // qmllint enable missing-property
    tooltipText: model.tooltip
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
