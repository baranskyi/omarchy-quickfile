# QuickFile

An IDE-like file manager for the Omarchy desktop. QuickFile lives inside
`omarchy-shell`: it opens from the bar or `SUPER+B` and uses the current Omarchy
theme automatically.

QuickFile opens as an ordinary application window. Summoning it focuses it
immediately, so the first keystroke lands in the file list; `Alt+Tab` reaches it
like any other application, and it can stay open beside the editor it was opened
from for as long as it is useful. It follows you to the workspace you are on.

Opening QuickFile moves the workspace aside rather than covering it: while the
window is open it reserves the strip it occupies through a layer-shell exclusive
zone, so tiled windows retile next to it and a window you were working in never
ends up underneath. The bar keeps its own space and its widgets stay put.
Closing gives the strip straight back. Pinned, the dock stays where it is when
you change workspace. See [Window placement](#window-placement) for the rules
that dock it to the left edge; QuickFile still opens and works without them.

QuickFile is an independent open-source project inspired by the FileBlade
concept. It does not depend on or copy unreleased FileBlade source code.

## Working now

- Native Omarchy manifest with `service`, `bar-widget`, and `panel` entry points.
- Application window: focused on summon, reachable with `Alt+Tab`, closable
  from the compositor like any other window, and docked without covering the
  windows it opens beside.
- Expandable directory tree, directory navigation, back/forward/up/home.
- Git branch and per-path working-tree status.
- Fuzzy, contains, exact, prefix, suffix, and regular-expression search across
  file names, folder names, relative paths, and bounded text-file contents.
- Optional `SMART` search interprets natural-language requests in English,
  Russian, Ukrainian and other languages with a local multilingual Laya model.
  It extracts bounded keywords and explicit formats and ranks by them and by
  requested file/folder, broad type, name/path/content, and calendar period;
  uncertain hints never remove lexical matches. It walks past dependency,
  build and cache trees, so the scan budget of a search from home goes to the
  user's own folders. Without the model it degrades transparently to
  keyword-only search.
- Live search badges distinguish `FOLDER`, `NAME`, `PATH`, and `CONTENT`;
  content hits include the matching line number and a short snippet. When
  ripgrep (`rg`) is available it safely prefilters content candidates, with a
  transparent bounded Python fallback.
- Back, Forward and Parent navigation remember each directory's exact top row,
  pixel offset and selected entry. Returning to a long directory therefore
  resumes where it was left instead of jumping to the beginning.
- Hidden-file toggle and native filesystem monitoring while the window is
  visible. External changes update rows quietly without resetting the list;
  `Ctrl+R` remains available for an explicit refresh.
- Keyboard navigation with arrows or `HJKL`.
- Persistent click/keyboard selection, independent hover highlighting, and
  an in-window bounded text, image, directory, or metadata preview on `Space`.
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
| `←` | Parent directory |
| `Delete` / `Backspace` | Move selected files and folders to Trash |
| `/`, `Ctrl+F` | Focus search |
| `?` | Open the keyboard shortcut sheet |
| `Enter` | Confirm the open dialog (Trash, replace, rename) |
| `H`, `.` | Toggle hidden files |
| `P` | Properties for the selected item |
| `N` / `Shift+N` | New file / new folder |
| `F` | Star or unstar the selected item |
| `R` | Rename the selected item |
| `C` | Copy the selection |
| `S` / `Shift+S` | Next / previous sort order |
| `T` / `Shift+T` | Next / previous timestamp format |
| `Ctrl+R` | Refresh (listings also refresh themselves on filesystem events) |
| `Ctrl+Shift+T` | Open the Trash browser to restore or permanently delete |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / cut / paste selected items |
| `Ctrl+D` | Duplicate selected items |
| `Ctrl+Z` | Undo the latest reversible QuickFile operation |
| `Space` | Preview the hovered item, otherwise the selected item, in the window |
| `Shift+Space` | Open the hovered/selected file in Sushi QuickView |
| `Ctrl+click` | Toggle one item in the selection |
| `Shift+click` | Select a range from the anchor |
| Drag | Export selected files to a terminal or another application |
| Double click | Enter directory/open file |
| Right click | Select and reveal color, note, path, and properties |

The `FILES` strip carries three controls, all sharing one idiom: a left click
rotates through the options, a right click opens the full list at the pointer.
The sort chip orders the listing by name (either direction), modification time
(either direction), size or file type, with folders above files in every
order; `S` and `Shift+S` do the same from the keyboard. The date chip chooses
how each row's timestamp reads:

| Chip | Example | Reads |
|---|---|---|
| `FULL` | `2026-09-08 10:50` | The whole stamp, always |
| `ADAPT` | `Sep  8 10:50` · `Nov  2  2025` | Clock time, the year once a file is old |
| `SMART` | `10:50` · `Yesterday 10:50` · `Tue 13:49` · `8 Sep` | The nearest useful phrasing |
| `REL` | `20h` · `3d` · `8mo` | Age only |
| `OFF` | — | No timestamp column |

Hovering a timestamp shows the whole stamp down to the second whatever the
chip says, so a short format costs no information. Under `OFF` the modification
time remains on the inspector's Properties tab. Both chips hide during a
search, where results are ranked by relevance and the timestamp column gives
way to the match badge. The item count sits in the centre of the bottom bar,
where an operation's progress or the pending clipboard takes its place while
there is something to report.

The `?` key, or the button beside the settings gear, opens the same list in a
sheet, so the keys are reachable without leaving the panel.

Wherever the keyboard lands, the place it landed marks itself with a thin
outline that brightens and fades in about half a second: the search field when
`/` opens it, the row that takes the cursor back when Escape leaves it, and the
inspector when a right click opens it on an item. It is a flash, not a state —
nothing stays lit, and the outline never takes a click from what it marks.

Click the search-mode label to cycle between search modes. Folder chevrons
expand in place; double-clicking the row changes the tree root.

A folder's `Size` is the whole tree, not the size of its index: opening
Properties on one walks it, counting hard-linked bytes once and skipping
symlink targets, the way `du` does. Small folders resolve before you notice.
Past a second the panel raises a sheet with the running total, the files and
folders counted so far, and the folder being walked; closing it stops the walk
and the row keeps the partial total, marked as stopped rather than passed off
as final. A walk that hits its own bound marks the total with a `+` instead of
presenting a floor as an answer. The walk follows the inspector — change the selection or close the
panel and it stops.

In the properties inspector, choose a color or enter a note (`Ctrl+Enter` saves it).
File actions are available as an icon strip directly below the selected name;
delayed tooltips explain each action. Starring is done from the file row
itself; starred items appear as indented children of the `FAVORITES` module
and have a remove control there.
The palette button in the top-right corner reopens this inspector after it has
been collapsed. Hover is only a preview highlight; selection remains on the
item you clicked.

QuickFile watches the displayed directories, search scope, relevant Git files,
and Knowledge sources through GIO. Changes are grouped into short batches and
applied to existing rows; unchanged data does not rebuild the view. Background
updates preserve the viewport, selection and unsaved inspector drafts and do
not activate the Refresh button. Closing the window stops its watchers; reopening
it reconciles anything changed in the meantime. If monitoring is unavailable or
its bounded watch limit is exceeded, a silent 30-second fallback keeps data fresh.

`SMART` is an explicit seventh search mode. Its 700 ms input pause coalesces
typing before inference; the six deterministic modes retain their shorter live
delay. The chips below the field show the active hints, with a typed format in
place of the broad kind it implies (`PDF`) and every other kind asked for
(`IMAGE`, `VIDEO`), or `KEYWORDS ONLY` when the optional model is unavailable.
Explicit words — `PDF`, `folder`/`папка`/`тека`, `inside`/`внутри`,
`yesterday`/`вчера`/`вчора`, `last month` — are parsed by fixed English, Russian
and Ukrainian rules, which take precedence. `Last week` is the calendar week
before this one, while `the past week`, `last 7 days`, `за неделю`, `за
последнюю неделю` and `за останній тиждень` are the seven days up to today and
`the past year`, `за последний год` and `за останній рік` the 365; `this
year`/`в этом году`/`цього року` is the calendar year and `last year`/`в прошлом
году`/`минулого року` the one before it. A rolling window of another length is
the shortest of these that holds it (`the past 3 days`, `the last few days`, `за
последние две недели`, `за последние 3 месяца`, the day before yesterday),
`recent`, `недавние` or `нещодавні` ask for the past month and `this morning`
for today. A longer word that begins like a time word is a topic (`годовщина`).
The model is asked only whether files or folders are wanted, where the words
should match and which calendar period is meant — its answers on file kinds were
mostly wrong — and fills only the hints the rules leave open, at 75% confidence
or more. Its hints only reorder rows: they never decide which rows are listed or
which files are read.

A format written as a word (`inventory pdf`, `diagram png`, `inventory in
excel`, `pdf-документ`) or with its dot (`.md`, `*.ts`) weighs almost like a
requirement, and narrows the kind it implies: `pdf` alone lists PDFs, not every
document. A format word that describes another word — `csv parser`, `mp3 to
wav`, `tools for pdf`, `json-server` — and an extension that is also an ordinary
word (`opus`, `tar`, `md` without its dot) stay keywords, while after a verb of
searching (`looking for pdf`, `hunting for png`) the format is asked for. The
kind named first, by a kind word or a format, is the one asked for (`видео с
музыкой` is a video and `mp4 with music` an MP4, `script for photos` is code),
except that of two English nouns side by side the last one is (`photo archive`);
kinds joined by `and`/`и`/`та` are all asked for (`photos and videos`). A folder
named for a kind (`Videos`, `Музыка`) is listed for it. Any text file under the
XDG configuration home counts as configuration, so a Lua or CSS config ranks as
one, if a little less surely than a file in a configuration format.

Keywords match whole words, word starts or, from six letters, the inside of a
word of a name — never scattered letters — and a word of three letters matches
only with an ending (`tax` finds `taxes`, not `syntax` or `taxonomy`). Beside
another keyword, a word of a name that begins a long keyword abbreviates it
(`development notes` finds `dev-notes.md`), unless it only frames a request
(`and`); one of three letters is as often a word of its own (`new` of
`newsletter`, `pro` of `project`), so it counts only where it ends on a
consonant and stands beside the other keyword in the order the query writes
them. A match in a folder on the way counts for less than in the entry's own
name, and text inside a file for less still, the longer the file the less,
unless the query asks about contents (`mentions`, `the memo that discusses`,
`где упоминается`). Keywords drop one common Russian/Ukrainian case ending, so
`графиком` still finds `график.pdf`, and a word too short to trim meets its
other case forms (`дачи` finds `Дача`, not `дачный`). English plurals, a
fleeting vowel (`книжок` finds `книжка`), month names where a date writes them
(`march` finds `2024/03/` and `scan_20240312.pdf`, and `10` counts as October
only in a year's folder; `Мартин` is a name, not March) and a small vocabulary
of document and recording words (`resume`/`cv`/`резюме`, `contract`/`договір`,
`invoice`/`рахунок`, `screenshot`/`скриншот`, `recording`/`запис`) are matched
as spellings of each other; a Ukrainian `лист` is a letter only when a letter is
asked for, as typed it is as often a sheet. Russian and Ukrainian spellings fold
together in names and in text (`кино`/`кіно`, `Одесса`/`Одеса`,
`объект`/`об'єкт`); an apostrophe between letters is part of its word (`м'ясо`,
`мʼясо` and `мясо` are one), and a short word shortened by its doubled letter
still takes only its own endings (`Инна` is not `иначе`). A word in one script
meets its transliteration in the other (`Львів`/`Lviv`, `Тюмень`/`Tyumen`), a
word borrowed from English its English spelling as well (`компьютер`/`computer`,
`джаз`/`jazz`) — an English word never meets its neighbour's (`wine` is not
`vine`). A short word typed in lower case is as often another word there (`мост`
is not `most`): it meets only the same whole word or its plural, for less than
the word itself in a name or a text, and one of three letters only when it has
no vowel, as an abbreviation (`смс`/`sms`). A word that an entry's type says
counts for that entry: a phone's `IMG_0042.PNG` is a screenshot, a call's `.m4a`
a recording, a folder a project, a `.lua` file `lua`. Such an entry is listed on
its type alone only with the date and format the query types, and a file's
extension says what it is, never what it is about (`pdf parser` is not every
PDF). The translations of such a word name only entries of its type and the
folders that hold them: English `recording` finds `Запис 03.mp4`, not an
appointment. A file typed with its extension (`notes.md`, `package.json`) is
found by its whole name, by another spelling of its extension (`ledger.xls`
finds `ledger.xlsx`, `site-backup.tgz` finds `site-backup.tar.gz`) and, below
those, by its name alone. A keyword of five letters or more that no name spells
as typed forgives one misspelt letter (`calender` finds `calendar`). Quoted
words are matched as typed, as whole words, and a query of symbols (`!!!`,
`C++`) finds the names that contain them. `change`, `update`, `edit` and
`modify` are keywords (`CHANGES.md`, `change log`, a photo editor's `Edited`
folder) unless the query says someone did them (`what they edited`, `updated
today`). A word spent on a kind or on what someone did still counts for a name
or a folder that says it — `config.toml` for `… config`, `Edited/` for `edited
photos` — as one more keyword found would; a kind word only for an entry of that
kind or a folder named for it (a JPG called `video-still.jpg` is no video), and
in a request of hints alone only among rows that satisfy the same hints. Topic
words are not translated and no embeddings index is built: retrieval remains a
bounded local name/path/content search.

The walk is breadth-first, so every top-level folder is reached before any is
searched deeply, and it does not enter `node_modules`, `__pycache__`,
`site-packages`, a Python installation's `lib/python3.X` (one that holds
`site-packages`), a virtualenv's tools or directories tagged `CACHEDIR.TAG`
(Cargo's `target/`) unless the query names one. With hidden files shown,
dot-directories are entered only after every other folder, since application
state would otherwise spend the scan budget first. With ripgrep, one bounded
pass per keyword tells which files hold its text, so text counts for every file
rather than for the ones an 8 MiB read budget happened to reach; Python reads
only what rg could not answer and the lines shown. Every row with a keyword in
its name, path or text is listed — a word that only frames the request, such as
`project` or `recording`, is not enough in a path or a text, but an entry named
with it is listed (`Recording 3.m4a`, a `Recordings` folder), and every audio
file is a candidate for `voice memo` whatever it is called (a word that is not
always media, such as `запись`, only ranks the media another keyword finds) —
best first: a row with every keyword before one with some (less so when some are
found only in a long text), a row with a keyword before one whose type alone
says some of them, names before text, words written side by side in the query
and in a name before scattered ones, and among equals the shallower. A request
of hints alone (`архивы за прошлый месяц`) lists what satisfies them, every hint
first and the kind it names before the date: an archive of another month comes
before a document of last month. A request for a folder or a project also
credits a folder with what one entry inside it says, less for each level down,
so the project whose README describes the request is found however its folder is
named; a folder's date counts only when folders are asked for. `truncated` marks
a result that lost a row it would have listed, whether to the scan, time, row or
content budget.

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
the modules control. While the window is visible, the adapter checks at an
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
available Undo. `Ctrl+Shift+T` opens the Trash browser with restore and
permanent-delete controls.

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

Smart Search is also optional. Open QuickFile settings, choose **Install Smart
Search**, and confirm the download. QuickFile creates an isolated environment
under `$XDG_DATA_HOME/omarchy/quickfile/semantic/`, installs
[Laya 0.3.5](https://github.com/NandhaKishorM/laya/tree/v0.3.5), and downloads
only the multilingual checkpoint pinned at
[revision `1c5edc17a7acd8701df6fc341c0d179f1c62c982`][smart-model]. PyTorch's
CPU build comes from `download.pytorch.org`, the other Python packages from
PyPI, and the model weights from Hugging Face: about 1 GB to download and 1.8 GB
on disk. The CPU build avoids several gigabytes of CUDA libraries and never
wakes a discrete GPU. Once setup finishes, inference runs on the CPU with the
model hub and Transformers in offline mode; the model loads in roughly 15–20
seconds when SMART is first used and then answers in about 0.3–0.5 seconds. It
stays loaded until the panel closes or another search mode is chosen.
The settings control can retry setup or move the entire environment and model
to Trash.

[smart-model]: https://huggingface.co/convaiinnovations/laya/tree/1c5edc17a7acd8701df6fc341c0d179f1c62c982/multilingual

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
The optional Smart Search environment is likewise retained across plugin
removal; remove it from QuickFile settings first if it is no longer wanted.

## Security model

Filenames are untrusted input. Every text sink in the plugin — names, paths,
backend messages and tooltips — renders literally: each `Text` is pinned to
`Text.PlainText`, and tooltip values are escaped before they reach Qt Quick
Controls' shared tooltip, which renders with `Text.AutoText`. A file called
`<img src="…">` is shown as that text and loads nothing.

QuickFile runs inside the unsandboxed Omarchy shell with the permissions of the
signed-in user. It collects no telemetry. Its only network-capable path is the
explicitly confirmed Smart Search installer; ordinary file-manager operation
and all model inference are local and offline. Smart Search sends the model only
the user's query — never file names, paths, contents, notes, or Knowledge data.
QuickFile does not require elevated privileges or overwrite Omarchy
configuration. Filesystem paths cross the QML/backend boundary as opaque tokens
and fixed argument-array values; recursive scans and watches are bounded.
Destructive choices require confirmation, and ordinary deletion uses the
freedesktop Trash. The optional
session adapter performs a bounded `/proc` scan only while the window is visible;
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

### Window placement

QuickFile is a real window, so Hyprland tiles it by default. To dock it to the
left edge instead, add a window rule to `~/.config/hypr/hyprland.lua`. The
values below assume a 30px top bar and the default 10px outer gap; adjust them
to taste. `pin` keeps the dock in place across workspaces, and QuickFile
reserves a matching strip for as long as it is open:

```lua
o.window({ class = "^org.quickshell$", title = "^QuickFile$" }, {
  float = true,
  pin = true,
  size = { 480, "(monitor_h-50)" },
  move = { 10, 40 },
})
```

This is optional. Without it QuickFile still opens, focuses, and works — it just
takes a tile like any other application rather than a fixed edge.

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

The QML harness runs isolated offscreen service and UI regression checks against
the plugin exactly as shipped — there is no test-only window adapter to keep in
step with the panel. Compositor placement and focus still need a live Omarchy
check. GitHub Actions runs backend and native watcher tests on pushes and pull
requests.

## Architecture

```text
BarWidget.qml ─┐
SUPER+B ───────┼─> omarchy-shell panel lifecycle ─> Panel.qml
shell IPC ─────┘                                  │
                                                  v
                                             Service.qml
                                                  │
                         fixed argv + bounded JSON├─> bin/quickfile
                                                  │
                                      bounded JSONL└─> bin/quickfile-semantic
                                                           └─ local Laya model
```

Long-running or fallible filesystem work runs outside the shell UI process.
The service owns navigation state and coalesces reload/property requests, so a
slow disk or malformed file cannot block or crash the bar.
`bin/quickfile-watch` supplies filesystem and volume events. Stable QML list
models reconcile changed rows by path token instead of replacing the model.
`bin/quickfile-semantic` is dependency-free for status/setup and runs inference
through its isolated environment only while a non-empty SMART search is active.
The filesystem backend validates its bounded plan and remains fully functional
when the helper is absent, loading, slow, malformed, or stopped.

## Next milestones

- Independent resizable left and right panes.
- Memory and Skills remain intentionally folded into Project Knowledge until
  they have distinct, useful workflows instead of duplicate file lists.
- Declarative extension modules plus an explicitly trusted QML extension tier
  remain deferred while everyday file-management workflows are completed.

## License

MIT — see `LICENSE`.
