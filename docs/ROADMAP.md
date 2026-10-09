# QuickFile roadmap

## 0.1 — filesystem blade (complete)

The vertical slice proves the integration boundary: a native Omarchy panel and
bar widget, a focused-monitor Wayland surface, theme tokens, safe filesystem
identity, navigation/search, metadata, and a small set of recoverable actions.

- [x] Hyprland-aware dock mode that pushes tiled windows aside.

## 0.2 — core file operations (complete)

- [x] Single-item copy, cut, paste, move and duplicate with keep-both naming.
- [x] Desktop-style multi-selection and batch copy, cut, paste, duplicate and Trash.
- [x] Per-operation progress reporting and cancellation for recursive transfers.
- [x] Atomic no-replace rename; copy/move collisions use bounded keep-both naming.
- [x] Explicit collision policy for each operation: keep both, skip,
  non-destructive folder merge, or confirmed replace with Trash-backed Undo.
- [x] Persistent operation journal with guarded undo for reversible operations.
- [x] Trash module using GIO metadata, restore to original path, and explicit
  permanent-delete confirmation.
- [x] Mount/eject support through UDisks without privileged shell commands.

## 0.3 — navigation, organization and preview (complete)

- [x] Collapsible starred favorites above the file tree.
- [x] Per-item colors and private notes stored outside file contents/xattrs.
- [x] Quick Nav for XDG roots, private recent locations, Git roots/worktrees,
  and optional zoxide history.
- [x] Bounded text-content search with labeled live results and snippets;
  optional `rg` prefilter acceleration with a bounded Python fallback.
- [x] Bounded text, image, directory and metadata previews in-blade on `Space`;
  system Sushi QuickView remains available on `Shift+Space`.
- [x] Race-free folder navigation that clears stale rows, rejects stale backend
  results, suppresses accidental double-entry clicks, and restores the saved
  viewport and originating folder on Back, Forward and Parent navigation.
- [x] Standards-based `text/uri-list` drag source for external applications.
- [x] Internal-token and local-URI drop targets for copying or moving items to
  folders, the current location, favorites and mounted devices.

## 0.4 — agent context (complete)

- [x] Discover conventional project/user instructions for Codex, Claude,
  Gemini, Cursor, GitHub Copilot and Windsurf.
- [x] Deduplicate shared targets, expose symlink bindings and group by scope.
- [x] Approximate per-file and total token budgets with relative usage bars.
- [x] Open, inspect, annotate, favorite, QuickView and drag knowledge files.
- [x] Explicit registry for arbitrary shared memory/rule files and agent
  mappings, stored without modifying files or agent configurations.

## 0.5 — knowledge registry controls (current)

- [x] Add, remap and remove registry files from the properties inspector.
- [x] Per-agent selector chips for Codex, Claude, Gemini, Cursor, Copilot and
  Windsurf.
- [x] Preview-and-confirm creation of actual agent configuration symlinks with
  native/connected/conflict states and a strict no-overwrite policy.
- [x] Opt-in read-only adapters for active agent sessions; never infer a running
  session merely from a rule file on disk.

## 0.6 — blades and modules

- Independent left/right sidebars with resizable vertical blades.
- [x] Reorder, collapse, pin and persist the Sessions, Devices, Favorites and
  Project Knowledge module layout without rebuilding file delegates.
- Built-ins: Files, Properties, Git, Notes, Memory and Skills.
- Small declarative extension API for data/action modules.
- Trusted-QML extension tier with an explicit unsandboxed-code warning.

## 0.7 — local smart search

- [x] Explicit SMART mode with English/Russian/Ukrainian deterministic parsing,
  inflection-tolerant keywords, and soft typed hints from an optional
  multilingual Laya checkpoint, accepted only at calibrated confidence.
- [x] CPU-only runtime: no CUDA download and no discrete-GPU wake-up.
- [x] Dependency-isolated, user-confirmed model setup with atomic installation,
  offline inference, recoverable removal, and keyword-only fallback.
- [x] Coalesced inference requests, stale-response rejection, bounded plan
  validation, and stable live-model reconciliation.
- Semantic embeddings, synonym retrieval, and domain fine-tuning remain future
  experiments; SMART currently reranks the bounded lexical candidate set.

## 0.8 — offline drive catalog (complete)

A drive that is not plugged in can still be found: QuickFile walks an external
drive once into a private catalog and lists it, dimmed, while it is away. The
walk is a bounded, cancellable scan like measuring a folder.

- [x] Stable drive identity from filesystem UUID, partition UUID or a real disk
  serial; placeholder serials and label guesses are never an identity. Locked
  LUKS containers match the catalog made inside them.
- [x] One private `0600` SQLite catalog per drive in a `0700` directory, holding
  names, relative paths, sizes, dates and kinds only, built aside and swapped in
  atomically; a cancelled or interrupted walk never replaces the previous one.
- [x] Bounded, cancellable indexer with streamed progress, entry/depth/queue
  ceilings that publish a partial catalog, and a stop when the drive is pulled.
- [x] Index and Forget from `DEVICES`, automatic re-index when an indexed drive
  is mounted again, footer progress and Cancel, dimmed offline rows with their
  index age; an unreadable catalog stays listed so it can be forgotten.
- [x] Offline rows in search, both the deterministic modes and SMART, after the
  live rows and within a time budget, with an `OFFLINE` badge and the drive to
  connect.
- [x] A setting to keep offline rows out of search.
- [x] An offline row comes alive in place, with its selection kept, when its drive
  is connected.
- [x] Enter on an offline row names the drive to connect, unlock or mount, and
  mounts a connected drive in place; when the drive arrives the row is
  selected, pulsed and announced, never opened.

Deferred:

- Incremental re-indexing; a full walk is simpler and correct, since folder
  dates do not change when a file inside is edited.
- An FTS5 trigram index, if plain substring scans miss the search budget on
  large catalogs.
- A typo-tolerant prefilter for offline SMART matches.
- Browsing an offline drive's folder tree in `FILES`.

## Non-negotiable constraints

Implemented filesystem monitoring: native GIO events, bounded watches and event
batching, incremental row updates, stable selection/viewport, and protected
unsaved inspector drafts. Periodic scanning remains only as a degraded fallback.

- Never edit packaged files under `/usr/share/omarchy`.
- Never interpolate filenames into shell strings; always pass argv arrays or
  binary path tokens.
- Destructive actions require explicit confirmation and do not masquerade as
  ordinary navigation.
- Every recursive operation is bounded or cancellable.
- UI colors, type scale, spacing and corners come from Omarchy `Color`/`Style`.
