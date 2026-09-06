# QuickFile

An IDE-like filesystem blade for the Omarchy desktop. QuickFile lives inside
`omarchy-shell`: it opens from the bar or `SUPER+B`, follows the active monitor,
and uses the current Omarchy theme automatically.

The blade participates in Hyprland's usable workspace instead of covering it:
opening QuickFile reserves space on the left and smoothly pushes tiled windows
aside. After a short focus handoff it uses on-demand keyboard focus, so the rest
of the desktop remains interactive.

QuickFile is an independent open-source project inspired by the FileBlade
concept. It does not depend on or copy unreleased FileBlade source code.

## Working now

- Native Omarchy manifest with `service`, `bar-widget`, and `panel` entry points.
- Hyprland-aware left dock on the focused display, below the Omarchy bar.
- Expandable directory tree, directory navigation, back/forward/up/home.
- Git branch and per-path working-tree status.
- Fuzzy, contains, exact, prefix, suffix, and regular-expression search across
  file names, folder names, relative paths, and bounded text-file contents.
- Live search badges distinguish `FOLDER`, `NAME`, `PATH`, and `CONTENT`;
  content hits include the matching line number and a short snippet. When
  ripgrep (`rg`) is available it safely prefilters content candidates, with a
  transparent bounded Python fallback.
- Quick Nav (`Ctrl+P`) combines XDG folders, recent locations, Git roots and
  worktrees, plus zoxide history when zoxide is installed.
- Back, Forward and Parent navigation remember each directory's exact top row,
  pixel offset and selected entry. Returning to a long directory therefore
  resumes where it was left instead of jumping to the beginning.
- Hidden-file toggle and native filesystem monitoring while the blade is
  visible. External changes update rows quietly without resetting the list;
  `Ctrl+R` remains available for an explicit refresh.
- Keyboard navigation with arrows or `HJKL`.
- Persistent click/keyboard selection, independent hover highlighting, and
  an in-blade bounded text, image, directory, or metadata preview on `Space`.
  `Shift+Space` opens the hovered or selected file in system Sushi QuickView.
- Open through the XDG/GIO default application.
- Create file/folder, copy, cut, paste, duplicate, rename, and confirmed move
  to the freedesktop Trash. Rename is atomic and refuses an occupied name.
  Copy/move conflicts are resolved explicitly for the entire operation with
  Keep Both, Skip, non-destructive folder Merge, or separately confirmed
  Replace. Replace preserves the previous destination in Trash for safe Undo.
- Large recursive copies are scanned within fixed depth/item limits, report live
  item/byte progress, remain cancellable, and remove partial destinations after
  cancellation or copy failure.
- Persistent safe undo for rename, copy, move, duplicate, Trash and restore.
  Copy undo verifies that its result has not been changed or replaced before
  removing it.
- Trash browser with restore to the original path and a separate permanent-delete
  confirmation. Restore never forces replacement of an existing path.
- Desktop-style multi-selection with `Ctrl`, `Shift`, keyboard ranges and
  batch copy, cut, paste, duplicate, and Trash actions.
- Native Wayland drag sources with `text/uri-list` and shell-quoted plain text,
  so one or several files can be dragged into terminals and other applications.
- Folder rows, the current-folder header, favorites and mounted devices accept
  internal or local `file://` drops, then ask whether to Copy or Move.
- Per-file and per-folder theme-aware colors, private notes, and starred
  favorites. The collapsible favorites module stays above the regular `FILES`
  tree, and semantic colors follow the active Omarchy palette.
- Live `DEVICES` module for USB sticks and other external storage. It shows
  capacity, connection type, mount state and mount path; clicking mounts and
  opens a drive through UDisks, with a separate safe-unmount control.
- Collapsible `PROJECT KNOWLEDGE` index for agent instructions that apply to the
  current directory. It discovers project and user rules for Codex, Claude,
  Gemini, Cursor, GitHub Copilot, and Windsurf, merges shared symlink targets,
  and shows an approximate per-file and total token budget.
