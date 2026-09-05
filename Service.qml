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
  readonly property string homePath: Quickshell.env("HOME") || "/"
  // Only used if native monitoring is unavailable or its watch limit is hit.
  readonly property int fallbackRefreshInterval: 30000

  property bool initialized: false
  property bool panelVisible: false
  property bool busy: listingProcess.running
  readonly property bool foregroundBusy: busy && !listInFlightBackground
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
  property string query: ""
  property string searchMode: "fuzzy"
  property bool caseSensitive: false
  property bool truncated: false
  property string searchEngine: ""
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
    }
  }

  function ensureLoaded() {
    if (!settingsLoaded && !settingsLoadProcess.running) reloadSettings()
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

  function rowKey(row) {
    return String(row.token || row.device || row.sessionKey || "")
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

  function buildListCommand() {
    var trimmed = String(query || "").trim()
    var command = ["/usr/bin/env", "python3", cliPath,
      trimmed === "" ? "tree" : "search"]
    rootArgument(command)
    if (showHidden) command.push("--show-hidden")
    if (trimmed === "") {
      for (var i = 0; i < expandedTokens.length; i++) {
        command.push("--expanded")
        command.push(String(expandedTokens[i]))
      }
    } else {
      command.push("--query")
      command.push(trimmed)
      command.push("--mode")
      command.push(searchMode)
      if (caseSensitive) command.push("--case-sensitive")
    }
    return command
  }

  function reload(background) {
    var silent = background === true
    if (silent && !panelVisible) return false
    if (listingProcess.running) {
      reloadPending = true
      reloadPendingForeground = reloadPendingForeground || !silent
      return false
    }
    listStdout = ""
    listStderr = ""
    errorMessage = ""
    listInFlightRootToken = rootToken
    listInFlightRootPath = rootPath
    listInFlightBackground = silent
    listInFlightRevision = metadataRevision
    listingProcess.command = buildListCommand()
    listInFlightCommand = JSON.stringify(listingProcess.command)
    listingRequests++
    listingProcess.running = true
    return true
  }

  function refreshAll(background) {
    var listingStarted = reload(background === true)
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
    settingsSaveProcess.command = ["/usr/bin/env", "python3", cliPath, "settings",
      "--active-sessions", activeSessionsEnabled ? "true" : "false",
      "--module-layout-json", JSON.stringify(moduleLayout)]
    settingsSaveProcess.running = true
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
    if (!sameData(volumes, nextVolumes)) {
      listingAboutToChange()
      reconcileRows(volumeRows, volumes, nextVolumes)
      volumes = nextVolumes
      modelChanged()
    }
    volumesError = ""
    return true
  }

  function pathInsideMount(path, mountPath) {
    var value = String(path || "")
    var mount = String(mountPath || "")
    if (value === "" || mount === "") return false
    return value === mount || value.indexOf(mount.replace(/\/$/, "") + "/") === 0
  }

  function openVolume(volume) {
    if (!volume || volumeActionProcess.running) return false
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
    return runVolumeAction("unmount", volume)
  }

  function runVolumeAction(kind, volume) {
    if (volumeActionProcess.running || !volume || !volume.device) return false
    volumeActionKind = String(kind || "")
    volumeActionDevice = String(volume.device || "")
    volumeActionMountPath = String(volume.mountPath || "")
    volumeActionStdout = ""
    volumeActionStderr = ""
    actionMessage = ""
    volumeActionProcess.command = ["/usr/bin/env", "python3", cliPath,
      "volume-action", volumeActionKind, "--device", volumeActionDevice]
    volumeActionProcess.running = true
    return true
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
    if (listInFlightRevision !== metadataRevision
        || listInFlightCommand !== JSON.stringify(buildListCommand())) {
      reloadPending = true
      reloadPendingForeground = reloadPendingForeground || !listInFlightBackground
      return true
    }
    var nextEntries = Array.isArray(parsed.entries) ? parsed.entries : []
    var nextFavorites = Array.isArray(parsed.favorites) ? parsed.favorites : []
    var nextGit = parsed.git || ({ root: "", branch: "" })
    var changed = !sameData(entries, nextEntries) || !sameData(favorites, nextFavorites)
      || !sameData(git, nextGit) || truncated !== (parsed.truncated === true)
      || searchEngine !== String(parsed.engine || "")
    var anchorToken = selectionAnchorIndex >= 0 && selectionAnchorIndex < entries.length
      ? String(entries[selectionAnchorIndex].token || "") : ""
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
    truncated = parsed.truncated === true
    searchEngine = String(parsed.engine || "")
    errorMessage = ""

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
    if (!sameData(selectedEntry, selected)) selectedEntry = selected
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
    }
    if (changed) {
      listingChanges++
      modelChanged()
    }
    listWatch = parsed.watch || null
    syncWatchConfiguration()
    if (recordNavigationOnListing) {
      recordNavigationOnListing = false
      recordRecentLocation(rootToken, rootPath)
    }
    if (knowledgeRootToken !== rootToken) Qt.callLater(root.reloadKnowledge)
    return true
  }

  function location() {
    return ({ path: rootPath, token: rootToken })
  }

  function navigate(path, token, recordHistory) {
    var nextPath = String(path || "")
    var nextToken = String(token || "")
    if (!nextPath && !nextToken) return false
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
    query = String(text || "")
    if (mode) searchMode = String(mode)
    reload()
  }

  function toggleExpanded(token) {
    var value = String(token || "")
    if (!value) return
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

  function effectiveSelectionTokens(anchorToken) {
    var hasExplicitAnchor = anchorToken !== undefined && anchorToken !== null
      && String(anchorToken) !== ""
    var anchor = String(hasExplicitAnchor ? anchorToken : (selectedToken || ""))
    if (!hasExplicitAnchor && selectedTokens.length > 0)
      return selectedTokens.slice()
    if (anchor !== "" && isSelected(anchor) && selectedTokens.length > 0)
      return selectedTokens.slice()
    return anchor === "" ? [] : [anchor]
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
    if (entry.isDir === true) toggleExpanded(entry.token)
    else runAction("open", entry.token)
  }

  function enterIndex(index) {
    if (index < 0 || index >= entries.length) return
    var entry = entries[index]
    if (entry.isDir === true) {
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
    if (entry.isDir === true) {
      var now = Date.now()
      if (now < navigationBlockedUntil) return false
      navigationBlockedUntil = now + 450
      return navigate(entry.path, entry.token, true)
    }
    return runAction("open", entry.token)
  }

  function inspect(token) {
    propertyPendingToken = String(token || "")
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
    var values = Array.isArray(tokens) ? tokens : []
    if (actionBusy || values.length === 0) return false
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
    pendingOperation = Object.assign({}, request, {
      tokens: (request.tokens || []).slice(),
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
    if (destination === "" || destination.length > 8192 || values === null) return false
    return runOperation(move === true ? "move" : "copy", values, destination)
  }

  function dropExternalUrisOnDirectory(destinationToken, sourceUris, move) {
    var destination = String(destinationToken || "")
    var supplied = boundedArgumentValues(sourceUris, 16384)
    if (destination === "" || destination.length > 8192 || supplied === null) return false
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
    clipboardMode = "copy"
    clipboardTokens = tokens
    clipboardToken = tokens.length > 0 ? String(tokens[0]) : ""
    var copiedEntry = tokens.length === 1 ? visibleEntryForToken(tokens[0]) : null
    clipboardName = tokens.length === 1 ? String(copiedEntry ? copiedEntry.name : "item")
      : tokens.length + " items"
    actionMessage = "Copied “" + clipboardName + "”"
    return true
  }

  function cutSelected() {
    if (!selectedEntry || !selectedToken) return false
    var tokens = effectiveSelectionTokens()
    clipboardMode = "cut"
    clipboardTokens = tokens
    clipboardToken = tokens.length > 0 ? String(tokens[0]) : ""
    var cutEntry = tokens.length === 1 ? visibleEntryForToken(tokens[0]) : null
    clipboardName = tokens.length === 1 ? String(cutEntry ? cutEntry.name : "item")
      : tokens.length + " items"
    actionMessage = "Cut “" + clipboardName + "”"
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
    return runOperation("rename", [selectedToken], "", name)
  }
  function trashSelected() { return runOperation("trash", effectiveSelectionTokens()) }
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
    return target && target.isDir !== true
      ? runAction("preview", String(target.token || "")) : false
  }
  function copySelectedPath() { return runAction("copy-path", selectedToken) }
  function duplicateSelected() {
    return runOperation("duplicate", effectiveSelectionTokens())
  }

  function saveEntryMetadata(entry, color, note, starred) {
    if (actionBusy || !entry || !entry.token) return false
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
      root.refreshAll(true)
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
    interval: root.fallbackRefreshInterval
    repeat: true
    running: root.panelVisible && root.initialized
      && (!root.watcherReady || root.watcherDegraded || root.watchTruncated)
    onTriggered: root.refreshAll(true)
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

  IpcHandler {
    target: "quickfile"
    function status(): string {
      return JSON.stringify({
        visible: root.panelVisible, watching: root.watcherReady,
        fallback: root.watcherDegraded || root.watcherFailed || root.watchTruncated,
        watchError: root.watchError, busy: root.busy,
        foregroundBusy: root.foregroundBusy, entries: root.entries.length,
        listingRequests: root.listingRequests, listingChanges: root.listingChanges,
        activeSessionsEnabled: root.activeSessionsEnabled,
        activeSessions: root.activeSessions.length,
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
      if (root.reloadPending) {
        var foreground = root.reloadPendingForeground
        root.reloadPending = false
        root.reloadPendingForeground = false
        Qt.callLater(function() { root.reload(!foreground) })
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
      if (ok && kind === "mount" && parsed.volume
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
      var message = ok ? String(parsed.message || "Done")
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
