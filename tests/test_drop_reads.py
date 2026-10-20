"""Guard the panel's drop handling against reading a drag's data.

On Wayland, Qt 6.12 reads another client's drag offer to the end on the GUI
thread, with no byte cap and no deadline (`QWaylandMimeData::readData`). The
shell is one process for the whole desktop, so a drag source that keeps
streaming would stall it and exhaust its memory. `getDataAsString`,
`getDataAsArrayBuffer`, `urls`, `text`, `html` and `colorData` all take that
path; a drop into a QuickFile folder is QuickFile's own drag, recognised by its
`source`, and carries its tokens in the panel's own state instead.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
DATA_READS = re.compile(r"\bgetDataAs(String|ArrayBuffer)\b")
# What a drop may touch on a drag event: who started it, what it allows, and
# its answer. None of these reads the offer.
SAFE_MEMBERS = {"source", "supportedActions", "accepted", "accept"}
DROP_FUNCTIONS = ("directoryDropPayload", "canEnterDirectoryDrop", "beginDirectoryDrop")
HANDLER = re.compile(r"\bon(?:Entered|Dropped|PositionChanged|Exited)\s*:\s*function\s*\((\w+)\)")


def plugin_qml_files() -> list[Path]:
    files = [*ROOT.glob("*.qml"), *ROOT.glob("components/*.qml")]
    return sorted(path for path in files if path.is_file())


def code(path: Path) -> str:
    return "\n".join(line.split("//", 1)[0]
                     for line in path.read_text(encoding="utf-8").splitlines())


def block(text: str, start: int) -> str:
    """The braced block that opens at or after `start`."""
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
    raise AssertionError("unbalanced braces")


def members(body: str, names: set[str]) -> set[str]:
    found = set()
    for name in names:
        found |= set(re.findall(rf"\b{re.escape(name)}\.(\w+)", body))
    return found


class DropReadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.panel = code(ROOT / "Panel.qml")

    def test_no_qml_reads_drag_data(self) -> None:
        offenders = [
            str(path.relative_to(ROOT))
            for path in plugin_qml_files()
            if DATA_READS.search(code(path))
        ]
        self.assertEqual(offenders, [])

    def test_every_drop_area_is_the_directory_target(self) -> None:
        areas = {
            str(path.relative_to(ROOT)): len(re.findall(r"\bDropArea\b", code(path)))
            for path in plugin_qml_files()
        }
        self.assertEqual({name: count for name, count in areas.items() if count},
                         {"Panel.qml": 1})
        self.assertIn("component DirectoryDropTarget: DropArea {", self.panel)

    def test_drop_target_touches_only_safe_members(self) -> None:
        target = block(self.panel, self.panel.index("component DirectoryDropTarget: DropArea"))
        parameters = set(HANDLER.findall(target)) | {"drag", "drop"}
        self.assertTrue({"drag", "drop"} <= set(HANDLER.findall(target)),
                        "the drop target's handlers were renamed; update this guard")
        self.assertLessEqual(members(target, parameters), SAFE_MEMBERS)

    def test_drop_functions_touch_only_safe_members(self) -> None:
        for name in DROP_FUNCTIONS:
            match = re.search(rf"\bfunction {name}\((\w+)", self.panel)
            self.assertIsNotNone(match, name)
            body = block(self.panel, match.start())
            self.assertLessEqual(members(body, {match.group(1)}), SAFE_MEMBERS, name)

    def test_rows_do_not_offer_quickfile_tokens(self) -> None:
        self.assertNotIn("application/x-quickfile-tokens", self.panel)


if __name__ == "__main__":
    unittest.main()
