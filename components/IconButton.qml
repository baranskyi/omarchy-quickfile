import QtQuick
import QtQuick.Controls
import qs.Commons

Rectangle {
  id: root

  property string glyph: ""
  property string tooltip: ""
  property bool active: false
  property bool framed: false
  property bool available: true
  property int buttonSize: Style.space(28)
  signal clicked(int button)

  width: buttonSize
  height: buttonSize
  radius: Style.cornerRadius > 0 ? Style.space(5) : 0
  color: active ? Style.selectedFill
    : (mouse.containsMouse ? Style.hoverFill
      : (framed ? Style.normalFill : "transparent"))
  border.width: framed ? Style.normalBorderWidth : 0
  border.color: framed ? Style.normalBorderColor : "transparent"
  opacity: available ? 1 : 0.35

  Text {
    anchors.centerIn: parent
    text: root.glyph
    color: root.active ? Color.accent : Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    renderType: Text.NativeRendering
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: root.available ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: function(event) {
      if (root.available) root.clicked(event.button)
    }
    ToolTip.visible: containsMouse && root.tooltip !== ""
    ToolTip.delay: 650
    ToolTip.timeout: 5000
    ToolTip.text: root.tooltip
  }
}
