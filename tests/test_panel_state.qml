import QtQuick
import QtTest
import Quickshell
import "plugin" as Quickfile

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
    initialized: true
    rootPath: "/quickfile-test"
    rootToken: "test-root"
    knowledgeCollapsed: true
    function setPanelVisible(value) {}
    function inspect(token) {}
    function saveSelectedMetadata(color, note, starred) { return !rejectSave }
    function saveSelectedKnowledge(registered, agents) { return !rejectSave }
    function renameSelected(name) { return true }
    function reloadTrash() { return true }
    function permanentlyDeleteTrash(uri) { return true }
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
    manifest: ({ id: "m0sthatedman.quickfile" })
    inspectorOpen: false
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

    fixture.trashEntries = [{ uri: "trash:///old.txt", name: "old.txt",
      originalPath: "/quickfile-test/old.txt" }]
    panel.openTrashBrowser()
    check(panel.editorMode === "trash-browser", "Trash browser did not open")
    panel.confirmTrashDelete(fixture.trashEntries[0])
    check(panel.editorMode === "trash-delete" && panel.pendingTrashEntry.name === "old.txt",
      "Permanent delete did not require a separate confirmation state")
    panel.commitEditor()
    check(panel.editorMode === "trash-browser" && panel.pendingTrashEntry === null,
      "Confirmed permanent delete did not return to Trash")
  }

  function dropEvent(formats, values) {
    return { formats: formats, supportedActions: Qt.CopyAction | Qt.MoveAction,
      getDataAsString: function(format) { return values[format] || "" } }
  }

  function newFeatureChecks() {
    panel.dismissEditor()
    select(entry("navigation-draft", "stored"))
    panel.noteDraft = "keep my unsaved note"
    fixture.quickNavEntries = [
      { name: "Home", path: "/home/test", token: "home", kind: "home" },
      { name: "Project with spaces", path: "/work/project with spaces", token: "project", kind: "worktree" },
      { name: "Downloads", path: "/home/test/Downloads", token: "downloads", kind: "xdg" }
    ]
    check(panel.openQuickNav() && panel.editorMode === "quick-nav", "Quick Nav did not open")
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
    for (var i = 0; i < 80; i++) rows.push(entry("row-" + i, ""))
    fixture.entries = rows
    fixture.entriesModel.clear()
    for (var index = 0; index < rows.length; index++)
      fixture.entriesModel.append({ rowData: rows[index], scope: "" })
    select(rows[40])
    panel.open("{}")
    panel.keyboardIndex = 40
  }

  function viewportChecks() {
    fileView = objectFinder.findChild(panel, "quickfileFileList")
    check(fileView !== null, "could not find the rendered file list")
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

    panel.keyboardIndex = 70
    select(fixture.entries[70])
    panel.moveSelection(1, Qt.NoModifier)
    var current = fileView.itemAtIndex(71)
    check(current !== null && current.y >= fileView.contentY - 1
        && current.y + current.height <= fileView.contentY + fileView.height + 1,
      "keyboard navigation did not bring its new selection into view")

    panel.inspectorOpen = true
    var noteEditor = objectFinder.findChild(panel, "quickfileNoteEditor")
    check(noteEditor !== null, "could not find the rendered note editor")
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
    id: captureTimer
    interval: 100
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
    if (mode === "quick-nav") panel.openQuickNav()
    else if (mode === "conflict" || mode === "conflict-replace") {
      fixture.pendingOperation = { kind: "copy", tokens: ["source"] }
      fixture.conflictRequested([{ name: "report.txt", sourceKind: "file", targetKind: "file",
        sourcePath: "/home/test/Downloads/report.txt", targetPath: "/home/test/Reports/report.txt" }])
      if (mode === "conflict-replace") panel.chooseConflictPolicy("replace")
    } else panel.showInlinePreview(fixture.selectedEntry)
    captureTimer.start()
    return true
  }

  Timer {
    id: viewportTimer
    interval: 300
    onTriggered: {
      try {
        testRoot.viewportChecks()
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
      newFeatureChecks()
      prepareViewport()
      viewportTimer.start()
    } catch (error) {
      console.error("QUICKFILE_TESTS_FAILED panel-state: " + error + "\n" + error.stack)
      Qt.quit()
    }
  }
}
