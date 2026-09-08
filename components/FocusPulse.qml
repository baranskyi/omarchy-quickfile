import QtQuick
import qs.Commons

// A one-shot outline that brightens and fades where the keyboard just landed,
// so a jump between the search field, the list and the inspector is visible
// without the user hunting for the cursor. Draws nothing until `pulse()` is
// called and nothing after it settles: no fill, no layout, no hit testing.
Rectangle {
  id: root

  property color pulseColor: Color.accent
  // Fast enough to read as a flash rather than a state change.
  property int riseDuration: 110
  property int holdDuration: 90
  property int fallDuration: 420

  // True from the moment `pulse()` is called until the outline has faded, so
  // callers and tests can see the mark without waiting for the first frame.
  readonly property bool active: flash.running

  function pulse() {
    flash.restart()
  }

  color: "transparent"
  radius: Style.cornerRadius > 0 ? Style.space(6) : 0
  border.width: Math.max(1, Style.normalBorderWidth)
  border.color: root.pulseColor
  opacity: 0
  visible: active || opacity > 0
  // The outline sits over whatever it marks and must never take a click from
  // it — the pulse follows the pointer's action, it does not intercept it.
  enabled: false

  SequentialAnimation {
    id: flash
    NumberAnimation {
      target: root
      property: "opacity"
      to: 0.85
      duration: root.riseDuration
      easing.type: Easing.OutQuad
    }
    PauseAnimation { duration: root.holdDuration }
    NumberAnimation {
      target: root
      property: "opacity"
      to: 0
      duration: root.fallDuration
      easing.type: Easing.OutCubic
    }
  }
}
