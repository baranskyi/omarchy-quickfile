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
  property int createdDriveDelegates: 0
  property int destroyedDriveDelegates: 0
  property int createdOfflineDelegates: 0
  property int destroyedOfflineDelegates: 0
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

  // Drive catalog bookkeeping, driven through its own request/exit cycle. The
  // process-starting and signalling calls are recorded instead, so no backend
  // runs.
  Quickfile.Service {
    id: drives
    rootPath: suite.fixture
    initialized: false
    property var launches: []
    property var sentSignals: []
    property var forgetLaunches: []
    property var volumeActions: []
    property int volumeReloads: 0
    function startCatalogIndexProcess(command) {
      launches.push(command)
      return true
    }
    function signalCatalogIndex(signalNumber) {
      sentSignals.push(signalNumber)
      return true
    }
    function startCatalogForgetProcess(command) {
      forgetLaunches.push(command)
      return true
    }
    function runVolumeAction(kind, volume) {
      volumeActions.push(kind + ":" + String(volume.device || ""))
      return true
    }
    function reloadVolumes() {
      volumeReloads++
      return true
    }
  }

  // Search rows from drive catalogs. Everything a guard could hand a catalog
  // token to is either recorded here or a real process whose busy flag shows.
  Quickfile.Service {
    id: offline
    rootPath: suite.fixture
    rootToken: "offline-root"
    knowledgeRootToken: "offline-root"
    initialized: true
    property var volumeActions: []
    property int volumeReloads: 0
    property int searchRefreshes: 0
    property var reloads: []
    property int settingsSaves: 0
    property var inspections: []
    property var revealed: []
    function runVolumeAction(kind, volume, navigateAfter) {
      volumeActions.push(kind + ":" + String(volume.device || "")
        + (navigateAfter === false ? ":stay" : ""))
      return true
    }
    function reloadVolumes() {
      volumeReloads++
      return true
    }
    function scheduleSearchRefresh() {
      searchRefreshes++
      return true
    }
    function reload(background) {
      reloads.push(background === true)
      return true
    }
    function persistSettings() {
      settingsSaves++
      return true
    }
    function startPendingInspection() {
      inspections.push(propertyPendingToken)
      propertyPendingToken = ""
    }
    function startCatalogIndexProcess(command) { return true }
    property var operations: []
    function runOperation(kind, tokens) {
      operations.push(kind + ":" + tokens.join(","))
      pendingOperation = { kind: kind, tokens: tokens.slice() }
      return true
    }
    onRevealRequested: function(token) { revealed.push(token) }
  }

  Item {
    Repeater {
      id: offlineRows
      model: offline.entriesModel
      delegate: Item {
        required property var rowData
        Component.onCompleted: suite.createdOfflineDelegates++
        Component.onDestruction: suite.destroyedOfflineDelegates++
      }
    }
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

  Item {
    Repeater {
      id: driveRows
      model: drives.volumesModel
      delegate: Item {
        required property var rowData
        Component.onCompleted: suite.createdDriveDelegates++
        Component.onDestruction: suite.destroyedDriveDelegates++
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

    synthetic.searchMode = "smart"
    synthetic.query = "find config yesterday"
    synthetic.semanticPlanQuery = synthetic.query
    synthetic.semanticPlan = ({ version: 1, terms: ["config"], hints: {
      target: { value: "file", confidence: 0.8, source: "laya" },
      kind: { value: "config", confidence: 0.9, source: "rule" },
      location: { value: "any", confidence: 0.5, source: "laya" },
      time: { value: "yesterday", confidence: 0.9, source: "rule" }
    } })
    var smartCommand = synthetic.buildListCommand()
    check(smartCommand[smartCommand.indexOf("--mode") + 1] === "smart"
      && smartCommand.indexOf("--smart-plan-json") >= 0,
      "Smart listing command did not carry its bounded analysis plan")
    var planBeforeStale = synthetic.semanticPlan
    synthetic.semanticPendingId = 9
    synthetic.semanticPendingQuery = synthetic.query
    check(synthetic.handleSemanticEvent(JSON.stringify({ event: "analysis", id: 8,
      plan: { version: 1, terms: ["stale"], hints: {} } })),
      "A stale semantic response was not handled")
    check(synthetic.semanticPlan === planBeforeStale,
      "A stale semantic response replaced the current plan")
    prepareRequest()
    var smartListing = JSON.parse(response(synthetic.entries))
    smartListing.smart = { state: "ready", model: "laya-multilingual", device: "cpu",
      terms: ["config"], hints: synthetic.semanticPlan.hints }
    synthetic.listInFlightBackground = false
    check(synthetic.applyListing(JSON.stringify(smartListing)),
      "Smart listing metadata was rejected")
    check(synthetic.listingIsNewResults,
      "A foreground search answered by a new command was not marked as new results")
    synthetic.listInFlightBackground = false
    check(synthetic.applyListing(JSON.stringify(smartListing))
        && !synthetic.listingIsNewResults,
      "Re-applying the same search command was marked as new results")
    synthetic.listInFlightBackground = true
    check(synthetic.semanticResult && synthetic.semanticResult.state === "ready"
      && synthetic.semanticModel === "laya-multilingual" && synthetic.semanticDevice === "cpu",
      "Smart listing metadata was not published")
    // Emptying the field must not unload a warm model; leaving SMART must.
    synthetic.semanticSessionActive = true
    synthetic.query = ""
    check(synthetic.semanticSessionActive,
      "Clearing a SMART query ended the model session")
    synthetic.searchMode = "fuzzy"
    check(!synthetic.semanticSessionActive,
      "Leaving SMART did not end the model session")
    synthetic.semanticPlan = null
    synthetic.semanticPlanQuery = ""
    synthetic.semanticResult = null

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
    catalogUnitTests()
    offlineSearchUnitTests()
    console.log("QuickFile service model assertions passed:", assertions)
  }

  // A connected drive row as `volumes` reports it; `extra` overrides fields.
  function drive(id, device, extra) {
    var mounted = !!extra && extra.mounted === true
    return Object.assign({ id: id || device, catalogVolumeId: id, device: device,
      deviceName: device.replace("/dev/", ""), name: "Drive " + device.slice(-4),
      label: "", uuid: "", partUuid: "", serial: "", model: "Stick", vendor: "",
      fstype: "exfat", transport: "usb", size: 64000000000, sizeText: "64 GB",
      mountPath: mounted ? "/run/media/test/" + device.slice(-4) : "",
      mountToken: mounted ? "mount-" + device.slice(-4) : "",
      mounted: false, removable: true, hotplug: true, readOnly: false,
      canMount: true, canUnmount: mounted, identityStrength: id ? "strong" : "none",
      catalogued: false, indexedAt: "", indexedEpoch: 0, catalogEntries: 0,
      catalogState: "", offline: false, locked: false }, extra || ({}))
  }

  function offlineDrive(id, name, epoch) {
    return { id: id, catalogVolumeId: id, offline: true, catalogued: true, locked: false,
      name: name, label: name, uuid: "", partUuid: "", serial: "", model: "Stick",
      vendor: "", fstype: "exfat", transport: "usb", size: 64000000000, sizeText: "64 GB",
      device: "", deviceName: "", mountPath: "", mountToken: "", mounted: false,
      removable: true, hotplug: true, readOnly: false, canMount: false, canUnmount: false,
      identityStrength: "strong", indexedAt: "2026-10-01T10:00:00", indexedEpoch: epoch,
      catalogEntries: 12, catalogState: "complete" }
  }

  function snapshot(rows) {
    var offline = rows.filter(function(row) { return row.offline === true }).length
    return JSON.stringify({ ok: true, volumes: rows, count: rows.length - offline,
      offlineCount: offline })
  }

  function catalogUnitTests() {
    var old = Date.now() / 1000 - 7 * 86400
    var archive = drive("uuid:A1", "/dev/sdb1", { name: "ARCHIVE", label: "ARCHIVE",
      mounted: true, catalogued: true, indexedEpoch: old, catalogState: "complete" })

    var indexCommand = drives.buildCatalogIndexCommand(archive)
    check(JSON.stringify(indexCommand) === JSON.stringify(["/usr/bin/env", "python3",
      drives.cliPath, "catalog-index", "--device", "/dev/sdb1"]),
      "Catalog index command is not the fixed argv the backend expects: " + indexCommand)
    var forgetCommand = drives.buildCatalogForgetCommand("uuid:A1 $(rm -rf ~)")
    check(JSON.stringify(forgetCommand) === JSON.stringify(["/usr/bin/env", "python3",
      drives.cliPath, "catalog-forget", "--volume-id", "uuid:A1 $(rm -rf ~)"]),
      "Catalog forget command did not pass the volume id as one argv value")

    drives.handleCatalogIndexEvent(JSON.stringify({ event: "progress", phase: "indexing",
      files: 1200, directories: 30, bytes: 4096, path: "/run/media/test/Photos" }))
    check(drives.catalogIndexPhase === "indexing" && drives.catalogIndexFiles === 1200
      && drives.catalogIndexDirectories === 30 && drives.catalogIndexBytes === 4096,
      "Catalog index progress did not reach the service state")
    drives.handleCatalogIndexEvent(JSON.stringify({ event: "progress", phase: "saving",
      files: 1300, directories: 31, bytes: 5000 }))
    check(drives.catalogIndexPhase === "saving" && drives.catalogIndexFiles === 1300,
      "The saving phase was not reported")
    drives.handleCatalogIndexEvent("not json")
    check(drives.catalogIndexFiles === 1300, "A malformed progress line changed the state")
    drives.handleCatalogIndexEvent(JSON.stringify({ ok: false, event: "result",
      error: "The drive was disconnected while indexing", code: "catalog-volume-lost" }))
    check(drives.catalogIndexError === "The drive was disconnected while indexing"
      && drives.catalogIndexResult.code === "catalog-volume-lost",
      "A structured index failure was not kept")
    drives.handleCatalogIndexEvent(JSON.stringify({ ok: true, event: "result",
      volume: { volumeId: "uuid:A1", name: "ARCHIVE", entries: 41300, files: 41200,
        directories: 100, bytes: 9000, truncated: false, state: "complete" } }))
    check(drives.catalogIndexResult.ok === true && drives.catalogIndexFiles === 41200
      && drives.catalogIndexError === "", "The index result did not replace the progress")
    drives.catalogIndexResult = null

    // Drives already mounted when QuickFile starts were not just plugged in.
    var created = createdDriveDelegates
    check(drives.applyVolumes(snapshot([archive])), "The first drive snapshot was rejected")
    check(drives.volumesSnapshotReady && drives.launches.length === 0,
      "The baseline drive snapshot started an index")
    check(drives.catalogVolumeCount === 1 && drives.offlineVolumeCount === 0,
      "Catalogued and offline drive counts were not published")
    check(createdDriveDelegates === created + 1, "The drive row did not get a delegate")
    var archiveDelegate = driveRows.itemAt(0)
    drives.applyVolumes(snapshot([archive]))
    check(drives.launches.length === 0 && driveRows.itemAt(0) === archiveDelegate,
      "An unchanged drive snapshot started an index or rebuilt its row")

    // Unmounted, then mounted again: that transition re-indexes, once.
    var unmounted = drive("uuid:A1", "/dev/sdb1", { name: "ARCHIVE", label: "ARCHIVE",
      catalogued: true, indexedEpoch: old, catalogState: "complete" })
    drives.applyVolumes(snapshot([unmounted]))
    check(drives.launches.length === 0, "Unmounting a catalogued drive started an index")
    drives.applyVolumes(snapshot([archive]))
    check(drives.launches.length === 1
      && JSON.stringify(drives.launches[0]) === JSON.stringify(indexCommand),
      "Mounting a known drive again did not re-index it")
    check(drives.catalogIndexVolumeId === "uuid:A1" && drives.catalogIndexAutomatic
      && drives.catalogIndexDevice === "/dev/sdb1" && drives.catalogIndexName === "ARCHIVE",
      "The automatic index did not record which drive it walks")
    check(!drives.actionBusy && !drives.operationBusy,
      "A drive index was folded into the foreground busy state")
    check(!drives.indexVolume(archive, false), "A second index started while one was running")
    check(!drives.forgetCatalog("uuid:A1") && drives.actionMessage === "This drive is being indexed",
      "Forgetting the drive being indexed was not refused")
    drives.applyVolumes(snapshot([archive]))
    check(drives.launches.length === 1, "A repeated mounted snapshot re-indexed the drive")

    drives.handleCatalogIndexEvent(JSON.stringify({ ok: true, event: "result",
      volume: { volumeId: "uuid:A1", name: "ARCHIVE", entries: 41300, files: 41200,
        directories: 100, bytes: 9000, truncated: false, state: "partial",
        partialReason: "entry-limit" } }))
    var finished = []
    var finishHandler = function(kind, ok, message) { finished.push([kind, ok, message]) }
    drives.actionFinished.connect(finishHandler)
    drives.finishCatalogIndex(0)
    check(drives.actionMessage === "Indexed “ARCHIVE” · 41.2k files · partial",
      "The finished index did not report its size and partial state: " + drives.actionMessage)
    check(finished.length === 1 && finished[0][0] === "catalog-index" && finished[0][1] === true,
      "The finished index did not announce itself")
    check(drives.catalogIndexVolumeId === "" && drives.catalogIndexDevice === ""
      && !drives.catalogIndexAutomatic, "The finished index left its drive recorded")
    // Indexing stamps the catalog; the next snapshot must not loop into another run.
    var fresh = Object.assign({}, archive, { indexedEpoch: Date.now() / 1000,
      catalogEntries: 41300, catalogState: "partial" })
    drives.applyVolumes(snapshot([fresh]))
    check(drives.launches.length === 1, "A finished index started another one")

    // A drive indexed a moment ago is not walked again on a quick replug.
    var recent = drive("uuid:B2", "/dev/sdc1", { catalogued: true,
      indexedEpoch: Date.now() / 1000 - 10 })
    drives.applyVolumes(snapshot([fresh, recent]))
    drives.applyVolumes(snapshot([fresh, Object.assign({}, recent, { mounted: true,
      canUnmount: true, mountPath: "/run/media/test/sdc1" })]))
    check(drives.launches.length === 1, "A drive indexed seconds ago was re-indexed")

    // Two drives at once: one runs, the other waits its turn.
    var c3 = drive("uuid:C3", "/dev/sdd1", { catalogued: true, indexedEpoch: old })
    var d4 = drive("uuid:D4", "/dev/sde1", { catalogued: true, indexedEpoch: old })
    drives.applyVolumes(snapshot([fresh, c3, d4]))
    var c3Mounted = drive("uuid:C3", "/dev/sdd1", { catalogued: true, indexedEpoch: old,
      mounted: true })
    var d4Mounted = drive("uuid:D4", "/dev/sde1", { catalogued: true, indexedEpoch: old,
      mounted: true })
    drives.applyVolumes(snapshot([fresh, c3Mounted, d4Mounted]))
    check(drives.launches.length === 2 && drives.catalogIndexVolumeId === "uuid:C3"
      && drives.autoIndexQueue.join(",") === "uuid:D4",
      "Two remounted drives did not run one at a time: " + drives.autoIndexQueue)
    drives.applyVolumes(snapshot([fresh, c3Mounted, d4Mounted]))
    check(drives.autoIndexQueue.length === 1, "A queued drive was queued twice")

    // Stopping an automatic run skips that drive for the session and moves on.
    // SIGTERM first; a walk stuck in a pulled drive's I/O gets SIGKILL later.
    drives.actionMessage = "Connect “OLD DRIVE” to browse it"
    check(drives.cancelCatalogIndex() && drives.catalogIndexCancelling,
      "Cancelling an index did not latch")
    check(drives.sentSignals.join(",") === "15" && drives.catalogIndexKillPending,
      "Cancelling an index did not send SIGTERM and arm the kill: " + drives.sentSignals)
    check(!drives.cancelCatalogIndex() && drives.sentSignals.length === 1,
      "A second cancel was not ignored")
    check(drives.escalateCatalogIndexCancel() && drives.sentSignals.join(",") === "15,9"
      && !drives.catalogIndexKillPending, "A walk ignoring SIGTERM was not killed")
    drives.finishCatalogIndex(130)
    check(drives.actionMessage === "Connect “OLD DRIVE” to browse it",
      "A cancelled index wiped the message that arrived while it ran: " + drives.actionMessage)
    check(drives.autoIndexSkipped["uuid:C3"] === true,
      "Stopping an automatic index did not skip the drive for the session")
    check(drives.launches.length === 3 && drives.catalogIndexVolumeId === "uuid:D4"
      && drives.autoIndexQueue.length === 0, "The queued drive did not start next")
    drives.catalogIndexResult = { ok: true, event: "result",
      volume: { name: "Drive sde1", files: 12, state: "complete" } }
    drives.finishCatalogIndex(0)
    check(drives.actionMessage === "Indexed “Drive sde1” · 12 files",
      "A small index did not report its count")
    drives.applyVolumes(snapshot([fresh, c3, d4]))
    drives.applyVolumes(snapshot([fresh, c3Mounted, d4]))
    check(drives.launches.length === 3, "A skipped drive was re-indexed in the same session")

    // Unmounting the drive being indexed stops the walk, then unmounts.
    var e5 = drive("uuid:E5", "/dev/sdf1", { mounted: true })
    drives.applyVolumes(snapshot([fresh, c3Mounted, d4, e5]))
    check(drives.launches.length === 3, "A drive without a catalog was indexed on its own")
    check(drives.indexVolume(e5, false) && drives.launches.length === 4
      && !drives.catalogIndexAutomatic, "A requested index did not start")
    check(drives.actionMessage === "",
      "A new index left an older message over its progress: " + drives.actionMessage)
    check(!drives.catalogIndexKillPending, "A finished index left its kill armed")
    check(drives.unmountVolume(e5) && drives.unmountAfterIndexDevice === "/dev/sdf1"
      && drives.catalogIndexCancelling && drives.volumeActions.length === 0,
      "Unmounting the drive being indexed did not cancel first and park the unmount")
    drives.finishCatalogIndex(130)
    check(drives.volumeActions.join(",") === "unmount:/dev/sdf1"
      && drives.unmountAfterIndexDevice === "",
      "The parked unmount did not run once the index stopped")
    check(drives.autoIndexSkipped["uuid:E5"] !== true,
      "Unmounting mid-index was mistaken for skipping the drive")

    // Drives that cannot carry a catalog are refused.
    var anonymous = drive("", "/dev/sdh1", { mounted: true })
    check(!drives.indexVolume(anonymous, false)
      && drives.actionMessage === "This drive has no stable identity",
      "A drive without a stable identity was indexed")
    check(!drives.indexVolume(c3, false), "An unmounted drive was indexed")
    var away = offlineDrive("uuid:OFF", "OLD DRIVE", old)
    check(!drives.indexVolume(away, false), "An offline drive was indexed")
    check(drives.launches.length === 4, "A refused index still started a process")

    // An offline row keeps its catalog id as its key, so replugging the drive
    // updates the row in place instead of rebuilding it.
    check(drives.rowKey(away) === "uuid:OFF", "An offline row was not keyed by its catalog id")
    drives.applyVolumes(snapshot([fresh, away]))
    check(drives.offlineVolumeCount === 1 && drives.catalogVolumeCount === 2,
      "The offline drive was not counted")
    var awayIndex = -1
    for (var i = 0; i < driveRows.count; i++)
      if (driveRows.itemAt(i).rowData.id === "uuid:OFF") awayIndex = i
    check(awayIndex === 1, "The offline row was not rendered")
    var awayDelegate = driveRows.itemAt(awayIndex)
    var createdBeforeReplug = createdDriveDelegates
    var destroyedBeforeReplug = destroyedDriveDelegates
    var launchesBeforeReplug = drives.launches.length
    check(!drives.openVolume(away)
      && drives.actionMessage === "Connect “OLD DRIVE” to browse it",
      "Opening an offline drive did not say which drive to connect")
    check(drives.volumeActions.length === 1 && drives.launches.length === launchesBeforeReplug,
      "Opening an offline drive started a process")
    var replugged = drive("uuid:OFF", "/dev/sdg1", { name: "OLD DRIVE", label: "OLD DRIVE",
      catalogued: true, indexedEpoch: Date.now() / 1000 - 5, catalogState: "complete" })
    drives.applyVolumes(snapshot([fresh, replugged]))
    check(driveRows.itemAt(awayIndex) === awayDelegate
      && createdDriveDelegates === createdBeforeReplug
      && destroyedDriveDelegates === destroyedBeforeReplug,
      "Replugging an offline drive rebuilt its delegate")
    check(driveRows.itemAt(awayIndex).rowData.device === "/dev/sdg1"
      && drives.offlineVolumeCount === 0, "The replugged drive did not update in place")

    var locked = drive("uuid:LUKS", "/dev/sdi1", { name: "VAULT", catalogued: true,
      locked: true, canMount: false })
    check(!drives.openVolume(locked) && drives.actionMessage === "Unlock “VAULT” to browse it",
      "Opening a locked catalogued drive did not ask to unlock it")
    check(drives.volumeActions.length === 1, "Opening a locked drive started a process")

    // Two drives of one name are told apart by model and size in the list;
    // the hint names the drive by its label alone.
    var orphan = Object.assign(offlineDrive("uuid:OLD", "ARCHIVE", old),
      { name: "ARCHIVE · Old Stick · 8 GB" })
    check(!drives.openVolume(orphan) && drives.actionMessage === "Connect “ARCHIVE” to browse it",
      "The connect hint carried the listed model and size: " + drives.actionMessage)
    var lockedTwin = Object.assign({}, locked, { label: "VAULT", name: "VAULT · Stick · 64 GB" })
    check(!drives.openVolume(lockedTwin) && drives.actionMessage === "Unlock “VAULT” to browse it",
      "The unlock hint carried the listed model and size: " + drives.actionMessage)

    // Forgetting runs its own process; its exit reports and settles the queue.
    drives.autoIndexQueue = ["uuid:OFF", "uuid:Z9"]
    check(drives.forgetCatalog("uuid:OFF") && drives.catalogForgetVolumeId === "uuid:OFF"
      && drives.forgetLaunches.length === 1 && JSON.stringify(drives.forgetLaunches[0])
        === JSON.stringify(drives.buildCatalogForgetCommand("uuid:OFF")),
      "Forgetting a catalog did not start its process")
    drives.catalogForgetStdout = JSON.stringify({ ok: true, volumeId: "uuid:OFF",
      removed: true, message: "Forgot “OLD DRIVE”" })
    drives.finishCatalogForget(0)
    var forgot = finished[finished.length - 1]
    check(drives.actionMessage === "Forgot “OLD DRIVE”" && drives.catalogForgetVolumeId === ""
      && forgot[0] === "catalog-forget" && forgot[1] === true,
      "A forgotten catalog was not reported: " + drives.actionMessage)
    check(drives.autoIndexQueue.join(",") === "uuid:Z9",
      "A forgotten drive stayed queued for indexing: " + drives.autoIndexQueue)
    drives.forgetCatalog("uuid:Z9")
    drives.catalogForgetStdout = JSON.stringify({ ok: false, event: "result",
      error: "This drive is being indexed", code: "catalog-busy" })
    drives.finishCatalogForget(2)
    forgot = finished[finished.length - 1]
    check(drives.actionMessage === "This drive is being indexed" && forgot[1] === false
      && drives.autoIndexQueue.join(",") === "uuid:Z9",
      "A refused forget was not reported as the backend said it: " + drives.actionMessage)
    drives.forgetCatalog("uuid:Z9")
    drives.catalogForgetStderr = "Traceback: catalog dir is gone\n"
    drives.finishCatalogForget(1)
    check(drives.actionMessage === "Traceback: catalog dir is gone",
      "A forget without a result did not fall back to its stderr: " + drives.actionMessage)
    drives.autoIndexQueue = []

    // Never while the drive's own mount or unmount runs: a remounted drive in
    // that state waits in the queue for the snapshot after the action.
    var f6 = drive("uuid:F6", "/dev/sdj1", { catalogued: true, indexedEpoch: old })
    var f6Mounted = drive("uuid:F6", "/dev/sdj1", { catalogued: true, indexedEpoch: old,
      mounted: true })
    drives.applyVolumes(snapshot([fresh, f6]))
    var launchesBeforeAction = drives.launches.length
    drives.volumeActionDevice = "/dev/sdj1"
    check(!drives.indexVolume(f6Mounted, false) && drives.launches.length === launchesBeforeAction,
      "A drive was indexed while its own mount or unmount was running")
    drives.applyVolumes(snapshot([fresh, f6Mounted]))
    check(drives.launches.length === launchesBeforeAction
      && drives.autoIndexQueue.join(",") === "uuid:F6",
      "A remounted drive with an action in flight was not held back: " + drives.autoIndexQueue)
    drives.volumeActionDevice = ""
    drives.applyVolumes(snapshot([fresh, f6Mounted]))
    check(drives.launches.length === launchesBeforeAction + 1
      && drives.catalogIndexVolumeId === "uuid:F6" && drives.autoIndexQueue.length === 0,
      "The held drive did not start once its action had finished")
    drives.finishCatalogIndex(130)
    drives.actionFinished.disconnect(finishHandler)
  }

  // A search row from the catalog of ARCHIVE, as `search` reports it while
  // the drive is away; `extra` overrides fields.
  function catalogRow(name, extra) {
    var relative = "Photos/" + name
    // Shaped like the backend's token; only its prefix and uniqueness matter here.
    var token = "catalog:dXVpZDpBMQ:" + relative.replace(/[^A-Za-z0-9]/g, "_")
    return Object.assign({ name: name, path: "ARCHIVE:/" + relative, token: token, uri: "",
      shellQuotedPath: "", depth: 0, kind: "file", isDir: false, isSymlink: false,
      isHidden: false, isExecutable: false, hasChildren: false, expanded: false,
      size: 2048, sizeText: "2.0 KiB", modified: "2026-09-01T10:00:00",
      modifiedEpoch: 1788256800, permissions: "", mode: "", mime: "image/jpeg", git: "",
      relativePath: relative, matchKind: "name", matchLine: 0, matchSnippet: "",
      origin: "catalog", available: false, catalogToken: token, volumeId: "uuid:A1",
      volumeName: "ARCHIVE", volumeModel: "Stick", volumeSizeText: "64 GB",
      volumeState: "disconnected", indexedAt: "2026-10-01T10:00:00",
      indexedEpoch: 1790848800, catalogState: "complete" }, extra || ({}))
  }

  // The same row once ARCHIVE is mounted elsewhere: a real token and path,
  // the catalog token kept.
  function liveCatalogRow(row) {
    var path = "/run/media/test/ARCHIVE/" + row.relativePath
    return Object.assign({}, row, { available: true, volumeState: "mounted",
      token: "real-" + row.name, path: path, uri: "file://" + path,
      shellQuotedPath: "'" + path + "'" })
  }

  function catalogListing(rows) {
    var away = rows.filter(function(row) { return row.available === false }).length
    var here = rows.filter(function(row) { return row.available === true }).length
    return JSON.stringify({ ok: true, root: { token: offline.rootToken, path: offline.rootPath },
      entries: rows, favorites: [], git: { root: "", branch: "" }, truncated: false,
      catalog: { searched: 1, offlineMatches: away, availableMatches: here,
        truncated: false, scanned: 40 } })
  }

  function applyCatalog(rows) {
    offline.listInFlightRootToken = offline.rootToken
    offline.listInFlightRootPath = offline.rootPath
    offline.listInFlightCommand = JSON.stringify(offline.buildListCommand())
    offline.listInFlightRevision = offline.metadataRevision
    offline.listInFlightBackground = true
    offline.reloadPending = false
    check(offline.applyListing(catalogListing(rows)), "A listing with catalog rows was rejected")
  }

  function noProcessFor(what) {
    check(!offline.actionBusy && !offline.operationBusy && !offline.previewBusy
        && !offline.folderSizeBusy && offline.previewInFlightToken === ""
        && offline.inspections.filter(function(token) {
          return offline.isCatalogToken(token) }).length === 0,
      what + " started a process for an offline row")
  }

  function offlineSearchUnitTests() {
    // --no-catalog only when switched off, and only for a search.
    offline.searchMode = "fuzzy"
    offline.query = ""
    offline.offlineSearchEnabled = false
    check(offline.buildListCommand().indexOf("--no-catalog") < 0,
      "A folder listing carried --no-catalog")
    offline.query = "beach"
    check(offline.buildListCommand().indexOf("--no-catalog") >= 0,
      "A search with offline drives switched off did not pass --no-catalog")
    offline.searchMode = "smart"
    check(offline.buildListCommand().indexOf("--no-catalog") >= 0,
      "A SMART search with offline drives switched off did not pass --no-catalog")
    offline.searchMode = "fuzzy"
    offline.offlineSearchEnabled = true
    check(offline.buildListCommand().indexOf("--no-catalog") < 0,
      "A search with offline drives on passed --no-catalog")

    // Every save carries the switch; a store from before it reads as on.
    var settingsCommand = offline.buildSettingsCommand()
    check(settingsCommand[settingsCommand.indexOf("--offline-search") + 1] === "true",
      "Saved settings did not carry the offline-search switch: " + settingsCommand)
    offline.offlineSearchEnabled = false
    settingsCommand = offline.buildSettingsCommand()
    check(settingsCommand[settingsCommand.indexOf("--offline-search") + 1] === "false",
      "Saved settings did not carry the offline-search switch turned off")
    check(offline.applySettings(JSON.stringify({ ok: true, settings: { modules: [] } }))
        && offline.offlineSearchEnabled === true,
      "A settings store without the switch did not read as on")
    check(offline.applySettings(JSON.stringify({ ok: true,
      settings: { modules: [], offlineSearchEnabled: false } }))
        && offline.offlineSearchEnabled === false, "A stored switch-off was not applied")
    var reloadsBefore = offline.reloads.length
    check(offline.setOfflineSearchEnabled(true) && offline.offlineSearchEnabled
        && offline.settingsSaves === 1, "Turning offline search on was not saved")
    check(offline.reloads.length === reloadsBefore + 1
        && offline.reloads[offline.reloads.length - 1] === false,
      "Turning offline search on did not search again")
    check(!offline.setOfflineSearchEnabled(true) && offline.settingsSaves === 1,
      "Setting the switch to its own value saved again")

    // The catalog tally is kept; an unchanged answer changes nothing.
    var report = { token: "live-report", name: "beach-report.txt", isDir: false,
      path: offline.rootPath + "/beach-report.txt", relativePath: "beach-report.txt",
      matchKind: "name" }
    var photo = catalogRow("beach.jpg")
    var folder = catalogRow("Beach trip", { isDir: true, kind: "directory",
      mime: "inode/directory", size: 0, sizeText: "", matchKind: "folder" })
    applyCatalog([report, photo, folder])
    check(offline.catalogResult && offline.catalogResult.searched === 1
        && offline.catalogResult.scanned === 40 && offline.offlineMatchCount === 2,
      "The catalog tally of a search was not kept")
    check(offlineRows.count === 3, "Catalog rows did not get delegates")
    var changesBefore = offline.listingChanges
    var createdBefore = createdOfflineDelegates
    applyCatalog([report, photo, folder])
    check(offline.listingChanges === changesBefore && createdOfflineDelegates === createdBefore,
      "An unchanged search with catalog rows emitted a model change")
    check(!offline.listingIsNewResults, "A background search was marked as new results")

    // A refresh for a file event asks the walk alone and keeps the catalog
    // rows on screen with their tally; a drive change asks for both again.
    check(offline.buildListCommand(true).indexOf("--no-catalog") >= 0,
      "A refresh that keeps the catalog rows still read the catalogs")
    check(offline.catalogReusable(), "A full search's catalog rows were not kept for a refresh")
    var report2 = Object.assign({}, report, { token: "live-report-2",
      name: "beach-report-2.txt", path: offline.rootPath + "/beach-report-2.txt",
      relativePath: "beach-report-2.txt" })
    function walkOnly(rows) {
      offline.listInFlightReusesCatalog = true
      offline.listInFlightCommand = JSON.stringify(offline.buildListCommand(true))
      offline.listInFlightRevision = offline.metadataRevision
      offline.listInFlightBackground = true
      offline.reloadPending = false
      offline.reloadPendingCatalog = false
      var applied = offline.applyListing(JSON.stringify({ ok: true,
        root: { token: offline.rootToken, path: offline.rootPath }, entries: rows,
        favorites: [], git: { root: "", branch: "" }, truncated: false,
        catalog: { searched: 0, offlineMatches: 0, availableMatches: 0, truncated: false,
          scanned: 0 } }))
      offline.listInFlightReusesCatalog = false
      return applied
    }
    check(walkOnly([report, report2]), "A refresh of the walk alone was rejected")
    check(offline.entries.map(function(row) { return row.token }).join(",")
        === ["live-report", "live-report-2", photo.token, folder.token].join(","),
      "A refresh of the walk alone dropped the catalog rows: "
        + offline.entries.map(function(row) { return row.token }))
    check(offline.catalogResult.searched === 1 && offline.catalogResult.scanned === 40
        && offline.offlineMatchCount === 2, "A refresh of the walk alone lost the catalog tally")
    offline.catalogPresenceKey = "uuid:A1=unmounted"
    check(!offline.catalogReusable(), "Catalog rows were kept across a drive change")
    var entriesBefore = offline.entries
    check(walkOnly([report]) && offline.reloadPending && offline.reloadPendingCatalog
        && offline.entries === entriesBefore,
      "A walk that ran while a drive changed was applied with the old catalog rows")
    offline.reloadPending = false
    offline.reloadPendingCatalog = false
    offline.catalogPresenceKey = ""
    applyCatalog([report, photo, folder])
    check(offline.entries.length === 3 && offline.catalogReusable(),
      "The full search after a walk-only refresh was not taken as the new catalog answer")

    // Enter names the drive to plug in and opens nothing.
    check(offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)])),
      "The drive snapshot was rejected")
    var reloadsOfVolumes = offline.volumeReloads
    offline.activateIndex(1)
    check(offline.actionMessage === "Connect “ARCHIVE” to open beach.jpg",
      "Enter on an offline file did not say which drive to connect: " + offline.actionMessage)
    noProcessFor("Enter")
    check(offline.volumeReloads === reloadsOfVolumes + 1,
      "Enter on an offline row did not refresh the drive list first")
    check(offline.lastOfflineRequest && offline.lastOfflineRequest.catalogToken === photo.catalogToken
        && offline.lastOfflineRequest.volumeId === "uuid:A1"
        && offline.lastOfflineRequest.name === "beach.jpg",
      "Enter on an offline row did not remember the row asked for")
    check(offline.selectedToken === photo.token && offline.selectedOffline
        && offline.selectedProperties && offline.selectedProperties.offline === true
        && offline.selectedProperties.volumeName === "ARCHIVE"
        && offline.selectedProperties.volumeState === "disconnected"
        && offline.selectedProperties.catalogState === "complete",
      "Selecting an offline row did not synthesise its properties")
    // Its drive arrives but stays unmounted: the inspector says so at once.
    var refreshesBeforeArrival = offline.searchRefreshes
    offline.applyVolumes(snapshot([drive("uuid:A1", "/dev/sdb1", { name: "ARCHIVE",
      label: "ARCHIVE", catalogued: true, canMount: false, indexedEpoch: 1790848800,
      catalogState: "complete" })]))
    check(offline.selectedProperties.volumeState === "unmounted",
      "The inspector of an offline row did not follow its drive arriving: "
        + offline.selectedProperties.volumeState)
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    check(offline.selectedProperties.volumeState === "disconnected",
      "The inspector of an offline row did not follow its drive leaving")
    offline.searchRefreshes = refreshesBeforeArrival
    offline.inspect(photo.token)
    noProcessFor("Re-inspecting an offline row")
    offline.enterIndex(2)
    check(offline.actionMessage === "Connect “ARCHIVE” to browse Beach trip",
      "Entering an offline folder did not say which drive to connect: " + offline.actionMessage)
    check(offline.rootToken === "offline-root", "Entering an offline folder navigated")
    offline.actionMessage = ""
    check(!offline.enterEntry(photo)
        && offline.actionMessage === "Connect “ARCHIVE” to open beach.jpg",
      "Opening an offline row from a list did not hint: " + offline.actionMessage)
    noProcessFor("enterEntry")

    // Locked, mountable and unmountable drives each get their own word.
    var archive = drive("uuid:A1", "/dev/sdb1", { name: "ARCHIVE", label: "ARCHIVE",
      catalogued: true, indexedEpoch: 1790848800, catalogState: "complete" })
    offline.applyVolumes(snapshot([Object.assign({}, archive, { locked: true,
      canMount: false })]))
    check(offline.searchRefreshes === refreshesBeforeArrival + 1,
      "A drive arriving under a search did not refresh its offline rows")
    offline.activateIndex(1)
    check(offline.actionMessage === "Unlock “ARCHIVE” to open beach.jpg"
        && offline.volumeActions.length === 0,
      "A locked drive was not asked to be unlocked: " + offline.actionMessage)
    offline.applyVolumes(snapshot([archive]))
    offline.activateIndex(1)
    check(offline.volumeActions.join(",") === "mount:/dev/sdb1:stay"
        && offline.actionMessage === "Mounting “ARCHIVE”…",
      "A connected drive was not mounted in place: " + offline.volumeActions
        + " / " + offline.actionMessage)
    offline.applyVolumes(snapshot([Object.assign({}, archive, { canMount: false })]))
    offline.activateIndex(1)
    check(offline.actionMessage === "Mount “ARCHIVE” to open beach.jpg"
        && offline.volumeActions.length === 1,
      "A drive that cannot be mounted was not named: " + offline.actionMessage)
    noProcessFor("Opening a connected but unmounted drive's row")

    // A drive that turns up later is never mounted by the hint.
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    offline.activateIndex(1)
    offline.applyVolumes(snapshot([archive]))
    check(offline.volumeActions.length === 1,
      "A drive plugged in after the hint was mounted by QuickFile")
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))

    // Every other action leaves an offline row alone and says where it is.
    offline.selectIndex(1)
    offline.actionMessage = ""
    check(!offline.copySelected() && offline.clipboardToken === ""
        && offline.actionMessage === "Connect “ARCHIVE” to open beach.jpg",
      "Copying an offline row put it on the clipboard: " + offline.actionMessage)
    check(!offline.cutSelected() && offline.clipboardToken === "", "Cutting an offline row worked")
    check(offline.effectiveSelectionTokens().length === 0,
      "An offline row reached the selection actions")
    check(!offline.trashSelected(), "Trashing an offline row started")
    check(!offline.duplicateSelected(), "Duplicating an offline row started")
    check(!offline.renameSelected("renamed.jpg"), "Renaming an offline row started")
    check(!offline.loadPreview(photo) && offline.previewToken === "",
      "Previewing an offline row started")
    check(!offline.openPreviewExternally(photo), "Opening an offline row in Sushi started")
    check(!offline.toggleFavoriteEntry(photo), "Starring an offline row started")
    check(!offline.saveEntryMetadata(photo, "blue", "note", false),
      "Saving a note on an offline row started")
    check(!offline.saveEntryKnowledge(photo, true, ["codex"]),
      "Registering an offline row as knowledge started")
    check(!offline.previewSelectedKnowledgeLinks(), "Linking an offline row started")
    check(!offline.measureFolder(folder.token), "Measuring an offline folder started")
    check(!offline.runAction("copy-path", photo.token), "Copying an offline path started")
    check(!offline.runAction("open", photo.token), "Opening an offline row by token started")
    check(!offline.startOperationRequest({ kind: "copy", tokens: [photo.token],
      destinationToken: offline.rootToken }), "Copying an offline row by token started")
    check(!offline.dropOnDirectory(folder.token, ["live-report"], false),
      "A drop into an offline folder started")
    check(!offline.navigate(folder.path, folder.token, true) && offline.entries.length === 3,
      "Navigating into an offline folder cleared the search")
    noProcessFor("The offline action guards")
    check(offline.volumeActions.length === 1, "An offline action mounted a drive")

    // A mixed selection acts on what is here and says what it left out.
    offline.selectedTokens = ["live-report", photo.token]
    check(offline.copySelected() && offline.clipboardTokens.join(",") === "live-report"
        && offline.actionMessage === "Copied “beach-report.txt” · 1 offline item left out",
      "A mixed selection was not copied without its offline row: " + offline.actionMessage)
    check(offline.trashSelected() && offline.operations.join("|") === "trash:live-report"
        && offline.pendingOperation.offlineNote === " · 1 offline item left out",
      "A mixed trash did not say what it left out: " + offline.operations)
    check(offline.duplicateSelected()
        && offline.operations.join("|") === "trash:live-report|duplicate:live-report"
        && offline.pendingOperation.offlineNote === " · 1 offline item left out",
      "A mixed duplicate did not say what it left out: " + offline.operations)
    offline.pendingOperation = null
    offline.clearClipboard()
    offline.selectedTokens = [photo.token]

    // Unplugging a mounted drive: its live row goes back to its catalog form,
    // the selection and the delegate follow it.
    offline.lastOfflineRequest = null
    var livePhoto = liveCatalogRow(photo)
    applyCatalog([report, livePhoto, folder])
    var photoDelegate = offlineRows.itemAt(1)
    offline.selectIndex(1)
    offline.selectedTokens = ["live-report", livePhoto.token]
    offline.inspections = []
    createdBefore = createdOfflineDelegates
    var destroyedBefore = destroyedOfflineDelegates
    applyCatalog([report, photo, folder])
    check(offline.selectedToken === photo.token && offline.selectedEntry.available === false
        && offline.selectedTokens.join(",") === "live-report," + photo.token,
      "Unplugging the drive dropped the selection of its row: " + offline.selectedToken)
    check(offline.selectionAnchorIndex === 1, "Unplugging the drive lost the range anchor")
    check(offlineRows.count === 3 && offlineRows.itemAt(1) === photoDelegate
        && createdOfflineDelegates === createdBefore
        && destroyedOfflineDelegates === destroyedBefore,
      "Unplugging the drive rebuilt the row's delegate")
    check(offline.selectedProperties.offline === true && offline.inspections.length === 0,
      "The unplugged row kept its live properties or asked the backend")
    check(offline.revealed.length === 0, "A row nobody asked for was revealed")

    // Plugging it back in after Enter: the row comes alive in place, is
    // selected and announced, and nothing opens.
    offline.activateIndex(1)
    check(offline.lastOfflineRequest !== null, "Enter did not remember the row")
    applyCatalog([report, livePhoto, folder])
    check(offline.selectedToken === livePhoto.token && offline.selectedEntry.available === true
        && offline.selectedTokens.join(",") === livePhoto.token,
      "The row that came alive was not selected: " + offline.selectedToken)
    check(offline.revealed.join(",") === livePhoto.token,
      "The row that came alive was not revealed: " + offline.revealed)
    check(offline.actionMessage === "“ARCHIVE” connected · beach.jpg is ready",
      "The row that came alive was not announced: " + offline.actionMessage)
    check(offline.lastOfflineRequest === null, "The reveal did not consume the request")
    check(offlineRows.itemAt(1) === photoDelegate && offlineRows.count === 3,
      "The row that came alive rebuilt its delegate")
    check(offline.inspections.join(",") === livePhoto.token,
      "The live row was not inspected for real: " + offline.inspections)
    check(!offline.actionBusy && offline.rootToken === "offline-root"
        && !offline.listingIsNewResults, "The reveal opened, navigated or reset the view")
    applyCatalog([report, livePhoto, folder])
    check(offline.revealed.length === 1, "A refresh revealed the row a second time")

    // A drive mounted inside the searched folder: the walk lists the file
    // itself, without a catalog token, and the reveal finds it by path.
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    applyCatalog([report, photo, folder])
    offline.revealed = []
    offline.activateIndex(1)
    var walked = { token: "walk-photo", name: "beach.jpg", isDir: false,
      path: "/run/media/test/ARCHIVE/" + photo.relativePath,
      relativePath: "ARCHIVE/" + photo.relativePath, matchKind: "name" }
    offline.applyVolumes(snapshot([Object.assign({}, archive, { mounted: true,
      mountPath: "/run/media/test/ARCHIVE/", mountToken: "mount-archive", canUnmount: true })]))
    applyCatalog([report, walked, folder])
    check(offline.revealed.join(",") === "walk-photo" && offline.selectedToken === "walk-photo"
        && offline.actionMessage === "“ARCHIVE” connected · beach.jpg is ready",
      "A row the walk lists itself was not revealed: " + offline.revealed + " / "
        + offline.actionMessage)
    check(offline.lastOfflineRequest === null, "The walked reveal did not consume the request")

    // The walk's row and the catalog's are one file: unplugging the drive
    // hands the selection to the catalog row, mounting it hands it back.
    var mountedArchive = Object.assign({}, archive, { mounted: true,
      mountPath: "/run/media/test/ARCHIVE/", mountToken: "mount-archive", canUnmount: true })
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    applyCatalog([report, photo, folder])
    check(offline.selectedToken === photo.token && offline.selectedTokens.join(",") === photo.token
        && offline.selectionAnchorIndex === 1
        && offline.listingTokenMoves["walk-photo"] === photo.token,
      "Unplugging a drive the walk listed dropped the selection: " + offline.selectedToken)
    offline.applyVolumes(snapshot([mountedArchive]))
    applyCatalog([report, walked, folder])
    check(offline.selectedToken === "walk-photo"
        && offline.selectedTokens.join(",") === "walk-photo"
        && offline.revealed.join(",") === "walk-photo",
      "Mounting the drive back did not hand the selection to the walk's row: "
        + offline.selectedToken + " / " + offline.revealed)

    // A key on a row whose drive has just mounted: "Finding…" until the
    // search brings the row alive, then the reveal says it is ready.
    var mountedElsewhere = Object.assign({}, archive, { mounted: true,
      mountPath: "/run/media/test/ARCHIVE", mountToken: "mount-archive", canUnmount: true })
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    applyCatalog([report, photo, folder])
    offline.selectIndex(1)
    offline.applyVolumes(snapshot([mountedElsewhere]))
    check(offline.offlineHint(offline.selectedEntry)
        && offline.actionMessage === "Finding beach.jpg on “ARCHIVE”…"
        && offline.lastOfflineRequest !== null,
      "A row whose drive mounted did not wait for the search: " + offline.actionMessage)
    applyCatalog([report, liveCatalogRow(photo), folder])
    check(offline.actionMessage === "“ARCHIVE” connected · beach.jpg is ready"
        && offline.lastOfflineRequest === null,
      "\"Finding…\" outlived the row it was finding: " + offline.actionMessage)

    // A sheet open on another row holds the selection still: the row that
    // came alive waits for it to close, then takes the cursor.
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    applyCatalog([report, photo, folder])
    offline.activateIndex(1)
    offline.selectIndex(0)
    offline.revealed = []
    offline.selectionHeld = true
    offline.applyVolumes(snapshot([mountedElsewhere]))
    applyCatalog([report, liveCatalogRow(photo), folder])
    check(offline.selectedToken === "live-report"
        && offline.selectedTokens.join(",") === "live-report" && offline.revealed.length === 0 && offline.lastOfflineRequest !== null,
      "A reveal moved the selection from under an open sheet: " + offline.selectedToken)
    offline.selectionHeld = false
    offline.revealRequestedEntry()
    check(offline.selectedToken === "real-beach.jpg"
        && offline.revealed.join(",") === "real-beach.jpg",
      "The held reveal did not happen once the sheet closed: " + offline.selectedToken)

    // A new question forgets the row asked for.
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    applyCatalog([report, photo, folder])
    offline.activateIndex(1)
    offline.setSearch("beach trip", "fuzzy")
    check(offline.lastOfflineRequest === null, "Changing the query kept the old request")
    offline.setSearch("beach", "fuzzy")

    // Drive changes refresh a search on screen, and only a search.
    var refreshes = offline.searchRefreshes
    offline.applyVolumes(snapshot([archive]))
    check(offline.searchRefreshes === refreshes + 1,
      "A drive arriving under a search did not refresh it")
    offline.applyVolumes(snapshot([archive]))
    check(offline.searchRefreshes === refreshes + 1, "An unchanged drive list refreshed the search")
    offline.query = ""
    offline.applyVolumes(snapshot([Object.assign({}, archive, { mounted: true,
      mountPath: "/run/media/test/ARCHIVE", canUnmount: true })]))
    check(offline.searchRefreshes === refreshes + 1,
      "Mounting a drive refreshed a folder listing as if it were a search")
    offline.query = "beach"
    offline.catalogIndexVolumeId = "uuid:A1"
    offline.catalogIndexName = "ARCHIVE"
    offline.catalogIndexResult = { ok: true, event: "result",
      volume: { name: "ARCHIVE", files: 12, state: "complete" } }
    offline.finishCatalogIndex(0)
    check(offline.searchRefreshes === refreshes + 2,
      "A fresh catalog did not refresh the search on screen")

    // Forgetting a drive's catalog takes its rows off the search on screen.
    offline.applyVolumes(snapshot([offlineDrive("uuid:A1", "ARCHIVE", 1790848800)]))
    applyCatalog([report, photo, folder])
    offline.activateIndex(1)
    var refreshesBeforeForget = offline.searchRefreshes
    offline.catalogForgetVolumeId = "uuid:A1"
    offline.catalogForgetStdout = JSON.stringify({ ok: true, message: "Forgot ARCHIVE" })
    offline.finishCatalogForget(0)
    check(offline.searchRefreshes === refreshesBeforeForget + 1
        && offline.lastOfflineRequest === null,
      "Forgetting a drive left its rows and its request on screen")

    // A folder listing has no catalog to report.
    offline.query = ""
    offline.listInFlightCommand = JSON.stringify(offline.buildListCommand())
    offline.listInFlightBackground = true
    check(offline.applyListing(JSON.stringify({ ok: true, root: { token: offline.rootToken,
      path: offline.rootPath }, entries: [report], favorites: [],
      git: { root: "", branch: "" } })), "A folder listing was rejected")
    check(offline.catalogResult === null && offline.offlineMatchCount === 0,
      "A folder listing kept the last search's catalog tally")
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
          live.semanticSessionActive = true
          live.setPanelVisible(false)
          suite.check(!live.semanticSessionActive,
            "Closing the panel did not end the model session")
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
