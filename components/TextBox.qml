import QtQuick
import QtQuick.Controls.Basic as Basic
import QtQuick.Templates as T

// Every editable text box in QuickFile is one of these, never a TextField.
//
// Qt reads another client's clipboard by buffering its whole offer from the
// Wayland pipe before any length limit applies, with no byte cap and no
// deadline. The shell is one process for the whole desktop, so a clipboard
// owner that streams without end would stall it and eat its memory. A
// TextField takes that path on every paste — the paste keys, a middle click,
// its context menu — and even unasked: QQuickTextInput reads the full
// clipboard text each time the clipboard changes, just to know whether Paste
// is possible. QQuickTextEdit only looks at the offered formats, so this is a
// TextEdit held to one line unless `multiline`, and each way of pasting asks
// for pasteRequested instead; the panel fills the box from its bounded reader
// through insertPaste(). Drops are not a way in: neither Qt text item accepts
// them.
T.TextArea {
  id: control

  property bool multiline: false
  // TextField's limit, which TextEdit lacks: typing and pasting stop here.
  property int maximumLength: 32767
  // Bumped whenever the box loses the keyboard, so a paste asked for before
  // the user went elsewhere can tell that it no longer belongs here.
  property int focusEpoch: 0
  // How far one line has scrolled to keep the cursor in view: TextEdit does
  // not scroll itself the way TextInput does.
  property real scrollX: 0
  // Where the text starts when nothing is scrolled. These are the paddings of
  // the Fusion TextField and TextArea these boxes replace, so the text sits
  // where it did.
  readonly property real startPadding: multiline ? padding + 4 : padding
  // Set once the box is built: trimming and scrolling wait for it.
  property bool completed: false
  readonly property alias contextMenu: textMenu

  signal pasteRequested(bool primary)

  // The clipboard's text as this box takes it: no NULs, and on one line no
  // line breaks or tabs either, which would split a name or a query.
  function cleanPaste(text) {
    var clean = String(text === undefined || text === null ? "" : text)
      .replace(new RegExp("\\u0000", "g"), "")
    if (multiline) return clean.replace(new RegExp("\\r\\n?", "g"), "\n")
    // Built from a string: the QML lexer reads a line separator escape in a
    // regex literal as the end of the line.
    return clean.replace(
      new RegExp("\\r\\n|[\\r\\n\\t\\v\\f\\u0085\\u2028\\u2029]", "g"), " ")
  }

  // Inserts a paste at the cursor over the selection, cut to what the limit
  // still allows, as a native paste would. False when nothing changed.
  function insertPaste(text) {
    if (readOnly) return false
    var clean = cleanPaste(text)
    var start = Math.min(selectionStart, selectionEnd)
    var end = Math.max(selectionStart, selectionEnd)
    var room = Math.max(0, maximumLength - (length - (end - start)))
    if (clean.length > room) {
      clean = clean.substring(0, room)
      // Never keep half of a surrogate pair at the cut.
      var last = clean.charCodeAt(clean.length - 1)
      if (last >= 0xd800 && last <= 0xdbff) clean = clean.substring(0, clean.length - 1)
    }
    if (clean === "" && start === end) return false
    if (end > start) remove(start, end)
    if (clean !== "") insert(start, clean)
    cursorPosition = start + clean.length
    textEdited()
    return true
  }

  function requestPaste(primary) {
    if (readOnly) return false
    if (!activeFocus) forceActiveFocus()
    pasteRequested(primary === true)
    return true
  }

  // What was just typed sits before the cursor, so the excess comes back off
  // from there; a longer text set from outside loses its tail instead.
  function trimToLimit() {
    var excess = length - maximumLength
    if (!completed || maximumLength < 0 || excess <= 0) return
    var end = cursorPosition
    if (end >= excess) remove(end - excess, end)
    else remove(maximumLength, length)
  }

  function followCursor() {
    // Size and cursor settle while the box is still being built, when in a
    // delegate even the JavaScript globals can be missing.
    if (!completed) return
    if (multiline) {
      scrollX = 0
      return
    }
    var view = width - startPadding - rightPadding
    var caret = cursorRectangle.x - leftPadding
    var next = scrollX
    if (caret < next) next = caret
    else if (caret + cursorRectangle.width > next + view)
      next = caret + cursorRectangle.width - view
    next = Math.max(0, Math.min(next, contentWidth + cursorRectangle.width - view))
    if (next !== scrollX) scrollX = next
  }

  padding: multiline ? 6 : 4
  leftPadding: startPadding - scrollX
  wrapMode: multiline ? TextEdit.Wrap : TextEdit.NoWrap
  verticalAlignment: multiline ? TextEdit.AlignTop : TextEdit.AlignVCenter
  textFormat: TextEdit.PlainText
  clip: !multiline
  color: palette.text
  selectionColor: palette.highlight
  selectedTextColor: palette.highlightedText
  placeholderTextColor: palette.placeholderText

  onTextChanged: trimToLimit()
  onMaximumLengthChanged: trimToLimit()
  onCursorRectangleChanged: followCursor()
  onWidthChanged: followCursor()
  onContentWidthChanged: followCursor()
  onActiveFocusChanged: if (!activeFocus) focusEpoch++
  Component.onCompleted: {
    completed = true
    trimToLimit()
    followCursor()
  }

  Keys.onPressed: function(event) {
    // StandardKey.Paste is the set of chords Qt itself pastes on, the Paste
    // key among them.
    if (event.matches(StandardKey.Paste) || event.key === Qt.Key_Paste) {
      event.accepted = true
      control.requestPaste(false)
    } else if (!control.multiline
        && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      // One line has no newline to insert; the box's owner acts on Return.
      event.accepted = true
    } else if (!control.multiline
        && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
      // A tab character is not a name; move on as TextField did.
      event.accepted = true
      var next = control.nextItemInFocusChain(event.key === Qt.Key_Tab)
      if (next && next !== control) next.forceActiveFocus(Qt.TabFocusReason)
    }
  }

  Text {
    textFormat: Text.PlainText
    x: control.startPadding
    y: control.topPadding
    width: control.width - control.startPadding - control.rightPadding
    height: control.height - control.topPadding - control.bottomPadding
    text: control.placeholderText
    font: control.font
    color: control.placeholderTextColor
    verticalAlignment: control.verticalAlignment
    elide: Text.ElideRight
    renderType: control.renderType
    visible: !control.length && !control.preeditText
      && (!control.activeFocus || control.horizontalAlignment !== Qt.AlignHCenter)
  }

  // A middle click pastes the primary selection where it lands, through the
  // same reader. Other buttons pass straight through to the text.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.MiddleButton
    enabled: !control.readOnly
    onPressed: function(mouse) {
      control.forceActiveFocus(Qt.MouseFocusReason)
      control.deselect()
      control.cursorPosition = control.positionAt(mouse.x, mouse.y)
      control.requestPaste(true)
    }
  }

  // The menu Qt gives text controls, entry for entry, with Paste on the
  // bounded reader instead of Qt's.
  T.ContextMenu.menu: Basic.Menu {
    id: textMenu
    popupType: Qt.platform.pluginName !== "wayland" ? T.Popup.Window : T.Popup.Item

    Basic.MenuItem {
      text: "Undo"
      icon.name: "edit-undo"
      icon.width: 24
      icon.height: 24
      enabled: control.canUndo
      onTriggered: control.undo()
    }
    Basic.MenuItem {
      text: "Redo"
      icon.name: "edit-redo"
      icon.width: 24
      icon.height: 24
      enabled: control.canRedo
      onTriggered: control.redo()
    }
    Basic.MenuSeparator {}
    Basic.MenuItem {
      text: "Cut"
      icon.name: "edit-cut"
      icon.width: 24
      icon.height: 24
      enabled: !control.readOnly && control.selectedText.length > 0
      onTriggered: control.cut()
    }
    Basic.MenuItem {
      text: "Copy"
      icon.name: "edit-copy"
      icon.width: 24
      icon.height: 24
      enabled: control.selectedText.length > 0
      onTriggered: control.copy()
    }
    Basic.MenuItem {
      objectName: "quickfileTextBoxPaste"
      text: "Paste"
      icon.name: "edit-paste"
      icon.width: 24
      icon.height: 24
      enabled: !control.readOnly
      onTriggered: control.requestPaste(false)
    }
    Basic.MenuItem {
      text: "Delete"
      icon.name: "edit-delete"
      icon.width: 24
      icon.height: 24
      enabled: !control.readOnly && control.selectedText.length > 0
      onTriggered: control.remove(control.selectionStart, control.selectionEnd)
    }
    Basic.MenuSeparator {}
    Basic.MenuItem {
      text: "Select All"
      icon.name: "edit-select-all"
      icon.width: 24
      icon.height: 24
      onTriggered: control.selectAll()
    }
  }
}
