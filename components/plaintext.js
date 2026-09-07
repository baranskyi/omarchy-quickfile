.pragma library

// Tooltips are rendered by Qt Quick Controls' shared ToolTip, whose text sink
// uses Text.AutoText. Every Text this plugin declares is pinned to PlainText,
// but that shared item is not ours to configure, so a filename or path that
// looks like markup would still be parsed as rich text there — and a name such
// as `<img src="https://…">` would load a remote resource on hover.
//
// Escape the value, then wrap it so the result is unambiguously rich text: the
// escaped entities render as the literal characters the user typed, and no tag
// survives the escaping to load or execute anything.
function tooltip(value) {
  var text = value === undefined || value === null ? "" : String(value)
  if (text === "") return ""
  return "<span>" + text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\n/g, "<br>") + "</span>"
}