- Explicit Knowledge registry: any existing file can be added from its
  inspector and mapped to one or more supported agents. Removing a registry
  entry never removes the file or rewrites an agent configuration.
- Safe configuration-link workflow with a complete preview. It creates only
  missing symlinks, reports existing/native connections and conflicts, and
  never replaces an existing file or foreign symlink.
- Opt-in, read-only `AI SESSIONS` module for real terminal-backed Codex,
  Claude, Gemini, Cursor Agent, GitHub Copilot CLI and Windsurf Agent processes
  related to the displayed workspace. Detection uses only bounded local process
  metadata; it never treats an instruction file as a running session and never
  exposes command-line contents.
- Configurable module stack. Open the modules control in the title bar to move,
  collapse, expand or pin Sessions, Devices, Favorites and Project Knowledge.
  The order and state persist without rebuilding the live file list, changing
  selection, moving the viewport or discarding an unsaved note.
- The always-live `FILES` surface stays dedicated to navigation and file
  operations, while a persisted inspector switches between `Properties`,
  `Notes`, and read-only `Git` modules without rebuilding the file list.
- `Properties` exposes the full path with a one-click copy button plus POSIX
  metadata, owner/group, timestamps, MIME, inode, allocation,
  mount/filesystem details, ACLs, xattrs, and symlink data.
- `Notes` keeps color labels, unsaved note drafts, and the Project Knowledge
  registry alive while another inspector module is visible.
- `Git` gives the selected item its own repository, branch, and status view.
- Delayed hover tooltips explain every icon-only toolbar/navigation action.
- Compact inspector mode gives more space back to the file tree; the details
  icon expands the current inspector module when needed.
- Binary path tokens, so the backend can address filenames that are not valid
  UTF-8 without interpolating them into a shell command.

## Controls

| Input | Action |
| --- | --- |
| `SUPER+B` | Toggle QuickFile |
| `Esc` | Clear/leave search, then close |
| `↑` / `↓`, `J` / `K` | Move selection |
| `Shift+↑` / `Shift+↓` | Extend a contiguous selection |
| `Ctrl+Space` | Add/remove the focused item from the selection |
| `Ctrl+A` | Select all currently visible file rows |
| `Enter` | Expand a directory or open a file |
| `→` / `L` | Enter a directory or open a file |
| `←` / `H` | Parent directory |
| `Delete` / `Backspace` | Move selected files and folders to Trash |
| `/`, `Ctrl+F` | Focus search |
| `Ctrl+P` | Open Quick Nav |
| `.` | Toggle hidden files |
| `Ctrl+R` | Refresh |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / cut / paste selected items |
| `Ctrl+D` | Duplicate selected items |
| `Ctrl+Z` | Undo the latest reversible QuickFile operation |
| `Space` | Preview the hovered item, otherwise the selected item, in the blade |
| `Shift+Space` | Open the hovered/selected file in Sushi QuickView |
| `Ctrl+click` | Toggle one item in the selection |
| `Shift+click` | Select a range from the anchor |
| Drag | Export selected files to a terminal or another application |
| Double click | Enter directory/open file |
| Right click | Select and reveal color, note, path, and properties |

Click the search-mode label to cycle between search modes. Folder chevrons
expand in place; double-clicking the row changes the tree root. In the
properties inspector, choose a color, enter a note (`Ctrl+Enter` saves it), or
toggle the star. File actions are available as an icon strip directly below
the selected name; delayed tooltips explain each action. The details icon in
the title toggles Agents and the extended filesystem-property table. Starred
items appear as indented children of the `FAVORITES`
module and have a remove control there, without a redundant second star.
The palette button in the top-right corner reopens this inspector after it has
been collapsed. Hover is only a preview highlight; selection remains on the
item you clicked.

QuickFile watches the displayed directories, search scope, relevant Git files,
and Knowledge sources through GIO. Changes are grouped into short batches and
applied to existing rows; unchanged data does not rebuild the view. Background
updates preserve the viewport, selection and unsaved inspector drafts and do
not activate the Refresh button. Closing the blade stops its watchers; reopening
it reconciles anything changed in the meantime. If monitoring is unavailable or
its bounded watch limit is exceeded, a silent 30-second fallback keeps data fresh.

