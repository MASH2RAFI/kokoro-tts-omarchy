import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "mash2rafi.kokoro"

  readonly property var shell: root.bar ? root.bar.shell : null
  readonly property bool appOpen: root.shell && typeof root.shell.isPluginOpen === "function"
    ? root.shell.isPluginOpen(root.moduleName) : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰗋"
    slotSize: Style.bar.statusSlot
    active: root.appOpen
    useActiveColor: true
    tooltipText: "Kokoro TTS — click to open, right-click to speak the selection"
    onPressed: function(mouseButton) {
      if (!root.shell) return
      if (mouseButton === Qt.RightButton)
        root.shell.summon(root.moduleName, JSON.stringify({ action: "speakSelection" }))
      else
        root.shell.toggle(root.moduleName, "{}")
    }
  }
}
