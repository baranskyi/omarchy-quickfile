"""Guard the plugin's theme reads against QtQuick's own `Color` singleton.

Qt 6.12 registers a `Color` singleton in QtQuick. A QML file that imports both
QtQuick and `qs.Commons` unqualified can resolve `Color` to Qt's instead of
Omarchy's: `Color.popups` is then undefined, every theme binding fails, and the
panel renders black and ignores theme switches. Omarchy's own shell reaches the
theme as `Commons.Color`; QuickFile must too.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
UNQUALIFIED_COLOR = re.compile(r"(?<![.\w])Color\.")


def plugin_qml_files() -> list[Path]:
    files = [*ROOT.glob("*.qml"), *ROOT.glob("components/*.qml")]
    return sorted(path for path in files if path.is_file())


def code_lines(path: Path):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        code = line.split("//", 1)[0]
        if code.strip():
            yield number, code


class ThemeImportTests(unittest.TestCase):
    def test_plugin_has_qml_files(self) -> None:
        names = {path.name for path in plugin_qml_files()}
        self.assertIn("Panel.qml", names)
        self.assertIn("IconButton.qml", names)

    def test_color_is_always_qualified(self) -> None:
        offenders = [
            f"{path.relative_to(ROOT)}:{number}: {code.strip()}"
            for path in plugin_qml_files()
            for number, code in code_lines(path)
            if UNQUALIFIED_COLOR.search(code)
        ]
        self.assertEqual(offenders, [], "use Commons.Color, not Color:\n" + "\n".join(offenders))

    def test_files_using_commons_color_import_the_qualifier(self) -> None:
        missing = [
            str(path.relative_to(ROOT))
            for path in plugin_qml_files()
            if "Commons.Color" in path.read_text(encoding="utf-8")
            and not re.search(r"^import qs\.Commons as Commons$",
                              path.read_text(encoding="utf-8"), re.M)
        ]
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