External drives appear automatically in `DEVICES`. Click a mounted drive to
open it, or click an unmounted drive to mount and open it. The trailing eject
button safely unmounts it; if the current file view is on that drive, QuickFile
returns home after the unmount completes.

The short labels in `PROJECT KNOWLEDGE` (`CX`, `CL`, `GM`, `CU`, `CP`, `WS`) describe
which agent configuration references a file. They are bindings, not currently
running agent sessions. A chain glyph marks a symbolic-link binding; hovering
the row shows every binding path and its resolved target. Token counts are
explicit estimates (`≈`, based on file bytes), not model-specific tokenizer
results.

`AI SESSIONS` is disabled until explicitly enabled either from its header or
the modules control. While the blade is visible, the adapter checks at an
eight-second interval for allowlisted agent executables attached to a terminal
whose working directory is the displayed folder, a child folder, or its parent
workspace. It reads process name, PID, terminal, working directory and elapsed
time from `/proc`; it does not read command arguments, prompts, transcripts or
file contents. Clicking a session navigates to its working directory. Disabling
the module immediately clears its in-memory rows and stops polling.

To register an arbitrary file, select or right-click it, choose the agent chips
in the inspector, then press `Add`. `Save` changes those mappings and `Remove`
deletes only the QuickFile registry record. An empty agent selection is valid:
the file remains in `PROJECT KNOWLEDGE` as an unassigned registry item. Conventional
instruction files are still auto-discovered, so removing their explicit record
does not suppress the automatic binding.

For an explicitly registered file, press `Preview` before connecting it. The
dialog resolves the current Git root (or the displayed folder outside Git) and
shows every planned target as `CREATE`, `CONNECTED`, or `CONFLICT`. Pressing
`Create N` applies only the `CREATE` rows. Targets are `AGENTS.md` for Codex,
`.claude/rules/*.md` for Claude, `GEMINI.md` for Gemini,
`.cursor/rules/*.mdc` for Cursor, `.github/copilot-instructions.md` for Copilot,
and `.windsurf/rules/*.md` for Windsurf. Existing targets are never changed.

QuickFile-specific metadata is stored privately in
`$XDG_DATA_HOME/omarchy/quickfile/metadata.json` (normally
`~/.local/share/omarchy/quickfile/metadata.json`) with mode `0600`. It is kept
outside the files themselves, so choosing a color or adding a note does not
modify their contents or extended attributes. Metadata follows renames and
moves performed from QuickFile.

Quick Nav recent locations are stored as private binary path tokens in
`$XDG_STATE_HOME/omarchy/quickfile/recent-locations.json` (normally
`~/.local/state/omarchy/quickfile/recent-locations.json`) with mode `0600`.
Both `rg` and zoxide are optional; QuickFile remains functional without them.

Module layout, selected inspector tab, and the active-session opt-in are stored privately in
`$XDG_CONFIG_HOME/omarchy/quickfile/settings.json` (normally
`~/.config/omarchy/quickfile/settings.json`) with mode `0600`. Only a strict
built-in module allowlist is accepted; this setting is not an extension or an
arbitrary-QML loading mechanism.

The bounded operation journal is stored privately in
`$XDG_STATE_HOME/omarchy/quickfile/operations.json` (normally
`~/.local/state/omarchy/quickfile/operations.json`) with mode `0600`. It stores
only the information needed for safe undo, never file contents. The footer shows
recursive-operation progress and exposes Cancel; when idle it exposes the latest
available Undo. The Trash button in the top toolbar opens restore and permanent
delete controls.

## Requirements

QuickFile targets Omarchy 4 (Quattro). The stock Omarchy installation already
provides its core runtime dependencies:

- Quickshell and the Omarchy shell imports.
- Python 3, PyGObject/GIO and the `gio` command for filesystem monitoring,
  opening files and Trash integration.
- `lsblk` and `udisksctl` for the removable-device module.
- `wl-copy` for copying a selected path to the Wayland clipboard.

