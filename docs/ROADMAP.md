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
  results and suppresses accidental double-entry clicks.
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
- Opt-in read-only adapters for active agent sessions; never infer a running
  session merely from a rule file on disk.

## 0.6 — blades and modules

- Independent left/right sidebars with resizable vertical blades.
- Reorder, collapse, pin and persist module layout.
- Built-ins: Files, Properties, Git, Notes, Memory and Skills.
- Small declarative extension API for data/action modules.
- Trusted-QML extension tier with an explicit unsandboxed-code warning.

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
