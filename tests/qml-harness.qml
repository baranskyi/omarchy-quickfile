import QtQuick
import Quickshell
import "plugin" as Quickfile

ShellRoot {
  Quickfile.Service {
    id: quickfileService
  }

  Quickfile.Panel {
    service: quickfileService
    manifest: ({ id: "m0sthatedman.quickfile" })
    Component.onCompleted: open("{}")
  }
}
