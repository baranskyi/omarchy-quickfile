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
    useActiveColor: false
    iconComponent: Component {
      Item {
        QuickFileIcon {
          anchors.centerIn: parent
          // Tuned so the painted glyph is 26px tall -- the shared optical
          // height of the bar's icons -- and sits on their 29.5px centre.
          iconSize: 16
          color: button.foreground
          active: button.active
          activeBackgroundColor: button.foreground
          activeForegroundColor: root.bar
            ? root.bar.background : Color.background
        }
      }
    }
    active: root.opened
    tooltipText: root.opened ? "Close QuickFile" : "Open QuickFile"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && root.quickfile)
        root.quickfile.reload()
      else root.toggle()
    }
  }
}
