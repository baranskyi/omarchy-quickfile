import QtQuick
import QtQuick.Window
import Quickshell
import "plugin" as Quickfile

ShellRoot {
  id: testRoot

  Window {
    id: window
    visible: true
    width: 64
    height: 64
    color: "#081a2c"

    Quickfile.QuickFileIcon {
      id: icon
      anchors.centerIn: parent
      iconSize: 32
      color: "#ffb16c"
    }
  }

  Timer {
    interval: 150
    running: true
    onTriggered: {
      if (icon.width !== 32 || icon.height !== 32) {
        console.error("QUICKFILE_TESTS_FAILED icon: unexpected dimensions")
        Qt.exit(1)
        return
      }
      icon.grabToImage(function(result) {
        if (!result || String(result.url).length === 0) {
          console.error("QUICKFILE_TESTS_FAILED icon: render capture failed")
          Qt.exit(1)
          return
        }
        console.log("QUICKFILE_TESTS_PASSED icon: circuit-tree rendered at 32 px")
        Qt.quit()
      })
    }
  }
}
