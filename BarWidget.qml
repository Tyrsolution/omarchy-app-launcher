import QtQuick
import qs.Ui

// Bar button that summons the grid. It goes through shell IPC rather than
// touching the overlay directly, so the button and the SUPER+A binding share
// one toggle path (and the bar can reload without stranding an open overlay).
BarWidget {
  id: root
  moduleName: "tyrsolution.app-launcher"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "App Launcher"
    onPressed: function(mouseButton) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle tyrsolution.app-launcher '{}'")
    }
  }
}
