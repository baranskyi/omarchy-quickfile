import QtQuick
import Quickshell
import Quickshell.Wayland

// Reserves the strip the docked QuickFile window sits in, and nothing else.
//
// A layer-shell exclusive zone is the compositor's own way to say "keep tiled
// windows out of here". It composes with the bar's zone — the bar keeps its full
// width and its widgets stay where they were — and it belongs to this surface,
// so it disappears with the panel instead of living on in the monitor's
// configuration. The surface is transparent and masked out of input: it exists
// to reserve space, never to be seen or clicked.
//
// It lives in its own file so the panel can load it through a Loader. Layer
// shell needs a compositor, and the offscreen QML harness has none; a failure
// to create this surface must cost the reservation, not the file manager.
PanelWindow {
  id: root

  property int stripWidth: 0

  color: "transparent"
  implicitWidth: stripWidth
  exclusionMode: ExclusionMode.Auto

  anchors {
    left: true
    top: true
    bottom: true
  }

  mask: Region {}

  WlrLayershell.namespace: "omarchy-quickfile-dock"
  // Arranged after the bar. Layer-shell exclusive zones are applied in layer
  // order, so a strip on a lower layer would claim the bar's row first and
  // squeeze the bar itself; on the overlay layer the bar keeps its full width
  // and this strip only takes what is left below it.
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
}
