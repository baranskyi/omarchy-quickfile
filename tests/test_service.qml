import QtQuick
import Quickshell
import Quickshell.Io
import "plugin" as Quickfile

ShellRoot {
  id: suite

  property int assertions: 0
  property int beforeSignals: 0
  property int changedSignals: 0
  property int metadataSignals: 0
  property int conflictSignals: 0
  property int createdDelegates: 0
  property int destroyedDelegates: 0
  property int createdSessionDelegates: 0
  property int destroyedSessionDelegates: 0
  property bool finished: false
  property bool expectSilent: false
  property string phase: "startup"
  property double phaseStarted: Date.now()
  property double stableSince: Date.now()
  property int previousRequests: -1
  property int idleRequests: 0
  property var lastMetadata: null
  property var previousWatcherPid: null
  readonly property string fixture: Quickshell.env("QUICKFILE_TEST_ROOT")

  Quickfile.Service {
    id: synthetic
    rootPath: suite.fixture
    rootToken: "synthetic-root"
    knowledgeRootToken: "synthetic-root"
    initialized: false
  }

  Quickfile.Service {
    id: live
    rootPath: suite.fixture
    onForegroundBusyChanged: {
      if (suite.expectSilent && foregroundBusy)
        suite.fail("A filesystem event activated the foreground Refresh indicator")
    }
  }

  Connections {
    target: synthetic
    function onListingAboutToChange() { suite.beforeSignals++ }
    function onModelChanged() { suite.changedSignals++ }
    function onMetadataSaved(token, values) {
      suite.metadataSignals++
      suite.lastMetadata = { token: token, values: values }
    }
    function onConflictRequested(conflicts) { suite.conflictSignals++ }
  }

  Item {
    Repeater {
      id: rows
      model: synthetic.entriesModel
      delegate: Item {
        required property var rowData
        Component.onCompleted: suite.createdDelegates++
        Component.onDestruction: suite.destroyedDelegates++
      }
    }
  }

  Item {
    Repeater {
      id: sessionRows
      model: synthetic.sessionsModel
      delegate: Item {
        required property var rowData
        Component.onCompleted: suite.createdSessionDelegates++
        Component.onDestruction: suite.destroyedSessionDelegates++
      }
    }
  }

  function check(condition, message) {
    assertions++
    if (!condition) throw new Error(message)
  }

  function fail(message) {
    if (finished) return
    finished = true
    live.setPanelVisible(false)
    console.error("QUICKFILE_TESTS_FAILED service:", message)
    Qt.quit()
  }

  function row(token, note) {
    return { token: token, name: token + ".txt", note: note || "", color: "",
      isDir: false, starred: false, scope: "project", size: 10 }
  }

  function response(entries) {
    return JSON.stringify({ ok: true,
      root: { token: synthetic.rootToken, path: synthetic.rootPath },
      entries: entries, favorites: [], git: { root: "", branch: "" } })
  }

  function prepareRequest() {
    synthetic.listInFlightRootToken = synthetic.rootToken
    synthetic.listInFlightRootPath = synthetic.rootPath
    synthetic.listInFlightCommand = JSON.stringify(synthetic.buildListCommand())
    synthetic.listInFlightRevision = synthetic.metadataRevision
    synthetic.listInFlightBackground = true
    synthetic.reloadPending = false
    synthetic.reloadPendingForeground = false
  }

  function apply(entries) {
    prepareRequest()
    check(synthetic.applyListing(response(entries)), "Synthetic listing was rejected")
  }

  function runUnitTests() {
    apply([row("a"), row("b"), row("c")])
    check(rows.count === 3, "Initial rows were not created")
    var a = rows.itemAt(0)
    var b = rows.itemAt(1)
    var c = rows.itemAt(2)
    var snapshot = synthetic.entries
    var before = beforeSignals
    var changed = changedSignals
    var created = createdDelegates
    var destroyed = destroyedDelegates
    apply([row("a"), row("b"), row("c")])
    check(synthetic.entries === snapshot, "Unchanged listing replaced the snapshot")
    check(beforeSignals === before && changedSignals === changed,
      "Unchanged listing emitted change signals")
    check(createdDelegates === created && destroyedDelegates === destroyed,
      "Unchanged listing rebuilt delegates")
    check(rows.itemAt(1) === b, "Unchanged listing replaced a row object")

    synthetic.selectedToken = "b"
    synthetic.selectedTokens = ["a", "b"]
    synthetic.selectedEntry = synthetic.entries[1]
    synthetic.selectionAnchorIndex = 1
    apply([row("new"), row("a"), row("b"), row("c")])
    check(rows.itemAt(1) === a && rows.itemAt(2) === b && rows.itemAt(3) === c,
      "Inserting a row rebuilt existing delegates")
    check(synthetic.selectedToken === "b" && synthetic.selectedTokens.join(",") === "a,b",
      "Inserting a row changed selection")
    check(synthetic.selectionAnchorIndex === 2, "Range anchor did not follow its token")

    apply([row("c"), row("b", "updated"), row("a"), row("new")])
    check(rows.itemAt(0) === c && rows.itemAt(1) === b && rows.itemAt(2) === a,
      "Reordering rows rebuilt retained delegates")
    check(String(rows.itemAt(1).rowData.note) === "updated",
      "A changed row did not receive new metadata")
    check(synthetic.selectionAnchorIndex === 1, "Reordering lost the range anchor")
    apply([row("b", "updated"), row("a"), row("new")])
    check(rows.itemAt(0) === b && rows.itemAt(1) === a, "Removing a row rebuilt survivors")
    check(synthetic.selectionAnchorIndex === 0, "Removing a row moved the range anchor")
    check(beforeSignals === changedSignals, "Listing change signals are unbalanced")

    var currentSnapshot = synthetic.entries
    prepareRequest()
    synthetic.query = "new query"
    check(synthetic.applyListing(response([row("stale-search")])), "Stale search was not handled")
    check(synthetic.entries === currentSnapshot && synthetic.reloadPending,
      "An outdated search result replaced the current listing")
    synthetic.query = ""

    prepareRequest()
    synthetic.metadataRevision++
    check(synthetic.applyListing(response([row("stale-metadata")])), "Stale metadata was not handled")
    check(synthetic.entries === currentSnapshot && synthetic.reloadPending,
      "A pre-save listing replaced newer metadata")

    synthetic.selectedProperties = Object.assign({}, synthetic.selectedEntry, { detail: "keep" })
    var revision = synthetic.metadataRevision
    synthetic.applySavedMetadata("b", { note: "saved note", color: "blue", starred: true })
    check(synthetic.metadataRevision === revision + 1, "Save did not invalidate earlier requests")
    check(synthetic.selectedEntry.note === "saved note"
      && synthetic.selectedProperties.note === "saved note"
      && synthetic.selectedProperties.detail === "keep", "Save did not merge inspection snapshots")
    check(rows.itemAt(0) === b && rows.itemAt(0).rowData.note === "saved note",
      "Save replaced a delegate or left its values stale")
    check(metadataSignals === 1 && lastMetadata.token === "b"
      && lastMetadata.values.note === "saved note", "Save acknowledgement is incomplete")

    before = beforeSignals
    synthetic.applyVolumes(JSON.stringify({ ok: true, volumes: [] }))
    check(beforeSignals === before, "Unchanged volumes emitted model changes")
    synthetic.knowledgeInFlightRevision = synthetic.metadataRevision
    synthetic.applyKnowledge(JSON.stringify({ ok: true, root: { token: synthetic.rootToken },
      entries: [], totalTokens: 0, maxTokens: 0 }))
    check(beforeSignals === before, "Unchanged knowledge emitted model changes")
    check(beforeSignals === changedSignals, "Metadata/model change signals are unbalanced")

    var largeDirectories = []
    for (var watchIndex = 0; watchIndex < 4100; watchIndex++)
      largeDirectories.push("directory-" + watchIndex)
    synthetic.listWatch = { directories: largeDirectories, files: ["metadata-file"] }
    synthetic.knowledgeWatch = { directories: [], files: ["instruction-file"] }
    synthetic.syncWatchConfiguration()
    var boundedWatch = JSON.parse(synthetic.watchConfiguration)
    check(synthetic.watchTruncated, "Combined watch overflow did not enable fallback")
    check(boundedWatch.directories.length + boundedWatch.files.length === 4096,
      "Combined watch config exceeds the helper limit")
    check(boundedWatch.files.indexOf("metadata-file") >= 0
      && boundedWatch.files.indexOf("instruction-file") >= 0,
      "Oversized search discarded auxiliary file watches")
    synthetic.listWatch = null
    synthetic.knowledgeWatch = null
    synthetic.syncWatchConfiguration()
    synthetic.handleOperationEvent(JSON.stringify({ event: "progress", phase: "copying",
      itemsDone: 3, itemsTotal: 5, bytesDone: 25, bytesTotal: 100 }))
    check(synthetic.operationPhase === "copying"
      && synthetic.operationItemsDone === 3 && synthetic.operationItemsTotal === 5,
      "Operation progress did not preserve item counts")
    check(Math.abs(synthetic.operationProgress - 0.25) < 0.001,
      "Operation byte progress was not calculated")
    synthetic.handleOperationEvent(JSON.stringify({ event: "result", ok: false,
      error: "name conflict", code: "name-conflict" }))
    check(synthetic.operationResult && synthetic.operationResult.code === "name-conflict",
      "Operation result did not preserve a structured failure")

    var selectedBeforeBackgroundFeatures = synthetic.selectedToken
    check(synthetic.applyQuickNav(JSON.stringify({ ok: true, entries: [
      { token: "home-token", path: "/home/test", name: "Home", kind: "xdg" },
      { token: "recent-token", path: "/work/recent", name: "Recent", kind: "recent" }
    ] })), "Quick Nav response was rejected")
    check(synthetic.quickNavEntries.length === 2 && synthetic.quickNavModel.count === 2,
      "Quick Nav did not publish its bounded model")
    check(synthetic.selectedToken === selectedBeforeBackgroundFeatures,
      "Quick Nav loading changed the file selection")
    var recordCommand = synthetic.buildQuickNavRecordCommand("recent-token", "")
    check(recordCommand[3] === "quick-nav" && recordCommand.indexOf("--record") >= 0
      && recordCommand[recordCommand.indexOf("--path-token") + 1] === "recent-token",
      "Recent-location recording does not use a fixed token argument")

    var selectionBeforeSessions = synthetic.selectedToken
    var propertiesBeforeSessions = synthetic.selectedProperties
    check(synthetic.applySettings(JSON.stringify({ ok: true, settings: {
      activeSessionsEnabled: true,
      inspectorTab: "git",
      modules: [
        { id: "knowledge", pinned: true, collapsed: true },
        { id: "sessions", pinned: true, collapsed: false },
        { id: "favorites", pinned: false, collapsed: false },
        { id: "devices", pinned: false, collapsed: false }
      ]
    } })), "Settings response was rejected")
    check(synthetic.settingsLoaded && synthetic.activeSessionsEnabled
      && synthetic.inspectorTab === "git"
      && synthetic.moduleLayout[0].id === "knowledge" && synthetic.knowledgeCollapsed,
      "Persisted inspector tab, module order, or collapse state was not applied")
    check(synthetic.setInspectorTab("notes") && synthetic.inspectorTab === "notes"
      && !synthetic.setInspectorTab("terminal"),
      "Inspector tab setter did not enforce its built-in allowlist")
    synthetic.sessionsInFlightRootToken = synthetic.rootToken
    synthetic.sessionsInFlightRootPath = synthetic.rootPath
    check(synthetic.applySessions(JSON.stringify({ ok: true,
      root: { token: synthetic.rootToken }, sessions: [
        { sessionKey: "codex:42", agent: "codex", label: "Codex", pid: 42,
          cwd: synthetic.rootPath, cwdToken: synthetic.rootToken,
          location: "this folder", ageSeconds: 90 }
      ] })), "Active-session response was rejected")
    check(synthetic.activeSessions.length === 1 && synthetic.sessionsModel.count === 1,
      "Active sessions were not published through a stable model")
    var sessionDelegate = sessionRows.itemAt(0)
    var sessionCreated = createdSessionDelegates
    var sessionDestroyed = destroyedSessionDelegates
    synthetic.sessionsInFlightRootToken = synthetic.rootToken
    synthetic.sessionsInFlightRootPath = synthetic.rootPath
    check(synthetic.applySessions(JSON.stringify({ ok: true,
      root: { token: synthetic.rootToken }, sessions: synthetic.activeSessions })),
      "Unchanged active sessions were rejected")
    check(sessionRows.itemAt(0) === sessionDelegate
        && createdSessionDelegates === sessionCreated
        && destroyedSessionDelegates === sessionDestroyed,
      "Unchanged session polling rebuilt its delegates")
    check(synthetic.selectedToken === selectionBeforeSessions
      && synthetic.selectedProperties === propertiesBeforeSessions,
      "Active-session refresh changed file selection or inspector state")
    check(synthetic.moveModule("sessions", 1)
      && synthetic.moduleLayout[2].id === "sessions",
      "Module reordering did not update the live layout")
    check(synthetic.setModulePinned("favorites", true)
      && synthetic.moduleState("favorites").pinned,
      "Module pinning did not update the live layout")

    prepareRequest()
    var accelerated = JSON.parse(response(synthetic.entries))
    accelerated.engine = "rg"
    check(synthetic.applyListing(JSON.stringify(accelerated)),
      "Accelerated search listing was rejected")
    check(synthetic.searchEngine === "rg", "Search engine identity was discarded")

    synthetic.previewToken = "b"
    synthetic.previewRevision = 7
    synthetic.previewData = { kind: "metadata", name: "retained" }
    check(synthetic.applyPreview(JSON.stringify({ ok: true,
      preview: { kind: "text", text: "stale" } }), "a", 6),
      "Stale preview was not ignored cleanly")
    check(synthetic.previewData.name === "retained"
      && synthetic.selectedToken === selectedBeforeBackgroundFeatures,
      "Stale preview replaced current state or selection")
    check(synthetic.applyPreview(JSON.stringify({ ok: true,
      preview: { kind: "text", text: "current" } }), "b", 7),
      "Current preview was rejected")
    check(synthetic.previewData.kind === "text" && synthetic.previewData.text === "current",
      "Current inline preview was not published")
    var previewCommand = synthetic.buildPreviewCommand("opaque-preview-token")
    check(previewCommand.join("|").indexOf("preview|--path-token|opaque-preview-token") >= 0,
      "Preview command does not pass the opaque path token as a fixed argv value")

    var operationCommand = synthetic.buildOperationCommand({ kind: "copy",
      tokens: ["first-token", "second-token"], destinationToken: "folder-token",
      name: "", trashUris: [], sourceUris: [], conflictPolicy: "ask" })
    check(operationCommand[3] === "operation" && operationCommand[4] === "copy"
      && operationCommand[operationCommand.indexOf("--destination-token") + 1] === "folder-token"
      && operationCommand[operationCommand.indexOf("--conflict-policy") + 1] === "ask",
      "Drop operation command lost its destination token or safe conflict default")
    check(JSON.parse(operationCommand[operationCommand.indexOf("--path-tokens-json") + 1]).join(",")
      === "first-token,second-token", "Internal drops did not preserve opaque token values")
    var externalCommand = synthetic.buildOperationCommand({ kind: "copy", tokens: [],
      destinationToken: "folder-token", name: "", trashUris: [],
      sourceUris: ["file:///tmp/from-file-manager"], conflictPolicy: "ask" })
    check(JSON.parse(externalCommand[externalCommand.indexOf("--source-uris-json") + 1])[0]
      === "file:///tmp/from-file-manager", "External file drop did not use the URI argv channel")
    var tooManyTokens = []
    for (var tokenIndex = 0; tokenIndex < 501; tokenIndex++) tooManyTokens.push("t" + tokenIndex)
    check(!synthetic.dropOnDirectory("folder-token", tooManyTokens, false),
      "Drop token input was not bounded")

    synthetic.pendingOperation = { kind: "copy", tokens: ["first-token"],
      destinationToken: "folder-token", name: "", trashUris: [], sourceUris: [],
      conflictPolicy: "ask" }
    var conflicts = [{ sourceToken: "first-token", targetToken: "existing-token" }]
    check(synthetic.applyOperationCompletion({ ok: false, code: "operation-conflict",
      error: "A destination exists", conflicts: conflicts }),
      "Structured operation conflict was not recognized")
    check(synthetic.operationResult.code === "operation-conflict"
      && synthetic.operationConflicts.length === 1 && synthetic.pendingOperation !== null
      && conflictSignals === 1, "Conflict details or pending retry request were discarded")
    check(synthetic.dismissOperationConflict() && synthetic.pendingOperation === null
      && synthetic.operationConflicts.length === 0 && synthetic.operationResult === null,
      "Dismissing a conflict did not clear its pending request")
    synthetic.pendingOperation = { kind: "copy", tokens: ["first-token"] }
    check(!synthetic.applyOperationCompletion({ ok: true }),
      "Successful operation was mistaken for a conflict")
    check(synthetic.pendingOperation === null && synthetic.operationConflicts.length === 0,
      "Completed operation retained obsolete conflict state")
    console.log("QuickFile service model assertions passed:", assertions)
  }

  function entryNamed(name) {
    for (var i = 0; i < live.entries.length; i++)
      if (live.entries[i].name === name) return live.entries[i]
    return null
  }

  function transition(next) {
    phase = next
    phaseStarted = Date.now()
  }

  function mutate(action, next) {
    transition(next)
    mutation.command = ["/usr/bin/python3", "-c",
      "from pathlib import Path; import sys; p=Path(sys.argv[1]); " + action, fixture]
    mutation.running = true
  }

  Process {
    id: mutation
    onExited: function(code) {
      if (code !== 0) suite.fail("Fixture mutation failed with exit code " + code)
    }
  }

  Timer {
    interval: 100
    repeat: true
    running: !suite.finished
    onTriggered: {
      try {
        var now = Date.now()
        if (now - suite.phaseStarted > 12000)
          throw new Error("Timed out in " + suite.phase + ": " + live.errorMessage
            + " / " + live.watchError + "; requests=" + live.listingRequests)
        if (suite.phase === "startup") {
          if (live.listingRequests !== suite.previousRequests) {
            suite.previousRequests = live.listingRequests
            suite.stableSince = now
          }
          if (live.watcherReady && !live.busy && !live.knowledgeBusy
              && suite.entryNamed("original.txt") && now - suite.stableSince >= 1500) {
            suite.check(!live.watcherFailed && !live.watcherDegraded, "Native watcher is unavailable")
            suite.idleRequests = live.listingRequests
            suite.expectSilent = true
            suite.transition("idle")
          }
        } else if (suite.phase === "idle" && now - suite.phaseStarted >= 4500) {
          suite.check(live.listingRequests === suite.idleRequests,
            "An idle directory was repeatedly listed")
          suite.mutate("(p/'created.txt').write_text('created')", "created")
        } else if (suite.phase === "created" && suite.entryNamed("created.txt")) {
          suite.check(live.listingRequests > suite.idleRequests, "Creation did not trigger a listing")
          suite.mutate("(p/'created.txt').write_text('changed contents with a different size')", "written")
        } else if (suite.phase === "written") {
          var written = suite.entryNamed("created.txt")
          if (written && written.size === 38)
            suite.mutate("(p/'created.txt').rename(p/'renamed.txt')", "renamed")
        } else if (suite.phase === "renamed" && suite.entryNamed("renamed.txt")
            && !suite.entryNamed("created.txt")) {
          suite.mutate("(p/'renamed.txt').unlink()", "deleted")
        } else if (suite.phase === "deleted" && !suite.entryNamed("renamed.txt")) {
          live.setPanelVisible(false)
          suite.transition("closing")
        } else if (suite.phase === "closing" && !live.busy && now - suite.phaseStarted >= 700) {
          suite.check(!live.watcherReady, "Watcher remained ready after closing")
          suite.idleRequests = live.listingRequests
          suite.mutate("(p/'while-hidden.txt').write_text('hidden change')", "hidden")
        } else if (suite.phase === "hidden" && now - suite.phaseStarted >= 1500) {
          suite.check(live.listingRequests === suite.idleRequests,
            "Hidden panel continued requesting listings")
          suite.check(!suite.entryNamed("while-hidden.txt"), "Closed panel unexpectedly applied a change")
          live.setPanelVisible(true)
          suite.transition("reopened")
        } else if (suite.phase === "reopened" && live.watcherReady
            && suite.entryNamed("while-hidden.txt")) {
          suite.check(live.listingRequests > suite.idleRequests, "Reopening did not reconcile missed events")
          suite.previousWatcherPid = live.watcherPid
          live.setPanelVisible(false)
          suite.check(live.watcherStopping, "Closing did not record the requested watcher shutdown")
          live.setPanelVisible(true)
          suite.check(live.watcherStopping && !live.watcherFailed,
            "Same-turn reopening lost the intentional shutdown state")
          suite.transition("rapid-reopened")
        } else if (suite.phase === "rapid-reopened" && live.watcherReady
            && !live.watcherStopping) {
          suite.check(!live.watcherFailed && !live.watcherDegraded,
            "Rapid reopening disabled native watching")
          suite.check(live.watcherPid && live.watcherPid !== suite.previousWatcherPid,
            "Rapid reopening did not replace the stopped watcher")
          suite.mutate("(p/'after-rapid-reopen.txt').write_text('still watched')", "rapid-created")
        } else if (suite.phase === "rapid-created" && suite.entryNamed("after-rapid-reopen.txt")) {
          suite.check(live.watcherReady, "Rapidly reopened panel lost file monitoring")
          suite.previousWatcherPid = live.watcherPid
          mutation.command = ["/usr/bin/python3", "-c",
            "import os,sys,signal; os.kill(int(sys.argv[1]), signal.SIGKILL)",
            String(suite.previousWatcherPid)]
          mutation.running = true
          suite.transition("watcher-crashed")
        } else if (suite.phase === "watcher-crashed" && now - suite.phaseStarted >= 1500) {
          suite.check(live.watcherFailed && !live.watcherReady && !live.watcherPid,
            "Unexpected watcher exit did not remain in fallback without restarting")
          suite.finished = true
          live.setPanelVisible(false)
          console.log("QUICKFILE_TESTS_PASSED service:", suite.assertions,
            "assertions; native events, idle, hide/reopen, rapid reopen, crash fallback verified")
          Qt.quit()
        }
      } catch (error) { suite.fail(error.message) }
    }
  }

  Component.onCompleted: Qt.callLater(function() {
    try {
      suite.runUnitTests()
      suite.phaseStarted = Date.now()
      live.setPanelVisible(true)
    } catch (error) { suite.fail(error.message) }
  })
}
