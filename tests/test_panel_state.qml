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
    initialized: true
    rootPath: "/quickfile-test"
    rootToken: "test-root"
    knowledgeCollapsed: true
    function setPanelVisible(value) {}
    function inspect(token) {}
    function saveSelectedMetadata(color, note, starred) { return !rejectSave }
    function saveSelectedKnowledge(registered, agents) { return !rejectSave }
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
  }

  Timer {
    id: viewportTimer
    interval: 300
    onTriggered: {
      try {
        testRoot.viewportChecks()
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
      prepareViewport()
      viewportTimer.start()
    } catch (error) {
      console.error("QUICKFILE_TESTS_FAILED panel-state: " + error + "\n" + error.stack)
      Qt.quit()
    }
  }
}
