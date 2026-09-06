#!/usr/bin/env python3
"""Run QML regression harnesses in isolated, offscreen Quickshell processes.

Panel tests replace only the native layer-shell window wrapper with a plain Qt
Window in a temporary copy. The production Panel functions, models, controls,
and delegates run unchanged; compositor placement is outside this test's scope.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TESTS = ("test_service.qml", "test_panel_state.qml", "test_icon.qml")


def prepare_plugin(config: Path, panel_test: bool) -> None:
    plugin = config / "plugin"
    if not panel_test:
        plugin.symlink_to(ROOT, target_is_directory=True)
        return

    plugin.mkdir()
    for name in ("Service.qml", "components", "bin", "quickfile"):
        source = ROOT / name
        if source.exists():
            (plugin / name).symlink_to(source, target_is_directory=source.is_dir())

    source = (ROOT / "Panel.qml").read_text(encoding="utf-8")
    start_marker = "    PanelWindow {\n"
    end_marker = "      onVisibleChanged: {\n"
    if source.count(start_marker) != 1:
        raise RuntimeError("PanelWindow test adapter must match exactly one window")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    wrapper = """    Window {
      id: window
      objectName: "quickfilePanelWindow"
      required property var modelData
      visible: root.opened || root.revealProgress > 0.001
      width: root.bladeWidth
      height: 900
      color: "transparent"
      readonly property bool keyboardCaptureActive: root.opened

      function claimKeyboardFocus() {
        if (!root.opened || !visible) return
        Qt.callLater(function() { keyScope.forceActiveFocus() })
      }

"""
    adapted = source[:start] + wrapper + source[end:]
    adapted = adapted.replace("import QtQuick\n", "import QtQuick\nimport QtQuick.Window\n", 1)
    (plugin / "Panel.qml").write_text(adapted, encoding="utf-8")


def run_harness(executable: str, source: Path, timeout: float) -> bool:
    with tempfile.TemporaryDirectory(prefix="quickfile-qml-test-") as temporary:
        directory = Path(temporary)
        config = directory / "config"
        config.mkdir()
        prepare_plugin(config, source.name == "test_panel_state.qml")
        commons = Path("/usr/share/omarchy/shell/Commons")
        if commons.is_dir():
            (config / "Commons").symlink_to(commons, target_is_directory=True)
        target = config / "shell.qml"
        shutil.copy2(source, target)

        fixture = directory / "fixtures"
        fixture.mkdir()
        (fixture / "original.txt").write_text("original fixture\n", encoding="utf-8")
        runtime = directory / "runtime"
        runtime.mkdir(mode=0o700)
        environment = os.environ.copy()
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"):
            environment.pop(key, None)
        environment.update({
            "QT_QPA_PLATFORM": "offscreen",
            "QT_QPA_PLATFORMTHEME": "",
            "QT_QUICK_CONTROLS_STYLE": "Basic",
            "QT_QUICK_BACKEND": "software",
            "QSG_RHI_BACKEND": "software",
            "QML_DISABLE_DISK_CACHE": "1",
            "XDG_RUNTIME_DIR": str(runtime),
            "XDG_CACHE_HOME": str(directory / "cache"),
            "XDG_STATE_HOME": str(directory / "state"),
            "QUICKFILE_TEST_ROOT": str(fixture),
            "QUICKFILE_HOME": str(fixture),
            "QUICKFILE_METADATA_FILE": str(directory / "metadata.json"),
            "QUICKFILE_SETTINGS_FILE": str(directory / "settings.json"),
            "NO_COLOR": "1",
        })
        command = [executable, "--no-duplicate", "--no-color", "--path", str(target)]
        process = subprocess.Popen(
            command, env=environment, cwd=config, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, start_new_session=True,
        )
        timed_out = False
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate()
        passed = (
            not timed_out and process.returncode == 0
            and "QUICKFILE_TESTS_PASSED" in output
            and "QUICKFILE_TESTS_FAILED" not in output
        )
        print(f"{'PASS' if passed else 'FAIL'} {source.name}", flush=True)
        if passed:
            for line in output.splitlines():
                if "QUICKFILE_TESTS_PASSED" in line:
                    print(line, flush=True)
        else:
            print(output, end="" if output.endswith("\n") else "\n", flush=True)
            if timed_out:
                print(f"Harness exceeded {timeout:g}s timeout", flush=True)
        return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tests", nargs="*", help="Harness filenames from tests/")
    parser.add_argument("--timeout", type=float, default=45)
    args = parser.parse_args()
    executable = shutil.which("qs") or shutil.which("quickshell")
    if executable is None:
        parser.error("Quickshell (qs) must be installed to run the QML harnesses")
    failures = 0
    for name in args.tests or DEFAULT_TESTS:
        source = ROOT / "tests" / name
        if not source.is_file():
            parser.error(f"QML harness does not exist: {source}")
        failures += not run_harness(executable, source, args.timeout)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
