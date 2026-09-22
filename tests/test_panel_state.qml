import QtQuick
import QtTest
import Quickshell
import "plugin" as Quickfile
import "plugin/components/plaintext.js" as PlainText

// Run with tests/run_qml_tests.py. The real Panel renders offscreen against a
// Service with process-starting methods stubbed; no user files are touched.
ShellRoot {
  id: testRoot
  property var fileView: null
  property int assertions: 0

  TestResult { id: objectFinder }

  Quickfile.Service {
    id: fixture
    property bool rejectSave: false
    property var navigatedLocation: null
    property var lastDrop: null
    property string lastConflictPolicy: ""
    property string externalPreviewToken: ""
    property var lastTrashedTokens: []
    initialized: true
    rootPath: "/quickfile-test"
    rootToken: "test-root"
    knowledgeCollapsed: true
    function setPanelVisible(value) {}
    function inspect(token) {}
    function saveSelectedMetadata(color, note, starred) { return !rejectSave }
    function saveSelectedKnowledge(registered, agents) { return !rejectSave }
    function renameSelected(name) { return true }
    function trashSelected() {
      lastTrashedTokens = effectiveSelectionTokens()
      return true
    }
    function reloadTrash() { return true }
    function permanentlyDeleteTrash(uri) { return true }
    property string lastSearchQuery: "unset"
    property var sortCalls: []
    function setSearch(text, mode) {
      lastSearchQuery = String(text || "")
      query = lastSearchQuery
      // The real service reloads and republishes the model; the panel parks
      // its pending cursor until that lands, so the stub must land it too.
      modelChanged()
      return true
    }
    property var measuredTokens: []
    property int folderSizeCancels: 0
    function measureFolder(token) {
      if (String(token) === "") return false
      folderSizeToken = String(token)
      folderSizeBytes = 0
      folderSizeResult = null
      folderSizeError = ""
      measuredTokens.push(String(token))
      return true
    }
    function cancelFolderSize() { folderSizeCancels++; return true }
    function clearFolderSize() {
      folderSizeToken = ""
      folderSizeResult = null
      folderSizeError = ""
      return true
    }
    function setDateFormat(format) {
      if (dateFormats.indexOf(String(format)) < 0 || dateFormat === String(format))
        return false
      dateFormat = String(format)
      return true
    }
    function setSortOrder(order) {
      if (sortOrders.indexOf(String(order)) < 0 || sortOrder === String(order))
        return false
      sortOrder = String(order)
      sortCalls.push(sortOrder)
      return true
    }
    function reloadQuickNav() { return true }
    function navigateQuickNav(location) { navigatedLocation = location; return true }
    function loadPreview(value) {
      previewToken = value.token
      previewData = { kind: "text", token: value.token, name: value.name,
        path: value.path, mime: "text/plain", sizeText: "32 B", text: "<b>plain text</b>\nsecond line" }
      return true
    }
    function dropOnDirectory(destination, tokens, move) {
      lastDrop = { destination: destination, tokens: tokens, uris: [], move: move }
      return true
    }
    function dropExternalUrisOnDirectory(destination, uris, move) {
      lastDrop = { destination: destination, tokens: [], uris: uris, move: move }
      return true
    }
    function retryOperation(policy) { lastConflictPolicy = policy; return true }
    function openPreviewExternally(value) { externalPreviewToken = value ? value.token : ""; return !!value }
  }

  Quickfile.Panel {
    id: panel
    service: fixture
    manifest: ({ id: "m0sthatedman.quickfile", version: "9.9.9" })
  }

  function check(condition, message) {
    if (!condition) throw new Error(message)
    assertions++
  }

  function entry(token, note) {
    return ({ token: token, name: token, path: "/quickfile-test/" + token,
      note: note || "", color: "", starred: false, isDir: false,
      depth: 0, modified: "2026-09-05T09:00:00", registeredKnowledge: false,
      knowledgeAgents: [], agents: [], isKnowledge: false })
  }

  function select(value) {
    fixture.selectedEntry = value
    fixture.selectedToken = value.token
    fixture.selectedTokens = [value.token]
  }

  function metadataChecks() {
    select(entry("draft-file", "stored note"))
    panel.noteDraft = "unsaved note"
    panel.colorDraft = "blue"
    panel.toggleKnowledgeAgent("cursor")
    fixture.selectedEntry = entry("draft-file", "stored note")
    fixture.modelChanged()
    check(panel.noteDraft === "unsaved note", "listing update discarded an unsaved note")
    check(panel.colorDraft === "blue", "listing update discarded a color draft")
    check(panel.knowledgeAgentSelected("cursor"), "listing update discarded agent choices")

    fixture.selectedProperties = entry("draft-file", "stored note")
    check(panel.noteDraft === "unsaved note", "late properties discarded an unsaved note")
    check(panel.colorDraft === "blue", "late properties discarded a color draft")
    check(panel.knowledgeAgentSelected("cursor"), "late properties discarded agent choices")

    select(entry("other-file", "other note"))
    check(panel.noteDraft === "other note", "selection did not load the new note")
    check(panel.colorDraft === "", "selection retained the previous color draft")
    check(!panel.knowledgeAgentSelected("cursor"), "selection retained previous agent choices")
    fixture.selectedProperties = entry("draft-file", "late wrong-token note")
    check(panel.noteDraft === "other note", "wrong-token properties replaced the current note")

    panel.noteDraft = "first saved note"
    panel.colorDraft = "green"
    check(panel.saveMetadata(), "metadata save did not start")
    panel.noteDraft = "typed while saving"
    var saved = entry("other-file", "first saved note")
    saved.color = "green"
    fixture.selectedEntry = saved
    fixture.selectedProperties = saved
    fixture.modelChanged()
    fixture.actionFinished("metadata", true, "Saved")
    check(panel.noteDraft === "typed while saving" && panel.noteDirty,
      "successful save discarded a newer note edit")
    check(panel.colorDraft === "green" && !panel.colorDirty,
      "successful save did not clear the saved color draft")

    check(panel.saveMetadata(), "second metadata save did not start")
    fixture.actionFinished("metadata", false, "Simulated write failure")
    check(panel.noteDraft === "typed while saving" && panel.noteDirty,
      "failed save discarded the draft")
    fixture.rejectSave = true
    check(!panel.saveMetadata() && panel.metadataSavePending === null,
      "rejected save left a pending draft transaction")
    fixture.rejectSave = false

    panel.toggleKnowledgeAgent("codex")
    check(panel.saveKnowledgeRegistry(true), "Knowledge save did not start")
    panel.toggleKnowledgeAgent("cursor")
    var registered = entry("other-file", "first saved note")
    registered.color = "green"
    registered.registeredKnowledge = true
    registered.knowledgeAgents = ["codex"]
    fixture.selectedEntry = registered
    fixture.selectedProperties = registered
    fixture.modelChanged()
    fixture.actionFinished("metadata", true, "Saved")
    check(panel.knowledgeAgentSelected("cursor") && panel.knowledgeDirty,
      "successful Knowledge save discarded newer agent choices")
    check(panel.knowledgeRegisteredDraft,
      "successful Knowledge save did not update the registered state")
    check(panel.noteDraft === "typed while saving", "Knowledge save discarded the note draft")

    select(entry("clean-file", "before"))
    fixture.selectedEntry = entry("clean-file", "changed externally")
    fixture.modelChanged()
    check(panel.noteDraft === "changed externally" && !panel.noteDirty,
      "untouched note did not follow an external metadata change")
  }

  function operationChecks() {
    select(entry("rename-source", ""))
    panel.beginEditor("rename")
    panel.editorValue = "occupied-name"
    panel.commitEditor()
    check(panel.editorMode === "rename",
      "Rename dialog closed before the atomic operation completed")
    fixture.actionFinished("rename", false, "That name already exists")
    check(panel.editorMode === "rename" && panel.editorError === "That name already exists",
      "Rename conflict was not left visible in the dialog")
    fixture.actionFinished("rename", true, "Renamed")
    check(panel.editorMode === "", "Successful rename did not close its dialog")

    select(entry("single-delete", ""))
    check(panel.handleTrashShortcut(Qt.Key_Delete) && panel.editorMode === "trash",
      "Delete did not request Trash confirmation for one selected item")
    panel.commitEditor()
    check(panel.editorMode === "" && fixture.lastTrashedTokens.length === 1
        && fixture.lastTrashedTokens[0] === "single-delete",
      "Delete confirmation did not send the selected item to Trash")
    fixture.selectedTokens = ["single-delete", "second-delete"]
    check(panel.handleTrashShortcut(Qt.Key_Backspace) && panel.editorMode === "trash"
        && fixture.selectedTokens.length === 2,
      "Backspace did not preserve a multi-selection for Trash confirmation")
    check(panel.editorConfirmEnabled(),
      "the Trash confirmation refused the keyboard, leaving the mouse as the "
        + "only way to finish a deletion")
    var dialog = objectFinder.findChild(panel, "quickfileEditorDialog")
    check(dialog !== null && dialog.visible,
      "the Trash confirmation did not raise its dialog")
    panel.commitEditor()
    check(panel.editorMode === "" && fixture.lastTrashedTokens.length === 2,
      "Backspace confirmation did not send the full selection to Trash")
    check(!panel.editorConfirmEnabled(),
      "Return would still commit an editor that is no longer open")

    // Files and folders travel the same route to Trash; a mixed selection must
    // arrive whole rather than collapsing to the anchor row.
    select(entry("mixed-file", ""))
    var folderRow = entry("mixed-folder", "")
    folderRow.isDir = true
    fixture.selectedTokens = ["mixed-file", "mixed-folder"]
    check(panel.handleTrashShortcut(Qt.Key_Delete) && panel.editorMode === "trash",
      "Delete did not confirm a selection holding both a file and a folder")
    panel.commitEditor()
    check(fixture.lastTrashedTokens.length === 2
        && fixture.lastTrashedTokens.indexOf("mixed-folder") >= 0,
      "a folder in a mixed selection was dropped before Trash")

    fixture.clearSelection()
    check(panel.handleTrashShortcut(Qt.Key_Delete) && panel.editorMode === "",
      "Delete without a selection opened a destructive action")

    fixture.trashEntries = [{ uri: "trash:///old.txt", name: "old.txt",
      originalPath: "/quickfile-test/old.txt" }]
    panel.openTrashBrowser()
    check(panel.editorMode === "trash-browser", "Trash browser did not open")
    panel.confirmTrashDelete(fixture.trashEntries[0])
    check(panel.editorMode === "trash-delete" && panel.pendingTrashEntry.name === "old.txt",
      "Permanent delete did not require a separate confirmation state")
    check(panel.editorConfirmEnabled(),
      "permanent deletion could not be confirmed from the keyboard")
    panel.commitEditor()
    check(panel.editorMode === "trash-browser" && panel.pendingTrashEntry === null,
      "Confirmed permanent delete did not return to Trash")
    check(!panel.editorConfirmEnabled(),
      "Return in the Trash browser would fire the confirm action of a dialog "
        + "that shows no confirm button")
  }

  function dropEvent(formats, values) {
    return { formats: formats, supportedActions: Qt.CopyAction | Qt.MoveAction,
      getDataAsString: function(format) { return values[format] || "" } }
  }

  // A filename is untrusted input. Rendered as rich text, a name like
  // `<img src="https://…">` would make the panel fetch a remote resource the
  // moment the file is selected or hovered, so every sink that shows a name,
  // path or backend string has to render it literally.
  function untrustedTextChecks() {
    var hostile = '<img src="https://attacker.invalid/pixel.png">'
    select(entry(hostile, ""))
    var inspectorName = objectFinder.findChild(panel, "quickfileInspectorName")
    check(inspectorName !== null, "could not find the inspector name sink")
    check(inspectorName.textFormat === Text.PlainText,
      "the inspector name sink was not pinned to plain text")
    check(inspectorName.text === hostile,
      "a markup-like filename was not rendered literally")

    var escaped = PlainText.tooltip(hostile)
    check(escaped.indexOf("<img") === -1,
      "a markup-like value reached a tooltip with its tag intact")
    check(escaped.indexOf("&lt;img") !== -1,
      "tooltip escaping dropped the literal text instead of escaping it")
    check(PlainText.tooltip("") === "", "an empty tooltip gained markup")
    check(PlainText.tooltip("a & b").indexOf("a &amp; b") !== -1,
      "an ampersand in a name was not escaped")

    select(entry("plain-name", ""))
  }

  // A build artefact's version lives in the middle of its name, exactly where
  // an elided row hides it. Hovering a row that does not fit must reveal the
  // whole name, and the reveal must not resurrect the rich-text hazard: the
  // shared ToolTip sink parses AutoText, so the name reaches it escaped.
  function elidedNameTooltipChecks() {
    var hostile = '<img src="https://attacker.invalid/pixel.png">'
    var longName = "apollo-alarm-1.0.4-" + hostile + "-configured-release-bundle"
      + "-with-a-very-long-tail-that-cannot-possibly-fit-in-one-row.zip.sha256"
    var rows = fixture.entries.slice()
    var longRow = entry(longName, "")
    rows.push(longRow)
    fixture.entries = rows
    fixture.entriesModel.append({ rowData: longRow, scope: "" })
    var longIndex = rows.length - 1
    fileView.forceLayout()
    fileView.positionViewAtIndex(longIndex, ListView.Beginning)
    fileView.forceLayout()

    var longItem = fileView.itemAtIndex(longIndex)
    check(longItem !== null, "could not realise the row with the long name")
    var longLabel = objectFinder.findChild(longItem, "quickfileFileNameLabel")
    check(longLabel !== null, "could not find the file name sink of the long row")
    check(longLabel.text === longName,
      "the row did not carry the whole name behind its elision")
    check(longLabel.truncated,
      "a name far wider than the row was not reported as truncated")
    check(longLabel.hoverTooltip.indexOf(longName.substring(0, 19)) !== -1
        && longLabel.hoverTooltip.indexOf("zip.sha256") !== -1,
      "the hover tooltip did not carry the full name")
    check(longLabel.hoverTooltip.indexOf("<img") === -1
        && longLabel.hoverTooltip.indexOf("&lt;img") !== -1,
      "a markup-like name reached the hover tooltip with its tag intact")

    fileView.positionViewAtIndex(0, ListView.Beginning)
    fileView.forceLayout()
    var shortItem = fileView.itemAtIndex(0)
    var shortLabel = shortItem === null
      ? null : objectFinder.findChild(shortItem, "quickfileFileNameLabel")
    check(shortLabel !== null && !shortLabel.truncated,
      "a name that fits its row was reported as truncated, so it would raise a "
        + "tooltip over information the user can already read")

    fixture.entriesModel.remove(longIndex)
    fixture.entries = rows.slice(0, longIndex)
    fileView.forceLayout()
  }

  function searchFocusChecks() {
    var searchField = objectFinder.findChild(panel, "quickfileSearchField")
    var listFocus = objectFinder.findChild(panel, "quickfileListFocus")
    check(searchField !== null && listFocus !== null,
      "could not find the search field and the list focus sink")

    // A printable key that no shortcut claims must not reach a text sink:
    // that is what used to drop the user into search mid-navigation.
    check(panel.isTypingKey({ key: Qt.Key_G, text: "g", modifiers: Qt.NoModifier }),
      "a plain letter was not recognised as typing to swallow")
    check(panel.isTypingKey({ key: Qt.Key_G, text: "G", modifiers: Qt.ShiftModifier }),
      "a shifted letter was not recognised as typing to swallow")
    check(!panel.isTypingKey({ key: Qt.Key_C, text: "\u0003", modifiers: Qt.ControlModifier }),
      "a Control chord was mistaken for typing and would lose its shortcut")
    check(!panel.isTypingKey({ key: Qt.Key_Down, text: "", modifiers: Qt.NoModifier }),
      "an arrow key was mistaken for typing")

    var before = fixture.entries[3]
    select(before)
    panel.keyboardIndex = 3
    panel.beginSearch()
    check(searchField.activeFocus, "the slash key did not move focus into search")
    check(panel.searchReturnToken === before.token,
      "entering search did not remember the row to come back to")

    searchField.text = "row-1"
    fixture.query = "row-1"
    fixture.lastSearchQuery = "unset"
    // Land the cursor somewhere else, the way picking through results does.
    fixture.selectIndex(11)
    panel.keyboardIndex = 11
    panel.endSearch()
    check(fixture.lastSearchQuery === "",
      "leaving search kept the query alive behind an empty field")
    check(searchField.text === "", "leaving search left text in the field")
    check(listFocus.activeFocus,
      "leaving search did not hand the keyboard back to the list")
    check(panel.keyboardIndex === 3 && fixture.selectedToken === before.token,
      "Escape did not restore the row that was selected before the search")

    // Nothing selected before the search means the first row, not nowhere.
    fixture.clearSelection()
    panel.keyboardIndex = -1
    panel.beginSearch()
    check(panel.searchReturnToken === "",
      "entering search from an empty selection invented a row to return to")
    searchField.text = "row-2"
    fixture.query = "row-2"
    panel.endSearch()
    check(panel.keyboardIndex === 0
        && fixture.selectedToken === fixture.entries[0].token,
      "Escape from a search started without a selection did not land on the "
        + "first row")
  }

  function sortChecks() {
    var label = objectFinder.findChild(panel, "quickfileSortLabel")
    check(label !== null, "could not find the sort control")
    check(fixture.sortOrder === "name" && label.text.indexOf("A→Z") >= 0,
      "the sort control did not show the active order")
    check(panel.sortLabel("modified") === "NEW"
        && panel.sortLabel("size") === "SIZE"
        && panel.sortLabel("type") === "TYPE",
      "a sort order was missing its label")

    fixture.cycleSortOrder(1)
    check(fixture.sortOrder === "name-desc" && label.text.indexOf("Z→A") >= 0,
      "cycling forward did not advance the order or its label")
    fixture.cycleSortOrder(-1)
    check(fixture.sortOrder === "name", "cycling back did not return the order")
    fixture.cycleSortOrder(-1)
    check(fixture.sortOrder === "type",
      "cycling back from the first order did not wrap to the last")
    fixture.setSortOrder("name")

    var sortButton = objectFinder.findChild(panel, "quickfileSortButton")
    check(sortButton !== null && sortButton.visible,
      "the sort control was hidden while the folder tree was on screen")
    fixture.query = "row"
    check(!sortButton.visible,
      "the sort control stayed visible over relevance-ranked search results")
    fixture.query = ""
  }

  function choiceMenuChecks() {
    var menu = objectFinder.findChild(panel, "quickfileChoiceMenu")
    var sortButton = objectFinder.findChild(panel, "quickfileSortButton")
    var modeButton = objectFinder.findChild(panel, "quickfileSearchModeButton")
    check(menu !== null && sortButton !== null && modeButton !== null,
      "could not find the picker and the two controls that open it")
    check(!menu.visible, "the picker was open before anything asked for it")

    fixture.setSortOrder("size")
    panel.openChoiceMenu("sort", sortButton, 4, 4)
    check(menu.visible, "right-clicking the sort control did not open the picker")
    check(panel.choiceOptions.length === fixture.sortOrders.length,
      "the picker did not offer every sort order")
    check(panel.choiceActiveValue() === "size",
      "the picker did not mark the order that is actually in force")
    panel.applyChoice("type")
    check(fixture.sortOrder === "type",
      "picking an order from the list did not apply it")
    menu.close()
    check(panel.choiceKind === "", "closing the picker left it pointed at a control")

    fixture.searchMode = "fuzzy"
    panel.openChoiceMenu("search-mode", modeButton, 4, 4)
    check(panel.choiceOptions.length === 7 && panel.choiceActiveValue() === "fuzzy",
      "the picker did not offer the search modes with the active one marked")
    panel.applyChoice("regex")
    check(fixture.searchMode === "regex",
      "picking a search mode from the list did not apply it")
    menu.close()

    // Left click keeps rotating; the list is only the second way in.
    panel.cycleSearchMode(1)
    check(fixture.searchMode === "smart",
      "rotating after regex did not reach Smart Search")
    panel.cycleSearchMode(1)
    check(fixture.searchMode === "fuzzy",
      "rotating past Smart Search did not wrap to the first mode")
    panel.cycleSearchMode(-1)
    check(fixture.searchMode === "smart",
      "rotating backwards through the search modes did not wrap")
    fixture.searchMode = "fuzzy"
    fixture.setSortOrder("name")
  }

  function smartOnboardingChecks() {
    fixture.searchMode = "smart"
    fixture.settingsLoaded = true
    fixture.semanticStatusLoaded = true
    fixture.semanticInstalled = false
    fixture.semanticState = "not-installed"
    fixture.smartOnboardingDone = false
    check(fixture.smartOnboardingDue && panel.editorMode === "smart-onboarding",
      "Smart Search without its model did not offer the one-time tip")
    check(panel.editorConfirmEnabled(), "the tip's Download button was not available")
    panel.cancelEditor()
    check(panel.editorMode === "" && fixture.smartOnboardingDone && !fixture.smartOnboardingDue,
      "Not now did not close the tip for good")
    panel.applySearchMode("fuzzy")
    panel.applySearchMode("smart")
    check(panel.editorMode === "", "picking Smart again reopened an answered tip")

    fixture.smartOnboardingDone = false
    check(panel.editorMode === "smart-onboarding", "the tip did not return once it was due again")
    panel.commitEditor()
    check(panel.editorMode === "semantic-install" && fixture.smartOnboardingDone,
      "Download did not lead to the installer's confirmation")
    panel.dismissEditor()
    fixture.semanticStatusLoaded = false
    fixture.semanticState = "checking"
  }

  function dateFormatChecks() {
    // A fixed clock: 2026-09-09 14:00 local. Every expectation below is an
    // offset from it, so the assertions do not rot with the calendar.
    var now = new Date(2026, 8, 9, 14, 0, 0).getTime()
    function at(msAgo) { return ({ modifiedEpoch: (now - msAgo) / 1000 }) }
    // A wall clock an age away from the fixed one is built as a calendar date,
    // not as a subtraction: in a timezone that observes daylight saving, an
    // offset in milliseconds lands an hour off the hour it names, and an
    // assertion spelling out the clock would then fail on the calendar rather
    // than on the code.
    function on(year, month, dayOfMonth) {
      return ({ modifiedEpoch: new Date(year, month, dayOfMonth, 14, 0, 0).getTime() / 1000 })
    }
    var minute = 60000, hour = 3600000, day = 86400000

    fixture.dateFormat = "full"
    check(panel.dateLabel(at(0), now) === "2026-09-09 14:00",
      "the full format stopped producing the stamp it always has")
    check(panel.dateLabel(on(2025, 10, 13), now) === "2025-11-13 14:00",
      "the full format changed shape for an old file")

    fixture.dateFormat = "adaptive"
    check(panel.dateLabel(at(0), now) === "Sep  9 14:00",
      "adaptive did not pad a single-digit day to a fixed width")
    check(panel.dateLabel(at(2 * day), now) === "Sep  7 14:00",
      "adaptive dropped the clock time from a recent file")
    check(panel.dateLabel(at(300 * day), now) === "Nov 13  2025",
      "adaptive did not swap the clock for the year past six months")

    fixture.dateFormat = "smart"
    check(panel.dateLabel(at(3 * hour), now) === "11:00",
      "smart showed more than the clock for a file touched today")
    check(panel.dateLabel(at(28 * hour), now) === "Yesterday 10:00",
      "smart did not name yesterday")
    check(panel.dateLabel(at(3 * day), now) === "Sun 14:00",
      "smart did not name the weekday inside the last week")
    check(panel.dateLabel(at(30 * day), now) === "10 Aug",
      "smart kept a weekday past the week, or dropped the day of the month")
    check(panel.dateLabel(at(300 * day), now) === "Nov 2025",
      "smart did not fall back to month and year for another year")

    fixture.dateFormat = "relative"
    check(panel.dateLabel(at(0), now) === "now"
        && panel.dateLabel(at(-hour), now) === "now",
      "relative did not collapse the present, or read a future file as negative")
    check(panel.dateLabel(at(12 * minute), now) === "12m"
        && panel.dateLabel(at(5 * hour), now) === "5h"
        && panel.dateLabel(at(3 * day), now) === "3d"
        && panel.dateLabel(at(14 * day), now) === "2w"
        && panel.dateLabel(at(240 * day), now) === "8mo"
        && panel.dateLabel(at(800 * day), now) === "2y",
      "a relative step did not produce its unit")

    // Unit boundaries: each step must flip exactly where it claims to.
    check(panel.dateLabel(at(24 * hour), now) === "1d"
        && panel.dateLabel(at(24 * hour - minute), now) === "23h",
      "the hour-to-day boundary is off")
    check(panel.dateLabel(at(7 * day), now) === "1w"
        && panel.dateLabel(at(7 * day - minute), now) === "6d",
      "the day-to-week boundary is off")
    check(panel.dateLabel(at(30 * day), now) === "1mo"
        && panel.dateLabel(at(30 * day - minute), now) === "4w",
      "the week-to-month boundary is off")
    check(panel.dateLabel(at(365 * day), now) === "1y"
        && panel.dateLabel(at(365 * day - minute), now) === "12mo",
      "the month-to-year boundary is off")

    fixture.dateFormat = "adaptive"
    check(panel.dateLabel(at(179 * day), now).indexOf(":") > 0,
      "adaptive dropped the clock time inside six months")
    check(panel.dateLabel(at(181 * day), now).indexOf(":") < 0,
      "adaptive kept the clock time past six months")

    fixture.dateFormat = "smart"
    check(panel.dateLabel(at(6 * day), now).indexOf(":") > 0
        && panel.dateLabel(at(6 * day), now).length <= 9,
      "smart lost the weekday form on the sixth day")
    check(panel.dateLabel(at(7 * day), now) === "2 Sep",
      "smart kept a weekday on the seventh day")

    // Files dated in the future must not read as negative ages.
    fixture.dateFormat = "relative"
    check(panel.dateLabel(at(-30 * day), now) === "now",
      "a file dated in the future produced a negative age")
    fixture.dateFormat = "adaptive"
    check(panel.dateLabel(at(-30 * day), now).indexOf(":") < 0,
      "adaptive gave a future file a clock time it cannot mean")

    fixture.dateFormat = "off"
    check(panel.dateLabel(at(hour), now) === "",
      "the off format still produced a label")

    // Rows that carry no usable time must not print one, in any mode.
    for (var i = 0; i < fixture.dateFormats.length; i++) {
      fixture.dateFormat = fixture.dateFormats[i]
      check(panel.dateLabel({}, now) === "" && panel.dateLabel(null, now) === ""
          && panel.dateLabel({ modified: "not a date" }, now) === "",
        fixture.dateFormats[i] + " invented a timestamp for a row that has none")
    }

    // The ISO string is the fallback for rows without an epoch — the shape
    // every test fixture in this file uses.
    fixture.dateFormat = "full"
    check(panel.dateLabel({ modified: "2026-09-05T09:00:00" }, now) === "2026-09-05 09:00",
      "a row with only an ISO stamp lost its timestamp")
    check(panel.dateTooltip({ modified: "2026-09-05T09:00:33" }) === "2026-09-05 09:00:33",
      "the hover tooltip did not carry the whole stamp")
    check(panel.dateTooltip({}) === "", "the tooltip invented a stamp")

    // Epoch and ISO must name the same instant, or the same file would read
    // differently depending on which field survived.
    var moment = new Date(2026, 8, 5, 9, 0, 0)
    var formats = fixture.dateFormats
    for (var m = 0; m < formats.length; m++) {
      fixture.dateFormat = formats[m]
      check(panel.dateLabel({ modifiedEpoch: moment.getTime() / 1000 }, now)
          === panel.dateLabel({ modified: "2026-09-05T09:00:00+04:00" }, now),
        formats[m] + " read the epoch and the ISO stamp as different instants")
    }

    // The column is measured once for the whole list, so the name column's
    // ellipsis point cannot move from row to row.
    var widths = ({})
    for (var f = 0; f < fixture.dateFormats.length; f++) {
      fixture.dateFormat = fixture.dateFormats[f]
      widths[fixture.dateFormats[f]] = panel.dateColumnWidth
    }
    check(widths["off"] === 0, "the off format still reserved column width")
    check(widths["relative"] < widths["smart"]
        && widths["smart"] < widths["full"],
      "the reserved column width did not follow the length of the format")
    fixture.dateFormat = "full"
  }

  function dateChipChecks() {
    var chip = objectFinder.findChild(panel, "quickfileDateFormatButton")
    var label = objectFinder.findChild(panel, "quickfileDateFormatLabel")
    check(chip !== null && label !== null, "could not find the date format chip")
    check(chip.visible && label.text.indexOf("FULL") >= 0,
      "the chip did not show the active format")

    fixture.cycleDateFormat(1)
    check(fixture.dateFormat === "adaptive" && label.text.indexOf("ADAPT") >= 0,
      "clicking the chip did not advance the format or its label")
    fixture.cycleDateFormat(-1)
    check(fixture.dateFormat === "full", "cycling back did not return the format")
    fixture.cycleDateFormat(-1)
    check(fixture.dateFormat === "off", "cycling back from the first did not wrap")

    panel.openChoiceMenu("date-format", chip, 4, 4)
    check(panel.choiceOptions.length === fixture.dateFormats.length,
      "the picker did not offer every date format")
    check(panel.choiceActiveValue() === "off",
      "the picker did not mark the format that is in force")
    panel.applyChoice("smart")
    check(fixture.dateFormat === "smart",
      "picking a format from the list did not apply it")
    objectFinder.findChild(panel, "quickfileChoiceMenu").close()

    var timestamp = objectFinder.findChild(fileView.itemAtIndex(0), "quickfileRowTimestamp")
    var second = objectFinder.findChild(fileView.itemAtIndex(1), "quickfileRowTimestamp")
    check(timestamp !== null && timestamp.visible,
      "the row lost its timestamp while a format was active")

    // The whole point of the reserved column: two rows in the same mode must
    // reserve the same width, or the name's ellipsis point moves row to row.
    fixture.dateFormat = "smart"
    check(second !== null && timestamp.width === second.width,
      "two rows reserved different widths for the same format")
    var wide = timestamp.width
    fixture.dateFormat = "relative"
    check(timestamp.width < wide,
      "the reserved width did not shrink with a shorter format")

    // The row keeps its own hover: a hover-accepting item over the timestamp
    // would take the row fill, the star and the hovered token with it.
    check(objectFinder.findChild(timestamp, "quickfileRowTimestampMouse") === null,
      "the timestamp grew its own hover target and stole the row's")

    fixture.dateFormat = "full"
    fixture.dateFormat = "off"
    check(!timestamp.visible, "the off format left the column drawn")

    fixture.dateFormat = "full"
    fixture.query = "row"
    check(!chip.visible,
      "the chip stayed visible over a search, where the column is hidden")
    check(!timestamp.visible,
      "the row timestamp reappeared during a search")
    fixture.query = ""
  }

  function focusPulseChecks() {
    var searchPulse = objectFinder.findChild(panel, "quickfileSearchPulse")
    var inspectorPulse = objectFinder.findChild(panel, "quickfileInspectorPulse")
    check(searchPulse !== null && inspectorPulse !== null,
      "could not find the focus outlines")

    // Nothing is drawn until something asks for attention. The search outline
    // has legitimately run by now — the search checks above used it — so the
    // untouched one is the inspector's.
    check(!inspectorPulse.active && inspectorPulse.opacity === 0
        && !inspectorPulse.visible,
      "the inspector outline was drawn before anything landed there")

    panel.beginSearch()
    check(searchPulse.active && searchPulse.visible,
      "entering search did not mark the field the cursor moved to")
    check(!searchPulse.enabled,
      "the outline accepts input and could swallow a click on what it marks")

    panel.revealInspector()
    check(panel.inspectorOpen && inspectorPulse.active,
      "opening the inspector did not mark it")

    // Leaving search hands the cursor back to a row, and that row marks itself.
    var pulsed = []
    var handler = function(token) { pulsed.push(token) }
    panel.rowPulseRequested.connect(handler)
    panel.pulseRow(fixture.entries[2].token)
    check(pulsed.length === 1 && pulsed[0] === fixture.entries[2].token,
      "the row outline was not addressed to the row that took the cursor")
    panel.pulseRow("")
    check(pulsed.length === 1,
      "an empty token still asked some row to mark itself")
    panel.rowPulseRequested.disconnect(handler)

    var row = objectFinder.findChild(fileView.itemAtIndex(0), "quickfileRowPulse")
    check(row !== null && !row.active,
      "a row outline was drawn without being asked")
    panel.pulseRow(fixture.entries[0].token)
    check(row.active,
      "the row that took the cursor did not mark itself")

    panel.inspectorOpen = false
  }

  function shortcutChecks() {
    var mods = Qt.NoModifier
    select(entry("shortcut-target", ""))
    panel.editorMode = ""
    panel.inspectorOpen = false

    check(panel.handleLetterShortcut(Qt.Key_P, mods) && panel.inspectorOpen
        && fixture.inspectorTab === "properties",
      "P did not open the inspector on Properties")
    panel.inspectorOpen = false

    check(panel.handleLetterShortcut(Qt.Key_N, mods)
        && panel.editorMode === "new-file",
      "N did not open the new file dialog")
    panel.editorMode = ""
    check(panel.handleLetterShortcut(Qt.Key_N, Qt.ShiftModifier)
        && panel.editorMode === "new-folder",
      "Shift+N did not open the new folder dialog")
    panel.editorMode = ""
    check(panel.handleLetterShortcut(Qt.Key_R, mods)
        && panel.editorMode === "rename",
      "R did not open the rename dialog")
    panel.editorMode = ""

    var hidden = fixture.showHidden
    check(panel.handleLetterShortcut(Qt.Key_H, mods)
        && fixture.showHidden !== hidden,
      "H did not toggle hidden files")
    fixture.setShowHidden(hidden)

    fixture.setSortOrder("name")
    check(panel.handleLetterShortcut(Qt.Key_S, mods)
        && fixture.sortOrder === "name-desc",
      "S did not advance the sort order")
    check(panel.handleLetterShortcut(Qt.Key_S, Qt.ShiftModifier)
        && fixture.sortOrder === "name",
      "Shift+S did not walk the sort order back")

    fixture.setDateFormat("full")
    check(panel.handleLetterShortcut(Qt.Key_T, mods)
        && fixture.dateFormat === "adaptive",
      "T did not advance the time format")
    check(panel.handleLetterShortcut(Qt.Key_T, Qt.ShiftModifier)
        && fixture.dateFormat === "full",
      "Shift+T did not walk the time format back")

    // A chord must still reach the branch that owns it.
    check(!panel.handleLetterShortcut(Qt.Key_R, Qt.ControlModifier),
      "Ctrl+R was swallowed by the plain-letter shortcuts, losing Reload")
    check(!panel.handleLetterShortcut(Qt.Key_C, Qt.ControlModifier)
        && !panel.handleLetterShortcut(Qt.Key_T,
          Qt.ControlModifier | Qt.ShiftModifier),
      "a Control chord was claimed by the plain-letter shortcuts")
    check(!panel.handleLetterShortcut(Qt.Key_G, mods),
      "an unbound letter reported itself as handled")

    // The sheet and the handler have to name the same keys.
    var groups = panel.shortcutGroups()
    var listed = ""
    for (var g = 0; g < groups.length; g++) {
      check(String(groups[g].title) !== "" && groups[g].rows.length > 0,
        "a shortcut group was empty")
      for (var r = 0; r < groups[g].rows.length; r++) {
        var row = groups[g].rows[r]
        check(row.length === 2 && String(row[0]) !== "" && String(row[1]) !== "",
          "a shortcut row was missing its key or its meaning")
        listed += row[0] + "\n"
      }
    }
    var claimed = ["P", "F", "R", "H", "N", "Shift+N", "S · Shift+S",
      "T · Shift+T", "Space", "/"]
    for (var c = 0; c < claimed.length; c++)
      check(listed.indexOf(claimed[c]) >= 0,
        "the shortcut sheet does not mention " + claimed[c])

    var version = objectFinder.findChild(panel, "quickfileHeaderVersion")
    check(version !== null && version.visible && version.text === "9.9.9",
      "the header did not carry the version the host read from the manifest")
    var wordmark = objectFinder.findChild(panel, "quickfileHeaderTitle")
    check(wordmark !== null && version.font.pixelSize < wordmark.font.pixelSize,
      "the version was not drawn smaller than the wordmark it annotates")
    check(version.y <= wordmark.y + 1,
      "the version sat on the wordmark's baseline instead of above it")
    check(panel.pluginVersion === "9.9.9", "the version did not reach the panel")

    var link = objectFinder.findChild(panel, "quickfileAuthorLink")
    check(link !== null && link.url === "https://restless-brain.com",
      "the shortcut sheet lost its author link")

    var help = objectFinder.findChild(panel, "quickfileHelpButton")
    check(help !== null, "could not find the shortcuts button")
    check(!panel.editorConfirmEnabled(),
      "the shortcut sheet offered a confirm action it has nothing to confirm")
    panel.beginEditor("shortcuts")
    check(panel.editorMode === "shortcuts" && !panel.editorConfirmEnabled(),
      "the shortcut sheet opened with a confirm button")
    panel.editorMode = ""
  }

  function folderSizeChecks() {
    check(panel.sizeText(0) === "0 B" && panel.sizeText(2048) === "2.0 KiB"
        && panel.sizeText(3 * 1024 * 1024) === "3.0 MiB",
      "the byte formatter did not scale its units")

    var file = ({ kind: "file", token: "plain-file", sizeText: "12 B",
      allocatedSizeText: "4.0 KiB" })
    check(panel.folderSizeText(file) === "12 B · 4.0 KiB allocated",
      "a file's size row stopped reporting what the backend measured")

    // A directory nobody is walking reads exactly as before.
    var folder = ({ kind: "directory", token: "folder-token", sizeText: "2.7 KiB",
      allocatedSizeText: "0 B" })
    fixture.folderSizeToken = ""
    check(panel.folderSizeText(folder) === "2.7 KiB · 0 B allocated",
      "an unmeasured folder did not fall back to its own stat")

    fixture.folderSizeToken = "folder-token"
    fixture.folderSizeBusy = true
    fixture.folderSizeBytes = 5 * 1024 * 1024
    check(panel.folderSizeText(folder) === "5.0 MiB so far  ·  counting…",
      "a folder being walked did not report its running total")

    fixture.folderSizeBusy = false
    fixture.folderSizeResult = ({ sizeText: "5.0 MiB", truncated: false })
    fixture.folderSizeFiles = 120
    fixture.folderSizeDirectories = 8
    check(panel.folderSizeText(folder) === "5.0 MiB  ·  120 files  ·  8 folders",
      "a finished walk did not report the total and what it counted")

    // Counts abbreviate so the row cannot outgrow its column and elide into
    // something unreadable.
    fixture.folderSizeFiles = 211625
    fixture.folderSizeDirectories = 33067
    check(panel.folderSizeText(folder) === "5.0 MiB  ·  211.6k files  ·  33.1k folders",
      "large counts were not abbreviated to fit the row")
    check(panel.folderSizeText(folder).length <= 44,
      "the size row is long enough to elide in the properties column")

    fixture.folderSizeResult = ({ sizeText: "5.0 MiB", truncated: true })
    check(panel.folderSizeText(folder).indexOf("5.0 MiB+") === 0,
      "a walk that stopped early did not mark its total as a floor")
    fixture.folderSizeFiles = 120
    fixture.folderSizeDirectories = 8

    // A stopped walk must not pass its partial total off as the answer.
    fixture.folderSizeResult = null
    check(panel.folderSizeText(folder) === "5.0 MiB  ·  stopped",
      "a stopped walk presented its partial total as final")

    fixture.folderSizeError = "Permission denied"
    check(panel.folderSizeText(folder).indexOf("Permission denied") > 0,
      "a failed walk hid its reason")
    fixture.folderSizeError = ""
    fixture.folderSizeToken = ""
    fixture.folderSizeResult = null

    // The walk follows what the inspector is showing, and only that.
    fixture.measuredTokens = []
    fixture.inspectorTab = "properties"
    panel.inspectorOpen = true
    fixture.selectedProperties = ({ kind: "directory", token: "walk-me",
      sizeText: "4.0 KiB", allocatedSizeText: "0 B" })
    panel.syncFolderMeasurement()
    check(fixture.measuredTokens.length === 1
        && fixture.measuredTokens[0] === "walk-me",
      "opening Properties on a folder did not start measuring it")

    panel.syncFolderMeasurement()
    check(fixture.measuredTokens.length === 1,
      "the same folder was measured twice for one inspection")

    fixture.selectedProperties = ({ kind: "file", token: "not-a-folder",
      sizeText: "10 B" })
    panel.syncFolderMeasurement()
    check(fixture.folderSizeToken === "" && fixture.measuredTokens.length === 1,
      "selecting a file left the folder walk running")

    fixture.selectedProperties = ({ kind: "directory", token: "walk-me",
      sizeText: "4.0 KiB", allocatedSizeText: "0 B" })
    panel.syncFolderMeasurement()
    check(fixture.measuredTokens.length === 2, "the walk did not restart")
    var cancels = fixture.folderSizeCancels
    panel.inspectorOpen = false
    panel.syncFolderMeasurement()
    check(fixture.folderSizeToken === "",
      "closing the inspector left the folder walk running")

    // Dismissing the progress sheet is what stops the walk.
    fixture.folderSizeCancels = cancels
    panel.editorMode = "folder-size"
    panel.dismissEditor()
    check(panel.editorMode === "" && fixture.folderSizeCancels === cancels + 1,
      "closing the progress sheet did not stop the walk it was reporting")
    check(!panel.editorConfirmEnabled(),
      "the progress sheet offered a confirm action")

    fixture.selectedProperties = null
    fixture.measuredTokens = []
  }

  function footerChecks() {
    var footer = objectFinder.findChild(panel, "quickfileFooterStatus")
    check(footer !== null, "could not find the footer status label")
    check(footer.text.indexOf("items") >= 0,
      "the footer did not take over the item count")

    fixture.selectedTokens = [fixture.entries[0].token, fixture.entries[1].token]
    check(footer.text === "2 selected",
      "the footer did not report a multi-selection")
    fixture.selectedTokens = [fixture.entries[0].token]

    fixture.actionMessage = "Renamed"
    check(footer.text === "Renamed",
      "an action message did not take the centre slot from the count")
    fixture.actionMessage = ""
    check(footer.text.indexOf("items") >= 0,
      "the count did not come back when the message cleared")
  }

  function sizeBadgeChecks() {
    check(panel.sizeBadge({ size: 0 }) === "0B", "an empty file lost its size")
    check(panel.sizeBadge({ size: 512 }) === "512B",
      "a sub-kilobyte file was not reported in bytes")
    check(panel.sizeBadge({ size: 4200 }) === "4.1KB",
      "a kilobyte-scale file lost its fractional precision")
    check(panel.sizeBadge({ size: 45 * 1024 }) === "45KB",
      "a size past ten units kept a decimal the superscript has no room for")
    check(panel.sizeBadge({ size: 3 * 1024 * 1024 }) === "3.0MB",
      "a megabyte-scale file was not reported in megabytes")
    check(panel.sizeBadge({ size: 1024, isDir: true }) === "",
      "a directory showed its allocation size as if it were content")
    check(panel.sizeBadge({}) === "" && panel.sizeBadge(null) === "",
      "a row without a size still claimed one")

    var sized = entry("sized-file", "")
    sized.size = 2048
    var rows = fixture.entries.slice()
    rows.push(sized)
    fixture.entries = rows
    fixture.entriesModel.append({ rowData: sized, scope: "" })
    var index = rows.length - 1
    fileView.forceLayout()
    fileView.positionViewAtIndex(index, ListView.Beginning)
    fileView.forceLayout()

    var item = fileView.itemAtIndex(index)
    check(item !== null, "could not realise the row carrying a size")
    var badge = objectFinder.findChild(item, "quickfileFileSizeBadge")
    var label = objectFinder.findChild(item, "quickfileFileNameLabel")
    check(badge !== null && badge.visible && badge.text === "2.0KB",
      "the size superscript did not reach the row beside its name")
    check(badge.font.pixelSize < label.font.pixelSize,
      "the size was not drawn smaller than the name it annotates")
    check(badge.y <= label.y + 1,
      "the size sat on the name's baseline instead of above it")

    fixture.entriesModel.remove(index)
    fixture.entries = rows.slice(0, index)
    fileView.forceLayout()
  }

  function newFeatureChecks() {
    panel.dismissEditor()
    check(!panel.inspectorOpen,
      "inspector opened before an explicit toolbar or context action")
    select(entry("selection-does-not-open-inspector", ""))
    check(!panel.inspectorOpen,
      "ordinary file selection opened the inspector and resized the file list")
    panel.inspectorOpen = true
    fixture.navigationAboutToChange(fixture.rootPath, fixture.rootToken)
    check(!panel.inspectorOpen,
      "directory navigation left the inspector armed for the next click")
    var panelWindow = objectFinder.findChild(panel, "quickfilePanelWindow")
    check(panelWindow !== null && !panelWindow.visible,
      "a closed panel kept its application window mapped")
    panel.open("{}")
    check(panelWindow.visible, "opening the panel did not map its application window")
    panel.close()
    check(!panelWindow.visible, "closing the panel left its application window mapped")
    select(entry("navigation-draft", "stored"))
    panel.noteDraft = "keep my unsaved note"
    fixture.quickNavEntries = [
      { name: "Home", path: "/home/test", token: "home", kind: "home" },
      { name: "Project with spaces", path: "/work/project with spaces", token: "project", kind: "worktree" },
      { name: "Downloads", path: "/home/test/Downloads", token: "downloads", kind: "xdg" }
    ]
    // Quick Nav is switched off. Its filtering and navigation are still
    // covered so the flag is all that has to change to bring it back.
    check(!panel.quickNavEnabled && !panel.openQuickNav() && panel.editorMode === "",
      "the disabled Quick Nav still opened its dialog")
    panel.quickNavQuery = "worktree spaces"
    check(panel.quickNavResults.length === 1 && panel.quickNavResults[0].token === "project",
      "Quick Nav did not filter names, paths, and source labels together")
    check(panel.activateQuickLocation(0) && fixture.navigatedLocation.token === "project",
      "Quick Nav did not navigate using the original location token")
    check(panel.noteDraft === "keep my unsaved note", "opening Quick Nav discarded a note draft")
    check(!panel.activateQuickLocation(99), "Quick Nav accepted an invalid result index")

    var destination = { isDir: true, token: "destination", path: "/destination with spaces" }
    var nativeDropTarget = objectFinder.findChild(panel, "quickfileCurrentFolderDrop")
    check(nativeDropTarget && nativeDropTarget.keys.length === 0,
      "drop target filtered MIME drags through unrelated Drag.keys: "
        + (nativeDropTarget ? String(nativeDropTarget.keys) : "missing"))
    check(panel.canEnterDirectoryDrop({ formats: ["text/uri-list"], supportedActions: Qt.CopyAction,
      getDataAsString: function() { throw new Error("payload read before native drop") } }, destination),
      "drag hover tried to read native data before drop")
    var internal = dropEvent(["application/x-quickfile-tokens"], {
      "application/x-quickfile-tokens": JSON.stringify(["one-token", "two-token"])
    })
    check(panel.beginDirectoryDrop(internal, destination) && panel.editorMode === "drop-choice",
      "internal drop did not request an explicit copy/move choice")
    check(fixture.lastDrop === null, "drop started a transfer before the user's choice")
    check(panel.commitDirectoryDrop(true) && fixture.lastDrop.move
        && fixture.lastDrop.destination === "destination" && fixture.lastDrop.tokens.length === 2,
      "internal drop did not pass binary tokens and selected move action")
    var external = dropEvent(["text/uri-list", "text/plain"], {
      "text/uri-list": "# Comment\r\nfile:///tmp/a%20b.txt\r\nfile:///tmp/c%23d.txt\r\n",
      "text/plain": "$(must-not-run)"
    })
    check(panel.beginDirectoryDrop(external, destination), "external URI-list drop was rejected")
    check(panel.commitDirectoryDrop(false) && !fixture.lastDrop.move
        && fixture.lastDrop.uris[0] === "file:///tmp/a%20b.txt",
      "external drop did not preserve encoded URI data for the backend")
    check(!panel.canAcceptDirectoryDrop(dropEvent(["text/plain"], {
      "text/plain": "/tmp/not-a-uri"
    }), destination), "plain text was accepted as a filesystem drop")
    check(!panel.canAcceptDirectoryDrop(dropEvent(["text/uri-list"], {
      "text/uri-list": "https://example.com/file"
    }), destination), "remote URL was accepted as a local filesystem drop")
    check(!panel.canAcceptDirectoryDrop(internal, { isDir: false, token: "destination" }),
      "a file was accepted as a directory drop target")
    check(!panel.canAcceptDirectoryDrop(internal, { isDir: true, token: "one-token" }),
      "a source was allowed to drop onto itself")
    check(!panel.directoryDropPayload(dropEvent(["application/x-quickfile-tokens"], {
      "application/x-quickfile-tokens": "{invalid}"
    })), "malformed internal tokens were accepted")
    check(panel.directoryDropPayload({ formats: [], urls: ["file:///tmp/from-urls.txt"] }).uris[0]
        === "file:///tmp/from-urls.txt", "native drag.urls fallback was ignored")
    fixture.selectedTokens = ["selected-one", "selected-two"]
    check(JSON.parse(panel.dragMimeData({ token: "selected-one" })[
      "application/x-quickfile-tokens"]).length === 2,
      "internal drag payload lost the multi-selection")

    var fileConflict = { name: "report.txt", sourcePath: "/source/report.txt", sourceKind: "file",
      targetPath: "/target/report.txt", targetKind: "file", canMerge: false }
    fixture.pendingOperation = { kind: "copy", tokens: ["source"] }
    fixture.conflictRequested([fileConflict])
    check(panel.editorMode === "conflict" && panel.conflictRows.length === 1,
      "service conflict did not open the conflict dialog")
    check(!panel.chooseConflictPolicy("merge"), "file conflicts incorrectly offered folder merge")
    check(!panel.resolveOperationConflict("replace") && fixture.lastConflictPolicy === "",
      "replace bypassed its separate confirmation")
    check(panel.chooseConflictPolicy("replace") && panel.editorMode === "conflict-replace"
        && fixture.lastConflictPolicy === "", "replace ran before destructive confirmation")
    panel.cancelEditor()
    check(panel.editorMode === "conflict" && fixture.pendingOperation !== null,
      "Back from replace confirmation discarded the pending operation")
    panel.chooseConflictPolicy("replace")
    panel.commitEditor()
    check(fixture.lastConflictPolicy === "replace" && panel.editorMode === "",
      "confirmed replacement did not resume the operation")

    fixture.pendingOperation = { kind: "copy", tokens: ["folder"] }
    fixture.conflictRequested([{ sourceKind: "directory", targetKind: "directory", canMerge: true }])
    check(panel.conflictsCanMerge && panel.chooseConflictPolicy("merge")
        && fixture.lastConflictPolicy === "merge", "valid directory conflicts could not merge")
    fixture.pendingOperation = { kind: "copy", tokens: ["one", "two"] }
    fixture.conflictRequested([fileConflict, fileConflict])
    check(panel.chooseConflictPolicy("keep-both") && fixture.lastConflictPolicy === "keep-both",
      "keep-both policy did not apply to the pending operation")
    fixture.pendingOperation = { kind: "copy", tokens: ["one"] }
    fixture.conflictRequested([fileConflict])
    panel.dismissEditor()
    check(fixture.pendingOperation === null && panel.conflictRows.length === 0,
      "cancelling a conflict left a stale pending operation")
    check(panel.noteDraft === "keep my unsaved note", "drop/conflict workflow discarded the note draft")
  }

  function prepareViewport() {
    var rows = []
    for (var i = 0; i < 80; i++) {
      var row = entry("row-" + i, "")
      // Spread across bytes, kilobytes and megabytes so the rendered viewport
      // — and the screenshot taken from it — exercises every size superscript.
      row.size = Math.round(Math.pow(1024, i % 3) * (1 + (i % 7)))
      rows.push(row)
    }
    fixture.entries = rows
    fixture.entriesModel.clear()
    for (var index = 0; index < rows.length; index++)
      fixture.entriesModel.append({ rowData: rows[index], scope: "" })
    select(rows[40])
    panel.open("{}")
  }

  function viewportChecks() {
    fileView = objectFinder.findChild(panel, "quickfileFileList")
    check(fileView !== null, "could not find the rendered file list")
    var panelWindow = objectFinder.findChild(panel, "quickfilePanelWindow")
    var keyScope = objectFinder.findChild(panel, "quickfileKeyScope")
    check(panelWindow !== null && panelWindow.visible,
      "opening the panel did not map its application window")
    check(keyScope !== null && keyScope.activeFocus,
      "open panel did not activate its keyboard event scope")
    var blade = objectFinder.findChild(panel, "quickfileBlade")
    check(blade !== null && blade.width === panelWindow.width
        && blade.height === panelWindow.height,
      "panel content did not fill its application window")
    var moduleSettings = objectFinder.findChild(panel, "quickfileModuleSettings")
    check(moduleSettings !== null, "module settings popup was not rendered")
    moduleSettings.open()
    check(moduleSettings.visible, "module settings popup did not open")
    moduleSettings.close()
    check(panel.keyboardIndex === 40,
      "opening the panel did not retain the selected file as the keyboard cursor")
    check(panel.handleVerticalNavigationKey(Qt.Key_Down, Qt.NoModifier)
        && panel.keyboardIndex === 41 && fixture.selectedToken === "row-41",
      "Down did not move selection to the next file")
    check(panel.handleVerticalNavigationKey(Qt.Key_Up, Qt.NoModifier)
        && panel.keyboardIndex === 40 && fixture.selectedToken === "row-40",
      "Up did not move selection to the previous file")
    fileView.forceLayout()
    fileView.positionViewAtIndex(35, ListView.Beginning)
    fileView.forceLayout()
    fileView.contentY += 7
    var topIndex = fileView.indexAt(1, fileView.contentY + 1)
    check(topIndex >= 0, "test could not locate the first visible row")
    var top = fileView.itemAtIndex(topIndex)
    var topToken = String(top.modelData.token)
    var topOffset = top.y - fileView.contentY
    var preservedDelegate = fileView.itemAtIndex(40)
    var inserted = entry("inserted-at-top", "")

    fixture.listingAboutToChange()
    fixture.entries = [inserted].concat(fixture.entries)
    fixture.entriesModel.insert(0, { rowData: inserted, scope: "" })
    fixture.modelChanged()
    fileView.forceLayout()
    check(panel.keyboardIndex === 41, "cursor did not follow its file after an insertion")
    check(fileView.itemAtIndex(41) === preservedDelegate,
      "insertion recreated an unaffected visible file delegate")
    var retainedTop = fileView.itemAtIndex(topIndex + 1)
    check(retainedTop !== null && String(retainedTop.modelData.token) === topToken,
      "insertion lost the top visible file")
    check(Math.abs((retainedTop.y - fileView.contentY) - topOffset) < 1,
      "insertion moved the viewport away from its first visible file")

    fixture.listingAboutToChange()
    var reordered = fixture.entries.slice()
    var moved = reordered.splice(41, 1)[0]
    reordered.splice(43, 0, moved)
    fixture.entries = reordered
    fixture.entriesModel.move(41, 43, 1)
    fixture.modelChanged()
    check(panel.keyboardIndex === 43, "cursor did not follow its file after reordering")

    fixture.listingAboutToChange()
    fileView.interactionRevision++
    fileView.contentY += 20
    var userScroll = fileView.contentY
    fixture.modelChanged()
    check(Math.abs(fileView.contentY - userScroll) < 1,
      "a user scroll during an update was overwritten")

    // A new answer to a search (a SMART plan arriving for the same query)
    // starts at its best match instead of holding the old top row in place.
    fileView.interactionRevision++
    fileView.positionViewAtIndex(35, ListView.Beginning)
    fileView.forceLayout()
    fixture.listingIsNewResults = true
    fixture.listingAboutToChange()
    var ranked = fixture.entries.slice()
    var best = ranked.splice(60, 1)[0]
    ranked.unshift(best)
    fixture.entries = ranked
    fixture.entriesModel.move(60, 0, 1)
    fixture.modelChanged()
    fileView.forceLayout()
    fixture.listingIsNewResults = false
    check(fileView.indexAt(1, fileView.contentY + 1) === 0,
      "new search results kept the old top row instead of showing the best match")
    fileView.positionViewAtIndex(35, ListView.Beginning)
    fileView.forceLayout()

    panel.keyboardIndex = 70
    select(fixture.entries[70])
    panel.moveSelection(1, Qt.NoModifier)
    var current = fileView.itemAtIndex(71)
    check(current !== null && current.y >= fileView.contentY - 1
        && current.y + current.height <= fileView.contentY + fileView.height + 1,
      "keyboard navigation did not bring its new selection into view")

    var parentRows = fixture.entries.slice()
    fileView.positionViewAtIndex(52, ListView.Beginning)
    fileView.forceLayout()
    fileView.contentY += 9
    panel.keyboardIndex = 67
    select(parentRows[67])
    var rememberedTopIndex = fileView.indexAt(1, fileView.contentY + 1)
    var rememberedTopRow = fileView.itemAtIndex(rememberedTopIndex)
    var rememberedTopToken = String(rememberedTopRow.modelData.token)
    var rememberedTopOffset = rememberedTopRow.y - fileView.contentY
    var rememberedSelection = fixture.selectedToken

    fixture.navigationAboutToChange(fixture.rootPath, fixture.rootToken)
    fixture.rootPath = "/quickfile-test/child"
    fixture.rootToken = "child-root"
    fixture.foregroundListingPending = true
    fixture.listingAboutToChange()
    fixture.entries = []
    fixture.entriesModel.clear()
    fixture.selectedToken = ""
    fixture.selectedTokens = []
    fixture.selectedEntry = null
    fixture.modelChanged()
    var emptyState = objectFinder.findChild(panel, "quickfileEmptyState")
    check(emptyState !== null && !emptyState.visible,
      "empty-folder artwork appeared while foreground navigation was pending")
    fixture.foregroundListingPending = false
    var childRows = [entry("inside-child", "")]
    fixture.listingAboutToChange()
    fixture.entries = childRows
    fixture.entriesModel.append({ rowData: childRows[0], scope: "" })
    fixture.modelChanged()

    fixture.navigationAboutToChange(fixture.rootPath, fixture.rootToken)
    fixture.rootPath = "/quickfile-test"
    fixture.rootToken = "test-root"
    fixture.listingAboutToChange()
    fixture.entries = []
    fixture.entriesModel.clear()
    fixture.selectedToken = ""
    fixture.selectedTokens = []
    fixture.selectedEntry = null
    fixture.modelChanged()
    fixture.listingAboutToChange()
    fixture.entries = parentRows
    for (var parentIndex = 0; parentIndex < parentRows.length; parentIndex++)
      fixture.entriesModel.append({ rowData: parentRows[parentIndex], scope: "" })
    fixture.modelChanged()
    fileView.forceLayout()
    var restoredTopIndex = fileView.rowIndexForKey(rememberedTopToken)
    var restoredTopRow = fileView.itemAtIndex(restoredTopIndex)
    check(restoredTopRow !== null
        && Math.abs((restoredTopRow.y - fileView.contentY) - rememberedTopOffset) < 1,
      "returning to a directory did not restore its exact scroll position")
    check(fixture.selectedToken === rememberedSelection
        && panel.keyboardIndex === fileView.rowIndexForKey(rememberedSelection),
      "returning to a directory did not restore the folder used to enter it")

    fixture.settingsLoaded = true
    fixture.inspectorTab = "notes"
    panel.inspectorOpen = true
    var noteEditor = objectFinder.findChild(panel, "quickfileNoteEditor")
    var propertiesTab = objectFinder.findChild(panel, "quickfilePropertiesTab")
    var notesTab = objectFinder.findChild(panel, "quickfileNotesTab")
    var gitTab = objectFinder.findChild(panel, "quickfileGitTab")
    check(noteEditor !== null, "could not find the rendered note editor")
    check(propertiesTab !== null && notesTab !== null && gitTab !== null
        && notesTab.visible && !propertiesTab.visible && !gitTab.visible,
      "persisted Notes tab was not rendered as the active inspector module")
    noteEditor.forceActiveFocus()
    noteEditor.insert(0, "draft with a selected phrase")
    noteEditor.select(6, 10)
    var textBefore = noteEditor.text
    var cursorBefore = noteEditor.cursorPosition
    fixture.modelChanged()
    fixture.selectedProperties = entry(fixture.selectedToken, "")
    check(noteEditor.text === textBefore && panel.noteDraft === textBefore,
      "background update reset the note editor's typed text")
    check(noteEditor.activeFocus && noteEditor.cursorPosition === cursorBefore
        && noteEditor.selectionStart === 6 && noteEditor.selectionEnd === 10,
      "background update reset note focus, text selection, or cursor")

    var fileDelegateBeforeTabs = fileView.itemAtIndex(panel.keyboardIndex)
    var viewportBeforeTabs = fileView.contentY
    check(fixture.setInspectorTab("git") && gitTab.visible
        && !notesTab.visible && !propertiesTab.visible,
      "Git inspector module did not become active")
    check(fixture.setInspectorTab("properties") && propertiesTab.visible
        && !notesTab.visible && !gitTab.visible,
      "Properties inspector module did not become active")
    check(fixture.setInspectorTab("notes") && notesTab.visible
        && !propertiesTab.visible && !gitTab.visible,
      "Notes inspector module did not become active again")
    fileView.forceLayout()
    check(noteEditor.text === textBefore && panel.noteDraft === textBefore
        && fileView.itemAtIndex(panel.keyboardIndex) === fileDelegateBeforeTabs
        && Math.abs(fileView.contentY - viewportBeforeTabs) < 1,
      "inspector tab changes rebuilt file delegates, moved the viewport, or discarded the draft")
    noteEditor.forceActiveFocus()
    noteEditor.select(6, 10)

    fixture.moduleLayout = fixture.defaultModuleLayout()
    fixture.applyModuleCollapseFlags()
    var sessionsModule = objectFinder.findChild(panel, "quickfileSessionsModule")
    var knowledgeModule = objectFinder.findChild(panel, "quickfileKnowledgeModule")
    var fileDelegateBeforeModules = fileView.itemAtIndex(panel.keyboardIndex)
    var expandedSessionsHeight = sessionsModule ? sessionsModule.height : 0
    check(sessionsModule !== null && knowledgeModule !== null
      && sessionsModule.y < knowledgeModule.y,
      "default module order was not rendered")
    check(fixture.moveModule("sessions", 1)
        && fixture.moveModule("sessions", 1)
        && fixture.moveModule("sessions", 1)
        && knowledgeModule.y < sessionsModule.y,
      "reordering modules did not move the existing section")
    check(fixture.setModuleCollapsed("sessions", true)
        && sessionsModule.height > 0 && sessionsModule.height < expandedSessionsHeight,
      "collapsed module did not retain only its live header")
    check(fileView.itemAtIndex(panel.keyboardIndex) === fileDelegateBeforeModules
        && noteEditor.text === textBefore && noteEditor.activeFocus
        && noteEditor.selectionStart === 6 && noteEditor.selectionEnd === 10,
      "module changes rebuilt file delegates or discarded the editor draft")

    // The Smart Search chip row sits between the field and the module stack:
    // every module, in any order, and the strip below them must clear it.
    var smartSummary = objectFinder.findChild(panel, "quickfileSmartSummary")
    var contextStrip = objectFinder.findChild(panel, "quickfileContextStrip")
    var summarySearchField = objectFinder.findChild(panel, "quickfileSearchField")
    var modulesBeforeChips = fixture.moduleLayout
    fixture.setModulePinned("sessions", true)
    fixture.setModulePinned("devices", true)
    fixture.setModulePinned("favorites", true)
    fixture.setModulePinned("knowledge", true)
    fixture.searchMode = "smart"
    summarySearchField.text = "find config yesterday"
    check(smartSummary.visible && smartSummary.height > 0,
      "the Smart Search chip row did not appear for a SMART query")
    var stacked = ["quickfileSessionsModule", "quickfileDevicesModule",
      "quickfileFavoritesModule", "quickfileKnowledgeModule"]
      .map(function(name) { return objectFinder.findChild(panel, name) })
      .filter(function(item) { return item !== null && item.visible && item.height > 0 })
      .sort(function(a, b) { return a.y - b.y })
    check(stacked.length === 4, "a pinned module was not shown beside the chip row")
    var chipBottom = smartSummary.y + smartSummary.height
    for (var m = 0; m < stacked.length; m++) {
      check(stacked[m].y >= chipBottom,
        stacked[m].objectName + " was drawn over the Smart Search chip row")
      if (m > 0)
        check(stacked[m - 1].y + stacked[m - 1].height <= stacked[m].y + 0.5,
          stacked[m - 1].objectName + " overlapped " + stacked[m].objectName)
    }
    // The chips glow while SMART is still working and settle once it is done.
    fixture.query = ""
    check(panel.smartSearchWorking(), "a pending SMART query did not mark the search as working")
    fixture.query = "find config yesterday"
    fixture.semanticState = "analyzing"
    check(panel.smartSearchWorking(), "an analysing model did not mark the search as working")
    fixture.semanticState = "ready"
    fixture.foregroundListingPending = false
    check(!panel.smartSearchWorking(), "a finished SMART search still read as working")
    // A typed format is shown as itself rather than as the broad kind.
    var resultBeforeFormat = fixture.semanticResult
    fixture.semanticResult = ({ state: "ready", terms: ["garden"], formats: ["pdf"], hints: {
      target: { value: "file", confidence: 1, source: "rule" },
      kind: { value: "document", confidence: 1, source: "rule" }
    } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["FILE", "PDF"]),
      "a typed format did not take the place of its broad kind chip: " + panel.smartSummaryLabels())
    fixture.semanticResult = ({ state: "ready", hints: { kind: { value: "document" } } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["DOCUMENT"]),
      "a plan without formats lost its kind chip")
    // Every kind a query asks for is shown, a format in place of its own.
    fixture.semanticResult = ({ state: "ready", kinds: ["image", "video"], hints: {
      kind: { value: "image", confidence: 1, source: "rule" },
      time: { value: "past-week", confidence: 1, source: "rule" }
    } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["IMAGE", "VIDEO", "PAST WEEK"]),
      "a second kind asked for had no chip: " + panel.smartSummaryLabels())
    fixture.semanticResult = ({ state: "ready", hints: {
      time: { value: "last-year", confidence: 1, source: "rule" }
    } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["LAST YEAR"]),
      "the calendar year before this one had no chip: " + panel.smartSummaryLabels())
    fixture.semanticResult = ({ state: "ready", formats: ["pdf"], kinds: ["document", "image"],
      hints: { kind: { value: "document", confidence: 1, source: "rule" } } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["PDF", "IMAGE"]),
      "a format beside a second kind read wrong: " + panel.smartSummaryLabels())
    // The kind named first may be another than the format's: its chip stays,
    // and a format's own kind never shows beside it.
    fixture.semanticResult = ({ state: "ready", formats: ["pdf"], kinds: ["image", "document"],
      hints: { kind: { value: "image", confidence: 1, source: "rule" } } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["PDF", "IMAGE"]),
      "a kind named before a format lost its chip: " + panel.smartSummaryLabels())
    fixture.semanticResult = ({ state: "ready", formats: ["mp3"], kinds: ["video", "audio"],
      hints: { kind: { value: "video", confidence: 1, source: "rule" } } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["MP3", "VIDEO"]),
      "a format's own kind showed in place of the kind asked for: " + panel.smartSummaryLabels())
    fixture.semanticResult = ({ state: "ready", formats: ["pdf", "png"], kinds: ["document", "image"],
      hints: { kind: { value: "document", confidence: 1, source: "rule" } } })
    check(JSON.stringify(panel.smartSummaryLabels()) === JSON.stringify(["PDF", "PNG"]),
      "two formats of two kinds showed a kind chip: " + panel.smartSummaryLabels())
    fixture.semanticResult = resultBeforeFormat
    var smartChips = objectFinder.findChild(panel, "quickfileSmartChips")
    var settledChip = smartChips && smartChips.count > 0 ? smartChips.itemAt(0) : null
    check(settledChip !== null && settledChip.glow === 0 && !settledChip.layer.enabled,
      "a settled Smart Search chip kept its glow")
    var lastModule = stacked[stacked.length - 1]
    check(contextStrip.y >= lastModule.y + lastModule.height - 0.5,
      "the context strip was drawn over the module stack")
    summarySearchField.text = ""
    fixture.query = ""
    fixture.semanticState = "checking"
    fixture.searchMode = "fuzzy"
    fixture.moduleLayout = modulesBeforeChips
    fixture.applyModuleCollapseFlags()
    check(!smartSummary.visible && smartSummary.height === 0,
      "the Smart Search chip row kept its space after leaving SMART")

    check(panel.showInlinePreview(fixture.selectedEntry), "inline preview did not start")
    var preview = objectFinder.findChild(panel, "quickfileInlinePreview")
    var previewText = objectFinder.findChild(panel, "quickfilePreviewText")
    check(preview !== null && preview.visible && previewText.text === "<b>plain text</b>\nsecond line"
        && previewText.textFormat === TextEdit.PlainText,
      "inline text preview was not displayed safely as plain text")
    var currentPreview = fixture.previewData
    fixture.applyPreview(JSON.stringify({ ok: true, preview: { kind: "text", text: "late wrong item" } }),
      "stale-token", fixture.previewRevision)
    fixture.applyPreview(JSON.stringify({ ok: true, preview: { kind: "text", text: "late revision" } }),
      fixture.previewToken, fixture.previewRevision - 1)
    check(fixture.previewData === currentPreview && panel.noteDraft === textBefore,
      "a stale preview response changed the visible preview or note draft")
    check(panel.previewHoveredOrSelected(true) && fixture.externalPreviewToken === fixture.selectedToken,
      "external Sushi preview was not retained for the selected file")
    check(noteEditor.text === textBefore && noteEditor.activeFocus
        && noteEditor.selectionStart === 6 && noteEditor.selectionEnd === 10,
      "preview stole focus or discarded an unsaved note selection")
    fixture.previewData = { kind: "image", name: "image.png", uri: "", width: 800, height: 600,
      mime: "image/png", sizeText: "32 KB" }
    var imagePreview = objectFinder.findChild(panel, "quickfilePreviewImage")
    check(imagePreview.visible && imagePreview.sourceSize.width === 720
        && imagePreview.sourceSize.height === 360 && panel.previewSummary().indexOf("800 × 600") >= 0,
      "image preview did not expose bounded rendering and dimensions")
    panel.closeInlinePreview()
    check(!preview.visible && fixture.previewData === null && panel.noteDraft === textBefore,
      "closing preview changed the note draft or kept stale preview data")
  }

  Timer {
    id: pulseTimer
    interval: 140
    onTriggered: {
      var which = String(Quickshell.env("QUICKFILE_PANEL_SCREENSHOT_MODE") || "")
        .substring(6)
      if (which === "search") panel.beginSearch()
      else if (which === "inspector") panel.revealInspector()
      else panel.pulseRow(testRoot.fileView.itemAtIndex(52).modelData.token)
      captureTimer.restart()
    }
  }

  Timer {
    id: captureTimer
    interval: 160
    onTriggered: {
      testRoot.fileView.parent.parent.grabToImage(function(result) {
        if (result.saveToFile(String(Quickshell.env("QUICKFILE_PANEL_SCREENSHOT"))))
          console.log("QUICKFILE_TESTS_PASSED panel-state " + testRoot.assertions + " assertions; screenshot captured")
        else console.error("QUICKFILE_TESTS_FAILED panel screenshot could not be saved")
        Qt.quit()
      })
    }
  }

  function captureIfRequested() {
    if (!Quickshell.env("QUICKFILE_PANEL_SCREENSHOT")) return false
    var mode = String(Quickshell.env("QUICKFILE_PANEL_SCREENSHOT_MODE") || "preview")
    if (mode === "folder-size") {
      fixture.folderSizeBusy = true
      fixture.folderSizeToken = "walk-me"
      fixture.folderSizeBytes = 5.4 * 1024 * 1024 * 1024
      fixture.folderSizeFiles = 48213
      fixture.folderSizeDirectories = 3907
      fixture.folderSizePath = "/home/test/Personal-Super-Agent/Projects/omarchy-quickfile/components"
      panel.beginEditor("folder-size")
    } else if (mode === "shortcuts") {
      panel.beginEditor("shortcuts")
    } else if (mode === "smart-onboarding") {
      panel.beginEditor("smart-onboarding")
    } else if (mode === "inspector") {
      fixture.inspectorTab = "notes"
      panel.inspectorOpen = true
    } else if (mode.indexOf("pulse-") === 0) {
      // Fired from the capture timer, once the layout has settled.
    } else if (mode.indexOf("date-") === 0) {
      fixture.dateFormat = mode.substring(5)
      var spread = fixture.entries.slice()
      // Spread the rows across today, this week, this year and last year so a
      // screenshot shows every branch of the format at once.
      var steps = [0, 3600000, 28 * 3600000, 3 * 86400000, 30 * 86400000,
        300 * 86400000]
      for (var i = 0; i < spread.length; i++) {
        spread[i] = Object.assign({}, spread[i], {
          modifiedEpoch: (Date.now() - steps[i % steps.length]) / 1000 })
        fixture.entriesModel.set(i, { rowData: spread[i], scope: "" })
      }
      fixture.entries = spread
    } else if (mode === "quick-nav") panel.openQuickNav()
    else if (mode === "conflict" || mode === "conflict-replace") {
      fixture.pendingOperation = { kind: "copy", tokens: ["source"] }
      fixture.conflictRequested([{ name: "report.txt", sourceKind: "file", targetKind: "file",
        sourcePath: "/home/test/Downloads/report.txt", targetPath: "/home/test/Reports/report.txt" }])
      if (mode === "conflict-replace") panel.chooseConflictPolicy("replace")
    } else panel.showInlinePreview(fixture.selectedEntry)
    if (mode.indexOf("pulse-") === 0) pulseTimer.start()
    else captureTimer.start()
    return true
  }

  Timer {
    id: viewportTimer
    interval: 300
    onTriggered: {
      try {
        testRoot.viewportChecks()
        testRoot.elidedNameTooltipChecks()
        testRoot.sizeBadgeChecks()
        testRoot.searchFocusChecks()
        testRoot.sortChecks()
        testRoot.choiceMenuChecks()
        testRoot.smartOnboardingChecks()
        testRoot.dateFormatChecks()
        testRoot.dateChipChecks()
        testRoot.footerChecks()
        testRoot.folderSizeChecks()
        // After the pulse checks: P opens the inspector, and they assert on an
        // inspector outline that nothing has asked for yet.
        testRoot.focusPulseChecks()
        testRoot.shortcutChecks()
        if (testRoot.captureIfRequested()) return
        console.log("QUICKFILE_TESTS_PASSED panel-state " + testRoot.assertions + " assertions")
      } catch (error) {
        console.error("QUICKFILE_TESTS_FAILED panel-state: " + error + "\n" + error.stack)
      }
      Qt.quit()
    }
  }

  Component.onCompleted: {
    try {
      metadataChecks()
      operationChecks()
      untrustedTextChecks()
      newFeatureChecks()
      prepareViewport()
      viewportTimer.start()
    } catch (error) {
      console.error("QUICKFILE_TESTS_FAILED panel-state: " + error + "\n" + error.stack)
      Qt.quit()
    }
  }
}
