from __future__ import annotations

import base64
import json
import os
import select
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WATCHER = ROOT / "bin" / "quickfile-watch"


class WatchIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        probe = subprocess.run(
            ["/usr/bin/python3", "-c", "from gi.repository import Gio, GLib"],
            capture_output=True,
        )
        if probe.returncode:
            raise unittest.SkipTest("python-gobject is not installed")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.process = subprocess.Popen(
            ["/usr/bin/python3", str(WATCHER)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.buffer = b""

    def tearDown(self) -> None:
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
            self.fail("Watcher did not exit after stdin closed")
        stderr = self.process.stderr.read().decode("utf-8", "replace")
        self.process.stdout.close()
        self.process.stderr.close()
        self.temporary.cleanup()
        self.assertEqual(self.process.returncode, 0, stderr)
        self.assertEqual(stderr, "")

    def next_event(self, timeout: float = 2.0) -> dict | None:
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                return None
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                self.fail("Watcher exited unexpectedly")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def configure(self, directories=(), files=()) -> None:
        def token(path) -> str:
            return base64.urlsafe_b64encode(os.fsencode(path)).decode("ascii").rstrip("=")

        self.process.stdin.write((json.dumps({
            "directories": [token(path) for path in directories],
            "files": [token(path) for path in files],
        }) + "\n").encode())
        self.process.stdin.flush()
        self.assertEqual(self.next_event(), {"event": "ready"})

    def changed(self) -> None:
        self.assertEqual(self.next_event(), {"event": "changed"})

    def quiet(self, timeout: float = 0.45) -> None:
        self.assertIsNone(self.next_event(timeout))

    def test_idle_and_reads_do_not_trigger_updates(self) -> None:
        file = self.root / "read-me.txt"
        file.write_text("hello")
        self.configure([self.root])
        self.quiet(0.7)
        for _ in range(4):
            file.read_text()
            list(self.root.iterdir())
            file.stat()
        self.quiet(0.7)

    def test_create_write_rename_and_delete(self) -> None:
        self.configure([self.root])
        file = self.root / "created.txt"
        file.write_text("one")
        self.changed()
        file.write_text("two")
        self.changed()
        renamed = file.rename(self.root / "renamed.txt")
        self.changed()
        renamed.unlink()
        self.changed()
        self.quiet()

    def test_atomic_replacement_keeps_file_watch_alive(self) -> None:
        target = self.root / "metadata.json"
        target.write_text("zero")
        self.configure(files=[target])
        for index in range(3):
            temporary = self.root / "temporary.json"
            temporary.write_text(str(index))
            temporary.replace(target)
            self.changed()
            target.write_text("after replacement")
            self.changed()
        self.quiet()

    def test_file_watch_filters_unrelated_siblings(self) -> None:
        watched = self.root / "watched.txt"
        watched.write_text("hello")
        self.configure(files=[watched])
        (self.root / "unrelated.txt").write_text("irrelevant")
        self.quiet()
        watched.write_text("changed")
        self.changed()

    def test_configuration_replaces_watches_and_can_remove_all(self) -> None:
        old = self.root / "old"
        new = self.root / "new"
        old.mkdir()
        new.mkdir()
        self.configure([old])
        self.configure([new])
        (old / "ignored.txt").write_text("one")
        self.quiet()
        (new / "noticed.txt").write_text("two")
        self.changed()
        self.configure()
        (new / "ignored.txt").write_text("three")
        self.quiet()

    def test_missing_nested_directory_is_rearmed_when_created(self) -> None:
        future = self.root / "future" / "nested"
        self.configure([future])
        (self.root / "unrelated").mkdir()
        self.quiet()
        future.mkdir(parents=True)
        self.changed()
        (future / "file.txt").write_text("one")
        self.changed()
        (future / "file.txt").write_text("two")
        self.changed()

    def test_missing_file_detects_parent_creation_then_atomic_saves(self) -> None:
        future = self.root / "data" / "quickfile" / "metadata.json"
        self.configure(files=[future])
        future.parent.mkdir(parents=True)
        future.write_text("one")
        self.changed()
        temporary = future.with_name("temporary.json")
        temporary.write_text("two")
        temporary.replace(future)
        self.changed()

    def test_directory_replacement_does_not_leave_stale_inode_watch(self) -> None:
        directory = self.root / "watched"
        directory.mkdir()
        self.configure([directory])
        directory.rename(self.root / "old")
        directory.mkdir()
        self.changed()
        (directory / "new.txt").write_text("new inode")
        self.changed()
        (self.root / "old" / "ignored.txt").write_text("old inode")
        self.quiet()

    def test_burst_coalesces_and_unchanged_config_stays_quiet(self) -> None:
        self.configure([self.root])
        self.configure([self.root])
        self.quiet()
        for index in range(20):
            (self.root / f"file-{index}").write_text("burst")
        self.changed()
        self.quiet()

    def test_continuous_writes_have_bounded_notification_latency(self) -> None:
        file = self.root / "busy.txt"
        file.write_text("initial")
        self.configure([self.root])
        stopped = threading.Event()

        def write_continuously() -> None:
            while not stopped.is_set():
                file.write_text("still changing")
                stopped.wait(0.04)

        writer = threading.Thread(target=write_continuously)
        writer.start()
        try:
            self.assertEqual(self.next_event(0.8), {"event": "changed"})
            self.assertTrue(writer.is_alive())
        finally:
            stopped.set()
            writer.join(timeout=2)

    def test_listing_git_repository_does_not_generate_watch_feedback(self) -> None:
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, capture_output=True)
        file = self.root / "tracked.txt"
        file.write_text("staged")
        subprocess.run(["git", "-C", str(self.root), "add", "tracked.txt"], check=True, capture_output=True)
        self.configure([self.root], files=[self.root / ".git" / "index"])
        file.write_text("working tree changes")
        self.changed()
        result = subprocess.run(
            ["/usr/bin/python3", str(ROOT / "bin" / "quickfile"), "tree", "--path", str(self.root)],
            env={**os.environ, "QUICKFILE_METADATA_FILE": str(self.root / "metadata.json")},
            capture_output=True, check=True,
        )
        self.assertTrue(json.loads(result.stdout)["ok"])
        self.quiet(0.7)

    def test_non_utf8_paths_are_preserved(self) -> None:
        directory = os.fsdecode(os.fsencode(self.root) + b"/nonutf8-\xff")
        os.mkdir(directory)
        self.configure([directory])
        with open(os.path.join(directory, "created.txt"), "w") as stream:
            stream.write("created")
        self.changed()

    def test_invalid_configuration_reports_error_and_can_recover(self) -> None:
        self.process.stdin.write(b'{"files":["invalid!"]}\n')
        self.process.stdin.flush()
        self.assertEqual(self.next_event()["event"], "error")
        self.configure([self.root])
        (self.root / "file.txt").write_text("recovered")
        self.changed()


if __name__ == "__main__":
    unittest.main()
