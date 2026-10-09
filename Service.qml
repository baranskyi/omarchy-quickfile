import QtQuick
import QtQml.Models
import Quickshell
import Quickshell.Io

// One shared data owner for every panel and bar instance. Filesystem work is
// deliberately kept outside the shell process: this object only schedules the
// bundled CLI and publishes bounded JSON models.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginDir: Qt.resolvedUrl(".").toString()
    .replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cliPath: pluginDir + "/bin/quickfile"
  readonly property string semanticCliPath: pluginDir + "/bin/quickfile-semantic"
  readonly property string homePath: Quickshell.env("HOME") || "/"
  // Only used if native monitoring is unavailable or its watch limit is hit.
  readonly property int fallbackRefreshInterval: 30000

  property bool initialized: false
  property bool panelVisible: false
  property bool busy: listingProcess.running
  // Process.running becomes false just before its exit handler applies stdout.
  // Keep an explicit foreground latch so the UI cannot render a false empty
  // state in that one-frame gap.
  property bool foregroundListingPending: false
  readonly property bool foregroundBusy: foregroundListingPending
    || (busy && !listInFlightBackground)
  property bool knowledgeBusy: knowledgeProcess.running
  property bool sessionsBusy: sessionsProcess.running
  property bool settingsBusy: settingsLoadProcess.running || settingsSaveProcess.running
  property bool volumesBusy: volumesProcess.running || volumeActionProcess.running
  property bool operationBusy: operationProcess.running
  property bool actionBusy: actionProcess.running || operationBusy || knowledgeLinksProcess.running
    || volumeActionProcess.running
  property string errorMessage: ""
  property string actionMessage: ""
  property string operationPhase: ""
  property real operationProgress: -1
  property int operationItemsDone: 0
  property int operationItemsTotal: 0
  property real operationBytesDone: 0
  property real operationBytesTotal: 0
  property bool operationCancelling: false
  property var operationResult: null
  property var trashEntries: []
  property bool trashBusy: trashProcess.running
  property string trashError: ""
  property bool trashReloadPending: false
  property bool undoAvailable: false
  property string undoId: ""
  property string undoLabel: ""
  property bool historyReloadPending: false
  property var quickNavEntries: []
  property bool quickNavBusy: quickNavProcess.running || quickNavRecordProcess.running
  readonly property bool quickNavLoading: quickNavBusy
  property string quickNavError: ""
  property bool quickNavReloadPending: false
  property string quickNavStdout: ""
  property string quickNavStderr: ""
  property bool quickNavRecordPending: false
  property string quickNavRecordToken: ""
  property string quickNavRecordPath: ""
  property bool recordNavigationOnListing: false
  property var previewData: null
  property bool previewBusy: previewProcess.running
  readonly property bool previewLoading: previewBusy
  property string previewError: ""
  property string previewToken: ""
  property string previewInFlightToken: ""
  property string previewPendingToken: ""
  property int previewRevision: 0
  property int previewInFlightRevision: 0
  property string previewStdout: ""
  property string previewStderr: ""
  property var pendingOperation: null
  property var operationConflicts: []

  property string rootPath: homePath
  property string rootToken: ""
  property string parentPath: "/"
  property string parentToken: ""
  property var entries: []
  property var favorites: []
  property bool favoritesCollapsed: false
  property var volumes: []
  property bool volumesCollapsed: false
  property string volumesError: ""
  property bool volumesReloadPending: false
  property var knowledgeFiles: []
  property bool knowledgeCollapsed: false
  property int knowledgeTotalTokens: 0
  property int knowledgeMaxTokens: 0
  property bool knowledgeTruncated: false
  property string knowledgeRootToken: ""
  property string knowledgeError: ""
  property bool knowledgeReloadPending: false
  property var knowledgeLinkPlan: null
  property string knowledgeLinkError: ""
  property bool knowledgeLinkApplying: false
  readonly property var moduleIds: ["sessions", "devices", "favorites", "knowledge"]
  property var moduleLayout: defaultModuleLayout()
  property bool settingsLoaded: false
  property string settingsError: ""
  property bool settingsSaveQueued: false
  property bool activeSessionsEnabled: false
  property string inspectorTab: "properties"
  property var activeSessions: []
  property bool sessionsCollapsed: false
  property bool sessionsReloadPending: false
  property string sessionsError: ""
  property string sessionsStdout: ""
  property string sessionsStderr: ""
  property string sessionsInFlightRootToken: ""
  property string sessionsInFlightRootPath: ""
  property string settingsStdout: ""
  property string settingsStderr: ""
  property var selectedEntry: null
  property var selectedProperties: null
  property string selectedToken: ""
  property var selectedTokens: []
  property int selectionAnchorIndex: -1
  property string clipboardMode: ""
  property string clipboardToken: ""
  property var clipboardTokens: []
  property string clipboardName: ""
  property var expandedTokens: []
  property bool showHidden: false
  // Listing order, persisted with the other panel preferences. Search results
  // keep their relevance ranking, so this only shapes the folder tree.
  readonly property var sortOrders: ["name", "name-desc", "modified",
    "modified-asc", "size", "type"]
  property string sortOrder: "name"
  // How Panel renders a row's timestamp. Presentation only — unlike sortOrder
  // this never re-runs the listing.
  readonly property var dateFormats: ["full", "adaptive", "smart", "relative", "off"]
  property string dateFormat: "full"

  // Recursive size of the inspected folder. `st_size` on a directory is the
  // size of its index, not of what it holds, so the real number has to be
  // walked for — and a deep tree takes long enough that the walk reports as
  // it goes and can be stopped.
  property string folderSizeToken: ""
  property bool folderSizeBusy: folderSizeProcess.running
  property bool folderSizeCancelling: false
  property double folderSizeBytes: 0
  property double folderSizeAllocated: 0
  property int folderSizeFiles: 0
  property int folderSizeDirectories: 0
  property string folderSizePath: ""
  property var folderSizeResult: null
  property string folderSizeError: ""
  property double folderSizeStarted: 0

  // Offline catalog of an external drive: names, paths, sizes and dates,
  // walked once so a search can say which drive to plug in. One walk at a
  // time, reported and cancellable like the folder walk, and kept out of
  // actionBusy so a slow USB disk never blocks browsing or file operations.
  // catalogIndexVolumeId is set from the request until the exit handler has
  // run; the process's own running flag drops just before that handler.
  property string catalogIndexDevice: ""
  property string catalogIndexVolumeId: ""
  property string catalogIndexName: ""
  property bool catalogIndexAutomatic: false
  readonly property bool catalogIndexBusy: catalogIndexProcess.running
  property bool catalogIndexCancelling: false
  readonly property bool catalogIndexKillPending: catalogIndexKillTimer.running
  property string catalogIndexPhase: ""
  property double catalogIndexFiles: 0
  property double catalogIndexDirectories: 0
  property double catalogIndexBytes: 0
  property string catalogIndexError: ""
  property var catalogIndexResult: null
  property string catalogIndexStderr: ""
  // An unmount asked for mid-walk waits for the walk to let go of the mount;
  // udisksctl would otherwise fail with "target is busy".
  property string unmountAfterIndexDevice: ""
  // Known drives re-index when they are mounted again, one at a time. A drive
  // whose automatic run the user stopped is left alone for the session.
  readonly property int catalogAutoRefreshMinAge: 60
  property var autoIndexQueue: []
  property var autoIndexSkipped: ({})
  // The first drive snapshot is only a baseline: drives already mounted when
  // QuickFile starts were not just plugged in.
  property bool volumesSnapshotReady: false
  property int catalogVolumeCount: 0
  property int offlineVolumeCount: 0
  property string catalogForgetVolumeId: ""
  readonly property bool catalogForgetBusy: catalogForgetProcess.running
  property string catalogForgetStdout: ""
  property string catalogForgetStderr: ""
  // Every search also lists matches from the catalogs of drives that are
  // away, after the live rows. One switch turns them off; DEVICES keeps its
  // offline drives either way.
  property bool offlineSearchEnabled: true
  property var catalogResult: null
  // Search rows on drives that are away, not the drives (offlineVolumeCount).
  property int offlineMatchCount: 0
  // The offline row the user last tried to open. When its drive arrives the
  // row is selected and announced, never opened: a drive that turns up later
  // is the desktop's to mount.
  property var lastOfflineRequest: null
  readonly property bool selectedOffline: isOfflineEntry(selectedEntry)
    || isCatalogToken(selectedToken)
  // The presence of every catalogued drive, so a plug, unplug, mount or
  // unlock refreshes the offline rows of a search that is on screen.
  property string catalogPresenceKey: ""
  // Where each catalogued drive was last mounted: a row the walk listed on
  // it is still known for the same file once the drive is gone.
  property var catalogMountPaths: ({})
  // The panel holds the selection still while a sheet is open or a draft is
  // unsaved; the reveal of an offline row waits for it to let go.
  property bool selectionHeld: false
  // Old token → new token for the rows the last listing gave a new token,
  // for the panel's keyboard cursor to follow them.
  property var listingTokenMoves: ({})
  // The full search whose catalog rows are on screen, and the drives it saw:
  // a refresh for a file event asks the walk alone while both still hold.
  property string catalogRowsCommand: ""
  property string catalogRowsPresence: ""
  property bool listInFlightReusesCatalog: false
  property bool reloadPendingCatalog: false
  // A message the user's own action asked for: the footer shows it over the
  // standing clipboard line until anything newer is said or copied.
  property bool actionNoticeFresh: false
  property string query: ""
  // Plain-language search is the default; without its optional model it
  // still ranks the typed keywords, and a one-time tip offers the model.
  property string searchMode: "smart"
  property bool smartOnboardingDone: false
  property bool caseSensitive: false
  property bool truncated: false
  property string searchEngine: ""
  property bool semanticStatusLoaded: false
  property bool semanticInstalled: false
  property string semanticState: "checking"
  property string semanticError: ""
  property string semanticPythonPath: ""
  property string semanticModel: "laya-multilingual"
  property string semanticDevice: ""
  property real semanticProgress: 0
  property string semanticProgressPhase: ""
  property bool semanticHelperReady: false
  property bool semanticHelperFailed: false
  property bool semanticFallback: false
  property var semanticPlan: null
  property var semanticResult: null
  property string semanticPlanQuery: ""
  property int semanticRequestId: 0
  property int semanticPendingId: 0
  property string semanticPendingQuery: ""
  property string semanticStatusStdout: ""
  property string semanticStatusStderr: ""
  property string semanticHelperStderr: ""
  property string semanticSetupStderr: ""
  property string semanticSetupAction: ""
  readonly property bool semanticSetupBusy: semanticSetupProcess.running
  readonly property bool smartOnboardingDue: settingsLoaded && semanticStatusLoaded
    && !smartOnboardingDone && !semanticInstalled && !semanticSetupBusy
    && semanticState === "not-installed"
  // Set by the first non-empty SMART query and kept until the mode changes or
  // the panel closes, so clearing the field does not unload a warm model.
  property bool semanticSessionActive: false
  readonly property bool semanticShouldRun: panelVisible && searchMode === "smart"
    && semanticSessionActive && semanticInstalled
    && !semanticHelperFailed && !semanticSetupBusy
  property var git: ({ root: "", branch: "" })

  // Keep QML delegates alive. The arrays above remain the service's snapshots;
  // views consume these models and receive only insert/remove/move/data changes.
  property alias entriesModel: fileRows
  property alias favoritesModel: favoriteRows
  property alias knowledgeModel: knowledgeRows
  property alias sessionsModel: sessionRows
  property alias volumesModel: volumeRows
  property alias quickNavModel: quickNavRows
  ListModel { id: fileRows; dynamicRoles: true }
  ListModel { id: favoriteRows; dynamicRoles: true }
  ListModel { id: knowledgeRows; dynamicRoles: true }
  ListModel { id: sessionRows; dynamicRoles: true }
  ListModel { id: volumeRows; dynamicRoles: true }
  ListModel { id: quickNavRows; dynamicRoles: true }

  property var listWatch: null
  property var knowledgeWatch: null
  property string watchConfiguration: ""
  property bool watcherReady: false
  property bool watcherFailed: false
  property bool watcherStopping: false
  readonly property var watcherPid: watchProcess.processId
  property bool watcherDegraded: false
  property bool watchTruncated: false
  property string watchError: ""
  property int listingRequests: 0
  property int listingChanges: 0
  property int metadataRevision: 0
  property int listInFlightRevision: 0
  property int knowledgeInFlightRevision: 0
  property int propertyInFlightRevision: 0

  property var backStack: []
  property var forwardStack: []
  property bool reloadPending: false
  property bool reloadPendingForeground: false
  property bool listInFlightBackground: false
  property string listInFlightCommand: ""
  // The command whose rows are on screen. A foreground search answered by a
  // different command is a new result set, not a refresh of the old one: a
  // new query, or the same SMART query once its analysis arrives. The panel
  // shows such a set from its top instead of holding the old top row in place.
  property string appliedListingCommand: ""
  property bool listingIsNewResults: false
  property string listInFlightRootToken: ""
  property string listInFlightRootPath: ""
  property double navigationBlockedUntil: 0
  property string listStdout: ""
  property string listStderr: ""
  property string propertyStdout: ""
  property string propertyStderr: ""
  property string actionStdout: ""
  property string actionStderr: ""
  property string operationStderr: ""
  property string trashStdout: ""
  property string trashStderr: ""
  property string historyStdout: ""
  property string historyStderr: ""
  property string volumesStdout: ""
  property string volumesStderr: ""
  property string volumeActionStdout: ""
  property string volumeActionStderr: ""
  property string volumeActionKind: ""
  property string volumeActionDevice: ""
  property string volumeActionMountPath: ""
  // A mount asked for by an offline row keeps the search on screen.
  property bool volumeActionNavigate: true
  property string knowledgeStdout: ""
  property string knowledgeStderr: ""
  property string knowledgeLinkStdout: ""
  property string knowledgeLinkStderr: ""
  property string propertyInFlightToken: ""
  property string propertyPendingToken: ""
  property string actionKind: ""
  property string actionMetadataToken: ""

  signal listingAboutToChange()
  signal modelChanged()
  signal navigationAboutToChange(string path, string token)
  signal metadataSaved(string token, var values)
  signal actionFinished(string kind, bool ok, string message)
  signal knowledgeLinksFinished(bool ok, bool applied, string message)
  signal conflictRequested(var conflicts)
  // The offline row the user asked for has come alive under this token.
  signal revealRequested(string token)

  onActionMessageChanged: actionNoticeFresh = false
  onClipboardTokenChanged: actionNoticeFresh = false
  onSelectionHeldChanged: if (!selectionHeld) Qt.callLater(root.revealRequestedEntry)

  function announce(text) {
    actionMessage = String(text || "")
    actionNoticeFresh = actionMessage !== ""
  }

  function setPanelVisible(value) {
    if (panelVisible === (value === true)) return
    // Preserve why the old process is exiting if the panel reopens before
    // SIGTERM completes; its exit must not disable the replacement watcher.
    if (value !== true && watchProcess.running) watcherStopping = true
    panelVisible = value === true
    if (panelVisible) {
      watcherFailed = false
      ensureLoaded()
    } else {
      watcherReady = false
      eventRefresh.stop()
      semanticInferenceTimeout.stop()
      semanticSessionActive = false
    }
  }

  onSearchModeChanged: if (searchMode !== "smart") semanticSessionActive = false

  function ensureLoaded() {
    if (!settingsLoaded && !settingsLoadProcess.running) reloadSettings()
    if (!semanticStatusLoaded && !semanticStatusProcess.running) reloadSemanticStatus()
    if (!initialized) {
      initialized = true
      recordNavigationOnListing = true
      reload()
      reloadVolumes()
      reloadHistory()
      reloadQuickNav()
    } else {
      // Reconcile changes that happened while the panel (and watcher) was shut.
      reload(true)
      reloadKnowledge()
      reloadVolumes()
      reloadHistory()
      reloadQuickNav()
    }
    if (settingsLoaded && activeSessionsEnabled) reloadSessions()
  }

  function sameData(left, right) {
    return JSON.stringify(left) === JSON.stringify(right)
  }

  function defaultModuleLayout() {
    return [
      { id: "sessions", pinned: true, collapsed: false },
      { id: "devices", pinned: false, collapsed: false },
      { id: "favorites", pinned: false, collapsed: false },
      { id: "knowledge", pinned: true, collapsed: false }
    ]
  }

  function normalizedModuleLayout(value) {
    var source = Array.isArray(value) ? value : []
    var result = []
    var seen = ({})
    for (var i = 0; i < source.length; i++) {
      var row = source[i] || ({})
      var id = String(row.id || "")
      if (moduleIds.indexOf(id) < 0 || seen[id]) continue
      result.push({ id: id, pinned: row.pinned === true, collapsed: row.collapsed === true })
      seen[id] = true
    }
    var defaults = defaultModuleLayout()
    for (var j = 0; j < defaults.length; j++)
      if (!seen[defaults[j].id]) result.push(defaults[j])
    return result
  }

  function moduleState(moduleId) {
    var id = String(moduleId || "")
    for (var i = 0; i < moduleLayout.length; i++)
      if (String(moduleLayout[i].id || "") === id) return moduleLayout[i]
    return { id: id, pinned: false, collapsed: false }
  }

  function moduleIndex(moduleId) {
    var id = String(moduleId || "")
    for (var i = 0; i < moduleLayout.length; i++)
      if (String(moduleLayout[i].id || "") === id) return i
    return -1
  }

  function applyModuleCollapseFlags() {
    sessionsCollapsed = moduleState("sessions").collapsed === true
    volumesCollapsed = moduleState("devices").collapsed === true
    favoritesCollapsed = moduleState("favorites").collapsed === true
    knowledgeCollapsed = moduleState("knowledge").collapsed === true
  }

  function updateModule(moduleId, changes) {
    var index = moduleIndex(moduleId)
    if (index < 0 || !settingsLoaded) return false
    var next = moduleLayout.slice()
    next[index] = Object.assign({}, next[index], changes || ({}))
    moduleLayout = normalizedModuleLayout(next)
    applyModuleCollapseFlags()
    persistSettings()
    return true
  }

  function setModuleCollapsed(moduleId, collapsed) {
    return updateModule(moduleId, { collapsed: collapsed === true })
  }

  function toggleModuleCollapsed(moduleId) {
    var state = moduleState(moduleId)
    return setModuleCollapsed(moduleId, state.collapsed !== true)
  }

  function setModulePinned(moduleId, pinned) {
    return updateModule(moduleId, { pinned: pinned === true })
  }

  function moveModule(moduleId, offset) {
    var index = moduleIndex(moduleId)
    var target = index + Number(offset || 0)
    if (index < 0 || target < 0 || target >= moduleLayout.length || !settingsLoaded)
      return false
    var next = moduleLayout.slice()
    var moving = next.splice(index, 1)[0]
    next.splice(target, 0, moving)
    moduleLayout = normalizedModuleLayout(next)
    applyModuleCollapseFlags()
    persistSettings()
    return true
  }

  function setInspectorTab(tab) {
    var value = String(tab || "")
    if (!settingsLoaded || ["properties", "notes", "git"].indexOf(value) < 0
        || inspectorTab === value) return false
    inspectorTab = value
    persistSettings()
    return true
  }

  function setSortOrder(order) {
    var value = String(order || "")
    if (sortOrders.indexOf(value) < 0 || sortOrder === value) return false
    sortOrder = value
    if (settingsLoaded) persistSettings()
    reload()
    return true
  }

  function cycleSortOrder(step) {
    var delta = Number(step) || 1
    var index = sortOrders.indexOf(sortOrder)
    if (index < 0) index = 0
    var count = sortOrders.length
    return setSortOrder(sortOrders[((index + delta) % count + count) % count])
  }

  function setDateFormat(format) {
    var value = String(format || "")
    if (dateFormats.indexOf(value) < 0 || dateFormat === value) return false
    dateFormat = value
    if (settingsLoaded) persistSettings()
    return true
  }

  function cycleDateFormat(step) {
    var delta = Number(step) || 1
    var index = dateFormats.indexOf(dateFormat)
    if (index < 0) index = 0
    var count = dateFormats.length
    return setDateFormat(dateFormats[((index + delta) % count + count) % count])
  }

  // Drive rows carry an id that survives unplug, replug and unlock, so one
  // delegate follows the drive instead of whichever /dev node it got. A
  // search row from a drive catalog is keyed the same way: its token turns
  // real when the drive is plugged in, its catalog token stays.
  function rowKey(row) {
    return String(row.catalogToken || row.token || row.id || row.device
      || row.sessionKey || "")
  }

  function reconcileRows(model, previous, next) {
    var keys = previous.map(rowKey)
    var wanted = ({})
    var previousByKey = ({})
    for (var i = 0; i < previous.length; i++) previousByKey[rowKey(previous[i])] = previous[i]
    for (var j = 0; j < next.length; j++) wanted[rowKey(next[j])] = true
    for (var k = keys.length - 1; k >= 0; k--) {
      if (!wanted[keys[k]]) {
        model.remove(k)
        keys.splice(k, 1)
      }
    }
    for (var n = 0; n < next.length; n++) {
      var key = rowKey(next[n])
      var index = keys.indexOf(key, n)
      if (index < 0) {
        model.insert(n, { rowData: next[n], scope: String(next[n].scope || "") })
        keys.splice(n, 0, key)
      } else {
        if (index !== n) {
          model.move(index, n, 1)
          keys.splice(index, 1)
          keys.splice(n, 0, key)
        }
        if (!sameData(previousByKey[key], next[n]))
          model.set(n, { rowData: next[n], scope: String(next[n].scope || "") })
      }
    }
  }

  function quickNavRowKey(row) {
    return String(row.token || row.path || row.uri || row.name || "")
  }

  function reconcileQuickNav(previous, next) {
    var keys = previous.map(quickNavRowKey)
    var wanted = ({})
    var previousByKey = ({})
    for (var i = 0; i < previous.length; i++)
      previousByKey[quickNavRowKey(previous[i])] = previous[i]
    for (var j = 0; j < next.length; j++) wanted[quickNavRowKey(next[j])] = true
    for (var k = keys.length - 1; k >= 0; k--) {
      if (!wanted[keys[k]]) {
        quickNavRows.remove(k)
        keys.splice(k, 1)
      }
    }
    for (var n = 0; n < next.length; n++) {
      var key = quickNavRowKey(next[n])
      var index = keys.indexOf(key, n)
      if (index < 0) {
        quickNavRows.insert(n, { rowData: next[n] })
        keys.splice(n, 0, key)
      } else {
        if (index !== n) {
          quickNavRows.move(index, n, 1)
          keys.splice(index, 1)
          keys.splice(n, 0, key)
        }
        if (!sameData(previousByKey[key], next[n]))
          quickNavRows.set(n, { rowData: next[n] })
      }
    }
  }

  function syncWatchConfiguration() {
    var directories = []
    var files = []
    var watches = [listWatch, knowledgeWatch]
    watchTruncated = false
    for (var i = 0; i < watches.length; i++) {
      var watch = watches[i]
      if (!watch) continue
      watchTruncated = watchTruncated || watch.truncated === true
      directories = directories.concat(watch.directories || [])
      files = files.concat(watch.files || [])
    }
    function unique(values) {
      return values.filter(function(value, index) { return values.indexOf(value) === index }).sort()
    }
    directories = unique(directories)
    files = unique(files)
    if (directories.length + files.length > 4096) {
      watchTruncated = true
      // Keep native coverage for part of an oversized search, with the normal
      // silent fallback covering the rest instead of rejecting every watch.
      files = files.slice(0, 4096)
      directories = directories.slice(0, 4096 - files.length)
    }
    var configuration = JSON.stringify({ directories: directories, files: files })
    if (configuration === watchConfiguration) return
    watchConfiguration = configuration
    if (watchProcess.running && !watcherStopping) sendWatchConfiguration()
  }

  function sendWatchConfiguration() {
    watcherReady = false
    watcherDegraded = false
    watchError = ""
    watchProcess.write((watchConfiguration || '{"directories":[],"files":[]}') + "\n")
    watchStartupTimeout.restart()
  }

  function scheduleBackgroundRefresh() {
    // Do not restart this timer: continuous writes still get bounded latency.
    if (panelVisible && initialized && !operationBusy && !eventRefresh.running)
      eventRefresh.start()
  }

  function handleWatchEvent(raw) {
    if (watcherStopping || !panelVisible) return
    var message = null
    try { message = JSON.parse(raw) } catch (error) { return }
    if (message.event === "ready") {
      watcherReady = true
      watchStartupTimeout.stop()
      // Close the initial-listing / installing-watches race, silently.
      scheduleBackgroundRefresh()
    } else if (message.event === "changed") {
      scheduleBackgroundRefresh()
    } else if (message.event === "volumes") {
      if (panelVisible) reloadVolumes()
    } else if (message.event === "error") {
      watcherDegraded = true
      watchError = String(message.error || "Native file monitoring unavailable")
      console.warn("QuickFile watch:", watchError)
    }
  }

  function rootArgument(command) {
    if (rootToken !== "") {
      command.push("--path-token")
      command.push(rootToken)
    } else {
      command.push("--path")
      command.push(rootPath)
    }
  }

  function reloadSemanticStatus() {
    if (semanticStatusProcess.running || semanticSetupProcess.running) return false
    semanticStatusStdout = ""
    semanticStatusStderr = ""
    semanticStatusProcess.command = ["/usr/bin/python3", semanticCliPath, "status"]
    semanticStatusProcess.running = true
    return true
  }

  function applySemanticStatus(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      semanticState = "failed"
      semanticError = "Smart-search status returned invalid data"
      return false
    }
    if (!parsed || parsed.ok !== true) {
      semanticState = "failed"
      semanticError = parsed && parsed.message ? String(parsed.message)
        : "Could not check smart-search status"
      return false
    }
    semanticStatusLoaded = true
    semanticInstalled = parsed.installed === true
    semanticPythonPath = semanticInstalled ? String(parsed.pythonPath || "") : ""
    semanticModel = String(parsed.model || "laya-multilingual")
    semanticState = semanticInstalled ? "installed" : String(parsed.state || "not-installed")
    semanticError = ""
    semanticProgress = semanticInstalled ? 1 : 0
    semanticProgressPhase = ""
    semanticHelperFailed = false
    return true
  }

  function installSemantic() {
    if (semanticSetupProcess.running) return false
    semanticSetupAction = "install"
    semanticSetupStderr = ""
    semanticError = ""
    semanticState = "installing"
    semanticProgress = 0
    semanticProgressPhase = "starting"
    semanticSetupProcess.command = ["/usr/bin/python3", semanticCliPath, "install"]
    semanticSetupProcess.running = true
    return true
  }

  function removeSemantic() {
    if (semanticSetupProcess.running) return false
    semanticSetupAction = "remove"
    semanticSetupStderr = ""
    semanticError = ""
    semanticState = "removing"
    semanticHelperFailed = true
    semanticSetupProcess.command = ["/usr/bin/python3", semanticCliPath, "remove"]
    semanticSetupProcess.running = true
    return true
  }

  function handleSemanticSetupEvent(raw) {
    var message = null
    try { message = JSON.parse(String(raw || "")) } catch (error) { return false }
    if (!message || !message.event) return false
    if (message.event === "progress") {
      semanticState = "installing"
      semanticProgress = Math.max(0, Math.min(1, Number(message.progress || 0)))
      semanticProgressPhase = String(message.phase || "working")
      return true
    }
    if (message.event === "error") {
      semanticState = "failed"
      semanticError = String(message.message || "Smart-search setup failed")
      return true
    }
    if (message.event === "result") {
      semanticInstalled = message.installed === true || message.state === "ready"
      semanticPythonPath = semanticInstalled ? String(message.pythonPath || "") : ""
      semanticState = semanticInstalled ? "installed" : "not-installed"
      semanticProgress = semanticInstalled ? 1 : 0
      semanticProgressPhase = ""
      semanticError = ""
      semanticHelperFailed = false
      semanticStatusLoaded = true
      return true
    }
    return false
  }

  function requestSmartAnalysis() {
    var trimmed = String(query || "").trim()
    semanticRequestId++
    semanticPendingId = semanticRequestId
    semanticPendingQuery = trimmed
    semanticPlan = null
    semanticPlanQuery = ""
    semanticResult = null
    semanticFallback = false
    semanticInferenceTimeout.stop()
    if (searchMode !== "smart" || trimmed === "") return false
    if (!semanticInstalled) {
      semanticFallback = true
      semanticState = "not-installed"
      reload()
      return false
    }
    if (!semanticSessionActive) {
      // A failed helper stays stopped for the rest of its session instead of
      // reloading torch on every query; a new session or Retry tries again.
      semanticHelperFailed = false
      semanticSessionActive = true
    }
    if (semanticHelperFailed) {
      semanticFallback = true
      reload()
      return false
    }
    if (semanticHelperReady && semanticProcess.running) {
      semanticState = "analyzing"
      semanticProcess.write(JSON.stringify({
        op: "analyze", id: semanticPendingId, query: semanticPendingQuery
      }) + "\n")
      semanticInferenceTimeout.restart()
      return true
    }
    semanticState = "loading"
    semanticLoadTimeout.restart()
    // Publish keyword results immediately while the optional model warms up.
    semanticFallback = true
    reload()
    // `semanticShouldRun` starts the process through its running binding.
    return true
  }

  function sendPendingSmartAnalysis() {
    if (!semanticHelperReady || !semanticProcess.running || searchMode !== "smart"
        || semanticPendingQuery !== String(query || "").trim()) return false
    semanticState = "analyzing"
    semanticProcess.write(JSON.stringify({
      op: "analyze", id: semanticPendingId, query: semanticPendingQuery
    }) + "\n")
    semanticInferenceTimeout.restart()
    return true
  }

  function useSmartFallback(reason) {
    semanticInferenceTimeout.stop()
    // Any result that arrives after a timeout/error belongs to the abandoned
    // request and must not silently replace the published fallback listing.
    semanticRequestId++
    semanticPendingId = semanticRequestId
    semanticPendingQuery = ""
    semanticFallback = true
    semanticPlan = null
    semanticPlanQuery = ""
    semanticResult = ({ state: "fallback", fallbackReason: String(reason || "model-unavailable") })
    if (searchMode === "smart" && String(query || "").trim() !== "") reload()
  }

  function handleSemanticEvent(raw) {
    var message = null
    try { message = JSON.parse(String(raw || "")) } catch (error) { return false }
    if (!message || !message.event) return false
    if (message.event === "ready") {
      semanticLoadTimeout.stop()
      semanticHelperReady = true
      semanticHelperFailed = false
      semanticState = "ready"
      semanticDevice = String(message.device || "")
      semanticModel = String(message.model || "laya-multilingual")
      return sendPendingSmartAnalysis()
    }
    if (message.event === "analysis") {
      if (Number(message.id) !== semanticPendingId || searchMode !== "smart"
          || semanticPendingQuery !== String(query || "").trim()) return true
      semanticInferenceTimeout.stop()
      var plan = message.plan
      if (!plan || typeof plan !== "object") {
        useSmartFallback("invalid-plan")
        return false
      }
      semanticPlan = plan
      semanticPlanQuery = semanticPendingQuery
      semanticFallback = false
      semanticState = "ready"
      semanticResult = ({
        state: "ready", terms: plan.terms || [], hints: plan.hints || ({}),
        formats: plan.formats || [], kinds: plan.kinds || [],
        model: String(message.model || semanticModel),
        device: String(message.device || semanticDevice),
        latencyMs: Number(message.latencyMs || 0)
      })
      reload()
      return true
    }
    if (message.event === "error") {
      if (message.id !== undefined && Number(message.id) !== semanticPendingId) return true
      semanticError = String(message.message || "Smart-search analysis failed")
      useSmartFallback(String(message.code || "model-error"))
      return true
    }
    return false
  }

  // Without the catalogs when switched off, or when withoutCatalog keeps the
  // catalog rows already on screen (catalogReusable).
  function buildListCommand(withoutCatalog) {
    var trimmed = String(query || "").trim()
    var command = ["/usr/bin/env", "python3", cliPath,
      trimmed === "" ? "tree" : "search"]
    rootArgument(command)
    if (showHidden) command.push("--show-hidden")
    if (trimmed === "") {
      command.push("--sort")
      command.push(sortOrder)
      for (var i = 0; i < expandedTokens.length; i++) {
        command.push("--expanded")
        command.push(String(expandedTokens[i]))
      }
    } else {
      command.push("--query")
      command.push(trimmed)
      command.push("--mode")
      command.push(searchMode)
      if (searchMode === "smart" && semanticPlan
          && semanticPlanQuery === trimmed) {
        command.push("--smart-plan-json")
        command.push(JSON.stringify(semanticPlan))
      }
      if (caseSensitive) command.push("--case-sensitive")
      if (!offlineSearchEnabled || withoutCatalog === true) command.push("--no-catalog")
    }
    return command
  }

  // What the catalogs answer changes only with the query, its flags, the
  // drives or a catalog itself (each of which searches in full), never with
  // a file event, so the refresh for one can keep the catalog rows on screen.
  function catalogReusable() {
    return offlineSearchEnabled && catalogResult !== null && catalogRowsCommand !== ""
      && catalogRowsCommand === JSON.stringify(buildListCommand())
      && catalogRowsPresence === catalogPresenceKey
  }

  // reuseCatalog: a background refresh that asks the walk alone while the
  // catalog rows on screen still answer the search.
  function reload(background, reuseCatalog) {
    var silent = background === true
    var reuse = silent && reuseCatalog === true
    if (silent && !panelVisible) return false
    if (!silent) foregroundListingPending = true
    if (listingProcess.running) {
      reloadPending = true
      reloadPendingForeground = reloadPendingForeground || !silent
      reloadPendingCatalog = reloadPendingCatalog || !reuse
      return false
    }
    listStdout = ""
    listStderr = ""
    errorMessage = ""
    listInFlightRootToken = rootToken
    listInFlightRootPath = rootPath
    listInFlightBackground = silent
    listInFlightRevision = metadataRevision
    listInFlightReusesCatalog = reuse && catalogReusable()
    listingProcess.command = buildListCommand(listInFlightReusesCatalog)
    listInFlightCommand = JSON.stringify(listingProcess.command)
    listingRequests++
    listingProcess.running = true
    return true
  }

  function refreshAll(background, reuseCatalog) {
    var listingStarted = reload(background === true, reuseCatalog === true)
    var knowledgeStarted = reloadKnowledge()
    var volumesStarted = reloadVolumes()
    return listingStarted || knowledgeStarted || volumesStarted
  }

  function reloadVolumes() {
    if (volumesProcess.running || volumeActionProcess.running) {
      volumesReloadPending = true
      return false
    }
    volumesStdout = ""
    volumesStderr = ""
    volumesError = ""
    volumesProcess.command = ["/usr/bin/env", "python3", cliPath, "volumes"]
    volumesProcess.running = true
    return true
  }

  function buildQuickNavCommand() {
    return ["/usr/bin/env", "python3", cliPath, "quick-nav"]
  }

  function reloadQuickNav() {
    if (quickNavProcess.running || quickNavRecordProcess.running) {
      quickNavReloadPending = true
      return false
    }
    quickNavStdout = ""
    quickNavStderr = ""
    quickNavError = ""
    quickNavProcess.command = buildQuickNavCommand()
    quickNavProcess.running = true
    return true
  }

  function applyQuickNav(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      quickNavError = "Quick Nav returned invalid data"
      return false
    }
    if (!parsed || parsed.ok !== true) {
      quickNavError = parsed && parsed.error
        ? String(parsed.error) : "Could not load Quick Nav"
      return false
    }
    var next = Array.isArray(parsed.entries) ? parsed.entries : []
    if (!sameData(quickNavEntries, next)) {
      reconcileQuickNav(quickNavEntries, next)
      quickNavEntries = next
    }
    quickNavError = ""
    return true
  }

  function buildQuickNavRecordCommand(token, path) {
    var command = ["/usr/bin/env", "python3", cliPath, "quick-nav", "--record"]
    if (String(token || "") !== "") {
      command.push("--path-token")
      command.push(String(token))
    } else {
      command.push("--path")
      command.push(String(path || ""))
    }
    return command
  }

  function recordRecentLocation(token, path) {
    var valueToken = String(token || "")
    var valuePath = String(path || "")
    if (valueToken === "" && valuePath === "") return false
    if (quickNavRecordProcess.running || quickNavProcess.running) {
      quickNavRecordToken = valueToken
      quickNavRecordPath = valuePath
      quickNavRecordPending = true
      return false
    }
    quickNavRecordToken = valueToken
    quickNavRecordPath = valuePath
    quickNavRecordPending = false
    quickNavStdout = ""
    quickNavStderr = ""
    quickNavRecordProcess.command = buildQuickNavRecordCommand(valueToken, valuePath)
    quickNavRecordProcess.running = true
    return true
  }

  function navigateQuickNav(entry) {
    if (!entry) return false
    return navigate(String(entry.path || ""), String(entry.token || ""), true)
  }

  function reloadSettings() {
    if (settingsLoadProcess.running) return false
    settingsStdout = ""
    settingsStderr = ""
    settingsError = ""
    settingsLoadProcess.command = ["/usr/bin/env", "python3", cliPath, "settings"]
    settingsLoadProcess.running = true
    return true
  }

  function applySettings(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      settingsError = "Settings returned invalid data"
      return false
    }
    if (!parsed || parsed.ok !== true || !parsed.settings) {
      settingsError = parsed && parsed.error ? String(parsed.error) : "Could not load settings"
      return false
    }
    moduleLayout = normalizedModuleLayout(parsed.settings.modules)
    activeSessionsEnabled = parsed.settings.activeSessionsEnabled === true
    inspectorTab = ["properties", "notes", "git"].indexOf(
      String(parsed.settings.inspectorTab || "")) >= 0
      ? String(parsed.settings.inspectorTab) : "properties"
    var storedSort = String(parsed.settings.sortOrder || "")
    if (sortOrders.indexOf(storedSort) >= 0 && storedSort !== sortOrder) {
      sortOrder = storedSort
      Qt.callLater(function() { root.reload() })
    }
    var storedFormat = String(parsed.settings.dateFormat || "")
    if (dateFormats.indexOf(storedFormat) >= 0) dateFormat = storedFormat
    smartOnboardingDone = parsed.settings.smartOnboardingDone === true
    // On unless switched off: a store written before the switch existed has no key.
    var storedOffline = parsed.settings.offlineSearchEnabled !== false
    if (storedOffline !== offlineSearchEnabled) {
      offlineSearchEnabled = storedOffline
      if (String(query || "").trim() !== "") Qt.callLater(function() { root.reload() })
    }
    applyModuleCollapseFlags()
    settingsLoaded = true
    settingsError = ""
    if (panelVisible && activeSessionsEnabled) Qt.callLater(reloadSessions)
    return true
  }

  function persistSettings() {
    if (!settingsLoaded) return false
    if (settingsSaveProcess.running) {
      settingsSaveQueued = true
      return false
    }
    settingsSaveQueued = false
    settingsStdout = ""
    settingsStderr = ""
    settingsError = ""
    settingsSaveProcess.command = buildSettingsCommand()
    settingsSaveProcess.running = true
    return true
  }

  // Every setting on every save: the store is replaced whole.
  function buildSettingsCommand() {
    return ["/usr/bin/env", "python3", cliPath, "settings",
      "--active-sessions", activeSessionsEnabled ? "true" : "false",
      "--inspector-tab", inspectorTab,
      "--sort-order", sortOrder,
      "--date-format", dateFormat,
      "--smart-onboarding-done", smartOnboardingDone ? "true" : "false",
      "--offline-search", offlineSearchEnabled ? "true" : "false",
      "--module-layout-json", JSON.stringify(moduleLayout)]
  }

  function setOfflineSearchEnabled(enabled) {
    var value = enabled === true
    if (!settingsLoaded || offlineSearchEnabled === value) return false
    offlineSearchEnabled = value
    persistSettings()
    if (String(query || "").trim() !== "") reload()
    return true
  }

  function finishSmartOnboarding() {
    if (smartOnboardingDone) return false
    smartOnboardingDone = true
    persistSettings()
    return true
  }

  function setActiveSessionsEnabled(enabled) {
    var value = enabled === true
    if (!settingsLoaded || activeSessionsEnabled === value) return false
    activeSessionsEnabled = value
    if (!value) {
      reconcileRows(sessionRows, activeSessions, [])
      activeSessions = []
      sessionsError = ""
      sessionsReloadPending = false
    } else if (panelVisible) {
      Qt.callLater(reloadSessions)
    }
    persistSettings()
    return true
  }

  function reloadSessions() {
    if (!activeSessionsEnabled || !panelVisible) return false
    if (sessionsProcess.running) {
      sessionsReloadPending = true
      return false
    }
    sessionsStdout = ""
    sessionsStderr = ""
    sessionsError = ""
    sessionsInFlightRootToken = rootToken
    sessionsInFlightRootPath = rootPath
    var command = ["/usr/bin/env", "python3", cliPath, "sessions"]
    rootArgument(command)
    sessionsProcess.command = command
    sessionsProcess.running = true
    return true
  }

  function applySessions(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      sessionsError = "AI session scan returned invalid data"
      return false
    }
    if (!parsed || parsed.ok !== true) {
      sessionsError = parsed && parsed.error
        ? String(parsed.error) : "Could not inspect active AI sessions"
      return false
    }
    var parsedToken = parsed.root ? String(parsed.root.token || "") : ""
    var stale = (sessionsInFlightRootToken !== rootToken)
      || (sessionsInFlightRootToken === "" && sessionsInFlightRootPath !== rootPath)
      || (rootToken !== "" && parsedToken !== "" && parsedToken !== rootToken)
    if (stale) {
      sessionsReloadPending = true
      return true
    }
    var next = Array.isArray(parsed.sessions) ? parsed.sessions : []
    if (!sameData(activeSessions, next)) {
      reconcileRows(sessionRows, activeSessions, next)
      activeSessions = next
    }
    sessionsError = ""
    return true
  }

  function navigateSession(session) {
    if (!session) return false
    return navigate(String(session.cwd || ""), String(session.cwdToken || ""), true)
  }

  function applyVolumes(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      volumesError = "Storage scan returned invalid data"
      return false
    }
    if (!parsed || parsed.ok !== true) {
      volumesError = parsed && parsed.error
        ? String(parsed.error) : "Could not inspect external drives"
      return false
    }
    var nextVolumes = Array.isArray(parsed.volumes) ? parsed.volumes : []
    var previousVolumes = volumes
    var changed = !sameData(volumes, nextVolumes)
    if (changed) {
      listingAboutToChange()
      reconcileRows(volumeRows, volumes, nextVolumes)
      volumes = nextVolumes
      modelChanged()
    }
    var catalogued = 0
    var offline = 0
    for (var i = 0; i < nextVolumes.length; i++) {
      if (nextVolumes[i].catalogued === true) catalogued++
      if (nextVolumes[i].offline === true) offline++
    }
    var reportedOffline = Number(parsed.offlineCount)
    catalogVolumeCount = catalogued
    offlineVolumeCount = isFinite(reportedOffline) && reportedOffline >= 0
      ? reportedOffline : offline
    volumesError = ""
    if (volumesSnapshotReady && changed) queueRemountedCatalogs(previousVolumes, nextVolumes)
    // A drive arriving, leaving, mounting or unlocking changes what its search
    // rows say and whether they open. The first snapshot only sets the
    // baseline: the search on screen already looked for itself.
    var presence = catalogPresence(nextVolumes)
    if (volumesSnapshotReady && presence !== catalogPresenceKey
        && String(query || "").trim() !== "") scheduleSearchRefresh()
    catalogPresenceKey = presence
    rememberCatalogMounts(nextVolumes)
    // An offline row's inspector says where its drive is now, before the
    // search catches up.
    if (isCatalogToken(selectedToken)) inspect(selectedToken)
    volumesSnapshotReady = true
    // A queued drive held back by its mount or unmount goes once the
    // snapshot that follows the action says what became of it.
    startNextAutoIndex()
    return true
  }

  // Kept past an unplug, replaced by the next mount.
  function rememberCatalogMounts(rows) {
    var next = Object.assign({}, catalogMountPaths)
    for (var i = 0; i < rows.length; i++) {
      var id = String(rows[i].catalogVolumeId || "")
      if (id !== "" && rows[i].mounted === true && String(rows[i].mountPath || "") !== "")
        next[id] = String(rows[i].mountPath)
    }
    if (!sameData(catalogMountPaths, next)) catalogMountPaths = next
  }

  // A connected catalogued drive and how it is reachable; a drive that is
  // away has no entry, which is its own state.
  function catalogPresence(rows) {
    var states = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var id = String(row.catalogVolumeId || "")
      if (id === "" || row.catalogued !== true || row.offline === true) continue
      states.push(id + "=" + (row.locked === true ? "locked"
        : row.mounted === true ? "mounted" : "unmounted"))
    }
    return states.sort().join("\n")
  }

  // The one place a drive change refreshes the search, in the background so
  // the rows change in place under a still viewport and selection. Several
  // changes in one turn coalesce into one listing.
  function scheduleSearchRefresh() {
    Qt.callLater(root.reloadInBackground)
    return true
  }

  function reloadInBackground() { return reload(true) }

  function volumeForCatalogId(volumeId) {
    var id = String(volumeId || "")
    if (id === "") return null
    for (var i = 0; i < volumes.length; i++)
      if (String(volumes[i].catalogVolumeId || "") === id) return volumes[i]
    return null
  }

  function volumeForDevice(device) {
    var value = String(device || "")
    if (value === "") return null
    for (var i = 0; i < volumes.length; i++)
      if (volumes[i].offline !== true && String(volumes[i].device || "") === value)
        return volumes[i]
    return null
  }

  // A transition, never a state: a drive that was already mounted in the last
  // snapshot is not re-indexed, so finishing an index cannot start another.
  function queueRemountedCatalogs(previous, next) {
    var wasMounted = ({})
    for (var i = 0; i < previous.length; i++) {
      var before = previous[i]
      if (before.mounted === true && before.offline !== true && before.catalogVolumeId)
        wasMounted[String(before.catalogVolumeId)] = true
    }
    var now = Date.now() / 1000
    for (var j = 0; j < next.length; j++) {
      var row = next[j]
      var id = String(row.catalogVolumeId || "")
      if (id === "" || row.catalogued !== true || row.mounted !== true
          || row.offline === true || wasMounted[id] || autoIndexSkipped[id]) continue
      if (now - Number(row.indexedEpoch || 0) <= catalogAutoRefreshMinAge) continue
      if (catalogIndexBusy || catalogIndexVolumeId !== "" || volumeActionPending(row)) {
        if (id !== catalogIndexVolumeId && autoIndexQueue.indexOf(id) < 0)
          autoIndexQueue = autoIndexQueue.concat([id])
      } else {
        indexVolume(row, true)
      }
    }
  }

  function startNextAutoIndex() {
    while (autoIndexQueue.length > 0 && catalogIndexVolumeId === "") {
      var queue = autoIndexQueue.slice()
      var id = queue.shift()
      var volume = volumeForCatalogId(id)
      if (volume && volumeActionPending(volume)) return false
      autoIndexQueue = queue
      if (autoIndexSkipped[id]) continue
      if (volume && volume.mounted === true && volume.offline !== true
          && indexVolume(volume, true)) return true
    }
    return false
  }

  function buildCatalogIndexCommand(volume) {
    return ["/usr/bin/env", "python3", cliPath, "catalog-index",
      "--device", String(volume && volume.device || "")]
  }

  function buildCatalogForgetCommand(volumeId) {
    return ["/usr/bin/env", "python3", cliPath, "catalog-forget",
      "--volume-id", String(volumeId || "")]
  }

  // A mount or unmount still running on this drive: the walk would hold the
  // mount busy under udisksctl, or lose it halfway.
  function volumeActionPending(volume) {
    var device = String(volume && volume.device || "")
    return device !== "" && device === volumeActionDevice
  }

  function volumeIndexable(volume) {
    return !!volume && volume.offline !== true && volume.locked !== true
      && volume.mounted === true && String(volume.device || "") !== ""
      && volume.identityStrength !== "none" && String(volume.catalogVolumeId || "") !== ""
  }

  function indexVolume(volume, automatic) {
    if (!volume || catalogIndexBusy || catalogIndexVolumeId !== "") return false
    if (volumeActionPending(volume)) return false
    if (!volumeIndexable(volume)) {
      if (automatic !== true && volume.mounted === true && volume.offline !== true)
        actionMessage = "This drive has no stable identity"
      return false
    }
    var id = String(volume.catalogVolumeId)
    autoIndexQueue = autoIndexQueue.filter(function(value) { return value !== id })
    catalogIndexDevice = String(volume.device)
    catalogIndexVolumeId = id
    catalogIndexName = String(volume.label || volume.name || volume.device)
    catalogIndexAutomatic = automatic === true
    catalogIndexCancelling = false
    catalogIndexPhase = ""
    catalogIndexFiles = 0
    catalogIndexDirectories = 0
    catalogIndexBytes = 0
    catalogIndexError = ""
    catalogIndexResult = null
    catalogIndexStderr = ""
    // The footer shows the walk until something newer has a word to say;
    // whatever it said before the walk began is not newer.
    actionMessage = ""
    return startCatalogIndexProcess(buildCatalogIndexCommand(volume))
  }

  // The one place an index process starts, so the harness can drive the
  // whole request/exit cycle without a backend.
  function startCatalogIndexProcess(command) {
    catalogIndexProcess.command = command
    catalogIndexProcess.running = true
    return true
  }

  function cancelCatalogIndex() {
    if (catalogIndexVolumeId === "" || catalogIndexCancelling) return false
    catalogIndexCancelling = true
    if (signalCatalogIndex(15)) catalogIndexKillTimer.restart()
    return true
  }

  // The one place the walk is signalled, beside the one place it starts.
  function signalCatalogIndex(signalNumber) {
    if (!catalogIndexProcess.running) return false
    catalogIndexProcess.signal(signalNumber)
    return true
  }

  function escalateCatalogIndexCancel() {
    catalogIndexKillTimer.stop()
    return catalogIndexCancelling && signalCatalogIndex(9)
  }

  function handleCatalogIndexEvent(line) {
    var parsed = null
    try { parsed = JSON.parse(String(line || "")) } catch (error) { return }
    if (!parsed) return
    if (parsed.event === "progress") {
      catalogIndexPhase = String(parsed.phase || "")
      catalogIndexFiles = Number(parsed.files) || 0
      catalogIndexDirectories = Number(parsed.directories) || 0
      catalogIndexBytes = Number(parsed.bytes) || 0
      return
    }
    if (parsed.ok === true) {
      catalogIndexResult = parsed
      var volume = parsed.volume || ({})
      catalogIndexFiles = Number(volume.files) || 0
      catalogIndexDirectories = Number(volume.directories) || 0
      catalogIndexBytes = Number(volume.bytes) || 0
      catalogIndexError = ""
    } else if (parsed.error) {
      catalogIndexResult = parsed
      catalogIndexError = String(parsed.error)
    }
  }

  // Panel's compactTokens, so the finished message reads like the progress.
  function compactCount(value) {
    var amount = Math.max(0, Number(value || 0))
    if (amount < 1000) return String(Math.round(amount))
    var digits = amount >= 10000 ? 1 : 2
    return (amount / 1000).toFixed(digits).replace(/\.0+$/, "") + "k"
  }

  function finishCatalogIndex(exitCode) {
    catalogIndexKillTimer.stop()
    var parsed = catalogIndexResult
    var volumeId = catalogIndexVolumeId
    var automatic = catalogIndexAutomatic
    var parkedDevice = unmountAfterIndexDevice
    var cancelled = catalogIndexCancelling || exitCode === 130
      || (parsed && (parsed.code === "cancelled" || parsed.code === "operation-cancelled"))
    var ok = exitCode === 0 && parsed && parsed.ok === true
    var message = ""
    if (ok) {
      var result = parsed.volume || ({})
      message = "Indexed “" + String(result.name || catalogIndexName) + "” · "
        + compactCount(result.files) + " files"
        + (String(result.state || "") === "partial" ? " · partial" : "")
    } else if (!cancelled) {
      message = parsed && parsed.error ? String(parsed.error)
        : (catalogIndexError || catalogIndexStderr.trim() || "Could not index the drive")
    }
    // A cancelled walk has nothing to report, and a message that arrived
    // while it ran is still the latest word.
    if (message !== "") actionMessage = message
    catalogIndexDevice = ""
    catalogIndexVolumeId = ""
    catalogIndexName = ""
    catalogIndexAutomatic = false
    catalogIndexCancelling = false
    catalogIndexPhase = ""
    unmountAfterIndexDevice = ""
    // Stopping an automatic run means "not now". Unmounting mid-run does not:
    // the drive re-indexes the next time it is mounted.
    if (automatic && cancelled && parkedDevice === "" && volumeId !== "") {
      var skipped = Object.assign({}, autoIndexSkipped)
      skipped[volumeId] = true
      autoIndexSkipped = skipped
    }
    actionFinished("catalog-index", ok, message)
    Qt.callLater(root.reloadVolumes)
    // A search on screen may have rows in the catalog just replaced.
    if (ok && String(query || "").trim() !== "") scheduleSearchRefresh()
    if (parkedDevice !== "") {
      var parked = volumeForDevice(parkedDevice)
      if (parked) unmountVolume(parked)
    }
    // The next queued drive starts without clearing what this walk just said.
    var reported = actionMessage
    if (startNextAutoIndex()) actionMessage = reported
  }

  function forgetCatalog(volumeId) {
    var id = String(volumeId || "")
    if (id === "" || catalogForgetProcess.running) return false
    if (id === catalogIndexVolumeId) {
      // The walk would publish the catalog again seconds after it was removed.
      actionMessage = "This drive is being indexed"
      return false
    }
    catalogForgetVolumeId = id
    catalogForgetStdout = ""
    catalogForgetStderr = ""
    return startCatalogForgetProcess(buildCatalogForgetCommand(id))
  }

  function startCatalogForgetProcess(command) {
    catalogForgetProcess.command = command
    catalogForgetProcess.running = true
    return true
  }

  function finishCatalogForget(exitCode) {
    var id = catalogForgetVolumeId
    var parsed = null
    try { parsed = JSON.parse(catalogForgetStdout) } catch (error) {}
    var ok = exitCode === 0 && parsed && parsed.ok === true
    var message = ok ? String(parsed.message || "Forgot the drive's catalog")
      : (parsed && parsed.error ? String(parsed.error)
        : (catalogForgetStderr.trim() || "Could not forget the drive's catalog"))
    catalogForgetVolumeId = ""
    if (ok) autoIndexQueue = autoIndexQueue.filter(function(value) { return value !== id })
    actionMessage = message
    actionFinished("catalog-forget", ok, message)
    Qt.callLater(root.reloadVolumes)
    if (ok) {
      // Its rows on screen are of a catalog that no longer exists, and the
      // drive list will not say so: an offline drive leaves no presence.
      if (lastOfflineRequest && lastOfflineRequest.volumeId === id) lastOfflineRequest = null
      if (String(query || "").trim() !== "") scheduleSearchRefresh()
    }
  }

  function pathInsideMount(path, mountPath) {
    var value = String(path || "")
    var mount = String(mountPath || "")
    if (value === "" || mount === "") return false
    return value === mount || value.indexOf(mount.replace(/\/$/, "") + "/") === 0
  }

  function openVolume(volume) {
    if (!volume) return false
    // A catalogued drive that is away, or still locked, has nothing to mount.
    // Named by its label: the listed name may carry a model and size to tell
    // two same-named drives apart, which the row already shows.
    var name = String(volume.label || volume.name || "this drive")
    if (volume.offline === true) {
      announce("Connect “" + name + "” to browse it")
      return false
    }
    if (volume.locked === true) {
      announce("Unlock “" + name + "” to browse it")
      return false
    }
    if (volumeActionProcess.running) return false
    if (volume.mounted === true && String(volume.mountPath || "") !== "")
      return navigate(String(volume.mountPath), String(volume.mountToken || ""), true)
    if (volume.canMount !== true) {
      actionMessage = "This external drive cannot be mounted"
      return false
    }
    return runVolumeAction("mount", volume)
  }

  function unmountVolume(volume) {
    if (!volume || volume.mounted !== true || volume.canUnmount !== true) return false
    var device = String(volume.device || "")
    if (catalogIndexVolumeId !== "" && device !== "" && device === catalogIndexDevice) {
      unmountAfterIndexDevice = device
      cancelCatalogIndex()
      return true
    }
    return runVolumeAction("unmount", volume)
  }

  // A mount opens the drive unless navigateAfter is false.
  function runVolumeAction(kind, volume, navigateAfter) {
    if (volumeActionProcess.running || !volume || !volume.device) return false
    volumeActionKind = String(kind || "")
    volumeActionDevice = String(volume.device || "")
    volumeActionMountPath = String(volume.mountPath || "")
    volumeActionNavigate = navigateAfter !== false
    volumeActionStdout = ""
    volumeActionStderr = ""
    actionMessage = ""
    volumeActionProcess.command = ["/usr/bin/env", "python3", cliPath,
      "volume-action", volumeActionKind, "--device", volumeActionDevice]
    volumeActionProcess.running = true
    return true
  }

  // A search row from the catalog of a drive that is away. Its token names
  // the catalog, not a path, and the backend refuses it: every action is
  // turned into a hint here before it gets that far.
  function isCatalogToken(token) {
    return String(token || "").indexOf("catalog:") === 0
  }

  function isOfflineEntry(entry) {
    return !!entry && (entry.available === false || isCatalogToken(entry.token))
  }

  // The drive list is fresher than the search that produced the row: a drive
  // plugged in since then is not "disconnected" any more.
  function offlineVolumeState(entry) {
    var volume = volumeForCatalogId(entry ? entry.volumeId : "")
    if (volume && volume.offline === true) return "disconnected"
    if (volume) return volume.locked === true ? "locked"
      : volume.mounted === true ? "mounted" : "unmounted"
    return String(entry && entry.volumeState || "disconnected")
  }

  function offlineHintText(entry, state) {
    var drive = "“" + String(entry.volumeName || "this drive") + "”"
    var target = (entry.isDir === true ? " to browse " : " to open ")
      + String(entry.name || "it")
    if (state === "locked") return "Unlock " + drive + target
    if (state === "unmounted") return "Mount " + drive + target
    return "Connect " + drive + target
  }

  // Copying, starring or trashing an offline row only says where it is.
  function offlineHint(entry) {
    if (!isOfflineEntry(entry)) return false
    var state = offlineVolumeState(entry)
    if (state === "mounted") refreshStaleOfflineRow(entry)
    else announce(offlineHintText(entry, state))
    return true
  }

  // Mounted since this search ran: the refresh brings the row alive, and
  // its reveal replaces this message.
  function refreshStaleOfflineRow(entry) {
    rememberOfflineRequest(entry)
    announce("Finding " + String(entry.name || "it") + " on “"
      + String(entry.volumeName || "this drive") + "”…")
    if (String(query || "").trim() !== "") scheduleSearchRefresh()
  }

  function rememberOfflineRequest(entry) {
    lastOfflineRequest = { catalogToken: String(entry.catalogToken || entry.token || ""),
      volumeId: String(entry.volumeId || ""), name: String(entry.name || ""),
      relativePath: String(entry.relativePath || ""),
      volumeName: String(entry.volumeName || "") }
  }

  // Opening one names the drive to plug in. A drive that is here but not
  // mounted is mounted where the search is; one that turns up later is left
  // to the desktop, and its row comes alive by itself (applyListing).
  function requestOfflineEntry(entry) {
    if (!isOfflineEntry(entry)) return false
    rememberOfflineRequest(entry)
    // The snapshot can predate a drive the automounter did not touch.
    reloadVolumes()
    var state = offlineVolumeState(entry)
    var volume = volumeForCatalogId(entry.volumeId)
    if (state === "mounted") {
      refreshStaleOfflineRow(entry)
      return false
    }
    if (state === "unmounted" && volume && volume.canMount === true
        && runVolumeAction("mount", volume, false)) {
      announce("Mounting “" + String(entry.volumeName || "this drive") + "”…")
      return false
    }
    announce(offlineHintText(entry, state))
    return false
  }

  // The inspector's view of an offline row: what the catalog knows, without
  // asking the backend about a path it cannot reach.
  function offlineProperties(entry) {
    if (!entry) return null
    return { offline: true, token: String(entry.token || ""),
      catalogToken: String(entry.catalogToken || entry.token || ""),
      name: String(entry.name || ""), path: String(entry.path || ""),
      relativePath: String(entry.relativePath || ""), isDir: entry.isDir === true,
      kind: String(entry.kind || ""), mime: String(entry.mime || ""),
      size: Number(entry.size || 0), sizeText: String(entry.sizeText || ""),
      modified: String(entry.modified || ""), modifiedEpoch: Number(entry.modifiedEpoch || 0),
      volumeId: String(entry.volumeId || ""), volumeName: String(entry.volumeName || ""),
      volumeModel: String(entry.volumeModel || ""),
      volumeSizeText: String(entry.volumeSizeText || ""),
      indexedAt: String(entry.indexedAt || ""), indexedEpoch: Number(entry.indexedEpoch || 0),
      catalogState: String(entry.catalogState || ""),
      volumeState: offlineVolumeState(entry) }
  }

  function reloadKnowledge() {
    if (knowledgeProcess.running) {
      knowledgeReloadPending = true
      return false
    }
    knowledgeStdout = ""
    knowledgeStderr = ""
    knowledgeError = ""
    knowledgeInFlightRevision = metadataRevision
    var command = ["/usr/bin/env", "python3", cliPath, "knowledge"]
    rootArgument(command)
    knowledgeProcess.command = command
    knowledgeProcess.running = true
    return true
  }

  function applyKnowledge(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      knowledgeError = "Knowledge index returned invalid data"
      return false
    }
    if (!parsed || parsed.ok !== true) {
      knowledgeError = parsed && parsed.error
        ? String(parsed.error) : "Could not index knowledge files"
      return false
    }
    if (knowledgeInFlightRevision !== metadataRevision) {
      knowledgeReloadPending = true
      return true
    }
    var parsedRootToken = parsed.root ? String(parsed.root.token || "") : ""
    if (rootToken !== "" && parsedRootToken !== "" && parsedRootToken !== rootToken) {
      knowledgeReloadPending = true
      return true
    }
    knowledgeWatch = parsed.watch || null
    syncWatchConfiguration()
    var nextKnowledge = Array.isArray(parsed.entries) ? parsed.entries : []
    var changed = !sameData(knowledgeFiles, nextKnowledge)
      || knowledgeTotalTokens !== Number(parsed.totalTokens || 0)
      || knowledgeTruncated !== (parsed.truncated === true)
    if (changed) listingAboutToChange()
    reconcileRows(knowledgeRows, knowledgeFiles, nextKnowledge)
    if (changed) knowledgeFiles = nextKnowledge
    knowledgeTotalTokens = Number(parsed.totalTokens || 0)
    knowledgeMaxTokens = Number(parsed.maxTokens || 0)
    knowledgeTruncated = parsed.truncated === true
    knowledgeRootToken = parsedRootToken || rootToken
    knowledgeError = ""
    if (selectedToken !== "") {
      var selected = visibleEntryForToken(selectedToken)
      if (selected) selectedEntry = selected
      else clearSelection()
    }
    if (changed) modelChanged()
    return true
  }

  function applyListing(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      errorMessage = "QuickFile returned invalid data"
      return false
    }
    if (!parsed || parsed.ok !== true) {
      errorMessage = parsed && parsed.error ? String(parsed.error) : "Could not read this folder"
      return false
    }
    var requestIsCurrent = listInFlightRootToken !== ""
      ? String(rootToken || "") === listInFlightRootToken
      : String(rootToken || "") === "" && String(rootPath || "") === listInFlightRootPath
    if (!requestIsCurrent) {
      reloadPending = true
      return true
    }
    var reusedCatalog = listInFlightReusesCatalog
    if (listInFlightRevision !== metadataRevision
        || listInFlightCommand !== JSON.stringify(buildListCommand(reusedCatalog))) {
      reloadPending = true
      reloadPendingForeground = reloadPendingForeground || !listInFlightBackground
      return true
    }
    // A drive came or went while the walk ran: the catalog rows on screen
    // no longer answer, so the search runs again in full.
    if (reusedCatalog && !catalogReusable()) {
      reloadPending = true
      reloadPendingCatalog = true
      return true
    }
    var nextEntries = Array.isArray(parsed.entries) ? parsed.entries : []
    var nextFavorites = Array.isArray(parsed.favorites) ? parsed.favorites : []
    var nextGit = parsed.git || ({ root: "", branch: "" })
    var nextSemanticResult = parsed.smart || null
    var nextCatalog = parsed.catalog || null
    var nextTruncated = parsed.truncated === true
    if (reusedCatalog) {
      // The walk's rows are new; the catalog's are those on screen, less any
      // the walk now lists itself.
      var walked = ({})
      for (var w = 0; w < nextEntries.length; w++) {
        walked["token:" + String(nextEntries[w].token || "")] = true
        walked["path:" + String(nextEntries[w].path || "")] = true
      }
      var carried = entries.filter(function(entry) {
        return entry.origin === "catalog" && !walked["token:" + String(entry.token || "")]
          && !walked["path:" + String(entry.path || "")]
      })
      var carriedHere = carried.filter(function(entry) { return entry.available === true }).length
      nextEntries = nextEntries.concat(carried)
      nextCatalog = Object.assign({}, catalogResult, {
        offlineMatches: carried.length - carriedHere, availableMatches: carriedHere })
      nextTruncated = nextTruncated || catalogResult.truncated === true
    }
    var reportedOffline = Number(nextCatalog ? nextCatalog.offlineMatches : 0)
    var nextOfflineCount = isFinite(reportedOffline) && reportedOffline >= 0
      ? reportedOffline
      : nextEntries.filter(function(entry) { return entry.available === false }).length
    var changed = !sameData(entries, nextEntries) || !sameData(favorites, nextFavorites)
      || !sameData(git, nextGit) || truncated !== nextTruncated
      || searchEngine !== String(parsed.engine || "")
      || !sameData(semanticResult, nextSemanticResult)
      || !sameData(catalogResult, nextCatalog) || offlineMatchCount !== nextOfflineCount
    var previousEntries = entries
    var anchorToken = selectionAnchorIndex >= 0 && selectionAnchorIndex < entries.length
      ? String(entries[selectionAnchorIndex].token || "") : ""
    listingIsNewResults = !listInFlightBackground && String(query || "").trim() !== ""
      && listInFlightCommand !== appliedListingCommand
    appliedListingCommand = listInFlightCommand
    if (changed) listingAboutToChange()
    if (parsed.root) {
      rootPath = String(parsed.root.path || rootPath)
      rootToken = String(parsed.root.token || rootToken)
      parentPath = String(parsed.root.parentPath || rootPath)
      parentToken = String(parsed.root.parentToken || rootToken)
    }
    if (!sameData(entries, nextEntries)) {
      reconcileRows(fileRows, entries, nextEntries)
      entries = nextEntries
    }
    if (!sameData(favorites, nextFavorites)) {
      reconcileRows(favoriteRows, favorites, nextFavorites)
      favorites = nextFavorites
    }
    if (!sameData(git, nextGit)) git = nextGit
    truncated = nextTruncated
    searchEngine = String(parsed.engine || "")
    if (!sameData(catalogResult, nextCatalog)) catalogResult = nextCatalog
    if (!reusedCatalog) {
      catalogRowsCommand = nextCatalog ? listInFlightCommand : ""
      catalogRowsPresence = catalogPresenceKey
    }
    offlineMatchCount = nextOfflineCount
    semanticResult = nextSemanticResult
    if (nextSemanticResult) {
      semanticFallback = String(nextSemanticResult.state || "") === "fallback"
      if (nextSemanticResult.model) semanticModel = String(nextSemanticResult.model)
      if (nextSemanticResult.device) semanticDevice = String(nextSemanticResult.device)
    } else if (searchMode !== "smart") {
      semanticFallback = false
    }
    errorMessage = ""

    // A catalog row changes token when its drive comes or goes. It is still
    // the row the user picked, found again by the catalog token both carry.
    var moves = catalogTokenMoves(previousEntries, entries)
    listingTokenMoves = moves
    var previousSelection = selectedToken
    if (moves[selectedToken] !== undefined) selectedToken = moves[selectedToken]
    if (moves[anchorToken] !== undefined) anchorToken = moves[anchorToken]
    var followedSelection = selectedTokens.map(function(token) {
      var value = String(token || "")
      return moves[value] !== undefined ? moves[value] : value
    })
    if (!sameData(selectedTokens, followedSelection)) selectedTokens = followedSelection

    var selected = null
    var visibleTokens = ({})
    for (var i = 0; i < entries.length; i++) {
      var entryToken = String(entries[i].token || "")
      visibleTokens[entryToken] = true
      if (entryToken === selectedToken) selected = entries[i]
    }
    for (var j = 0; j < favorites.length; j++) {
      var favoriteToken = String(favorites[j].token || "")
      visibleTokens[favoriteToken] = true
      if (!selected && favoriteToken === selectedToken) selected = favorites[j]
    }
    for (var knowledgeIndex = 0; knowledgeIndex < knowledgeFiles.length; knowledgeIndex++) {
      var knowledgeToken = String(knowledgeFiles[knowledgeIndex].token || "")
      visibleTokens[knowledgeToken] = true
      if (!selected && knowledgeToken === selectedToken)
        selected = knowledgeFiles[knowledgeIndex]
    }
    var retainedSelection = []
    for (var k = 0; k < selectedTokens.length; k++) {
      var retainedToken = String(selectedTokens[k] || "")
      if (visibleTokens[retainedToken]) retainedSelection.push(retainedToken)
    }
    if (!sameData(selectedTokens, retainedSelection)) selectedTokens = retainedSelection
    var selectedChanged = !sameData(selectedEntry, selected)
    if (selectedChanged) selectedEntry = selected
    if (anchorToken !== "") {
      selectionAnchorIndex = -1
      for (var anchorIndex = 0; anchorIndex < entries.length; anchorIndex++)
        if (String(entries[anchorIndex].token || "") === anchorToken)
          selectionAnchorIndex = anchorIndex
    }
    if (!selected) {
      if (previewToken !== "") clearPreview()
      selectedToken = ""
      selectedProperties = null
      selectionAnchorIndex = -1
    } else if (selectedToken !== previousSelection
        || (selectedChanged && isCatalogToken(selectedToken))) {
      // The inspector shows the catalog's view or the drive's, whichever is
      // true now; an offline row's own view says where its drive is now.
      if (previewToken !== "") clearPreview()
      inspect(selectedToken)
    }
    if (changed) {
      listingChanges++
      modelChanged()
    }
    revealRequestedEntry()
    listWatch = parsed.watch || null
    syncWatchConfiguration()
    if (recordNavigationOnListing) {
      recordNavigationOnListing = false
      recordRecentLocation(rootToken, rootPath)
    }
    if (knowledgeRootToken !== rootToken) Qt.callLater(root.reloadKnowledge)
    return true
  }

  // Old token → new token for every catalog row whose token changed, keyed
  // both by its old token and by its catalog token. A drive mounted inside
  // the searched folder is listed by the walk, whose row has no catalog
  // token: it is the same file as the catalog row at its path on the drive.
  function catalogTokenMoves(previous, next) {
    var current = ({})
    var walkedNow = ({})
    for (var i = 0; i < next.length; i++) {
      var key = String(next[i].catalogToken || "")
      if (key !== "") current[key] = String(next[i].token || "")
      else if (next[i].origin === undefined)
        walkedNow[String(next[i].path || "")] = String(next[i].token || "")
    }
    var moves = ({})
    for (var catalogToken in current)
      if (current[catalogToken] !== catalogToken) moves[catalogToken] = current[catalogToken]
    var walkedBefore = ({})
    for (var j = 0; j < previous.length; j++) {
      var before = String(previous[j].token || "")
      var previousKey = String(previous[j].catalogToken || "")
      var target = current[previousKey]
      if (target !== undefined && target !== before) moves[before] = target
      if (previousKey === "" && previous[j].origin === undefined)
        walkedBefore[String(previous[j].path || "")] = before
      var walkedTarget = previousKey !== "" ? walkedNow[catalogRowPath(previous[j])] : undefined
      if (target === undefined && walkedTarget !== undefined) moves[before] = walkedTarget
    }
    for (var k = 0; k < next.length; k++) {
      var walkedToken = String(next[k].catalogToken || "") !== ""
        ? walkedBefore[catalogRowPath(next[k])] : undefined
      if (walkedToken !== undefined && walkedToken !== String(next[k].token || ""))
        moves[walkedToken] = String(next[k].token || "")
    }
    return moves
  }

  // Where the walk lists a catalog row while its drive is mounted, or "".
  function catalogRowPath(row) {
    var mount = String(catalogMountPaths[String(row.volumeId || "")] || "")
    var relative = String(row.relativePath || "")
    return mount === "" || relative === "" ? "" : mount.replace(/\/+$/, "") + "/" + relative
  }

  // The row the user tried to open is on a drive that has just arrived: put
  // the cursor on it and say so. Opening it is still the user's next Enter.
  function revealRequestedEntry() {
    var request = lastOfflineRequest
    if (!request || request.catalogToken === "") return false
    // A rename or trash sheet acts on the selection, and a draft belongs to
    // it: the cursor moves once the panel lets go (onSelectionHeldChanged).
    if (selectionHeld) return false
    // A drive mounted inside the searched folder is listed by the walk
    // itself, whose row has no catalog token: it is found by its path.
    var volume = volumeForCatalogId(request.volumeId)
    var mountPath = volume && volume.mounted === true ? String(volume.mountPath || "") : ""
    var walkedPath = mountPath !== "" && String(request.relativePath || "") !== ""
      ? mountPath.replace(/\/+$/, "") + "/" + request.relativePath : ""
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var byCatalog = entry.available === true
        && String(entry.catalogToken || "") === request.catalogToken
      var byPath = walkedPath !== "" && entry.origin === undefined
        && String(entry.path || "") === walkedPath
      if (!byCatalog && !byPath) continue
      lastOfflineRequest = null
      // Usually already selected: the selection followed the row to its new token.
      if (selectedToken !== String(entry.token || "")) selectIndex(i)
      announce("“" + String(entry.volumeName || request.volumeName || "The drive")
        + "” connected · " + String(entry.name || request.name) + " is ready")
      revealRequested(String(entry.token || ""))
      return true
    }
    return false
  }

  function location() {
    return ({ path: rootPath, token: rootToken })
  }

  function navigate(path, token, recordHistory) {
    var nextPath = String(path || "")
    var nextToken = String(token || "")
    if ((!nextPath && !nextToken) || isCatalogToken(nextToken)) return false
    navigationAboutToChange(rootPath, rootToken)
    if (recordHistory !== false && rootPath !== "") {
      var back = backStack.slice()
      back.push(location())
      if (back.length > 100) back.shift()
      backStack = back
      forwardStack = []
    }
    rootPath = nextPath || rootPath
    rootToken = nextToken
    recordNavigationOnListing = true
    parentPath = rootPath
    parentToken = rootToken
    expandedTokens = []
    listingAboutToChange()
    fileRows.clear()
    knowledgeRows.clear()
    sessionRows.clear()
    entries = []
    knowledgeFiles = []
    activeSessions = []
    knowledgeTotalTokens = 0
    knowledgeMaxTokens = 0
    knowledgeRootToken = ""
    listWatch = null
    knowledgeWatch = null
    syncWatchConfiguration()
    query = ""
    semanticInferenceTimeout.stop()
    semanticLoadTimeout.stop()
    semanticPlan = null
    semanticPlanQuery = ""
    semanticResult = null
    semanticFallback = false
    clearPreview()
    selectedToken = ""
    selectedTokens = []
    selectionAnchorIndex = -1
    selectedEntry = null
    selectedProperties = null
    knowledgeLinkPlan = null
    knowledgeLinkError = ""
    sessionsError = ""
    errorMessage = ""
    truncated = false
    catalogResult = null
    offlineMatchCount = 0
    lastOfflineRequest = null
    modelChanged()
    var started = reload()
    if (activeSessionsEnabled && panelVisible) Qt.callLater(reloadSessions)
    return started
  }

  function goHome() {
    navigate(homePath, "", true)
  }

  function goParent() {
    if (parentToken === rootToken) return
    navigate(parentPath, parentToken, true)
  }

  function goBack() {
    if (backStack.length === 0) return
    var back = backStack.slice()
    var target = back.pop()
    var forward = forwardStack.slice()
    forward.push(location())
    backStack = back
    forwardStack = forward
    navigate(target.path, target.token, false)
  }

  function goForward() {
    if (forwardStack.length === 0) return
    var forward = forwardStack.slice()
    var target = forward.pop()
    var back = backStack.slice()
    back.push(location())
    backStack = back
    forwardStack = forward
    navigate(target.path, target.token, false)
  }

  function setShowHidden(value) {
    showHidden = value === true
    reload()
  }

  function setSearch(text, mode) {
    // A different question: the row asked for earlier is no longer on screen.
    if (String(text || "").trim() !== String(query || "").trim()) lastOfflineRequest = null
    query = String(text || "")
    if (mode) searchMode = String(mode)
    if (searchMode === "smart" && String(query || "").trim() !== "")
      requestSmartAnalysis()
    else {
      semanticInferenceTimeout.stop()
      semanticLoadTimeout.stop()
      semanticPlan = null
      semanticPlanQuery = ""
      semanticResult = null
      semanticFallback = false
      reload()
    }
  }

  function toggleExpanded(token) {
    var value = String(token || "")
    if (!value || isCatalogToken(value)) return
    var next = expandedTokens.slice()
    var index = next.indexOf(value)
    if (index >= 0) next.splice(index, 1)
    else next.push(value)
    expandedTokens = next
    reload()
  }

  function isSelected(token) {
    return selectedTokens.indexOf(String(token || "")) >= 0
  }

  function setActiveEntry(entry) {
    if (!entry) {
      clearPreview()
      selectedToken = ""
      selectedEntry = null
      selectedProperties = null
      return false
    }
    if (selectedToken !== "" && selectedToken !== String(entry.token || ""))
      clearPreview()
    selectedEntry = entry
    selectedToken = String(entry.token || "")
    inspect(selectedToken)
    return true
  }

  function focusIndex(index) {
    if (index < 0 || index >= entries.length) return false
    return setActiveEntry(entries[index])
  }

  function selectEntry(entry, index, mode) {
    if (!setActiveEntry(entry)) return false
    var token = selectedToken
    var selectionMode = String(mode || "replace")
    if (selectionMode === "focus") return true
    var next = selectedTokens.slice()
    if (selectionMode === "toggle") {
      var present = next.indexOf(token)
      if (present >= 0) next.splice(present, 1)
      else next.push(token)
      if (index >= 0) selectionAnchorIndex = index
    } else if (selectionMode === "range" && index >= 0 && selectionAnchorIndex >= 0) {
      next = []
      var start = Math.min(selectionAnchorIndex, index)
      var end = Math.max(selectionAnchorIndex, index)
      for (var i = start; i <= end; i++)
        next.push(String(entries[i].token || ""))
    } else {
      next = [token]
      if (index >= 0) selectionAnchorIndex = index
    }
    selectedTokens = next
    return true
  }

  function selectIndex(index, mode) {
    if (index < 0 || index >= entries.length) {
      clearSelection()
      return false
    }
    return selectEntry(entries[index], index, mode)
  }

  function selectFavorite(entry, mode) {
    selectionAnchorIndex = -1
    return selectEntry(entry, -1, mode)
  }

  function selectKnowledge(entry, mode) {
    selectionAnchorIndex = -1
    return selectEntry(entry, -1, mode)
  }

  function toggleIndex(index) {
    return selectIndex(index, "toggle")
  }

  function selectAllVisible() {
    var next = []
    for (var i = 0; i < entries.length; i++) next.push(String(entries[i].token || ""))
    selectedTokens = next
    if (entries.length > 0) {
      if (selectionAnchorIndex < 0) selectionAnchorIndex = 0
      setActiveEntry(entries[Math.max(0, Math.min(entries.length - 1, selectionAnchorIndex))])
    }
  }

  function clearSelection() {
    clearPreview()
    selectedTokens = []
    selectionAnchorIndex = -1
    selectedToken = ""
    selectedEntry = null
    selectedProperties = null
  }

  // What an action on the selection acts on. Rows on a drive that is away
  // are left out rather than failing the whole batch; callers say so.
  function effectiveSelectionTokens(anchorToken) {
    var hasExplicitAnchor = anchorToken !== undefined && anchorToken !== null
      && String(anchorToken) !== ""
    var anchor = String(hasExplicitAnchor ? anchorToken : (selectedToken || ""))
    var tokens = anchor === "" ? [] : [anchor]
    if ((!hasExplicitAnchor || (anchor !== "" && isSelected(anchor)))
        && selectedTokens.length > 0)
      tokens = selectedTokens.slice()
    return tokens.filter(function(token) { return !root.isCatalogToken(token) })
  }

  // Nothing to act on but rows on a drive that is away: say where they are.
  function refuseOffline(entry) {
    offlineHint(entry)
    return false
  }

  function refuseOfflineSelection() { return refuseOffline(selectedEntry) }

  // The offline rows a selection action leaves out.
  function offlineSelectionCount() {
    var all = selectedTokens.length > 0 ? selectedTokens : [selectedToken]
    return all.filter(function(token) { return root.isCatalogToken(token) }).length
  }

  // The same, as a suffix to the action's message.
  function offlineSelectionNote() {
    var left = offlineSelectionCount()
    if (left === 0) return ""
    return " · " + left + (left === 1 ? " offline item" : " offline items") + " left out"
  }

  // A trash or duplicate of a mixed selection: its outcome says what it left out.
  function runSelectionOperation(kind, tokens) {
    var note = offlineSelectionNote()
    if (!runOperation(kind, tokens)) return false
    if (pendingOperation)
      pendingOperation = Object.assign({}, pendingOperation, { offlineNote: note })
    return true
  }

  function visibleEntryForToken(token) {
    var value = String(token || "")
    for (var i = 0; i < entries.length; i++)
      if (String(entries[i].token || "") === value) return entries[i]
    for (var j = 0; j < favorites.length; j++)
      if (String(favorites[j].token || "") === value) return favorites[j]
    for (var k = 0; k < knowledgeFiles.length; k++)
      if (String(knowledgeFiles[k].token || "") === value) return knowledgeFiles[k]
    return null
  }

  function dragEntries(anchorEntry) {
    var tokens = effectiveSelectionTokens(anchorEntry ? anchorEntry.token : "")
    var output = []
    for (var i = 0; i < tokens.length; i++) {
      var entry = visibleEntryForToken(tokens[i])
      if (entry) output.push(entry)
    }
    return output
  }

  function dragUriList(anchorEntry) {
    var selected = dragEntries(anchorEntry)
    var uris = []
    for (var i = 0; i < selected.length; i++)
      if (selected[i].uri) uris.push(String(selected[i].uri))
    return uris.length > 0 ? uris.join("\r\n") + "\r\n" : ""
  }

  function dragText(anchorEntry) {
    var selected = dragEntries(anchorEntry)
    var paths = []
    for (var i = 0; i < selected.length; i++)
      paths.push(String(selected[i].shellQuotedPath || selected[i].path || ""))
    return paths.join(" ")
  }

  function activateIndex(index) {
    if (index < 0 || index >= entries.length) return
    var entry = entries[index]
    selectIndex(index)
    if (isOfflineEntry(entry)) requestOfflineEntry(entry)
    else if (entry.isDir === true) toggleExpanded(entry.token)
    else runAction("open", entry.token)
  }

  function enterIndex(index) {
    if (index < 0 || index >= entries.length) return
    var entry = entries[index]
    if (isOfflineEntry(entry)) requestOfflineEntry(entry)
    else if (entry.isDir === true) {
      var now = Date.now()
      if (now < navigationBlockedUntil) return
      navigationBlockedUntil = now + 450
      navigate(entry.path, entry.token, true)
    }
    else runAction("open", entry.token)
  }

  function enterEntry(entry) {
    if (!entry) return false
    setActiveEntry(entry)
    if (isOfflineEntry(entry)) return requestOfflineEntry(entry)
    if (entry.isDir === true) {
      var now = Date.now()
      if (now < navigationBlockedUntil) return false
      navigationBlockedUntil = now + 450
      return navigate(entry.path, entry.token, true)
    }
    return runAction("open", entry.token)
  }

  // The background refresh re-inspects the selection on every tick, so an
  // offline row has to be answered here or it would reach the backend.
  function inspect(token) {
    var value = String(token || "")
    if (isCatalogToken(value)) {
      propertyPendingToken = ""
      var entry = visibleEntryForToken(value)
      if (!entry && selectedEntry && String(selectedEntry.token || "") === value)
        entry = selectedEntry
      var properties = offlineProperties(entry)
      if (!sameData(selectedProperties, properties)) selectedProperties = properties
      return
    }
    propertyPendingToken = value
    if (!propertyProcess.running) startPendingInspection()
  }

  function startPendingInspection() {
    if (!propertyPendingToken) return
    propertyInFlightToken = propertyPendingToken
    propertyInFlightRevision = metadataRevision
    propertyPendingToken = ""
    propertyStdout = ""
    propertyStderr = ""
    propertyProcess.command = ["/usr/bin/env", "python3", cliPath,
      "properties", "--path-token", propertyInFlightToken]
    propertyProcess.running = true
  }

  function runAction(kind, token, name) {
    if (actionBusy || !token) return false
    if (isCatalogToken(token)) {
      var offline = visibleEntryForToken(token)
      if (["open", "preview", "reveal"].indexOf(String(kind)) >= 0) requestOfflineEntry(offline)
      else offlineHint(offline)
      return false
    }
    actionKind = String(kind || "")
    actionStdout = ""
    actionStderr = ""
    actionMessage = ""
    var command = ["/usr/bin/env", "python3", cliPath,
      "action", actionKind, "--path-token", String(token)]
    if (name !== undefined && name !== null && String(name) !== "") {
      command.push("--name")
      command.push(String(name))
    }
    actionProcess.command = command
    actionProcess.running = true
    return true
  }

  function buildPreviewCommand(token) {
    return ["/usr/bin/env", "python3", cliPath,
      "preview", "--path-token", String(token || "")]
  }

  function clearPreview() {
    previewRevision++
    previewToken = ""
    previewPendingToken = ""
    previewData = null
    previewError = ""
  }

  function loadPreview(entry) {
    if (!entry || String(entry.token || "") === "") {
      clearPreview()
      previewError = "Select an item to preview"
      return false
    }
    if (isOfflineEntry(entry)) {
      clearPreview()
      requestOfflineEntry(entry)
      return false
    }
    var token = String(entry.token)
    previewRevision++
    previewToken = token
    previewData = null
    previewError = ""
    previewPendingToken = token
    if (!previewProcess.running) startPendingPreview()
    return true
  }

  function startPendingPreview() {
    if (previewProcess.running || previewPendingToken === "") return false
    previewInFlightToken = previewPendingToken
    previewInFlightRevision = previewRevision
    previewPendingToken = ""
    previewStdout = ""
    previewStderr = ""
    previewProcess.command = buildPreviewCommand(previewInFlightToken)
    previewProcess.running = true
    return true
  }

  function applyPreview(raw, token, revision) {
    // Selection can change while thumbnail/text extraction is running. Never
    // let that old result replace the preview for the newly selected entry.
    if (Number(revision) !== previewRevision || String(token || "") !== previewToken)
      return true
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (error) {
      previewError = "Preview returned invalid data"
      previewData = null
      return false
    }
    if (!parsed || parsed.ok !== true || !parsed.preview) {
      previewError = parsed && parsed.error ? String(parsed.error) : "Could not preview this file"
      previewData = null
      return false
    }
    previewData = parsed.preview
    previewError = ""
    return true
  }

  function runBatchAction(kind, tokens, destinationToken) {
    var values = (Array.isArray(tokens) ? tokens : [])
      .filter(function(token) { return !root.isCatalogToken(token) })
    if (actionBusy || values.length === 0 || isCatalogToken(destinationToken)) return false
    actionKind = String(kind || "")
    actionStdout = ""
    actionStderr = ""
    actionMessage = ""
    actionProcess.command = ["/usr/bin/env", "python3", cliPath,
      "action", actionKind, "--path-tokens-json", JSON.stringify(values)]
    if (destinationToken) {
      actionProcess.command.push("--destination-token")
      actionProcess.command.push(String(destinationToken))
    }
    actionProcess.running = true
    return true
  }

  function runTransfer(kind, sourceTokens, destinationToken) {
    if (!destinationToken) return false
    return runOperation(kind, sourceTokens, destinationToken)
  }

  function buildOperationCommand(request) {
    var command = ["/usr/bin/env", "python3", cliPath,
      "operation", String(request.kind || "")]
    var values = Array.isArray(request.tokens) ? request.tokens : []
    var uris = Array.isArray(request.trashUris) ? request.trashUris : []
    var sourceUris = Array.isArray(request.sourceUris) ? request.sourceUris : []
    if (values.length === 1) {
      command.push("--path-token")
      command.push(String(values[0]))
    } else if (values.length > 1) {
      command.push("--path-tokens-json")
      command.push(JSON.stringify(values))
    }
    if (sourceUris.length > 0) {
      command.push("--source-uris-json")
      command.push(JSON.stringify(sourceUris))
    }
    if (request.destinationToken) {
      command.push("--destination-token")
      command.push(String(request.destinationToken))
    }
    if (request.name !== undefined && request.name !== null && String(request.name) !== "") {
      command.push("--name")
      command.push(String(request.name))
    }
    if (uris.length === 1) {
      command.push("--trash-uri")
      command.push(String(uris[0]))
    } else if (uris.length > 1) {
      command.push("--trash-uris-json")
      command.push(JSON.stringify(uris))
    }
    command.push("--conflict-policy")
    command.push(String(request.conflictPolicy || "ask"))
    return command
  }

  function startOperationRequest(request) {
    if (actionBusy || !request) return false
    // Nothing on a drive that is away can be moved, copied or trashed, and
    // nothing can land in it; the rest of a mixed batch still runs.
    var requested = request.tokens || []
    var tokens = requested.filter(function(token) { return !root.isCatalogToken(token) })
    if (isCatalogToken(request.destinationToken)) return false
    if (requested.length > 0 && tokens.length === 0
        && (request.trashUris || []).length === 0 && (request.sourceUris || []).length === 0)
      return false
    pendingOperation = Object.assign({}, request, {
      tokens: tokens,
      trashUris: (request.trashUris || []).slice(),
      sourceUris: (request.sourceUris || []).slice()
    })
    operationConflicts = []
    actionKind = String(request.kind || "")
    actionMessage = ""
    operationPhase = "starting"
    operationProgress = -1
    operationItemsDone = 0
    operationItemsTotal = 0
    operationBytesDone = 0
    operationBytesTotal = 0
    operationCancelling = false
    operationResult = null
    operationStderr = ""
    operationProcess.command = buildOperationCommand(pendingOperation)
    operationProcess.running = true
    return true
  }

  function runOperation(kind, tokens, destinationToken, name, trashUris,
      conflictPolicy, sourceUris) {
    var values = Array.isArray(tokens) ? tokens : []
    var uris = Array.isArray(trashUris) ? trashUris : []
    var externalUris = Array.isArray(sourceUris) ? sourceUris : []
    if (String(kind || "") !== "undo" && values.length === 0
        && uris.length === 0 && externalUris.length === 0) return false
    return startOperationRequest({
      kind: String(kind || ""), tokens: values, destinationToken: String(destinationToken || ""),
      name: name === undefined || name === null ? "" : String(name), trashUris: uris,
      conflictPolicy: String(conflictPolicy || "ask"), sourceUris: externalUris
    })
  }

  function retryOperation(policy) {
    var value = String(policy || "")
    if (["keep-both", "skip", "merge", "replace"].indexOf(value) < 0
        || !pendingOperation || actionBusy) return false
    var request = Object.assign({}, pendingOperation, { conflictPolicy: value })
    return startOperationRequest(request)
  }

  function dismissOperationConflict() {
    if (operationBusy || !pendingOperation) return false
    pendingOperation = null
    operationConflicts = []
    if (operationResult && operationResult.code === "operation-conflict")
      operationResult = null
    return true
  }

  function boundedArgumentValues(values, maxLength) {
    if (!Array.isArray(values) || values.length === 0 || values.length > 500) return null
    var output = []
    var total = 0
    for (var i = 0; i < values.length; i++) {
      var value = String(values[i] || "")
      total += value.length
      if (value === "" || value.length > maxLength || total > 1048576) return null
      output.push(value)
    }
    return output
  }

  function dropOnDirectory(destinationToken, sourceTokens, move) {
    var destination = String(destinationToken || "")
    var values = boundedArgumentValues(sourceTokens, 8192)
    if (destination === "" || destination.length > 8192 || values === null
        || isCatalogToken(destination)) return false
    return runOperation(move === true ? "move" : "copy", values, destination)
  }

  function dropExternalUrisOnDirectory(destinationToken, sourceUris, move) {
    var destination = String(destinationToken || "")
    var supplied = boundedArgumentValues(sourceUris, 16384)
    if (destination === "" || destination.length > 8192 || supplied === null
        || isCatalogToken(destination)) return false
    var localUris = []
    for (var i = 0; i < supplied.length; i++) {
      var value = String(supplied[i] || "").trim()
      if (value.indexOf("file://") === 0) localUris.push(value)
    }
    if (localUris.length !== supplied.length) return false
    return runOperation(move === true ? "move" : "copy", [], destination,
      "", [], "ask", localUris)
  }

  function handleOperationEvent(raw) {
    var message = null
    try { message = JSON.parse(raw) } catch (error) { return }
    if (message.event === "result" || message.ok !== undefined) {
      operationResult = message
      return
    }
    if (message.event !== "progress") return
    operationPhase = String(message.phase || "working")
    operationItemsDone = Number(message.itemsDone || 0)
    operationItemsTotal = Number(message.itemsTotal || 0)
    operationBytesDone = Number(message.bytesDone || 0)
    operationBytesTotal = Number(message.bytesTotal || 0)
    if (operationBytesTotal > 0)
      operationProgress = Math.max(0, Math.min(1, operationBytesDone / operationBytesTotal))
    else if (operationItemsTotal > 0)
      operationProgress = Math.max(0, Math.min(1, operationItemsDone / operationItemsTotal))
    else operationProgress = -1
  }

  function applyOperationCompletion(result) {
    var conflict = result && result.code === "operation-conflict"
    if (conflict) {
      operationResult = result
      operationConflicts = Array.isArray(result.conflicts) ? result.conflicts : []
      conflictRequested(operationConflicts)
    } else {
      pendingOperation = null
      operationConflicts = []
    }
    return conflict
  }

  function measureFolder(token) {
    var value = String(token || "")
    if (value === "" || !initialized || isCatalogToken(value)) return false
    if (folderSizeProcess.running) {
      if (folderSizeToken === value) return false
      cancelFolderSize()
    }
    folderSizeToken = value
    folderSizeCancelling = false
    folderSizeBytes = 0
    folderSizeAllocated = 0
    folderSizeFiles = 0
    folderSizeDirectories = 0
    folderSizePath = ""
    folderSizeResult = null
    folderSizeError = ""
    folderSizeStarted = Date.now()
    folderSizeProcess.command = ["/usr/bin/env", "python3", cliPath,
      "directory-size", "--path-token", value]
    folderSizeProcess.running = true
    return true
  }

  function cancelFolderSize() {
    if (!folderSizeProcess.running || folderSizeCancelling) return false
    folderSizeCancelling = true
    folderSizeProcess.signal(15)
    return true
  }

  function clearFolderSize() {
    if (folderSizeProcess.running) cancelFolderSize()
    folderSizeToken = ""
    folderSizeResult = null
    folderSizeError = ""
    folderSizeBytes = 0
    folderSizeAllocated = 0
    folderSizeFiles = 0
    folderSizeDirectories = 0
    folderSizePath = ""
  }

  function handleFolderSizeEvent(line) {
    var parsed = null
    try { parsed = JSON.parse(String(line || "")) } catch (error) { return }
    if (!parsed) return
    if (parsed.event === "progress") {
      folderSizeBytes = Number(parsed.bytesDone) || 0
      folderSizeAllocated = Number(parsed.allocated) || 0
      folderSizeFiles = Number(parsed.files) || 0
      folderSizeDirectories = Number(parsed.directories) || 0
      folderSizePath = String(parsed.path || "")
      return
    }
    if (parsed.ok === true) {
      folderSizeResult = parsed
      folderSizeBytes = Number(parsed.size) || 0
      folderSizeAllocated = Number(parsed.allocatedSize) || 0
      folderSizeFiles = Number(parsed.files) || 0
      folderSizeDirectories = Number(parsed.directories) || 0
    } else if (parsed.error) {
      folderSizeError = String(parsed.error)
    }
  }

  function cancelOperation() {
    if (!operationProcess.running || operationCancelling) return false
    operationCancelling = true
    actionMessage = "Cancelling…"
    operationProcess.signal(15)
    return true
  }

  function reloadTrash() {
    if (trashProcess.running) {
      trashReloadPending = true
      return false
    }
    trashStdout = ""
    trashStderr = ""
    trashError = ""
    trashProcess.command = ["/usr/bin/env", "python3", cliPath, "trash-list"]
    trashProcess.running = true
    return true
  }

  function reloadHistory() {
    if (historyProcess.running) {
      historyReloadPending = true
      return false
    }
    historyStdout = ""
    historyStderr = ""
    historyProcess.command = ["/usr/bin/env", "python3", cliPath, "history"]
    historyProcess.running = true
    return true
  }

  function restoreTrash(uri) { return runOperation("restore", [], "", "", [uri]) }
  function permanentlyDeleteTrash(uri) {
    return runOperation("trash-delete", [], "", "", [uri])
  }
  function undoLast() { return runOperation("undo", [], "", "", []) }

  function copySelected() {
    if (!selectedEntry || !selectedToken) return false
    var tokens = effectiveSelectionTokens()
    if (tokens.length === 0) return refuseOfflineSelection()
    clipboardMode = "copy"
    clipboardTokens = tokens
    clipboardToken = tokens.length > 0 ? String(tokens[0]) : ""
    var copiedEntry = tokens.length === 1 ? visibleEntryForToken(tokens[0]) : null
    clipboardName = tokens.length === 1 ? String(copiedEntry ? copiedEntry.name : "item")
      : tokens.length + " items"
    announce("Copied “" + clipboardName + "”" + offlineSelectionNote())
    return true
  }

  function cutSelected() {
    if (!selectedEntry || !selectedToken) return false
    var tokens = effectiveSelectionTokens()
    if (tokens.length === 0) return refuseOfflineSelection()
    clipboardMode = "cut"
    clipboardTokens = tokens
    clipboardToken = tokens.length > 0 ? String(tokens[0]) : ""
    var cutEntry = tokens.length === 1 ? visibleEntryForToken(tokens[0]) : null
    clipboardName = tokens.length === 1 ? String(cutEntry ? cutEntry.name : "item")
      : tokens.length + " items"
    announce("Cut “" + clipboardName + "”" + offlineSelectionNote())
    return true
  }

  function pasteHere() {
    if (!clipboardToken || !rootToken) return false
    return runTransfer(clipboardMode === "cut" ? "move" : "copy",
      clipboardTokens, rootToken)
  }

  function clearClipboard() {
    clipboardMode = ""
    clipboardToken = ""
    clipboardTokens = []
    clipboardName = ""
  }

  function createFile(name) { return runAction("touch", rootToken, name) }
  function createFolder(name) { return runAction("mkdir", rootToken, name) }
  function renameSelected(name) {
    if (isCatalogToken(selectedToken)) return refuseOfflineSelection()
    return runOperation("rename", [selectedToken], "", name)
  }
  function trashSelected() {
    var tokens = effectiveSelectionTokens()
    return tokens.length === 0 ? refuseOfflineSelection()
      : runSelectionOperation("trash", tokens)
  }
  function openSelected() { return runAction("open", selectedToken) }
  function revealSelected() { return runAction("reveal", selectedToken) }
  function previewSelected() {
    return previewEntry(selectedEntry)
  }

  function previewEntry(entry) {
    return loadPreview(entry)
  }
  function openPreviewExternally(entry) {
    var target = entry || selectedEntry
    if (isOfflineEntry(target)) return requestOfflineEntry(target)
    return target && target.isDir !== true
      ? runAction("preview", String(target.token || "")) : false
  }
  function copySelectedPath() { return runAction("copy-path", selectedToken) }
  function duplicateSelected() {
    var tokens = effectiveSelectionTokens()
    return tokens.length === 0 ? refuseOfflineSelection()
      : runSelectionOperation("duplicate", tokens)
  }

  // Colours, notes and stars are kept per path; a drive that is away has none.
  function saveEntryMetadata(entry, color, note, starred) {
    if (actionBusy || !entry || !entry.token) return false
    if (isOfflineEntry(entry)) return refuseOffline(entry)
    actionKind = "metadata"
    actionMetadataToken = String(entry.token)
    actionStdout = ""
    actionStderr = ""
    actionMessage = ""
    actionProcess.command = ["/usr/bin/env", "python3", cliPath,
      "metadata", "--path-token", String(entry.token),
      "--color", String(color || ""),
      "--note", String(note || ""),
      "--starred", starred === true ? "true" : "false"]
    actionProcess.running = true
    return true
  }

  function saveSelectedMetadata(color, note, starred) {
    return saveEntryMetadata(selectedEntry, color, note, starred)
  }

  function saveEntryKnowledge(entry, registered, agents) {
    if (actionBusy || !entry || !entry.token || entry.isDir === true)
      return false
    if (isOfflineEntry(entry)) return refuseOffline(entry)
    var values = Array.isArray(agents) ? agents : []
    actionKind = "metadata"
    actionMetadataToken = String(entry.token)
    actionStdout = ""
    actionStderr = ""
    actionMessage = ""
    actionProcess.command = ["/usr/bin/env", "python3", cliPath,
      "metadata", "--path-token", String(entry.token),
      "--knowledge", registered === true ? "true" : "false",
      "--agents-json", JSON.stringify(registered === true ? values : [])]
    actionProcess.running = true
    return true
  }

  function saveSelectedKnowledge(registered, agents) {
    return saveEntryKnowledge(selectedEntry, registered, agents)
  }

  function appendKnowledgeLinkRoot(command) {
    if (rootToken !== "") {
      command.push("--root-token")
      command.push(rootToken)
    } else {
      command.push("--root")
      command.push(rootPath)
    }
  }

  function previewSelectedKnowledgeLinks() {
    if (actionBusy || !selectedEntry || !selectedEntry.token
        || selectedEntry.isDir === true) return false
    if (isOfflineEntry(selectedEntry)) return refuseOfflineSelection()
    knowledgeLinkPlan = null
    knowledgeLinkError = ""
    knowledgeLinkStdout = ""
    knowledgeLinkStderr = ""
    knowledgeLinkApplying = false
    var command = ["/usr/bin/env", "python3", cliPath,
      "knowledge-links", "--source-token", String(selectedEntry.token)]
    appendKnowledgeLinkRoot(command)
    knowledgeLinksProcess.command = command
    knowledgeLinksProcess.running = true
    return true
  }

  function applyKnowledgeLinks() {
    if (actionBusy || !knowledgeLinkPlan || !knowledgeLinkPlan.sourceToken)
      return false
    knowledgeLinkError = ""
    knowledgeLinkStdout = ""
    knowledgeLinkStderr = ""
    knowledgeLinkApplying = true
    var command = ["/usr/bin/env", "python3", cliPath,
      "knowledge-links", "--source-token", String(knowledgeLinkPlan.sourceToken),
      "--apply"]
    appendKnowledgeLinkRoot(command)
    knowledgeLinksProcess.command = command
    knowledgeLinksProcess.running = true
    return true
  }

  function toggleFavoriteEntry(entry) {
    if (!entry) return false
    if (isOfflineEntry(entry)) return refuseOffline(entry)
    return saveEntryMetadata(entry, String(entry.color || ""), String(entry.note || ""),
      entry.starred !== true)
  }

  function applySavedMetadata(token, values) {
    metadataRevision++
    function updated(entry) {
      if (!entry || String(entry.token || "") !== token) return entry
      return Object.assign({}, entry, values)
    }
    listingAboutToChange()
    var nextEntries = entries.map(updated)
    var nextFavorites = favorites.map(updated)
    var nextKnowledge = knowledgeFiles.map(updated)
    reconcileRows(fileRows, entries, nextEntries)
    reconcileRows(favoriteRows, favorites, nextFavorites)
    reconcileRows(knowledgeRows, knowledgeFiles, nextKnowledge)
    entries = nextEntries
    favorites = nextFavorites
    knowledgeFiles = nextKnowledge
    selectedEntry = updated(selectedEntry)
    selectedProperties = updated(selectedProperties)
    modelChanged()
    metadataSaved(token, values)
  }

  Timer {
    id: eventRefresh
    interval: 100
    onTriggered: {
      if (!root.panelVisible || root.operationBusy) return
      // A file event changes no catalog: the catalog rows on screen stay.
      root.refreshAll(true, true)
      if (root.selectedToken !== "") root.inspect(root.selectedToken)
    }
  }

  Timer {
    id: watchStartupTimeout
    interval: 5000
    onTriggered: {
      if (!root.panelVisible || root.watcherReady) return
      root.watchError = "File monitor did not become ready; using background fallback"
      root.watcherFailed = true
    }
  }

  Timer {
    id: semanticLoadTimeout
    interval: 60000
    onTriggered: {
      if (!root.semanticHelperReady && root.semanticShouldRun) {
        root.semanticHelperFailed = true
        root.semanticState = "failed"
        root.semanticError = "Smart-search model did not load in time"
        root.useSmartFallback("load-timeout")
      }
    }
  }

  Timer {
    id: semanticInferenceTimeout
    interval: 5000
    onTriggered: {
      if (root.searchMode === "smart" && root.semanticPendingQuery === String(root.query || "").trim()) {
        root.semanticState = root.semanticHelperReady ? "ready" : "failed"
        root.semanticError = "Smart-search analysis timed out"
        root.useSmartFallback("timeout")
      }
    }
  }

  Timer {
    interval: root.fallbackRefreshInterval
    repeat: true
    running: root.panelVisible && root.initialized
      && (!root.watcherReady || root.watcherDegraded || root.watchTruncated)
    onTriggered: root.refreshAll(true, true)
  }

  Timer {
    interval: 8000
    repeat: true
    running: root.panelVisible && root.initialized && root.settingsLoaded
      && root.activeSessionsEnabled
    onTriggered: root.reloadSessions()
  }

  Process {
    id: watchProcess
    command: ["/usr/bin/python3", root.pluginDir + "/bin/quickfile-watch"]
    stdinEnabled: true
    running: root.panelVisible && root.initialized && !root.watcherFailed
      && !root.watcherStopping
    onStarted: root.sendWatchConfiguration()
    stdout: SplitParser { onRead: function(data) { root.handleWatchEvent(data) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") root.watchError = text.trim().slice(-1000)
    }
    onExited: {
      root.watcherReady = false
      watchStartupTimeout.stop()
      if (root.watcherStopping) {
        // Defer starting a replacement until the old exit handler is done.
        // The running binding restarts only if the panel has already reopened.
        Qt.callLater(function() { root.watcherStopping = false })
      } else if (root.panelVisible && root.initialized) {
        root.watcherFailed = true
        if (!root.watchError) root.watchError = "File monitor stopped; using background fallback"
      }
    }
  }

  Process {
    id: semanticStatusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.semanticStatusStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.semanticStatusStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (!root.applySemanticStatus(root.semanticStatusStdout) && !root.semanticError)
        root.semanticError = root.semanticStatusStderr.trim()
          || ("Smart-search status exited " + exitCode)
    }
  }

  Process {
    id: semanticSetupProcess
    stdout: SplitParser {
      onRead: function(data) { root.handleSemanticSetupEvent(data) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.semanticSetupStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.semanticState !== "failed") {
        root.semanticState = "failed"
        root.semanticError = root.semanticSetupStderr.trim()
          || ("Smart-search setup exited " + exitCode)
      }
      root.semanticSetupAction = ""
      if (exitCode === 0) Qt.callLater(root.reloadSemanticStatus)
    }
  }

  Process {
    id: semanticProcess
    command: root.semanticPythonPath !== ""
      ? [root.semanticPythonPath, root.semanticCliPath, "serve"] : []
    stdinEnabled: true
    running: root.semanticShouldRun
    onStarted: {
      root.semanticHelperReady = false
      root.semanticState = "loading"
      root.semanticError = ""
      semanticLoadTimeout.restart()
    }
    stdout: SplitParser {
      onRead: function(data) { root.handleSemanticEvent(data) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.semanticHelperStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var unexpected = root.panelVisible && root.searchMode === "smart"
        && root.semanticSessionActive && root.semanticInstalled
        && !root.semanticSetupBusy && !root.semanticHelperFailed
      root.semanticHelperReady = false
      semanticLoadTimeout.stop()
      semanticInferenceTimeout.stop()
      if (unexpected) {
        root.semanticHelperFailed = true
        root.semanticState = "failed"
        // Prefer the helper's own error event over its stderr tail.
        root.semanticError = root.semanticError || root.semanticHelperStderr.trim()
          || ("Smart-search helper exited " + exitCode)
        root.useSmartFallback("helper-exited")
      } else if (root.semanticInstalled && root.semanticState !== "failed") {
        root.semanticState = "installed"
      }
    }
  }

  IpcHandler {
    target: "quickfile"
    function status(): string {
      return JSON.stringify({
        visible: root.panelVisible, watching: root.watcherReady,
        fallback: root.watcherDegraded || root.watcherFailed || root.watchTruncated,
        watchError: root.watchError, busy: root.busy,
        foregroundBusy: root.foregroundBusy, entries: root.entries.length,
        listingRequests: root.listingRequests, listingChanges: root.listingChanges,
        foregroundListingPending: root.foregroundListingPending,
        activeSessionsEnabled: root.activeSessionsEnabled,
        activeSessions: root.activeSessions.length,
        inspectorTab: root.inspectorTab,
        sortOrder: root.sortOrder,
        dateFormat: root.dateFormat,
        smartInstalled: root.semanticInstalled,
        smartState: root.semanticState,
        smartModel: root.semanticModel,
        smartDevice: root.semanticDevice,
        smartFallback: root.semanticFallback,
        smartSession: root.semanticSessionActive,
        smartOnboardingDone: root.smartOnboardingDone,
        catalogVolumes: root.catalogVolumeCount,
        offlineVolumes: root.offlineVolumeCount,
        catalogIndexBusy: root.catalogIndexBusy,
        catalogIndexDevice: root.catalogIndexDevice,
        offlineMatches: root.offlineMatchCount,
        offlineSearchEnabled: root.offlineSearchEnabled,
        moduleLayout: root.moduleLayout
      })
    }
  }

  Process {
    id: settingsLoadProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.settingsStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.settingsStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (!root.applySettings(root.settingsStdout)) {
        root.moduleLayout = root.defaultModuleLayout()
        root.activeSessionsEnabled = false
        root.inspectorTab = "properties"
        root.applyModuleCollapseFlags()
        root.settingsLoaded = true
        if (!root.settingsError)
          root.settingsError = root.settingsStderr.trim() || ("Settings exited " + exitCode)
      }
    }
  }

  Process {
    id: settingsSaveProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.settingsStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.settingsStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(root.settingsStdout) } catch (error) {}
      if (exitCode !== 0 || !parsed || parsed.ok !== true)
        root.settingsError = parsed && parsed.error ? String(parsed.error)
          : (root.settingsStderr.trim() || "Could not save QuickFile settings")
      if (root.settingsSaveQueued) Qt.callLater(root.persistSettings)
    }
  }

  Process {
    id: sessionsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sessionsStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sessionsStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (root.activeSessionsEnabled && root.panelVisible
          && !root.applySessions(root.sessionsStdout) && !root.sessionsError)
        root.sessionsError = root.sessionsStderr.trim()
          || ("AI session scan exited " + exitCode)
      if (root.sessionsReloadPending && root.activeSessionsEnabled && root.panelVisible) {
        root.sessionsReloadPending = false
        Qt.callLater(root.reloadSessions)
      }
    }
  }

  Process {
    id: listingProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.listStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.listStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (!root.applyListing(root.listStdout) && !root.errorMessage)
        root.errorMessage = root.listStderr.trim() || ("QuickFile exited " + exitCode)
      var keepForegroundPending = root.reloadPending && root.reloadPendingForeground
      if (!root.listInFlightBackground && !keepForegroundPending)
        root.foregroundListingPending = false
      if (root.reloadPending) {
        var foreground = root.reloadPendingForeground
        var withCatalog = root.reloadPendingCatalog
        root.reloadPending = false
        root.reloadPendingForeground = false
        root.reloadPendingCatalog = false
        Qt.callLater(function() { root.reload(!foreground, !withCatalog) })
      }
    }
  }

  Process {
    id: propertyProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.propertyStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.propertyStderr = text.slice(-2000)
    }
    onExited: function() {
      if (root.propertyInFlightToken === root.selectedToken
          && root.propertyInFlightRevision === root.metadataRevision) {
        try {
          var parsed = JSON.parse(root.propertyStdout)
          root.selectedProperties = parsed && parsed.ok === true
            ? parsed.properties : null
        } catch (error) {
          root.selectedProperties = null
        }
      }
      root.propertyInFlightToken = ""
      if (root.propertyPendingToken) Qt.callLater(root.startPendingInspection)
    }
  }

  Process {
    id: volumesProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumesStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumesStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (!root.applyVolumes(root.volumesStdout) && !root.volumesError)
        root.volumesError = root.volumesStderr.trim()
          || ("Storage scan exited " + exitCode)
      if (root.volumesReloadPending) {
        root.volumesReloadPending = false
        Qt.callLater(root.reloadVolumes)
      }
    }
  }

  Process {
    id: volumeActionProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeActionStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeActionStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var kind = root.volumeActionKind
      var previousMountPath = root.volumeActionMountPath
      var navigateAfter = root.volumeActionNavigate
      var parsed = null
      try { parsed = JSON.parse(root.volumeActionStdout) } catch (error) {}
      var ok = exitCode === 0 && parsed && parsed.ok === true
      var message = ok ? String(parsed.message || "Done")
        : (parsed && parsed.error ? String(parsed.error)
          : (root.volumeActionStderr.trim() || "External drive action failed"))
      root.actionMessage = message
      root.volumeActionKind = ""
      root.volumeActionDevice = ""
      root.volumeActionMountPath = ""
      root.volumeActionNavigate = true
      if (ok && kind === "mount" && navigateAfter && parsed.volume
          && String(parsed.volume.mountPath || "") !== "") {
        root.navigate(String(parsed.volume.mountPath),
          String(parsed.volume.mountToken || ""), true)
      } else if (ok && kind === "unmount"
          && root.pathInsideMount(root.rootPath, previousMountPath)) {
        root.goHome()
      }
      root.actionFinished("volume-" + kind, ok, message)
      Qt.callLater(root.reloadVolumes)
    }
  }

  Process {
    id: knowledgeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.knowledgeStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.knowledgeStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (!root.applyKnowledge(root.knowledgeStdout) && !root.knowledgeError)
        root.knowledgeError = root.knowledgeStderr.trim()
          || ("Knowledge index exited " + exitCode)
      if (root.knowledgeReloadPending) {
        root.knowledgeReloadPending = false
        Qt.callLater(root.reloadKnowledge)
      }
    }
  }

  Process {
    id: knowledgeLinksProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.knowledgeLinkStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.knowledgeLinkStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var wasApplying = root.knowledgeLinkApplying
      var parsed = null
      try { parsed = JSON.parse(root.knowledgeLinkStdout) } catch (error) {}
      var ok = exitCode === 0 && parsed && parsed.ok === true
      var message = ok ? String(parsed.message || "Done")
        : (parsed && parsed.error ? String(parsed.error)
          : (root.knowledgeLinkStderr.trim() || "Could not prepare knowledge links"))
      if (ok) {
        root.knowledgeLinkPlan = parsed
        root.knowledgeLinkError = ""
        root.actionMessage = message
        if (wasApplying) Qt.callLater(root.refreshAll)
      } else {
        root.knowledgeLinkError = message
      }
      root.knowledgeLinkApplying = false
      root.knowledgeLinksFinished(ok, wasApplying, message)
    }
  }

  Process {
    id: trashProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.trashStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.trashStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(root.trashStdout) } catch (error) {}
      if (exitCode === 0 && parsed && parsed.ok === true) {
        root.trashEntries = Array.isArray(parsed.entries) ? parsed.entries : []
        root.trashError = ""
      } else {
        root.trashError = parsed && parsed.error ? String(parsed.error)
          : (root.trashStderr.trim() || "Could not read Trash")
      }
      if (root.trashReloadPending) {
        root.trashReloadPending = false
        Qt.callLater(root.reloadTrash)
      }
    }
  }

  Process {
    id: historyProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.historyStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.historyStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(root.historyStdout) } catch (error) {}
      if (exitCode === 0 && parsed && parsed.ok === true) {
        root.undoAvailable = parsed.undoAvailable === true
        root.undoId = parsed.operation ? String(parsed.operation.id || "") : ""
        root.undoLabel = parsed.operation ? String(parsed.operation.label || "") : ""
      }
      if (root.historyReloadPending) {
        root.historyReloadPending = false
        Qt.callLater(root.reloadHistory)
      }
    }
  }

  Process {
    id: quickNavProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.quickNavStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.quickNavStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (!root.applyQuickNav(root.quickNavStdout) && !root.quickNavError)
        root.quickNavError = root.quickNavStderr.trim() || ("Quick Nav exited " + exitCode)
      if (root.quickNavRecordPending) {
        var token = root.quickNavRecordToken
        var path = root.quickNavRecordPath
        root.quickNavRecordPending = false
        Qt.callLater(function() { root.recordRecentLocation(token, path) })
      } else if (root.quickNavReloadPending) {
        root.quickNavReloadPending = false
        Qt.callLater(root.reloadQuickNav)
      }
    }
  }

  Process {
    id: quickNavRecordProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.quickNavStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.quickNavStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.quickNavStderr.trim() !== "")
        root.quickNavError = root.quickNavStderr.trim()
      if (root.quickNavRecordPending) {
        var token = root.quickNavRecordToken
        var path = root.quickNavRecordPath
        root.quickNavRecordPending = false
        Qt.callLater(function() { root.recordRecentLocation(token, path) })
      } else {
        root.quickNavReloadPending = false
        if (!root.applyQuickNav(root.quickNavStdout) && !root.quickNavError)
          root.quickNavError = root.quickNavStderr.trim() || ("Quick Nav record exited " + exitCode)
      }
    }
  }

  Process {
    id: previewProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.previewStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.previewStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var token = root.previewInFlightToken
      var revision = root.previewInFlightRevision
      var isCurrent = token === root.previewToken && revision === root.previewRevision
      if (!root.applyPreview(root.previewStdout, token, revision) && isCurrent
          && root.previewError === "")
        root.previewError = root.previewStderr.trim() || ("Preview exited " + exitCode)
      root.previewInFlightToken = ""
      if (root.previewPendingToken !== "") Qt.callLater(root.startPendingPreview)
    }
  }

  Process {
    id: operationProcess
    stdout: SplitParser {
      onRead: function(data) { root.handleOperationEvent(data) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.operationStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var parsed = root.operationResult
      var kind = root.actionKind
      var ok = exitCode === 0 && parsed && parsed.ok === true
      var offlineNote = root.pendingOperation
        ? String(root.pendingOperation.offlineNote || "") : ""
      var message = ok ? String(parsed.message || "Done") + offlineNote
        : (parsed && parsed.error ? String(parsed.error)
          : (root.operationStderr.trim() || (root.operationCancelling
            ? "Operation cancelled" : "Action failed")))
      root.actionMessage = message
      root.operationPhase = ""
      root.operationProgress = -1
      root.operationCancelling = false
      root.actionKind = ""
      root.applyOperationCompletion(parsed)
      if (ok && kind === "move") root.clearClipboard()
      root.actionFinished(kind, ok, message)
      Qt.callLater(root.reloadHistory)
      Qt.callLater(root.reloadTrash)
      // A cancelled or failed batch can still have completed earlier items.
      Qt.callLater(root.refreshAll)
    }
  }

  Process {
    id: folderSizeProcess
    stdout: SplitParser {
      onRead: function(data) { root.handleFolderSizeEvent(data) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.folderSizeResult && text.trim() !== "")
          root.folderSizeError = text.slice(-400).trim()
      }
    }
    onExited: function(exitCode) {
      // A cancelled walk keeps the partial numbers on screen; they are still
      // a true floor for the folder, just not the whole of it.
      if (exitCode !== 0 && !root.folderSizeResult && root.folderSizeError === "")
        root.folderSizeError = root.folderSizeCancelling ? "" : "Could not measure the folder"
      root.folderSizeCancelling = false
    }
  }

  Process {
    id: catalogIndexProcess
    stdout: SplitParser {
      onRead: function(data) { root.handleCatalogIndexEvent(data) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.catalogIndexStderr = text.slice(-400)
    }
    onExited: function(exitCode) { root.finishCatalogIndex(exitCode) }
  }

  // SIGTERM is honoured between entries. A walk stuck in a pulled drive's I/O
  // never reaches the next check, so it is killed outright after a grace period.
  Timer {
    id: catalogIndexKillTimer
    interval: 5000
    onTriggered: root.escalateCatalogIndexCancel()
  }

  Process {
    id: catalogForgetProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.catalogForgetStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.catalogForgetStderr = text.slice(-2000)
    }
    onExited: function(exitCode) { root.finishCatalogForget(exitCode) }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionStderr = text.slice(-2000)
    }
    onExited: function(exitCode) {
      var parsed = null
      try { parsed = JSON.parse(root.actionStdout) } catch (error) {}
      var ok = exitCode === 0 && parsed && parsed.ok === true
      var message = ok ? String(parsed.message || "Done") : (parsed && parsed.error
        ? String(parsed.error) : (root.actionStderr.trim() || "Action failed"))
      root.actionMessage = message
      if (ok && root.actionKind === "metadata" && parsed.metadata)
        root.applySavedMetadata(root.actionMetadataToken, parsed.metadata)
      root.actionFinished(root.actionKind, ok, message)
      var kind = root.actionKind
      root.actionKind = ""
      if (ok && kind === "move") root.clearClipboard()
      if (ok && kind === "metadata" && root.selectedToken !== "")
        Qt.callLater(function() { root.inspect(root.selectedToken) })
      if (ok && kind !== "open" && kind !== "reveal"
          && kind !== "preview" && kind !== "copy-path")
        Qt.callLater(root.refreshAll)
    }
  }
}
