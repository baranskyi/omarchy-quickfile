pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "components" as Components

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false
  property bool focusPrimed: false
  property string targetScreenName: ""
  property int keyboardIndex: -1
  property bool inspectorOpen: true
  property bool inspectorDetailsVisible: false
  property string editorMode: ""
  property string editorValue: ""
  property string editorError: ""
  property string hoveredToken: ""
  property string metadataToken: service ? String(service.selectedToken || "") : ""
  property string noteDraft: ""
  property string colorDraft: ""
  property bool knowledgeRegisteredDraft: false
  property var knowledgeAgentsDraft: []
  property bool syncingMetadata: false
  property string metadataLoadedToken: ""
  property string noteBaseline: ""
  property string colorBaseline: ""
  property bool knowledgeRegisteredBaseline: false
  property var knowledgeAgentsBaseline: []
  property var metadataSavePending: null
  property var keyboardSnapshot: null
  readonly property bool noteDirty: noteDraft !== noteBaseline
  readonly property bool colorDirty: colorDraft !== colorBaseline
  readonly property bool knowledgeRegistrationDirty:
    knowledgeRegisteredDraft !== knowledgeRegisteredBaseline
  readonly property bool knowledgeAgentsDirty:
    !sameKnowledgeAgents(knowledgeAgentsDraft, knowledgeAgentsBaseline)
  readonly property bool knowledgeDirty: knowledgeRegistrationDirty || knowledgeAgentsDirty
  signal keyboardNavigationRequested(int index)
  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "m0sthatedman.quickfile"
  readonly property int bladeWidth: Style.space(410)
  readonly property color background: Color.popups.background
  readonly property color foreground: Color.popups.text
  readonly property color borderColor: Color.popups.border
  readonly property color muted: Color.muted
  readonly property color accent: Color.accent
  readonly property int primaryFontSize: Style.font.subtitle
  readonly property int secondaryFontSize: Style.font.body
  readonly property var colorChoices: [
    "red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown"
  ]
  readonly property var knowledgeAgentChoices: [
    { key: "codex", label: "CX", name: "Codex" },
    { key: "claude", label: "CL", name: "Claude" },
    { key: "gemini", label: "GM", name: "Gemini" },
    { key: "cursor", label: "CU", name: "Cursor" },
    { key: "copilot", label: "CP", name: "Copilot" },
    { key: "windsurf", label: "WS", name: "Windsurf" }
  ]
  property var itemPalette: ({})
  property real revealProgress: opened ? 1 : 0

  Behavior on revealProgress {
    NumberAnimation {
      duration: 180
      easing.type: Easing.OutCubic
    }
  }

  Timer {
    id: focusPrimeTimer
    interval: 90
    onTriggered: root.focusPrimed = true
  }

  FileView {
    id: itemPaletteFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadItemPalette(text())
    onFileChanged: reload()
    onLoadFailed: root.itemPalette = ({})
  }

  onAccentChanged: itemPaletteFile.reload()

  function loadItemPalette(raw) {
    var parsed = ({})
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*(red|yellow|orange|green|cyan|blue|magenta|brown)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) parsed[match[1]] = match[2]
    }
    itemPalette = parsed
  }

  function paletteColor(key) {
    var name = String(key || "")
    if (itemPalette[name]) return String(itemPalette[name])
    if (name === "red") return Color.urgent
    if (name === "blue") return root.accent
    var fallback = ({
      yellow: "#d0a215", orange: "#d0772b", green: "#879a39",
      cyan: "#3aa99f", magenta: "#ce5d97", brown: "#683b15"
    })
    return fallback[name] || root.foreground
  }

  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    if (monitor && monitor.name) return String(monitor.name)
    var screens = Quickshell.screens
    return screens.length > 0 ? String(screens[0].name || "") : ""
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) } catch (error) {}
    targetScreenName = focusedScreenName()
    focusPrimed = false
    opened = true
    focusPrimeTimer.restart()
    keyboardIndex = -1
    if (service) {
      service.setPanelVisible(true)
      if (payload.path) service.navigate(String(payload.path), "", true)
    }
  }

  function close() {
    editorMode = ""
    hoveredToken = ""
    focusPrimeTimer.stop()
    focusPrimed = false
    opened = false
    if (service) service.setPanelVisible(false)
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function fileGlyph(entry) {
    if (!entry) return "󰈔"
    if (entry.isDir === true) return entry.expanded === true ? "󰝰" : "󰉋"
    if (entry.isSymlink === true) return "󰌷"
    var name = String(entry.name || "").toLowerCase()
    if (name.match(/\.(png|jpg|jpeg|gif|webp|svg|avif)$/)) return "󰋩"
    if (name.match(/\.(mp3|flac|wav|ogg|m4a)$/)) return "󰎆"
    if (name.match(/\.(mp4|mkv|webm|mov)$/)) return "󰈫"
    if (name.match(/\.(zip|tar|gz|bz2|xz|7z|rar)$/)) return "󰀼"
    if (name.match(/\.(js|ts|tsx|jsx|py|rs|go|lua|qml|sh)$/)) return "󰅩"
    if (name.match(/\.(md|txt|rst|org)$/)) return "󰈙"
    return "󰈔"
  }

  function entryColor(entry) {
    if (entry && String(entry.color || "") !== "") {
      var stored = String(entry.color)
      return stored.charAt(0) === "#" ? stored : paletteColor(stored)
    }
    return entry && entry.isDir === true ? root.accent : root.foreground
  }

  function pointerSelectionMode(modifiers) {
    if ((modifiers & Qt.ControlModifier) !== 0) return "toggle"
    if ((modifiers & Qt.ShiftModifier) !== 0) return "range"
    return "replace"
  }

  function syncMetadataEditor(fromProperties) {
    var token = service ? String(service.selectedToken || "") : ""
    var changedSelection = token !== metadataLoadedToken
    var source = service && service.selectedEntry
      && String(service.selectedEntry.token || "") === token
        ? service.selectedEntry : ({})
    if ((fromProperties === true || changedSelection) && service
        && service.selectedProperties && token !== ""
        && String(service.selectedProperties.token || "") === token)
      source = service.selectedProperties
    var keepNote = !changedSelection && noteDirty
    var keepColor = !changedSelection && colorDirty
    var keepRegistration = !changedSelection && knowledgeRegistrationDirty
    var keepAgents = !changedSelection && knowledgeAgentsDirty
    syncingMetadata = true
    metadataLoadedToken = token
    noteBaseline = String(source.note || "")
    colorBaseline = String(source.color || "")
    knowledgeRegisteredBaseline = source.registeredKnowledge === true
    var explicitAgents = Array.isArray(source.knowledgeAgents)
      ? source.knowledgeAgents.slice() : []
    if (!knowledgeRegisteredBaseline && explicitAgents.length === 0
        && source.isKnowledge === true && Array.isArray(source.agents))
      explicitAgents = source.agents.slice()
    knowledgeAgentsBaseline = explicitAgents
    if (!keepNote) noteDraft = noteBaseline
    if (!keepColor) colorDraft = colorBaseline
    if (!keepRegistration) knowledgeRegisteredDraft = knowledgeRegisteredBaseline
    if (!keepAgents) knowledgeAgentsDraft = explicitAgents.slice()
    syncingMetadata = false
  }

  function saveMetadata(starred) {
    if (!service || !service.selectedEntry) return false
    if (metadataSavePending) return false
    metadataSavePending = ({ token: metadataToken, kind: "note",
      note: noteDraft, color: colorDraft })
    var started = service.saveSelectedMetadata(colorDraft, noteDraft,
      starred === undefined ? service.selectedEntry.starred === true : starred)
    if (!started) metadataSavePending = null
    return started
  }

  function finishMetadataSave(ok) {
    var saved = metadataSavePending
    metadataSavePending = null
    if (!ok || !saved || String(saved.token) !== metadataLoadedToken) return
    syncingMetadata = true
    if (saved.kind === "note") {
      if (!noteDirty || noteDraft === saved.note) noteDraft = saved.note
      if (!colorDirty || colorDraft === saved.color) colorDraft = saved.color
      noteBaseline = saved.note
      colorBaseline = saved.color
    } else {
      if (!knowledgeRegistrationDirty || knowledgeRegisteredDraft === saved.wasRegistered)
        knowledgeRegisteredDraft = saved.registered
      if (!knowledgeAgentsDirty || sameKnowledgeAgents(knowledgeAgentsDraft, saved.wasAgents))
        knowledgeAgentsDraft = saved.agents.slice()
      knowledgeRegisteredBaseline = saved.registered
      knowledgeAgentsBaseline = saved.agents.slice()
    }
    syncingMetadata = false
  }

  function previewHoveredOrSelected() {
    if (!service) return false
    var hovered = hoveredToken !== ""
      ? service.visibleEntryForToken(hoveredToken) : null
    return hovered ? service.previewEntry(hovered) : service.previewSelected()
  }

  onMetadataTokenChanged: syncMetadataEditor()

  function shortTime(value) {
    var text = String(value || "")
    if (text.length < 16) return text
    return text.slice(5, 10) + " " + text.slice(11, 16)
  }

  function compactTokens(value) {
    var amount = Math.max(0, Number(value || 0))
    if (amount < 1000) return String(Math.round(amount))
    var digits = amount >= 10000 ? 1 : 2
    return (amount / 1000).toFixed(digits).replace(/\.0+$/, "") + "k"
  }

  function agentBadges(agents) {
    var labels = ({
      codex: "CX", claude: "CL", gemini: "GM", cursor: "CU",
      copilot: "CP", windsurf: "WS"
    })
    var values = Array.isArray(agents) ? agents : []
    var output = []
    for (var i = 0; i < values.length; i++)
      output.push(labels[String(values[i])] || String(values[i]).slice(0, 2).toUpperCase())
    return output.join(" · ")
  }

  function knowledgeAgentSelected(key) {
    return knowledgeAgentsDraft.indexOf(String(key || "")) >= 0
  }

  function toggleKnowledgeAgent(key) {
    var value = String(key || "")
    var selected = knowledgeAgentsDraft.slice()
    var index = selected.indexOf(value)
    if (index >= 0) selected.splice(index, 1)
    else selected.push(value)
    var ordered = []
    for (var i = 0; i < knowledgeAgentChoices.length; i++) {
      var agent = String(knowledgeAgentChoices[i].key)
      if (selected.indexOf(agent) >= 0) ordered.push(agent)
    }
    knowledgeAgentsDraft = ordered
  }

  function sameKnowledgeAgents(left, right) {
    var first = Array.isArray(left) ? left : []
    var second = Array.isArray(right) ? right : []
    if (first.length !== second.length) return false
    for (var i = 0; i < first.length; i++)
      if (String(first[i]) !== String(second[i])) return false
    return true
  }

  function storedKnowledgeAgents() {
    return knowledgeAgentsBaseline
  }

  function saveKnowledgeRegistry(registered) {
    if (!service || !service.selectedEntry || service.selectedEntry.isDir === true)
      return false
    if (metadataSavePending) return false
    var agents = registered === true ? knowledgeAgentsDraft.slice() : []
    metadataSavePending = ({ token: metadataToken, kind: "knowledge",
      registered: registered === true, agents: agents,
      wasRegistered: knowledgeRegisteredDraft, wasAgents: knowledgeAgentsDraft.slice() })
    var started = service.saveSelectedKnowledge(registered === true, agents)
    if (!started) metadataSavePending = null
    return started
  }

  function beginKnowledgeLinks() {
    editorError = ""
    editorMode = "knowledge-links"
    if (!service || !service.previewSelectedKnowledgeLinks())
      editorError = "Select a registered Knowledge file first"
  }

  function knowledgeLinkStatusLabel(status) {
    var value = String(status || "")
    if (value === "create") return "CREATE"
    if (value === "connected") return "CONNECTED"
    if (value === "conflict") return "CONFLICT"
    return value.toUpperCase()
  }

  function knowledgeLinkStatusColor(status) {
    var value = String(status || "")
    if (value === "connected") return root.paletteColor("green")
    if (value === "conflict") return Color.urgent
    return root.accent
  }

  function knowledgeTooltip(entry) {
    if (!entry) return ""
    var bindings = Array.isArray(entry.bindings) ? entry.bindings : []
    var lines = []
    for (var i = 0; i < bindings.length; i++) {
      var binding = bindings[i]
      lines.push(String(binding.agent || "agent") + ": "
        + String(binding.displayPath || binding.path || "")
        + (binding.isSymlink === true ? " → " + String(binding.target || "") : ""))
    }
    return lines.join("\n")
  }

  function gitLabel(status) {
    var value = String(status || "").trim()
    if (!value) return ""
    if (value === "??") return "?"
    if (value.indexOf("D") >= 0) return "D"
    if (value.indexOf("A") >= 0) return "A"
    if (value.indexOf("R") >= 0) return "R"
    return "M"
  }

  function matchLabel(kind) {
    var value = String(kind || "")
    if (value === "folder") return "FOLDER"
    if (value === "name") return "NAME"
    if (value === "path") return "PATH"
    if (value === "content") return "CONTENT"
    return ""
  }

  function volumeGlyph(volume) {
    var transport = String(volume && volume.transport || "").toUpperCase()
    return transport === "USB" ? "󰕓" : "󰋊"
  }

  function volumeDetail(volume) {
    if (!volume) return ""
    var parts = []
    if (volume.sizeText) parts.push(String(volume.sizeText))
    if (volume.transport) parts.push(String(volume.transport))
    if (volume.mounted === true && volume.mountPath)
      parts.push(String(volume.mountPath))
    else parts.push("Not mounted")
    return parts.join("  ·  ")
  }

  function volumeIsCurrent(volume) {
    return root.service && volume && volume.mounted === true
      && root.service.pathInsideMount(root.service.rootPath,
        String(volume.mountPath || ""))
  }

  function propertyRows() {
    if (!service || !service.selectedProperties) return []
    var p = service.selectedProperties
    var rows = [
      { label: "Type", value: p.kind || "" },
      { label: "MIME", value: p.mime || "" },
      { label: "Size", value: (p.sizeText || "") + (p.allocatedSizeText ? " · " + p.allocatedSizeText + " allocated" : "") },
      { label: "Modified", value: p.modified || "" },
      { label: "Accessed", value: p.accessed || "" },
      { label: "Created", value: p.created || "—" },
      { label: "Permissions", value: (p.permissions || "") + "  " + (p.mode || "") },
      { label: "Owner", value: (p.owner || "") + ":" + (p.group || "") },
      { label: "Inode", value: String(p.inode || "") + " · " + String(p.hardLinks || 0) + " links" }
    ]
    if (p.children !== null && p.children !== undefined)
      rows.push({ label: "Children", value: String(p.children) })
    if (p.symlinkTarget)
      rows.push({ label: "Target", value: String(p.symlinkTarget) })
    if (p.git && (p.git.root || p.git.branch || p.git.status))
      rows.push({ label: "Git", value: [p.git.branch || "", p.git.status || "", p.git.root || ""].filter(Boolean).join(" · ") })
    if (p.mount && p.mount.mountpoint)
      rows.push({ label: "Filesystem", value: (p.mount.filesystem || "") + " · " + p.mount.mountpoint })
    if (p.filesystemUsage && p.filesystemUsage.freeText)
      rows.push({ label: "Free", value: p.filesystemUsage.freeText + " / " + p.filesystemUsage.totalText })
    if (p.xattrs && p.xattrs.length)
      rows.push({ label: "Extended attrs", value: String(p.xattrs.length) })
    if (p.acl)
      rows.push({ label: "ACL", value: String(p.acl).replace(/\n/g, " · ") })
    return rows
  }

  function moveSelection(delta, modifiers) {
    if (!service || service.entries.length === 0) {
      keyboardIndex = -1
      return
    }
    keyboardIndex = Math.max(0, Math.min(service.entries.length - 1,
      keyboardIndex < 0 ? (delta > 0 ? 0 : service.entries.length - 1)
        : keyboardIndex + delta))
    var mode = (modifiers & Qt.ShiftModifier) !== 0 ? "range"
      : ((modifiers & Qt.ControlModifier) !== 0 ? "focus" : "replace")
    service.selectIndex(keyboardIndex, mode)
    keyboardNavigationRequested(keyboardIndex)
  }

  function rememberKeyboardCursor() {
    keyboardSnapshot = service && keyboardIndex >= 0
      && keyboardIndex < service.entries.length
        ? ({ token: String(service.entries[keyboardIndex].token || ""),
          index: keyboardIndex, selection: service.selectedToken,
          path: service.rootPath, query: service.query }) : null
  }

  function restoreKeyboardCursor() {
    var saved = keyboardSnapshot
    keyboardSnapshot = null
    if (!service || service.entries.length === 0) {
      keyboardIndex = -1
      return
    }
    if (saved && saved.index === keyboardIndex && saved.path === service.rootPath
        && saved.query === service.query && saved.selection === service.selectedToken) {
      for (var i = 0; i < service.entries.length; i++) {
        if (String(service.entries[i].token || "") === saved.token) {
          keyboardIndex = i
          return
        }
      }
    }
    keyboardIndex = Math.min(keyboardIndex, service.entries.length - 1)
  }

  function beginEditor(mode) {
    if (!service) return
    editorValue = mode === "rename" && service.selectedEntry
      ? String(service.selectedEntry.name || "") : ""
    editorError = ""
    editorMode = mode
  }

  function commitEditor() {
    if (!service) return
    if (editorMode === "knowledge-links") {
      if (!service.applyKnowledgeLinks())
        editorError = "There are no safe links to create"
      return
    }
    if (editorMode === "trash") {
      if (!service.selectedToken) return
      service.trashSelected()
      editorMode = ""
      return
    }
    var name = String(editorValue || "")
    if (!name || name === "." || name === ".." || name.indexOf("/") >= 0) {
      editorError = "Enter a valid name without /"
      return
    }
    var started = editorMode === "new-file" ? service.createFile(name)
      : editorMode === "new-folder" ? service.createFolder(name)
      : editorMode === "rename" ? service.renameSelected(name) : false
    if (started) editorMode = ""
  }

  Connections {
    target: root.service
    function onListingAboutToChange() {
      root.rememberKeyboardCursor()
    }
    function onModelChanged() {
      root.restoreKeyboardCursor()
      if (root.hoveredToken !== ""
          && !root.service.visibleEntryForToken(root.hoveredToken))
        root.hoveredToken = ""
      root.syncMetadataEditor()
    }
    function onSelectedPropertiesChanged() {
      root.syncMetadataEditor(true)
    }
    function onActionFinished(kind, ok, message) {
      if (kind === "metadata") root.finishMetadataSave(ok)
      if (!ok) root.editorError = message
    }
    function onKnowledgeLinksFinished(ok, applied, message) {
      if (!ok) root.editorError = message
      else root.editorError = ""
    }
  }

  // Model rows retain their delegates. Preserve the first visible row as well
  // when inserts, removals, or reordering happen above the user's viewport.
  component StableListView: ListView {
    id: stableView
    property var viewportAnchor: null
    property int interactionRevision: 0
    readonly property bool scrollbarPressed: ScrollBar.vertical
      ? ScrollBar.vertical.pressed : false
    highlightFollowsCurrentItem: false

    function rowKey(index) {
      if (!model || index < 0 || index >= count) return ""
      var row = model.get(index).rowData
      return row ? String(row.token || row.device || "") : ""
    }

    function rememberViewport() {
      viewportAnchor = null
      if (!visible || moving || dragging || scrollbarPressed
          || count === 0 || height <= 0) return
      var index = -1
      for (var offset = 1; offset < Math.min(height, 80); offset += 4) {
        index = indexAt(1, contentY + offset)
        if (index >= 0) break
      }
      var row = index >= 0 ? itemAtIndex(index) : null
      if (!row) return
      viewportAnchor = ({ key: rowKey(index), offset: row.y - contentY,
        revision: interactionRevision,
        path: root.service ? root.service.rootPath : "",
        query: root.service ? root.service.query : "" })
    }

    function restoreViewport() {
      var saved = viewportAnchor
      viewportAnchor = null
      if (!saved || !visible || moving || dragging || scrollbarPressed
          || saved.revision !== interactionRevision
          || !root.service || saved.path !== root.service.rootPath
          || saved.query !== root.service.query) return
      var index = -1
      for (var i = 0; i < count; i++) {
        if (rowKey(i) === saved.key) {
          index = i
          break
        }
      }
      if (index < 0) return
      forceLayout()
      var row = itemAtIndex(index)
      if (!row) {
        positionViewAtIndex(index, ListView.Beginning)
        forceLayout()
        row = itemAtIndex(index)
      }
      if (row) contentY = Math.max(originY,
        Math.min(row.y - saved.offset, originY + Math.max(0, contentHeight - height)))
    }

    onMovingChanged: if (moving) interactionRevision++
    onDraggingChanged: if (dragging) interactionRevision++
    onScrollbarPressedChanged: if (scrollbarPressed) interactionRevision++
    Connections {
      target: root
      function onKeyboardNavigationRequested(index) { stableView.interactionRevision++ }
    }
    Connections {
      target: root.service
      function onListingAboutToChange() { stableView.rememberViewport() }
      function onModelChanged() { stableView.restoreViewport() }
    }
  }

  component ActionButton: Rectangle {
    id: actionButton
    property string glyph: ""
    property string label: ""
    signal clicked()
    implicitWidth: actionContent.implicitWidth + Style.space(16)
    implicitHeight: Style.space(28)
    radius: Style.cornerRadius > 0 ? Style.space(5) : 0
    color: actionMouse.containsMouse ? Style.hoverFill : Style.normalFill
    opacity: enabled ? 1 : 0.35
    Row {
      id: actionContent
      anchors.centerIn: parent
      spacing: Style.space(5)
      Text {
        text: actionButton.glyph
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: root.secondaryFontSize
        renderType: Text.NativeRendering
      }
      Text {
        text: actionButton.label
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: root.secondaryFontSize
        renderType: Text.NativeRendering
      }
    }
    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: actionButton.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: actionButton.clicked()
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: window
      required property var modelData
      screen: modelData
      visible: (root.opened || root.revealProgress > 0.001)
        && (root.targetScreenName === ""
          || String(modelData.name || "") === root.targetScreenName)
      implicitWidth: Math.max(1, Math.round(root.bladeWidth * root.revealProgress))
      color: "transparent"
      exclusionMode: visible ? ExclusionMode.Auto : ExclusionMode.Ignore

      anchors {
        top: true
        bottom: true
        left: true
      }
      margins {
        // The bar already owns Hyprland's top exclusive zone. Match the
        // compositor's outer window gap instead of adding the bar twice.
        top: Style.spacing.xl
        bottom: Style.spacing.xl
        left: Style.spacing.xl
      }

      WlrLayershell.namespace: "omarchy-quickfile"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: root.opened
        ? (root.focusPrimed ? WlrKeyboardFocus.OnDemand
          : WlrKeyboardFocus.Exclusive)
        : WlrKeyboardFocus.None

      onVisibleChanged: {
        if (visible) Qt.callLater(function() { keyScope.forceActiveFocus() })
      }

      Rectangle {
        id: blade
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: root.bladeWidth
        color: root.background
        radius: Style.cornerRadius
        border.width: Math.max(1, Style.normalBorderWidth)
        border.color: root.borderColor
        clip: true

        FocusScope {
          id: keyScope
          anchors.fill: parent
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (root.editorMode !== "") return
            if (noteEditor.activeFocus || pathField.activeFocus) return
            if (searchField.activeFocus) {
              if (event.key === Qt.Key_Escape) {
                if (searchField.text !== "") searchField.clear()
                else keyScope.forceActiveFocus()
                event.accepted = true
              }
              return
            }
            if (event.key === Qt.Key_Escape) {
              if (root.service && root.service.selectedTokens.length > 0)
                root.service.clearSelection()
              else root.requestClose()
              event.accepted = true
            } else if (event.key === Qt.Key_A
                && (event.modifiers & Qt.ControlModifier) !== 0) {
              root.service.selectAllVisible()
              event.accepted = true
            } else if (event.key === Qt.Key_C
                && (event.modifiers & Qt.ControlModifier) !== 0) {
              root.service.copySelected()
              event.accepted = true
            } else if (event.key === Qt.Key_X
                && (event.modifiers & Qt.ControlModifier) !== 0) {
              root.service.cutSelected()
              event.accepted = true
            } else if (event.key === Qt.Key_V
                && (event.modifiers & Qt.ControlModifier) !== 0) {
              root.service.pasteHere()
              event.accepted = true
            } else if (event.key === Qt.Key_D
                && (event.modifiers & Qt.ControlModifier) !== 0) {
              root.service.duplicateSelected()
              event.accepted = true
            } else if (event.key === Qt.Key_Space
                && (event.modifiers & Qt.ControlModifier) !== 0) {
              if (root.keyboardIndex >= 0) root.service.toggleIndex(root.keyboardIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Space) {
              root.previewHoveredOrSelected()
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
              root.moveSelection(-1, event.modifiers)
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
              root.moveSelection(1, event.modifiers)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.keyboardIndex >= 0) root.service.activateIndex(root.keyboardIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
              if (root.keyboardIndex >= 0) root.service.enterIndex(root.keyboardIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_H
                || event.key === Qt.Key_Backspace) {
              root.service.goParent()
              event.accepted = true
            } else if (event.key === Qt.Key_Slash
                || (event.key === Qt.Key_F && event.modifiers & Qt.ControlModifier)) {
              searchField.forceActiveFocus()
              searchField.selectAll()
              event.accepted = true
            } else if (event.key === Qt.Key_Period) {
              root.service.setShowHidden(!root.service.showHidden)
              event.accepted = true
            } else if (event.key === Qt.Key_R && event.modifiers & Qt.ControlModifier) {
              root.service.refreshAll()
              event.accepted = true
            }
          }

          Rectangle {
            id: header
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(46)
            color: Qt.alpha(root.foreground, 0.025)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              text: "QUICKFILE"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: root.secondaryFontSize
              font.bold: true
              font.letterSpacing: 1.2
              renderType: Text.NativeRendering
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Components.IconButton {
                glyph: "󰉖"
                tooltip: "New file"
                onClicked: root.beginEditor("new-file")
              }
              Components.IconButton {
                glyph: "󰉓"
                tooltip: "New folder"
                onClicked: root.beginEditor("new-folder")
              }
              Components.IconButton {
                glyph: "󰑐"
                tooltip: "Refresh"
                active: root.service ? root.service.foregroundBusy : false
                onClicked: if (root.service) root.service.refreshAll()
              }
              Components.IconButton {
                glyph: "󰈉"
                tooltip: "Show hidden files"
                active: root.service ? root.service.showHidden : false
                onClicked: if (root.service) root.service.setShowHidden(!root.service.showHidden)
              }
              Components.IconButton {
                glyph: "󰏘"
                tooltip: "Color, note, and properties"
                active: root.inspectorOpen
                available: root.service && root.service.selectedEntry !== null
                onClicked: root.inspectorOpen = !root.inspectorOpen
              }
              Components.IconButton {
                glyph: "󰅖"
                tooltip: "Close"
                onClicked: root.requestClose()
              }
            }
          }

          Components.Divider {
            anchors.top: header.bottom
            anchors.left: parent.left
            anchors.right: parent.right
          }

          Rectangle {
            id: locationBar
            anchors.top: header.bottom
            anchors.topMargin: 1
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(39)
            color: "transparent"

            Row {
              id: navButtons
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)
              Components.IconButton {
                glyph: "󰁍"
                tooltip: "Back"
                buttonSize: Style.space(26)
                available: root.service && root.service.backStack.length > 0
                onClicked: root.service.goBack()
              }
              Components.IconButton {
                glyph: "󰁔"
                tooltip: "Forward"
                buttonSize: Style.space(26)
                available: root.service && root.service.forwardStack.length > 0
                onClicked: root.service.goForward()
              }
              Components.IconButton {
                glyph: "󰁞"
                tooltip: "Parent folder"
                buttonSize: Style.space(26)
                onClicked: if (root.service) root.service.goParent()
              }
              Components.IconButton {
                glyph: "󰋜"
                tooltip: "Home folder"
                buttonSize: Style.space(26)
                onClicked: if (root.service) root.service.goHome()
              }
            }

            Text {
              anchors.left: navButtons.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.service ? root.service.rootPath : "Loading…"
              color: root.foreground
              opacity: 0.82
              elide: Text.ElideMiddle
              font.family: Style.font.family
              font.pixelSize: root.primaryFontSize
              renderType: Text.NativeRendering
            }
          }

          Rectangle {
            id: searchSurface
            anchors.top: locationBar.bottom
            anchors.left: parent.left
            anchors.leftMargin: Style.space(9)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(9)
            height: Style.space(34)
            radius: Style.cornerRadius > 0 ? Style.space(6) : 0
            color: Style.controlFill(searchField.activeFocus, searchMouse.containsMouse,
              root.foreground, root.accent)
            border.width: Style.controlBorderWidth(searchField.activeFocus, searchMouse.containsMouse)
            border.color: Style.controlBorder(searchField.activeFocus, searchMouse.containsMouse,
              root.foreground, root.accent)

            MouseArea {
              id: searchMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: searchField.forceActiveFocus()
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(9)
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }

            TextField {
              id: searchField
              anchors.left: parent.left
              anchors.leftMargin: Style.space(29)
              anchors.right: searchModeButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              color: root.foreground
              placeholderText: "Search files…"
              placeholderTextColor: Qt.alpha(root.muted, 0.78)
              selectByMouse: true
              font.family: Style.font.family
              font.pixelSize: root.primaryFontSize
              background: Item {}
              onTextEdited: searchDebounce.restart()
            }

            Rectangle {
              id: searchModeButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              width: modeText.implicitWidth + Style.space(10)
              height: Style.space(24)
              radius: Style.cornerRadius > 0 ? Style.space(4) : 0
              color: modeMouse.containsMouse ? Style.hoverFill : "transparent"
              Text {
                id: modeText
                anchors.centerIn: parent
                text: root.service ? String(root.service.searchMode).toUpperCase() : "FUZZY"
                color: root.accent
                font.family: Style.font.family
                font.pixelSize: root.secondaryFontSize
                renderType: Text.NativeRendering
              }
              MouseArea {
                id: modeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (!root.service) return
                  var modes = ["fuzzy", "contains", "exact", "prefix", "suffix", "regex"]
                  var next = (modes.indexOf(root.service.searchMode) + 1) % modes.length
                  root.service.searchMode = modes[next]
                  searchDebounce.restart()
                }
              }
            }

            Timer {
              id: searchDebounce
              interval: 180
              onTriggered: if (root.service)
                root.service.setSearch(searchField.text, root.service.searchMode)
            }
          }

          Rectangle {
            id: devicesHeader
            anchors.top: searchSurface.bottom
            anchors.topMargin: visible ? Style.space(6) : 0
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? Style.space(27) : 0
            // A background scan is transient and must not change layout. Keep
            // this section stable unless a drive or durable error exists.
            visible: root.service && (root.service.volumes.length > 0
              || root.service.volumesError !== "")
            color: "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: (root.service && root.service.volumesCollapsed ? "󰅂" : "󰅀")
                + "  󰋊  DEVICES"
              color: root.service && root.service.volumes.length > 0
                ? root.accent : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              renderType: Text.NativeRendering
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: !root.service ? ""
                : root.service.volumeActionKind !== ""
                  ? root.service.volumeActionKind.toUpperCase() + "ING…"
                : root.service.volumesError !== "" ? "DEVICE ERROR"
                : root.service.volumes.length
                  + (root.service.volumes.length === 1 ? " drive" : " drives")
              color: root.service && root.service.volumesError !== ""
                ? Color.urgent : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.service)
                root.service.volumesCollapsed = !root.service.volumesCollapsed
              ToolTip.visible: containsMouse && root.service
                && root.service.volumesError !== ""
              ToolTip.delay: 600
              ToolTip.text: root.service ? root.service.volumesError : ""
            }
          }

          StableListView {
            id: devicesList
            objectName: "quickfileDevicesList"
            anchors.top: devicesHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? Math.min(contentHeight, Style.space(126)) : 0
            visible: devicesHeader.visible && root.service
              && !root.service.volumesCollapsed && root.service.volumes.length > 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.service ? root.service.volumesModel : null

            delegate: Rectangle {
              id: deviceRow
              required property int index
              required property var rowData
              readonly property var modelData: rowData
              width: devicesList.width
              height: Style.space(42)
              readonly property bool current: root.volumeIsCurrent(modelData)
              color: current ? Style.focusFillColor
                : (deviceMouse.containsMouse ? Style.hoverFill : "transparent")

              Text {
                id: deviceIcon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(19)
                text: root.volumeGlyph(deviceRow.modelData)
                color: deviceRow.current ? root.accent : root.foreground
                font.family: Style.font.family
                font.pixelSize: root.primaryFontSize
                renderType: Text.NativeRendering
              }
              Column {
                anchors.left: deviceIcon.right
                anchors.leftMargin: Style.space(5)
                anchors.right: volumeActionButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                Text {
                  width: parent.width
                  text: String(deviceRow.modelData.name || deviceRow.modelData.device || "Drive")
                  color: deviceRow.current ? root.accent : root.foreground
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: root.primaryFontSize
                  renderType: Text.NativeRendering
                }
                Text {
                  width: parent.width
                  text: root.volumeDetail(deviceRow.modelData)
                  color: root.muted
                  elide: Text.ElideMiddle
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
              }
              MouseArea {
                id: deviceMouse
                z: 1
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.keyboardIndex = -1
                  root.service.openVolume(deviceRow.modelData)
                  keyScope.forceActiveFocus()
                }
              }
              Components.IconButton {
                id: volumeActionButton
                z: 3
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                glyph: deviceRow.modelData.mounted === true ? "󰍃" : "󰐕"
                tooltip: deviceRow.modelData.mounted === true
                  ? "Safely unmount drive" : "Mount and open drive"
                buttonSize: Style.space(27)
                available: root.service && !root.service.volumesBusy
                  && (deviceRow.modelData.mounted === true
                    ? deviceRow.modelData.canUnmount === true
                    : deviceRow.modelData.canMount === true)
                onClicked: {
                  if (deviceRow.modelData.mounted === true)
                    root.service.unmountVolume(deviceRow.modelData)
                  else root.service.openVolume(deviceRow.modelData)
                }
              }
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          }

          Rectangle {
            id: favoritesHeader
            anchors.top: devicesList.bottom
            anchors.topMargin: visible ? Style.space(4) : 0
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? Style.space(25) : 0
            visible: root.service && root.service.favorites.length > 0
            color: "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: (root.service && root.service.favoritesCollapsed ? "󰅂" : "󰅀")
                + "  ★  FAVORITES"
              color: root.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              renderType: Text.NativeRendering
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: root.service ? root.service.favorites.length + " pinned" : ""
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.service)
                root.service.favoritesCollapsed = !root.service.favoritesCollapsed
            }
          }

          StableListView {
            id: favoritesList
            objectName: "quickfileFavoritesList"
            anchors.top: favoritesHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? Math.min(contentHeight, Style.space(152)) : 0
            visible: favoritesHeader.visible && root.service
              && !root.service.favoritesCollapsed
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.service ? root.service.favoritesModel : null

            delegate: Rectangle {
              id: favoriteRow
              required property int index
              required property var rowData
              readonly property var modelData: rowData
              width: favoritesList.width
              height: Style.space(38)
              readonly property bool persistentSelected: root.service
                && root.service.isSelected(String(modelData.token || ""))
              color: persistentSelected ? Style.selectedFill
                : (root.service && root.service.selectedToken === String(modelData.token || ""))
                  ? Style.focusFillColor
                  : (favoriteMouse.containsMouse ? Style.hoverFill : "transparent")

              Text {
                id: favoriteIcon
                anchors.left: parent.left
                // Align children beneath the FAVORITES label instead of the
                // header chevron/star, making the module hierarchy explicit.
                anchors.leftMargin: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: root.fileGlyph(favoriteRow.modelData)
                color: root.entryColor(favoriteRow.modelData)
                font.family: Style.font.family
                font.pixelSize: root.primaryFontSize
                renderType: Text.NativeRendering
              }
              Column {
                anchors.left: favoriteIcon.right
                anchors.leftMargin: Style.space(7)
                anchors.right: unstarButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                Text {
                  width: parent.width
                  text: favoriteRow.modelData.name
                  color: root.entryColor(favoriteRow.modelData)
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: root.primaryFontSize
                  renderType: Text.NativeRendering
                }
                Text {
                  width: parent.width
                  text: favoriteRow.modelData.parentPath || ""
                  color: root.muted
                  elide: Text.ElideMiddle
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
              }
              Text {
                id: unstarButton
                z: 3
                anchors.right: parent.right
                anchors.rightMargin: Style.space(11)
                anchors.verticalCenter: parent.verticalCenter
                text: "󰅖"
                color: unstarMouse.containsMouse ? Color.urgent : root.muted
                font.family: Style.font.family
                font.pixelSize: root.secondaryFontSize
                renderType: Text.NativeRendering
                MouseArea {
                  id: unstarMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(7)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.service.toggleFavoriteEntry(favoriteRow.modelData)
                }
              }
              MouseArea {
                id: favoriteMouse
                z: 1
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: favoriteDrag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                onEntered: {
                  root.hoveredToken = String(favoriteRow.modelData.token || "")
                }
                onExited: if (root.hoveredToken === String(favoriteRow.modelData.token || ""))
                  root.hoveredToken = ""
                onClicked: function(event) {
                  root.keyboardIndex = -1
                  root.service.selectFavorite(favoriteRow.modelData,
                    event.button === Qt.RightButton && favoriteRow.persistentSelected
                      ? "focus" : root.pointerSelectionMode(event.modifiers))
                  keyScope.forceActiveFocus()
                  if (event.button === Qt.RightButton) root.inspectorOpen = true
                }
                onDoubleClicked: root.service.enterEntry(favoriteRow.modelData)
              }
              DragHandler {
                id: favoriteDrag
                target: null
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.ClosedHandCursor
                onActiveChanged: if (active) {
                  root.keyboardIndex = -1
                  if (!favoriteRow.persistentSelected)
                    root.service.selectFavorite(favoriteRow.modelData, "replace")
                }
              }
              Drag.active: favoriteDrag.active
              Drag.dragType: Drag.Automatic
              Drag.supportedActions: Qt.CopyAction
              Drag.mimeData: ({
                "text/uri-list": root.service ? root.service.dragUriList(favoriteRow.modelData) : "",
                "text/plain": root.service ? root.service.dragText(favoriteRow.modelData) : ""
              })
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          }

          Rectangle {
            id: knowledgeHeader
            anchors.top: favoritesList.bottom
            anchors.topMargin: Style.space(4)
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(27)
            color: "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: (root.service && root.service.knowledgeCollapsed ? "󰅂" : "󰅀")
                + "  󰧑  PROJECT KNOWLEDGE"
              color: root.service && root.service.knowledgeFiles.length > 0
                ? root.accent : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              renderType: Text.NativeRendering
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: !root.service ? ""
                : root.service.knowledgeBusy && root.service.knowledgeRootToken === ""
                  ? "SCANNING…"
                : root.service.knowledgeError !== "" ? "INDEX ERROR"
                : (root.service.knowledgeFiles.length
                  + (root.service.knowledgeTruncated ? "+" : "")
                  + " files  ·  ≈" + root.compactTokens(root.service.knowledgeTotalTokens))
              color: root.service && root.service.knowledgeError !== ""
                ? Color.urgent : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.service)
                root.service.knowledgeCollapsed = !root.service.knowledgeCollapsed
            }
          }

          StableListView {
            id: knowledgeList
            objectName: "quickfileKnowledgeList"
            anchors.top: knowledgeHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: visible ? Math.min(contentHeight, Style.space(184)) : 0
            visible: root.service && !root.service.knowledgeCollapsed
              && root.service.knowledgeFiles.length > 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.service ? root.service.knowledgeModel : null
            section.property: "scope"
            section.criteria: ViewSection.FullString
            section.delegate: Rectangle {
              required property string section
              width: knowledgeList.width
              height: Style.space(21)
              color: Qt.alpha(root.foreground, 0.018)
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.section
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                renderType: Text.NativeRendering
              }
            }

            delegate: Rectangle {
              id: knowledgeRow
              required property int index
              required property var rowData
              readonly property var modelData: rowData
              width: knowledgeList.width
              height: Style.space(42)
              readonly property bool persistentSelected: root.service
                && root.service.isSelected(String(modelData.token || ""))
              color: persistentSelected ? Style.selectedFill
                : (root.service && root.service.selectedToken === String(modelData.token || ""))
                  ? Style.focusFillColor
                  : (knowledgeMouse.containsMouse ? Style.hoverFill : "transparent")

              Text {
                id: knowledgeIcon
                anchors.left: parent.left
                // Keep Knowledge children aligned with Favorite children.
                anchors.leftMargin: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(19)
                text: root.fileGlyph(knowledgeRow.modelData)
                color: root.entryColor(knowledgeRow.modelData)
                font.family: Style.font.family
                font.pixelSize: root.primaryFontSize
                renderType: Text.NativeRendering
              }
              Column {
                anchors.left: knowledgeIcon.right
                anchors.leftMargin: Style.space(5)
                anchors.right: knowledgeMeta.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)
                Text {
                  width: parent.width
                  text: (knowledgeRow.modelData.starred === true ? "★  " : "")
                    + String(knowledgeRow.modelData.name || "")
                    + (knowledgeRow.modelData.hasSymlinkBinding === true ? "  󰌷" : "")
                  color: root.entryColor(knowledgeRow.modelData)
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: root.primaryFontSize
                  renderType: Text.NativeRendering
                }
                Text {
                  width: parent.width
                  text: String(knowledgeRow.modelData.displayPath || "")
                  color: root.muted
                  elide: Text.ElideMiddle
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
              }
              Column {
                id: knowledgeMeta
                anchors.right: parent.right
                anchors.rightMargin: Style.space(11)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(126)
                spacing: Style.space(2)
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignRight
                  text: root.agentBadges(knowledgeRow.modelData.agents)
                  color: root.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  renderType: Text.NativeRendering
                }
                Row {
                  anchors.right: parent.right
                  spacing: Style.space(5)
                  Rectangle {
                    width: Style.space(65)
                    height: Style.space(5)
                    radius: height / 2
                    color: Qt.alpha(root.muted, 0.18)
                    Rectangle {
                      width: parent.width * Math.max(0, Math.min(1,
                        Number(knowledgeRow.modelData.tokenEstimate || 0)
                          / Math.max(1, root.service.knowledgeMaxTokens)))
                      height: parent.height
                      radius: parent.radius
                      color: root.accent
                    }
                  }
                  Text {
                    width: Style.space(45)
                    text: "≈" + root.compactTokens(knowledgeRow.modelData.tokenEstimate)
                    horizontalAlignment: Text.AlignRight
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    renderType: Text.NativeRendering
                  }
                }
              }
              MouseArea {
                id: knowledgeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: knowledgeDrag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                onEntered: root.hoveredToken = String(knowledgeRow.modelData.token || "")
                onExited: if (root.hoveredToken === String(knowledgeRow.modelData.token || ""))
                  root.hoveredToken = ""
                onClicked: function(event) {
                  root.keyboardIndex = -1
                  root.service.selectKnowledge(knowledgeRow.modelData,
                    event.button === Qt.RightButton && knowledgeRow.persistentSelected
                      ? "focus" : root.pointerSelectionMode(event.modifiers))
                  keyScope.forceActiveFocus()
                  if (event.button === Qt.RightButton) root.inspectorOpen = true
                }
                onDoubleClicked: root.service.enterEntry(knowledgeRow.modelData)
                ToolTip.visible: containsMouse && root.knowledgeTooltip(knowledgeRow.modelData) !== ""
                ToolTip.delay: 700
                ToolTip.text: root.knowledgeTooltip(knowledgeRow.modelData)
              }
              DragHandler {
                id: knowledgeDrag
                target: null
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.ClosedHandCursor
                onActiveChanged: if (active && !knowledgeRow.persistentSelected) {
                  root.keyboardIndex = -1
                  root.service.selectKnowledge(knowledgeRow.modelData, "replace")
                }
              }
              Drag.active: knowledgeDrag.active
              Drag.dragType: Drag.Automatic
              Drag.supportedActions: Qt.CopyAction
              Drag.mimeData: ({
                "text/uri-list": root.service
                  ? root.service.dragUriList(knowledgeRow.modelData) : "",
                "text/plain": root.service
                  ? root.service.dragText(knowledgeRow.modelData) : ""
              })
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          }

          Rectangle {
            id: contextStrip
            anchors.top: knowledgeList.bottom
            anchors.topMargin: Style.space(4)
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(25)
            color: "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: root.service && root.service.git && root.service.git.branch
                ? ("FILES  ·  󰘬 " + root.service.git.branch) : "FILES"
              color: root.service && root.service.git && root.service.git.branch
                ? root.accent : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              renderType: Text.NativeRendering
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: !root.service ? ""
                : root.service.selectedTokens.length > 1
                  ? root.service.selectedTokens.length + " selected"
                  : (root.service.entries.length + (root.service.truncated ? "+" : "") + " items")
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
          }

          Rectangle {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(28)
            color: Qt.alpha(root.foreground, 0.025)
            border.width: 0

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: !root.service ? ""
                : root.service.actionBusy ? "Working…"
                : root.service.clipboardToken !== ""
                  ? ((root.service.clipboardMode === "cut" ? "Cut: " : "Copy: ")
                    + root.service.clipboardName)
                  : root.service.actionMessage
              color: root.muted
              elide: Text.ElideMiddle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }

          Rectangle {
            id: inspector
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footer.top
            height: !visible ? 0 : Math.min(
              root.inspectorDetailsVisible ? Style.space(468) : Style.space(266),
              blade.height * (root.inspectorDetailsVisible ? 0.48 : 0.34))
            visible: root.inspectorOpen && root.service
              && root.service.selectedEntry !== null
            color: Qt.alpha(root.foreground, 0.018)
            clip: true

            Behavior on height {
              NumberAnimation {
                duration: 150
                easing.type: Easing.OutCubic
              }
            }

            Components.Divider {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
            }

            Rectangle {
              id: inspectorHeader
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: Style.space(70)
              color: "transparent"
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.top: parent.top
                anchors.topMargin: Style.space(10)
                text: root.service && root.service.selectedEntry
                  ? root.service.selectedEntry.name : "Properties"
                color: root.foreground
                elide: Text.ElideRight
                width: parent.width - Style.space(118)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                renderType: Text.NativeRendering
              }
              Components.IconButton {
                anchors.right: inspectorDetailsButton.left
                anchors.rightMargin: Style.space(2)
                anchors.top: parent.top
                anchors.topMargin: Style.space(5)
                glyph: root.service && root.service.selectedEntry
                  && root.service.selectedEntry.starred === true ? "★" : "☆"
                tooltip: root.service && root.service.selectedEntry
                  && root.service.selectedEntry.starred === true ? "Unpin favorite" : "Pin favorite"
                active: root.service && root.service.selectedEntry
                  && root.service.selectedEntry.starred === true
                buttonSize: Style.space(25)
                available: root.service && root.service.selectedEntry && !root.service.actionBusy
                onClicked: root.saveMetadata(!(root.service.selectedEntry.starred === true))
              }
              Components.IconButton {
                id: inspectorDetailsButton
                anchors.right: closeInspectorButton.left
                anchors.rightMargin: Style.space(2)
                anchors.top: parent.top
                anchors.topMargin: Style.space(5)
                glyph: "󰒓"
                tooltip: root.inspectorDetailsVisible
                  ? "Hide Agents and file details"
                  : "Show Agents and file details"
                active: root.inspectorDetailsVisible
                buttonSize: Style.space(25)
                onClicked: root.inspectorDetailsVisible = !root.inspectorDetailsVisible
              }
              Components.IconButton {
                id: closeInspectorButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.top: parent.top
                anchors.topMargin: Style.space(5)
                glyph: "󰅖"
                tooltip: "Close properties"
                buttonSize: Style.space(25)
                onClicked: root.inspectorOpen = false
              }

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(9)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(5)
                spacing: Style.space(4)

                Components.IconButton {
                  glyph: "󰏋"
                  tooltip: "Open"
                  framed: true
                  buttonSize: Style.space(27)
                  available: root.service && root.service.selectedToken !== ""
                  onClicked: root.service.openSelected()
                }
                Components.IconButton {
                  glyph: "󰆏"
                  tooltip: "Copy  ·  Ctrl+C"
                  framed: true
                  buttonSize: Style.space(27)
                  available: root.service && root.service.selectedToken !== ""
                  onClicked: root.service.copySelected()
                }
                Components.IconButton {
                  glyph: "󰆐"
                  tooltip: "Cut  ·  Ctrl+X"
                  framed: true
                  buttonSize: Style.space(27)
                  available: root.service && root.service.selectedToken !== ""
                  onClicked: root.service.cutSelected()
                }
                Components.IconButton {
                  glyph: "󰆒"
                  tooltip: "Paste  ·  Ctrl+V"
                  framed: true
                  buttonSize: Style.space(27)
                  available: root.service && root.service.clipboardToken !== ""
                    && root.service.rootToken !== "" && !root.service.actionBusy
                  onClicked: root.service.pasteHere()
                }
                Components.IconButton {
                  glyph: "󰆴"
                  tooltip: "Duplicate  ·  Ctrl+D"
                  framed: true
                  buttonSize: Style.space(27)
                  available: root.service && root.service.selectedToken !== ""
                    && !root.service.actionBusy
                  onClicked: root.service.duplicateSelected()
                }
                Components.IconButton {
                  glyph: "󰑕"
                  tooltip: "Rename"
                  framed: true
                  buttonSize: Style.space(27)
                  available: root.service && root.service.selectedToken !== ""
                    && root.service.selectedTokens.length <= 1
                    && !root.service.actionBusy
                  onClicked: root.beginEditor("rename")
                }
                Components.IconButton {
                  glyph: "󰩺"
                  tooltip: "Move to Trash"
                  framed: true
                  buttonSize: Style.space(27)
                  available: root.service && root.service.selectedToken !== ""
                  onClicked: root.beginEditor("trash")
                }
              }
            }

            Rectangle {
              id: pathBar
              anchors.top: inspectorHeader.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              height: Style.space(42)
              color: "transparent"

              Text {
                id: pathLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(48)
                text: "Path"
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: root.secondaryFontSize
                renderType: Text.NativeRendering
              }

              TextField {
                id: pathField
                anchors.left: pathLabel.right
                anchors.right: copyPathButton.left
                anchors.rightMargin: Style.space(5)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(30)
                text: !root.service ? ""
                  : root.service.selectedProperties
                    ? String(root.service.selectedProperties.path || "")
                    : root.service.selectedEntry
                      ? String(root.service.selectedEntry.path || "") : ""
                readOnly: true
                selectByMouse: true
                color: root.foreground
                selectionColor: Style.selectionFill
                selectedTextColor: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                background: Rectangle {
                  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                  color: Style.normalFill
                  border.width: Style.normalBorderWidth
                  border.color: Style.normalBorderColor
                }
              }

              Components.IconButton {
                id: copyPathButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                glyph: "󰆏"
                tooltip: "Copy full path"
                buttonSize: Style.space(29)
                available: root.service && root.service.selectedToken !== ""
                  && !root.service.actionBusy
                onClicked: root.service.copySelectedPath()
              }
            }

            Rectangle {
              id: colorBar
              anchors.top: pathBar.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              height: Style.space(38)
              color: "transparent"

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(48)
                text: "Color"
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: root.secondaryFontSize
                renderType: Text.NativeRendering
              }
              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(54)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(7)

                Rectangle {
                  width: Style.space(20)
                  height: width
                  radius: width / 2
                  color: "transparent"
                  border.width: root.colorDraft === "" ? 2 : 1
                  border.color: root.colorDraft === "" ? root.accent : root.muted
                  Text {
                    anchors.centerIn: parent
                    text: "×"
                    color: root.muted
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(2)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.colorDraft = ""
                      root.saveMetadata()
                    }
                  }
                }
                Repeater {
                  model: root.colorChoices
                  delegate: Rectangle {
                    required property var modelData
                    width: Style.space(20)
                    height: width
                    radius: width / 2
                    color: root.paletteColor(String(modelData))
                    border.width: root.colorDraft === String(modelData) ? 3 : 1
                    border.color: root.colorDraft === String(modelData)
                      ? root.foreground : Qt.alpha(root.foreground, 0.32)
                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(2)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.colorDraft = String(parent.modelData)
                        root.saveMetadata()
                      }
                    }
                  }
                }
              }
            }

            Rectangle {
              id: noteBar
              anchors.top: colorBar.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              height: Style.space(76)
              color: "transparent"

              Text {
                id: noteLabel
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.space(9)
                width: Style.space(48)
                text: "Note"
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: root.secondaryFontSize
                renderType: Text.NativeRendering
              }
              TextArea {
                id: noteEditor
                objectName: "quickfileNoteEditor"
                anchors.left: noteLabel.right
                anchors.right: saveNoteButton.left
                anchors.rightMargin: Style.space(6)
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: Style.space(4)
                anchors.bottomMargin: Style.space(5)
                text: root.noteDraft
                placeholderText: "Add a note…"
                color: root.foreground
                placeholderTextColor: Qt.alpha(root.muted, 0.75)
                selectionColor: Style.selectionFill
                selectedTextColor: root.foreground
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                background: Rectangle {
                  radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                  color: Style.controlFill(noteEditor.activeFocus,
                    noteEditor.hovered, root.foreground, root.accent)
                  border.width: Style.controlBorderWidth(noteEditor.activeFocus,
                    noteEditor.hovered)
                  border.color: Style.controlBorder(noteEditor.activeFocus,
                    noteEditor.hovered, root.foreground, root.accent)
                }
                onTextChanged: if (!root.syncingMetadata && root.noteDraft !== text)
                  root.noteDraft = text
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return
                      && (event.modifiers & Qt.ControlModifier) !== 0) {
                    root.saveMetadata()
                    keyScope.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }
              ActionButton {
                id: saveNoteButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                glyph: "󰆓"
                label: "Save"
                enabled: root.service && root.service.selectedEntry
                  && !root.service.actionBusy
                  && (root.noteDirty || root.colorDirty)
                onClicked: root.saveMetadata()
              }
            }

            Rectangle {
              id: knowledgeRegistryBar
              anchors.top: noteBar.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              height: root.inspectorDetailsVisible ? Style.space(78) : Style.space(40)
              color: "transparent"

              Text {
                id: knowledgeRegistryLabel
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.space(9)
                text: "Project Knowledge"
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: root.secondaryFontSize
                renderType: Text.NativeRendering
              }

              Text {
                anchors.left: knowledgeRegistryLabel.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: knowledgeRegistryLabel.verticalCenter
                text: !root.service || !root.service.selectedEntry ? ""
                  : root.service.selectedEntry.isDir === true ? "Files only"
                  : root.knowledgeRegisteredDraft ? "Registered" : "Not registered"
                color: root.knowledgeRegisteredDraft ? root.accent : root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                renderType: Text.NativeRendering
              }

              Row {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Style.space(4)
                spacing: Style.space(5)

                ActionButton {
                  glyph: root.knowledgeRegisteredDraft ? "󰆓" : "󰐕"
                  label: root.knowledgeRegisteredDraft ? "Save" : "Add"
                  enabled: root.service && root.service.selectedEntry
                    && root.service.selectedEntry.isDir !== true
                    && !root.service.actionBusy
                    && (!root.knowledgeRegisteredDraft
                      || !root.sameKnowledgeAgents(root.knowledgeAgentsDraft,
                        root.storedKnowledgeAgents()))
                  onClicked: root.saveKnowledgeRegistry(true)
                }

                ActionButton {
                  visible: root.knowledgeRegisteredDraft
                  glyph: "󰅖"
                  label: "Remove"
                  enabled: root.service && !root.service.actionBusy
                  onClicked: root.saveKnowledgeRegistry(false)
                }
              }

              Text {
                id: knowledgeAgentsLabel
                visible: root.inspectorDetailsVisible
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(12)
                width: Style.space(48)
                text: "Agents"
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: root.secondaryFontSize
                renderType: Text.NativeRendering
              }

              Row {
                visible: root.inspectorDetailsVisible
                anchors.left: knowledgeAgentsLabel.right
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: knowledgeAgentsLabel.verticalCenter
                spacing: Style.space(6)

                Repeater {
                  model: root.knowledgeAgentChoices
                  delegate: Rectangle {
                    id: knowledgeAgentChip
                    required property var modelData
                    readonly property bool chosen:
                      root.knowledgeAgentSelected(String(modelData.key))
                    width: Style.space(34)
                    height: Style.space(23)
                    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                    enabled: root.service && root.service.selectedEntry
                      && root.service.selectedEntry.isDir !== true
                      && !root.service.actionBusy
                    opacity: enabled ? 1 : 0.35
                    color: chosen ? Qt.alpha(root.accent, 0.16) : Style.normalFill
                    border.width: chosen ? 2 : Style.normalBorderWidth
                    border.color: chosen ? root.accent : Style.normalBorderColor

                    Text {
                      anchors.centerIn: parent
                      text: String(knowledgeAgentChip.modelData.label)
                      color: knowledgeAgentChip.chosen ? root.accent : root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: knowledgeAgentChip.chosen
                      renderType: Text.NativeRendering
                    }
                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: knowledgeAgentChip.enabled
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleKnowledgeAgent(
                        String(knowledgeAgentChip.modelData.key))
                      ToolTip.visible: containsMouse
                      ToolTip.delay: 500
                      ToolTip.text: String(knowledgeAgentChip.modelData.name)
                    }
                  }
                }
              }

              ActionButton {
                visible: root.inspectorDetailsVisible
                anchors.right: parent.right
                anchors.verticalCenter: knowledgeAgentsLabel.verticalCenter
                glyph: "󰌷"
                label: "Preview"
                enabled: root.service && root.service.selectedEntry
                  && root.knowledgeRegisteredDraft
                  && !root.service.actionBusy
                onClicked: root.beginKnowledgeLinks()
              }
            }

            ListView {
              id: inspectorDetailsList
              visible: root.inspectorDetailsVisible
              anchors.top: knowledgeRegistryBar.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(8)
              anchors.bottomMargin: Style.space(7)
              spacing: Style.space(3)
              clip: true
              model: root.propertyRows()
              delegate: Row {
                required property var modelData
                width: ListView.view.width
                spacing: Style.space(8)
                Text {
                  width: Style.space(86)
                  text: parent.modelData.label
                  color: root.muted
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
                Text {
                  width: parent.width - Style.space(94)
                  text: parent.modelData.value
                  color: root.foreground
                  elide: Text.ElideMiddle
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
              }
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            }
          }

          StableListView {
            id: fileList
            objectName: "quickfileFileList"
            anchors.top: contextStrip.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: inspector.visible ? inspector.top : footer.top
            anchors.topMargin: Style.space(2)
            anchors.bottomMargin: Style.space(2)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.service ? root.service.entriesModel : null
            currentIndex: root.keyboardIndex

            Connections {
              target: root
              function onKeyboardNavigationRequested(index) {
                fileList.positionViewAtIndex(index, ListView.Contain)
              }
            }

            delegate: Rectangle {
              id: fileRow
              required property int index
              required property var rowData
              readonly property var modelData: rowData
              width: fileList.width
              height: modelData.matchKind === "content"
                ? Style.space(44) : Style.space(29)
              readonly property bool persistentSelected: root.service
                && root.service.isSelected(String(modelData.token || ""))
              color: persistentSelected ? Style.selectedFill
                : (rowMouse.containsMouse ? Style.hoverFill : "transparent")

              Rectangle {
                visible: root.keyboardIndex === fileRow.index
                width: Style.space(2)
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                color: root.accent
              }

              Text {
                id: chevron
                anchors.left: parent.left
                anchors.leftMargin: Style.space(9 + fileRow.modelData.depth * 15)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(13)
                text: fileRow.modelData.isDir && fileRow.modelData.hasChildren
                  ? (fileRow.modelData.expanded ? "󰅀" : "󰅂") : ""
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                renderType: Text.NativeRendering
              }

              Text {
                id: fileIcon
                anchors.left: chevron.right
                anchors.leftMargin: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(17)
                text: root.fileGlyph(fileRow.modelData)
                color: root.entryColor(fileRow.modelData)
                opacity: fileRow.modelData.isHidden ? 0.55 : 0.9
                font.family: Style.font.family
                font.pixelSize: root.primaryFontSize
                renderType: Text.NativeRendering
              }

              Column {
                id: fileText
                anchors.left: fileIcon.right
                anchors.leftMargin: Style.space(4)
                anchors.right: fileMeta.left
                anchors.rightMargin: Style.space(7)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: fileRow.modelData.relativePath || fileRow.modelData.name
                  textFormat: Text.PlainText
                  color: root.entryColor(fileRow.modelData)
                  opacity: fileRow.modelData.isHidden ? 0.58 : 1
                  elide: Text.ElideMiddle
                  font.family: Style.font.family
                  font.pixelSize: root.primaryFontSize
                  renderType: Text.NativeRendering
                }

                Text {
                  width: parent.width
                  visible: fileRow.modelData.matchKind === "content"
                  text: (fileRow.modelData.matchLine
                      ? "L" + fileRow.modelData.matchLine + "  " : "")
                    + String(fileRow.modelData.matchSnippet || "")
                  textFormat: Text.PlainText
                  color: root.muted
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  renderType: Text.NativeRendering
                }
              }

              Row {
                id: fileMeta
                z: 3
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                Text {
                  visible: String(fileRow.modelData.note || "") !== ""
                  text: "󰍩"
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  renderType: Text.NativeRendering
                }
                Text {
                  id: rowStar
                  visible: fileRow.modelData.starred === true || rowMouse.containsMouse
                  text: fileRow.modelData.starred === true ? "★" : "☆"
                  color: fileRow.modelData.starred === true
                    ? root.entryColor(fileRow.modelData) : root.muted
                  font.family: Style.font.family
                  font.pixelSize: root.secondaryFontSize
                  renderType: Text.NativeRendering
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.service.toggleFavoriteEntry(fileRow.modelData)
                  }
                }
                Rectangle {
                  id: matchBadge
                  visible: root.service && root.service.query !== ""
                    && root.matchLabel(fileRow.modelData.matchKind) !== ""
                  width: matchBadgeText.implicitWidth + Style.space(8)
                  height: Style.space(18)
                  radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                  color: Qt.alpha(root.accent, 0.11)
                  Text {
                    id: matchBadgeText
                    anchors.centerIn: parent
                    text: root.matchLabel(fileRow.modelData.matchKind)
                    color: root.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    renderType: Text.NativeRendering
                  }
                }
                Text {
                  text: root.gitLabel(fileRow.modelData.git)
                  color: text === "D" ? Color.urgent : root.accent
                  visible: text !== ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  renderType: Text.NativeRendering
                }
                Text {
                  visible: !root.service || root.service.query === ""
                  text: root.shortTime(fileRow.modelData.modified)
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  renderType: Text.NativeRendering
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: rowDrag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                onEntered: {
                  root.hoveredToken = String(fileRow.modelData.token || "")
                }
                onExited: if (root.hoveredToken === String(fileRow.modelData.token || ""))
                  root.hoveredToken = ""
                onClicked: function(event) {
                  root.keyboardIndex = fileRow.index
                  root.service.selectIndex(fileRow.index,
                    event.button === Qt.RightButton && fileRow.persistentSelected
                      ? "focus" : root.pointerSelectionMode(event.modifiers))
                  keyScope.forceActiveFocus()
                  if (event.button === Qt.RightButton) root.inspectorOpen = true
                }
                onDoubleClicked: function(event) {
                  root.keyboardIndex = fileRow.index
                  root.service.selectIndex(fileRow.index, "replace")
                  root.service.enterIndex(fileRow.index)
                  event.accepted = true
                }
              }

              DragHandler {
                id: rowDrag
                target: null
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.ClosedHandCursor
                onActiveChanged: if (active && !fileRow.persistentSelected) {
                  root.keyboardIndex = fileRow.index
                  root.service.selectIndex(fileRow.index, "replace")
                }
              }
              Drag.active: rowDrag.active
              Drag.dragType: Drag.Automatic
              Drag.supportedActions: Qt.CopyAction
              Drag.mimeData: ({
                "text/uri-list": root.service
                  ? root.service.dragUriList(fileRow.modelData) : "",
                "text/plain": root.service
                  ? root.service.dragText(fileRow.modelData) : ""
              })

              MouseArea {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4 + fileRow.modelData.depth * 15)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                height: parent.height
                enabled: fileRow.modelData.isDir && fileRow.modelData.hasChildren
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.keyboardIndex = fileRow.index
                  root.service.selectIndex(fileRow.index)
                  root.service.toggleExpanded(fileRow.modelData.token)
                }
              }
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          }

          Column {
            anchors.centerIn: fileList
            width: parent.width - Style.space(44)
            spacing: Style.space(8)
            visible: root.service && !root.service.foregroundBusy
              && root.service.entries.length === 0
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.service && root.service.errorMessage ? "󰅚" : "󰉖"
              color: root.service && root.service.errorMessage ? Color.urgent : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.space(28)
              renderType: Text.NativeRendering
            }
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              text: root.service && root.service.errorMessage
                ? root.service.errorMessage
                : (searchField.text ? "No matching files" : "This folder is empty")
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
          }

          Rectangle {
            anchors.fill: parent
            visible: root.editorMode !== ""
            color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.84)
            z: 20
            MouseArea { anchors.fill: parent; onClicked: {} }

            onVisibleChanged: {
              if (visible && root.editorMode !== "trash"
                  && root.editorMode !== "knowledge-links") {
                Qt.callLater(function() {
                  editorField.selectAll()
                  editorField.forceActiveFocus()
                })
              }
            }

            Rectangle {
              anchors.centerIn: parent
              width: parent.width - Style.space(42)
              height: editorContent.implicitHeight + Style.space(32)
              radius: Style.cornerRadius
              color: root.background
              border.width: Math.max(1, Style.normalBorderWidth)
              border.color: root.borderColor

              Column {
                id: editorContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(16)
                spacing: Style.space(12)

                Text {
                  text: root.editorMode === "new-file" ? "Create file"
                    : root.editorMode === "new-folder" ? "Create folder"
                    : root.editorMode === "rename" ? "Rename item"
                    : root.editorMode === "knowledge-links"
                      ? "Connect Project Knowledge"
                    : "Move to Trash?"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  renderType: Text.NativeRendering
                }

                Text {
                  visible: root.editorMode === "trash"
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: !root.service || !root.service.selectedEntry ? ""
                    : root.service.selectedTokens.length > 1
                      ? (root.service.selectedTokens.length
                        + " selected items can be restored from Trash.")
                      : ("“" + root.service.selectedEntry.name
                        + "” can be restored from Trash.")
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  renderType: Text.NativeRendering
                }

                Text {
                  visible: root.editorMode === "knowledge-links"
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: !root.service ? ""
                    : root.service.knowledgeLinkPlan
                      ? ("Source: " + root.service.knowledgeLinkPlan.source
                        + "\nProject: " + root.service.knowledgeLinkPlan.projectRoot)
                      : root.service.actionBusy ? "Preparing a safe link preview…"
                      : "Preparing preview…"
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }

                ListView {
                  id: knowledgeLinkList
                  visible: root.editorMode === "knowledge-links"
                    && root.service && root.service.knowledgeLinkPlan
                  width: parent.width
                  height: visible ? Math.min(contentHeight, Style.space(330)) : 0
                  spacing: Style.space(5)
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  model: visible && root.service.knowledgeLinkPlan
                    ? root.service.knowledgeLinkPlan.entries : []

                  delegate: Rectangle {
                    id: knowledgeLinkRow
                    required property var modelData
                    width: ListView.view.width
                    height: Style.space(55)
                    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                    color: Qt.alpha(root.knowledgeLinkStatusColor(modelData.status), 0.08)
                    border.width: 1
                    border.color: Qt.alpha(
                      root.knowledgeLinkStatusColor(modelData.status), 0.45)

                    Text {
                      id: knowledgeLinkAgent
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(25)
                      text: root.agentBadges([knowledgeLinkRow.modelData.agent])
                      color: root.knowledgeLinkStatusColor(knowledgeLinkRow.modelData.status)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      renderType: Text.NativeRendering
                    }

                    Column {
                      anchors.left: knowledgeLinkAgent.right
                      anchors.leftMargin: Style.space(5)
                      anchors.right: knowledgeLinkState.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)
                      Text {
                        width: parent.width
                        text: String(knowledgeLinkRow.modelData.relativeTarget || "")
                        color: root.foreground
                        elide: Text.ElideMiddle
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        renderType: Text.NativeRendering
                      }
                      Text {
                        width: parent.width
                        text: String(knowledgeLinkRow.modelData.reason || "")
                          + (knowledgeLinkRow.modelData.warning
                            ? " · " + knowledgeLinkRow.modelData.warning : "")
                        color: root.muted
                        elide: Text.ElideRight
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        renderType: Text.NativeRendering
                      }
                    }

                    Text {
                      id: knowledgeLinkState
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(70)
                      horizontalAlignment: Text.AlignRight
                      text: root.knowledgeLinkStatusLabel(knowledgeLinkRow.modelData.status)
                      color: root.knowledgeLinkStatusColor(knowledgeLinkRow.modelData.status)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      renderType: Text.NativeRendering
                    }
                  }

                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                }

                Text {
                  visible: root.editorMode === "knowledge-links"
                    && root.service && root.service.knowledgeLinkPlan
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: !root.service || !root.service.knowledgeLinkPlan ? ""
                    : ((root.service.knowledgeLinkPlan.createdCount !== undefined
                        ? "Created " + root.service.knowledgeLinkPlan.createdCount + " · " : "")
                      + root.service.knowledgeLinkPlan.createCount + " to create · "
                      + root.service.knowledgeLinkPlan.connectedCount + " connected · "
                      + root.service.knowledgeLinkPlan.conflictCount + " conflicts. "
                      + "Existing files and foreign links are never replaced."
                      + (root.service.knowledgeLinkPlan.errors
                          && root.service.knowledgeLinkPlan.errors.length > 0
                        ? " " + root.service.knowledgeLinkPlan.errors.length
                          + " links could not be created." : ""))
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }

                TextField {
                  id: editorField
                  visible: root.editorMode === "new-file"
                    || root.editorMode === "new-folder"
                    || root.editorMode === "rename"
                  text: root.editorValue
                  width: parent.width
                  height: Style.space(36)
                  color: root.foreground
                  selectByMouse: true
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  background: Rectangle {
                    radius: Style.cornerRadius > 0 ? Style.space(5) : 0
                    color: Style.focusFillColor
                    border.width: Style.focusBorderWidth
                    border.color: Style.focusBorderColor
                  }
                  onTextEdited: root.editorValue = text
                  Keys.onEscapePressed: function(event) {
                    root.editorMode = ""
                    keyScope.forceActiveFocus()
                    event.accepted = true
                  }
                  Keys.onReturnPressed: function(event) {
                    root.commitEditor()
                    event.accepted = true
                  }
                }

                Text {
                  visible: root.editorError !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.editorError
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }

                Row {
                  anchors.right: parent.right
                  spacing: Style.space(7)
                  ActionButton {
                    glyph: "󰅖"
                    label: "Cancel"
                    onClicked: {
                      root.editorMode = ""
                      keyScope.forceActiveFocus()
                    }
                  }
                  ActionButton {
                    glyph: root.editorMode === "trash" ? "󰩺"
                      : root.editorMode === "knowledge-links" ? "󰌷" : "󰄬"
                    label: root.editorMode === "trash" ? "Move to Trash"
                      : root.editorMode === "knowledge-links"
                        ? (!root.service || !root.service.knowledgeLinkPlan
                          ? "Preparing…"
                          : "Create " + root.service.knowledgeLinkPlan.createCount)
                      : "Confirm"
                    enabled: root.editorMode !== "knowledge-links"
                      || (root.service && root.service.knowledgeLinkPlan
                        && root.service.knowledgeLinkPlan.createCount > 0
                        && !root.service.actionBusy)
                    onClicked: root.commitEditor()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
