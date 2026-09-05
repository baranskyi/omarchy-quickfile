import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "m0sthatedman.quickfile"

  readonly property var quickfile: bar && bar.shell
    ? bar.shell.serviceFor(moduleName) : null
  readonly property bool opened: bar && bar.shell
    ? bar.shell.isPluginOpen(moduleName) : false

  function open() {
    if (bar && bar.shell) bar.shell.summon(moduleName, "{}")
  }

  function close() {
    if (bar && bar.shell) bar.shell.hide(moduleName)
  }

  function toggle() {
    if (bar && bar.shell) bar.shell.toggle(moduleName, "{}")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰉋"
    active: root.opened
    tooltipText: root.opened ? "Close Quickfile" : "Open Quickfile"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && root.quickfile)
        root.quickfile.reload()
      else root.toggle()
    }
  }
}
