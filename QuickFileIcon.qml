import QtQuick

Item {
  id: root

  property real iconSize: 16
  property color color: "white"

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    readonly property real strokeWidth: Math.max(1.5, Math.min(width, height) * 0.105)
    readonly property real nodeRadius: Math.max(1.45, Math.min(width, height) * 0.088)

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onStrokeWidthChanged: requestPaint()
    onNodeRadiusChanged: requestPaint()
    onPaint: {
      const ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      if (width <= 0 || height <= 0) return

      const trunkX = width * 0.25
      const branchEndX = width * 0.76
      const rows = [height * 0.2, height * 0.5, height * 0.8]

      ctx.strokeStyle = root.color
      ctx.fillStyle = root.color
      ctx.lineWidth = strokeWidth
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      ctx.beginPath()
      ctx.moveTo(trunkX, rows[0])
      ctx.lineTo(trunkX, rows[2])
      for (let i = 0; i < rows.length; ++i) {
        ctx.moveTo(trunkX, rows[i])
        ctx.lineTo(branchEndX, rows[i])
      }
      ctx.stroke()

      const nodes = [
        [trunkX, rows[0]],
        [branchEndX, rows[0]],
        [branchEndX, rows[1]],
        [branchEndX, rows[2]]
      ]
      for (let i = 0; i < nodes.length; ++i) {
        ctx.beginPath()
        ctx.arc(nodes[i][0], nodes[i][1], nodeRadius, 0, Math.PI * 2)
        ctx.fill()
      }
    }

    onAvailableChanged: if (available) requestPaint()
  }
}
