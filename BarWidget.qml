import QtQuick
import qs.Ui

// Bar button that summons the grid. It goes through shell IPC rather than
// touching the overlay directly, so the button and the SUPER+A binding share
// one toggle path (and the bar can reload without stranding an open overlay).
BarWidget {
  id: root
  moduleName: "tyrsolution.app-launcher"

  // Hosts that draw this widget themselves (e.g. a dock slot) look for an
  // `icon` on the widget, not on the inner button, and fall back to a
  // generic gear without it.
  readonly property string icon: button.text

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
      // Marked so the overlay knows it was summoned by pointer. Only the bar
      // is marked: the SUPER+A binding lives in the user's bindings.lua, which
      // a plugin cannot rewrite, so "unmarked" has to mean "not the bar" for
      // every existing install to keep working without a migration.
      root.bar.run("omarchy-shell shell toggle tyrsolution.app-launcher '{\"source\":\"bar\"}'")
    }
  }
}
