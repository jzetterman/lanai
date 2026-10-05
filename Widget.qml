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

  // A QEMU setup window has no Looking Glass display yet; use the panel instead.
  function primaryClick() {
    if (model.canStart) model.run(["start"], true)
    else if (model.canOpen && !model.busy) model.run(["open"], true)
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
            font.pixelSize: Style.bar.iconFont * 0.7
          }
        }
        Rectangle {
          x: parent.width * 0.33; y: parent.height * 0.84
          width: parent.width * 0.34; height: 1
          color: button.active ? button.activeColor : button.foreground
        }
      }
    }
    slotSize: Style.bar.statusSlot
    tooltipText: model.tooltip
    active: model.status.active === true
    activeFocusOnTab: true
    Keys.onReturnPressed: root.primaryClick()
    Keys.onSpacePressed: root.primaryClick()
    Keys.onMenuPressed: root.togglePanel()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePanel()
      else if (b === Qt.LeftButton) root.primaryClick()
    }
  }
}
