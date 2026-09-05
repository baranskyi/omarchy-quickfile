# QuickFile development

This directory is a standalone public repository:
https://github.com/baranskyi/omarchy-quickfile

- Keep changes scoped to QuickFile. Preserve unrelated user edits.
- Never edit the packaged Omarchy shell under `/usr/share/omarchy`.
- Filesystem paths must use fixed argv arrays and binary path tokens, never
  shell interpolation. Bound filesystem scans and event watches.
- Background changes must preserve live delegates, selection, viewport and
  unsaved editor drafts. Do not restore periodic full model resets.
- Verify backend and watcher changes with
  `dbus-run-session -- /usr/bin/python3 -m unittest discover -s tests -v`.
- Verify service/UI changes with `python3 tests/run_qml_tests.py`, and validate
  the plugin with `omarchy plugin validate .` when Omarchy is installed.
- After each completed and verified change requested by the owner, commit the
  relevant files and push to `origin` so GitHub stays current, unless the owner
  asks otherwise. Review the staged diff first; never commit secrets, private
  file metadata, caches or recordings. Do not overwrite remote history.
- A running desktop needs a verified plugin reload to use QML changes. Check
  `omarchy-shell quickfile status` after reload; command exit status alone does
  not prove that the new plugin is running.
