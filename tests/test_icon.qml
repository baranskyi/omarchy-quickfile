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
      activeBackgroundColor: "#f5ead8"
      activeForegroundColor: "#081a2c"
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
        if (String(icon.inkColor) !== "#ffb16c") {
          console.error("QUICKFILE_TESTS_FAILED icon: inactive color lost")
          Qt.exit(1)
          return
        }
        icon.active = true
        activeCapture.start()
      })
    }
  }

  Timer {
    id: activeCapture
    interval: 220
    onTriggered: {
      if (String(icon.inkColor) !== "#081a2c") {
        console.error("QUICKFILE_TESTS_FAILED icon: active contrast lost")
        Qt.exit(1)
        return
      }
      icon.grabToImage(function(result) {
        if (!result || String(result.url).length === 0) {
          console.error("QUICKFILE_TESTS_FAILED icon: active render failed")
          Qt.exit(1)
          return
        }
        console.log("QUICKFILE_TESTS_PASSED icon: inactive and active states rendered")
        Qt.quit()
      })
    }
  }
}