Git, `rg`, zoxide, GNOME Sushi, `getfacl`, and `lsattr` are optional. They add
Git context, faster content search, frequent locations, external QuickView,
ACL details, and filesystem attributes respectively. Missing optional tools do
not block the core file manager.

## Install

Install the public repository with Omarchy's standard plugin command:

```bash
omarchy plugin add https://github.com/baranskyi/omarchy-quickfile.git --enable
```

The manifest places the QuickFile button in the left bar section by default.
The optional `SUPER+B` binding below opens the same panel from the keyboard.

## Remove

Remove the installed plugin with:

```bash
omarchy plugin remove m0sthatedman.quickfile
```

Removal does not delete private metadata or operation history. This protects
notes and recovery information from accidental loss. If they are no longer
needed, the user-owned data lives under
`$XDG_DATA_HOME/omarchy/quickfile/` and
`$XDG_STATE_HOME/omarchy/quickfile/`.

## Security model

QuickFile runs inside the unsandboxed Omarchy shell with the permissions of the
signed-in user. It makes no network requests and collects no telemetry. It does
not require elevated privileges or overwrite Omarchy configuration. Filesystem
paths cross the QML/backend boundary as opaque tokens and fixed argument-array
values; recursive scans and watches are bounded. Destructive choices require
confirmation, and ordinary deletion uses the freedesktop Trash. The optional
session adapter performs a bounded `/proc` scan only while the blade is visible;
it neither controls agent processes nor reads their command lines.

## Development install

The working copy can be linked directly into the user plugin directory so QML
changes are picked up by the shell:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/m0sthatedman.quickfile
omarchy-shell shell rescanPlugins
omarchy plugin enable m0sthatedman.quickfile --after omarchy.workspaces
```

The project never modifies `/usr/share/omarchy`. For a normal packaged install,
copy a validated release checkout rather than using the development symlink.

The hotkey belongs in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + B", "QuickFile sidebar", "omarchy-shell shell toggle m0sthatedman.quickfile")
```

After editing Hyprland configuration, validate it:

```bash
hyprctl reload
hyprctl configerrors
```

## Verification

```bash
omarchy plugin validate .
python3 -m unittest discover -s tests -v
python3 tests/run_qml_tests.py
./bin/quickfile tree --path "$HOME" --no-git --limit 20
omarchy-shell quickfile status
```

The command backend is Python 3 standard-library code. The event helper uses
system Python and PyGObject/GIO (`python-gobject` on Arch, `python3-gi` on Debian).
File opening and Trash support use `gio`; Git, `getfacl`, and `lsattr` enrich the
model when available. Watcher tests use a session D-Bus; for an isolated run use
`dbus-run-session -- /usr/bin/python3 -m unittest discover -s tests -v`.

The QML harness runs isolated offscreen service and UI regression checks. Its
test-only window adapter replaces the native Wayland wrapper, while retaining
the actual panel content and logic. Desktop placement/focus still needs a live
Omarchy check. GitHub Actions runs backend and native watcher tests on pushes
and pull requests.

## Architecture

```text
BarWidget.qml ─┐
SUPER+B ───────┼─> omarchy-shell panel lifecycle ─> Panel.qml
shell IPC ─────┘                                  │
                                                  v
                                             Service.qml
                                                  │ fixed argv + bounded JSON
                                                  v
                                           bin/quickfile
```

Long-running or fallible filesystem work runs outside the shell UI process.
The service owns navigation state and coalesces reload/property requests, so a
slow disk or malformed file cannot block or crash the bar.
`bin/quickfile-watch` supplies filesystem and volume events. Stable QML list
models reconcile changed rows by path token instead of replacing the model.

## Next milestones

- Independent resizable left and right blades.
- Memory and Skills remain intentionally folded into Project Knowledge until
  they have distinct, useful workflows instead of duplicate file lists.
- Declarative extension modules plus an explicitly trusted QML extension tier
  remain deferred while everyday file-management workflows are completed.

## License

MIT — see `LICENSE`.
