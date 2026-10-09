from __future__ import annotations

import argparse
import base64
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "bin" / "quickfile"
LOADER = importlib.machinery.SourceFileLoader("quickfile_backend", str(BACKEND))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
quickfile = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(quickfile)
import quickfile_smart  # noqa: E402 - the backend adds its bundled bin directory


class BackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.environment = mock.patch.dict(
            os.environ,
            {
                "QUICKFILE_METADATA_FILE": str(self.root / "quickfile-metadata.json"),
                "QUICKFILE_STATE_FILE": str(self.root / "quickfile-operations.json"),
                "QUICKFILE_NAV_FILE": str(self.root / "quickfile-recent.json"),
                "QUICKFILE_SETTINGS_FILE": str(self.root / "quickfile-settings.json"),
                "QUICKFILE_CATALOG_DIR": str(self.root / "quickfile-catalog"),
                # No drive is plugged in unless a test says so.
                "QUICKFILE_DEV_DISK_DIR": str(self.root / "dev-disk"),
                "QUICKFILE_MOUNTINFO": str(self.root / "mountinfo"),
                "QUICKFILE_HOME": str(self.root),
                "XDG_CONFIG_HOME": str(self.root / "xdg-config"),
                "XDG_DATA_HOME": str(self.root / "xdg-data"),
                "XDG_STATE_HOME": str(self.root / "xdg-state"),
            },
        )
        self.environment.start()
        (self.root / "folder").mkdir()
        (self.root / "folder" / "nested.txt").write_text("nested", encoding="utf-8")
        (self.root / "notes.txt").write_text("hello", encoding="utf-8")
        (self.root / "Привет.md").write_text("unicode", encoding="utf-8")
        (self.root / ".hidden").write_text("secret", encoding="utf-8")
        (self.root / "notes-link").symlink_to(self.root / "notes.txt")

    def tearDown(self) -> None:
        self.environment.stop()
        self.tempdir.cleanup()

    def tree_args(self, **overrides):
        values = {
            "path": str(self.root),
            "path_token": None,
            "expanded": [],
            "show_hidden": False,
            "no_git": True,
            "max_depth": 12,
            "limit": 100,
            "sort": "name",
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_path_tokens_round_trip(self) -> None:
        path = str(self.root / "Привет.md")
        self.assertEqual(quickfile.decode_path(quickfile.encode_path(path)), path)

    def test_settings_persist_private_normalized_module_layout(self) -> None:
        saved = quickfile.settings_command(argparse.Namespace(
            active_sessions="true",
            inspector_tab="git",
            module_layout_json=json.dumps([
                {"id": "knowledge", "pinned": True, "collapsed": True},
                {"id": "sessions", "pinned": False, "collapsed": False},
            ]),
        ))
        self.assertTrue(saved["settings"]["activeSessionsEnabled"])
        self.assertEqual(saved["settings"]["inspectorTab"], "git")
        self.assertEqual(
            [row["id"] for row in saved["settings"]["modules"]],
            ["knowledge", "sessions", "devices", "favorites"],
        )
        self.assertTrue(saved["settings"]["modules"][0]["collapsed"])
        settings_path = Path(os.environ["QUICKFILE_SETTINGS_FILE"])
        self.assertEqual(settings_path.stat().st_mode & 0o777, 0o600)
        loaded = quickfile.settings_command(argparse.Namespace(
            active_sessions=None, inspector_tab=None, module_layout_json=None,
        ))
        self.assertEqual(loaded["settings"], saved["settings"])

    def test_settings_reject_unknown_inspector_tab(self) -> None:
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.settings_command(argparse.Namespace(
                active_sessions=None,
                inspector_tab="terminal",
                module_layout_json=None,
            ))
        self.assertEqual(raised.exception.code, "settings-invalid")

    def test_settings_reject_unknown_or_duplicate_modules(self) -> None:
        invalid_layouts = [
            [{"id": "network", "pinned": False, "collapsed": False}],
            [
                {"id": "sessions", "pinned": False, "collapsed": False},
                {"id": "sessions", "pinned": True, "collapsed": False},
            ],
        ]
        for layout in invalid_layouts:
            with self.subTest(layout=layout), self.assertRaises(quickfile.QuickfileError) as raised:
                quickfile.settings_command(argparse.Namespace(
                    active_sessions=None, module_layout_json=json.dumps(layout),
                ))
            self.assertEqual(raised.exception.code, "settings-invalid-layout")

    def test_active_sessions_require_allowlisted_terminal_processes_in_scope(self) -> None:
        proc_root = self.root / "proc"
        proc_root.mkdir()
        (proc_root / "uptime").write_text("1000.00 0.00\n", encoding="utf-8")

        def process(pid: int, comm: str, cwd: Path, stdin: str) -> None:
            directory = proc_root / str(pid)
            (directory / "fd").mkdir(parents=True)
            (directory / "comm").write_text(comm + "\n", encoding="utf-8")
            # After the parenthesized comm, index 19 is Linux stat field 22.
            fields = ["S"] + ["0"] * 18 + ["50000"]
            (directory / "stat").write_text(
                f"{pid} ({comm}) " + " ".join(fields) + "\n", encoding="utf-8"
            )
            (directory / "cwd").symlink_to(cwd)
            (directory / "fd" / "0").symlink_to(stdin)

        project = self.root / "project"
        project.mkdir()
        child = project / "src"
        child.mkdir()
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        process(101, "codex", child, "/dev/pts/7")
        process(102, "claude", project, "pipe:[123]")
        process(103, "python3", project, "/dev/pts/8")
        process(104, "gemini", elsewhere, "/dev/pts/9")

        rows = quickfile.active_session_rows(str(project), proc_root=proc_root)
        self.assertEqual([(row["agent"], row["pid"]) for row in rows], [("codex", 101)])
        self.assertEqual(rows[0]["location"], "src")
        self.assertEqual(rows[0]["cwdToken"], quickfile.encode_path(str(child)))
        self.assertGreaterEqual(rows[0]["ageSeconds"], 0)

    def test_active_sessions_do_not_infer_activity_from_instruction_files(self) -> None:
        project = self.root / "agent-project"
        project.mkdir()
        (project / "AGENTS.md").write_text("instructions", encoding="utf-8")
        proc_root = self.root / "empty-proc"
        proc_root.mkdir()
        (proc_root / "uptime").write_text("1000.00 0.00\n", encoding="utf-8")
        self.assertEqual(
            quickfile.active_session_rows(str(project), proc_root=proc_root), []
        )

    def test_external_command_capture_is_memory_bounded(self) -> None:
        code, output, error = quickfile.run_bounded([
            sys.executable, "-c",
            "import sys; sys.stdout.write('x' * 10000); sys.stderr.write('e' * 10000)",
        ], timeout=3, limit=64)
        self.assertEqual(code, 0)
        self.assertEqual(len(output), 64)
        self.assertEqual(len(error), 8192)

    def test_external_volumes_include_usb_and_exclude_internal_storage(self) -> None:
        payload = {
            "blockdevices": [
                {
                    "name": "sda", "path": "/dev/sda", "type": "disk",
                    "fstype": None, "size": 64 * 1024**3, "rm": True,
                    "hotplug": True, "tran": "usb", "model": "Pocket Drive",
                    "mountpoints": [],
                    "children": [{
                        "name": "sda1", "path": "/dev/sda1", "type": "part",
                        "fstype": "exfat", "label": "ARCHIVE", "uuid": "usb-1",
                        "size": 63 * 1024**3,
                        "mountpoints": ["/run/media/test/ARCHIVE"],
                        "rm": False, "hotplug": False, "tran": None,
                    }],
                },
                {
                    "name": "nvme0n1", "path": "/dev/nvme0n1", "type": "disk",
                    "fstype": "btrfs", "size": 1024**4, "rm": False,
                    "hotplug": False, "tran": "nvme", "model": "Internal",
                    "mountpoints": ["/"],
                },
            ],
        }
        rows = quickfile.volume_rows_from_lsblk(payload)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], "ARCHIVE")
        self.assertEqual(rows[0]["device"], "/dev/sda1")
        self.assertEqual(rows[0]["transport"], "USB")
        self.assertTrue(rows[0]["mounted"])
        self.assertEqual(rows[0]["mountPath"], "/run/media/test/ARCHIVE")

    def test_volume_mount_uses_discovered_device_without_shell(self) -> None:
        unmounted = {
            "device": "/dev/sdb1", "mounted": False, "canMount": True,
            "canUnmount": False, "mountPath": "", "mountToken": "",
        }
        mounted = dict(
            unmounted,
            mounted=True,
            canMount=False,
            canUnmount=True,
            mountPath="/run/media/test/USB",
            mountToken=quickfile.encode_path("/run/media/test/USB"),
        )
        with mock.patch.object(
            quickfile, "external_volumes", side_effect=[[unmounted], [mounted]]
        ), mock.patch.object(
            quickfile.shutil, "which", return_value="/usr/bin/udisksctl"
        ), mock.patch.object(
            quickfile, "run_bounded", return_value=(0, "", "")
        ) as runner:
            result = quickfile.volume_action_command(argparse.Namespace(
                action="mount", device="/dev/sdb1"
            ))
        runner.assert_called_once_with([
            "/usr/bin/udisksctl", "mount", "--block-device", "/dev/sdb1",
            "--no-user-interaction",
        ], timeout=30)
        self.assertTrue(result["volume"]["mounted"])
        self.assertEqual(result["volume"]["mountPath"], "/run/media/test/USB")

    def test_volume_action_rejects_undiscovered_device(self) -> None:
        with mock.patch.object(quickfile, "external_volumes", return_value=[]):
            with self.assertRaises(quickfile.QuickfileError) as raised:
                quickfile.volume_action_command(argparse.Namespace(
                    action="mount", device="/dev/nvme0n1"
                ))
        self.assertEqual(raised.exception.code, "volume-missing")

    # Offline drive catalog. No drive can be mounted here, so lsblk is faked
    # with a payload whose mount point is a directory of this test, and that
    # directory is reported as a mount point while it is in `mounts`.

    def partition(self, name: str = "sdb1", mount: Path | None = None, **values):
        node = {
            "name": name, "kname": name, "path": "/dev/" + name, "type": "part",
            "fstype": "exfat", "label": "ARCHIVE", "uuid": "DRIVE-1", "partuuid": None,
            "size": 63 * 1024**3, "mountpoints": [str(mount)] if mount else [None],
            "rm": False, "hotplug": False, "tran": None,
        }
        node.update(values)
        return node

    def disk(self, *children, name: str = "sdb", **values):
        node = {
            "name": name, "kname": name, "path": "/dev/" + name, "type": "disk",
            "fstype": None, "size": 64 * 1024**3, "rm": True, "hotplug": True,
            "tran": "usb", "model": "Pocket Drive", "serial": "S4EVNF0M123456X",
            "mountpoints": [None], "children": list(children),
        }
        node.update(values)
        return node

    @contextlib.contextmanager
    def lsblk(self, *disks, mounts: set[str] | None = None):
        mounted = mounts if mounts is not None else set()
        real_ismount = os.path.ismount
        payload = json.dumps({"blockdevices": list(disks)})
        with mock.patch.object(quickfile.shutil, "which", return_value="/usr/bin/lsblk"), \
                mock.patch.object(quickfile, "run_bounded", return_value=(0, payload, "")), \
                mock.patch.object(quickfile.os.path, "ismount", side_effect=lambda path: (
                    os.fspath(path) in mounted or real_ismount(path))):
            yield mounted

    def drive(self) -> Path:
        drive = self.root / "drive"
        (drive / "Photos" / "2024").mkdir(parents=True)
        (drive / "Photos" / "beach.jpg").write_bytes(b"j" * 300)
        (drive / "Photos" / "2024" / "trip.mov").write_bytes(b"m" * 40)
        (drive / ".config").mkdir()
        (drive / ".config" / "settings.json").write_text("{}", encoding="utf-8")
        (drive / "node_modules" / "left-pad").mkdir(parents=True)
        (drive / "node_modules" / "left-pad" / "index.js").write_text("x", encoding="utf-8")
        (drive / "target" / "debug").mkdir(parents=True)
        (drive / "target" / quickfile.SMART_CACHE_MARKER).write_text("tag", encoding="utf-8")
        (drive / "target" / "debug" / "app.o").write_bytes(b"o")
        (drive / ".git").mkdir()
        (drive / ".git" / "HEAD").write_text("ref", encoding="utf-8")
        for litter in ("$RECYCLE.BIN", ".Trash-1000", "lost+found", "System Volume Information"):
            (drive / litter).mkdir()
            (drive / litter / "deleted.txt").write_text("gone", encoding="utf-8")
        (drive / "photos-link").symlink_to(drive / "Photos")
        with open(os.path.join(os.fsencode(drive), b"caf\xe9.txt"), "wb") as stream:
            stream.write(b"latin-1")
        return drive

    def index_drive(self, drive: Path, callback=lambda _event: None, *, device: str = "/dev/sdb1",
                    disks=None, mounts: set[str] | None = None):
        disks = disks or (self.disk(self.partition(mount=drive)),)
        with self.lsblk(*disks, mounts=mounts if mounts is not None else {str(drive)}):
            return quickfile.catalog_index_command(argparse.Namespace(device=device), callback)

    def catalog_file(self, volume_id: str = "uuid:DRIVE-1") -> Path:
        return quickfile.catalog_dir() / (quickfile.catalog_stem(volume_id) + ".sqlite")

    def catalog_rows(self, volume_id: str = "uuid:DRIVE-1") -> dict[bytes, dict]:
        connection = sqlite3.connect(self.catalog_file(volume_id))
        connection.row_factory = sqlite3.Row
        try:
            return {bytes(row["rel"]): dict(row) for row in connection.execute("SELECT * FROM entries")}
        finally:
            connection.close()

    def catalog_temporaries(self) -> list[str]:
        directory = quickfile.catalog_dir()
        return sorted(name for name in os.listdir(directory) if name.startswith(".tmp-"))

    @contextlib.contextmanager
    def running_indexer(self):
        # Another QuickFile walking a drive: alive, and started as one.
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)", "catalog-index"])
        try:
            yield process.pid
        finally:
            process.kill()
            process.wait()

    def test_volume_identity_prefers_filesystem_then_partition_then_serial(self) -> None:
        identity = quickfile.volume_identity
        self.assertEqual(identity({"uuid": "1234-ABCD", "partUuid": "p-1", "serial": "S4EV123"}),
                         "uuid:1234-ABCD")
        self.assertEqual(identity({"uuid": "", "partUuid": "p-1", "serial": "S4EV123"}), "part:p-1")
        self.assertEqual(
            identity({"uuid": "", "partUuid": "", "serial": "S4EV123", "partition": "1",
                      "size": 1000}),
            "serial:S4EV123:1:1000",
        )
        for placeholder in ("000000000000", "0123456789ABCDEF", "0123456789abcdef", "AAAAAAAA",
                            "1234567890", "To Be Filled By O.E.M.", "  ", "", "0"):
            with self.subTest(serial=placeholder):
                self.assertIsNone(identity({"uuid": "", "partUuid": "", "serial": placeholder,
                                            "partition": "1", "size": 1000}))
        # Nothing about where or what it is named: label and size are no identity.
        self.assertIsNone(identity({"uuid": "", "partUuid": "", "serial": "", "label": "ARCHIVE",
                                    "size": 1000}))

    def test_volume_rows_inherit_the_disk_serial_into_their_identity(self) -> None:
        rows = quickfile.volume_rows_from_lsblk({"blockdevices": [
            self.disk(
                self.partition("sdb1", uuid=None),
                self.partition("sdb2", uuid=None, partuuid="0ab1-02", label="SECOND"),
            ),
            self.disk(self.partition("sdc1", uuid=None, label="CHEAP"),
                      name="sdc", serial="000000000000"),
            # A superfloppy stick: the filesystem sits on the disk itself.
            self.disk(name="sdd", fstype="vfat", label="FLOPPY", uuid=None, children=None,
                      size=2048),
        ]})
        by_device = {row["device"]: row for row in rows}
        first = by_device["/dev/sdb1"]
        self.assertEqual(first["serial"], "S4EVNF0M123456X")
        self.assertEqual(first["catalogVolumeId"], f"serial:S4EVNF0M123456X:1:{63 * 1024**3}")
        self.assertEqual(first["id"], first["catalogVolumeId"])
        self.assertEqual(first["identityStrength"], "strong")
        self.assertEqual(by_device["/dev/sdb2"]["catalogVolumeId"], "part:0ab1-02")
        self.assertEqual(by_device["/dev/sdb2"]["partUuid"], "0ab1-02")
        cheap = by_device["/dev/sdc1"]
        self.assertEqual(cheap["catalogVolumeId"], "")
        self.assertEqual(cheap["identityStrength"], "none")
        self.assertEqual(cheap["id"], "/dev/sdc1")
        self.assertEqual(by_device["/dev/sdd"]["catalogVolumeId"],
                         "serial:S4EVNF0M123456X::2048")

    def test_lsblk_is_asked_for_partition_uuids_and_serials(self) -> None:
        with self.lsblk():
            quickfile.external_volumes()
            argv = quickfile.run_bounded.call_args.args[0]
        columns = argv[argv.index("--output") + 1].split(",")
        self.assertIn("PARTUUID", columns)
        self.assertIn("SERIAL", columns)

    def test_catalog_index_writes_a_private_database_of_the_drive(self) -> None:
        drive = self.drive()
        result = self.index_drive(drive)
        self.assertTrue(result["ok"])
        volume = result["volume"]
        self.assertEqual(volume["volumeId"], "uuid:DRIVE-1")
        self.assertEqual(volume["name"], "ARCHIVE")
        self.assertEqual(volume["state"], "complete")
        self.assertEqual(volume["partialReason"], "")
        self.assertFalse(volume["truncated"])
        self.assertFalse(volume["replaced"])
        self.assertGreater(volume["indexedEpoch"], 0)
        self.assertTrue(volume["indexedAt"])

        path = self.catalog_file()
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.catalog_temporaries(), [])
        rows = self.catalog_rows()
        self.assertEqual(set(rows), {
            b"Photos", b"Photos/2024", b"Photos/beach.jpg", b"Photos/2024/trip.mov",
            b".config", b".config/settings.json",
            # Listed, as a SMART walk lists them, but never entered.
            b"node_modules", b"target",
            b"photos-link", b"caf\xe9.txt",
        })
        self.assertEqual(volume["entries"], len(rows))
        beach = rows[b"Photos/beach.jpg"]
        self.assertEqual(bytes(beach["name"]), b"beach.jpg")
        self.assertEqual((beach["is_dir"], beach["is_link"], beach["hidden"]), (0, 0, 0))
        self.assertEqual((beach["size"], beach["depth"], beach["smart_kind"]), (300, 1, "image"))
        self.assertEqual(beach["rel_fold"], "photos/beach.jpg")
        self.assertAlmostEqual(beach["mtime"], (drive / "Photos" / "beach.jpg").stat().st_mtime)
        self.assertEqual(rows[b"Photos"]["is_dir"], 1)
        self.assertEqual(rows[b"Photos"]["smart_kind"], "any")
        self.assertEqual(rows[b".config"]["hidden"], 1)
        self.assertEqual(rows[b".config/settings.json"]["hidden"], 1)
        link = rows[b"photos-link"]
        self.assertEqual((link["is_link"], link["is_dir"]), (1, 0))
        latin = rows[b"caf\xe9.txt"]
        self.assertEqual(bytes(latin["name"]), b"caf\xe9.txt")
        self.assertEqual(latin["name_fold"], "caf�.txt")
        self.assertEqual(volume["bytes"], 300 + 40 + 2 + len(b"latin-1"))

        connection = sqlite3.connect(path)
        try:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertEqual(connection.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            meta = dict(connection.execute("SELECT key, value FROM meta"))
            indexes = {row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'index'")}
        finally:
            connection.close()
        self.assertEqual(meta["volumeId"], "uuid:DRIVE-1")
        self.assertEqual(meta["state"], "complete")
        self.assertEqual(meta["serial"], "S4EVNF0M123456X")
        self.assertEqual(meta["entries"], str(len(rows)))
        self.assertIn("entries_mtime", indexes)
        self.assertIn("entries_kind", indexes)

        again = self.index_drive(drive)
        self.assertTrue(again["volume"]["replaced"])

    def test_catalog_index_streams_progress_then_saving(self) -> None:
        drive = self.drive()
        events = []
        # A second per call, so the throttle lets every directory through.
        with mock.patch.object(quickfile.time, "monotonic", side_effect=range(1, 10**6)):
            self.index_drive(drive, events.append)
        phases = [event["phase"] for event in events]
        self.assertGreater(phases.count("indexing"), 1)
        self.assertEqual(phases[-1], "saving")
        self.assertEqual(phases.count("saving"), 1)
        first = events[0]
        self.assertEqual(first["event"], "progress")
        self.assertEqual(set(first), {"event", "phase", "files", "directories", "bytes", "path"})
        self.assertEqual(set(events[-1]), {"event", "phase", "files", "directories", "bytes"})

    def test_catalog_index_publishes_a_ceiling_as_partial(self) -> None:
        drive = self.drive()
        cases = (
            ("CATALOG_ENTRY_LIMIT", 3, "entry-limit"),
            ("CATALOG_DEPTH_LIMIT", 0, "depth-limit"),
            ("MEASURE_PENDING_LIMIT", 0, "pending-limit"),
        )
        for constant, value, reason in cases:
            with self.subTest(constant=constant), mock.patch.object(quickfile, constant, value):
                result = self.index_drive(drive)
                self.assertEqual(result["volume"]["state"], "partial")
                self.assertEqual(result["volume"]["partialReason"], reason)
                self.assertTrue(result["volume"]["truncated"])
                rows = self.catalog_rows()
                self.assertNotIn(b"Photos/beach.jpg", rows)
                if constant == "CATALOG_ENTRY_LIMIT":
                    self.assertEqual(len(rows), 3)
        with self.lsblk():
            listed = quickfile.volumes_command(argparse.Namespace())["volumes"]
        self.assertEqual(listed[0]["catalogState"], "partial")

    def test_cancelled_catalog_index_keeps_the_previous_catalog(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        path = self.catalog_file()
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        (drive / "new.txt").write_text("new", encoding="utf-8")
        for phase in ("indexing", "saving"):
            def cancel(event, phase=phase):
                if event["phase"] == phase:
                    quickfile.request_operation_cancel(15, None)
            with self.subTest(phase=phase):
                try:
                    with self.assertRaises(quickfile.OperationCancelled):
                        self.index_drive(drive, cancel)
                finally:
                    quickfile._operation_cancelled = False
                self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
                self.assertEqual(self.catalog_temporaries(), [])
        # The last moment: the build is complete and flushed to disk, and a
        # cancel landing now must still not swap it in.
        real_fsync = os.fsync

        def cancel_while_flushing(descriptor):
            real_fsync(descriptor)
            quickfile.request_operation_cancel(15, None)

        try:
            with mock.patch.object(quickfile.os, "fsync", cancel_while_flushing), \
                    self.assertRaises(quickfile.OperationCancelled):
                self.index_drive(drive)
        finally:
            quickfile._operation_cancelled = False
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
        self.assertEqual(self.catalog_temporaries(), [])

    def test_catalog_index_resets_a_stale_cancel(self) -> None:
        quickfile.request_operation_cancel(15, None)
        try:
            result = self.index_drive(self.drive())
        finally:
            quickfile._operation_cancelled = False
        self.assertTrue(result["ok"])

    def test_catalog_index_publishes_nothing_when_the_drive_goes_away(self) -> None:
        drive = self.drive()
        mounts = {str(drive)}

        def unplug(event):
            if event["phase"] == "indexing":
                mounts.clear()

        with self.assertRaises(quickfile.QuickfileError) as raised:
            self.index_drive(drive, unplug, mounts=mounts)
        self.assertEqual(raised.exception.code, "catalog-volume-lost")
        self.assertEqual(str(raised.exception), "The drive was disconnected while indexing")
        self.assertFalse(self.catalog_file().exists())
        self.assertEqual(self.catalog_temporaries(), [])

        # Another filesystem mounted on the same directory is not the drive.
        self.index_drive(drive)
        path = self.catalog_file()
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        swapped = {"done": False}
        real_stat = os.stat

        def stat_after_swap(target, *args, **kwargs):
            result = real_stat(target, *args, **kwargs)
            if swapped["done"] and os.fspath(target) == str(drive):
                values = list(result[:10])
                values[2] += 1
                return os.stat_result(values)
            return result

        def swap(event):
            if event["phase"] == "indexing":
                swapped["done"] = True

        with mock.patch.object(quickfile.os, "stat", side_effect=stat_after_swap), \
                self.assertRaises(quickfile.QuickfileError) as raised:
            self.index_drive(drive, swap)
        self.assertEqual(raised.exception.code, "catalog-volume-lost")
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
        self.assertEqual(self.catalog_temporaries(), [])

    def test_catalog_index_checks_the_drive_after_an_unreadable_folder(self) -> None:
        drive = self.drive()
        mounts = {str(drive)}
        real_scandir = os.scandir
        after_failure = []

        def failing_scandir(path):
            if not mounts:
                after_failure.append(path)
            if os.fspath(path) == str(drive / "Photos"):
                mounts.clear()
                raise OSError(5, "Input/output error")
            return real_scandir(path)

        with mock.patch.object(quickfile.os, "scandir", failing_scandir), \
                self.assertRaises(quickfile.QuickfileError) as raised:
            self.index_drive(drive, mounts=mounts)
        self.assertEqual(raised.exception.code, "catalog-volume-lost")
        # The failed readdir is what noticed: no folder was read after it.
        self.assertEqual(after_failure, [])

    def test_catalog_index_treats_a_dead_mount_as_a_lost_drive(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        path = self.catalog_file()
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        real_scandir = os.scandir

        class DeadEntry:
            def __init__(self, entry):
                self.name = entry.name

            def stat(self, follow_symlinks=True):
                raise OSError(errno.EIO, "Input/output error")

        @contextlib.contextmanager
        def dead_children(target):
            with real_scandir(target) as iterator:
                yield (DeadEntry(entry) for entry in iterator)

        # Pulled, but still in the mount table until udisks catches up:
        # every uncached read fails at once while the mount checks all pass.
        def dead_folders(target):
            if os.fspath(target) == str(drive):
                return real_scandir(target)
            raise OSError(errno.EIO, "Input/output error")

        def dead_entries(target):
            return dead_children(target)

        for name, scandir in (("folders", dead_folders), ("entries", dead_entries)):
            with self.subTest(failing=name), \
                    mock.patch.object(quickfile.os, "scandir", scandir), \
                    self.assertRaises(quickfile.QuickfileError) as raised:
                self.index_drive(drive)
            self.assertEqual(raised.exception.code, "catalog-volume-lost")
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
            self.assertEqual(self.catalog_temporaries(), [])

        # Cached folders keep answering after the device is gone; its /dev
        # node is what goes first.
        node = {"present": True}
        real_stat = os.stat

        def device_stat(target, *args, **kwargs):
            if os.fspath(target) == "/dev/sdb1":
                if not node["present"]:
                    raise FileNotFoundError(errno.ENOENT, "No such file or directory")
                return os.stat_result((stat.S_IFBLK | 0o660, 0, 0, 1, 0, 0, 0, 0, 0, 0),
                                      {"st_rdev": 2065})
            return real_stat(target, *args, **kwargs)

        def pull(event):
            if event["phase"] == "indexing":
                node["present"] = False

        with mock.patch.object(quickfile, "CATALOG_PRESENCE_INTERVAL", 1), \
                mock.patch.object(quickfile.os, "stat", side_effect=device_stat), \
                self.assertRaises(quickfile.QuickfileError) as raised:
            self.index_drive(drive, pull)
        self.assertEqual(raised.exception.code, "catalog-volume-lost")
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
        self.assertEqual(self.catalog_temporaries(), [])

    def test_catalog_index_keeps_the_catalog_of_a_drive_it_cannot_read(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        path = self.catalog_file()
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        real_scandir = os.scandir

        def denied(folder):
            def scandir(target):
                if os.fspath(target) == str(folder):
                    raise PermissionError(errno.EACCES, "Permission denied")
                return real_scandir(target)
            return scandir

        # Still mounted, still this drive, but its top folder will not list.
        with mock.patch.object(quickfile.os, "scandir", denied(drive)), \
                self.assertRaises(quickfile.QuickfileError) as raised:
            self.index_drive(drive)
        self.assertEqual(raised.exception.code, "catalog-unreadable")
        self.assertEqual(str(raised.exception), "Could not read this drive")
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
        self.assertEqual(self.catalog_temporaries(), [])

        # One folder further down is just one folder: counted, and the rest saved.
        with mock.patch.object(quickfile.os, "scandir", denied(drive / "Photos")):
            result = self.index_drive(drive)
        self.assertTrue(result["ok"])
        rows = self.catalog_rows()
        self.assertIn(b"Photos", rows)
        self.assertNotIn(b"Photos/beach.jpg", rows)
        connection = sqlite3.connect(path)
        try:
            unreadable = connection.execute(
                "SELECT value FROM meta WHERE key = 'unreadable'").fetchone()[0]
        finally:
            connection.close()
        self.assertEqual(unreadable, "1")

    def test_catalog_index_keeps_the_previous_catalog_when_saving_fails(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        path = self.catalog_file()
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        with mock.patch.object(quickfile.os, "replace",
                               side_effect=OSError(errno.ENOSPC, "No space left on device")), \
                self.assertRaises(quickfile.QuickfileError) as raised:
            self.index_drive(drive)
        self.assertEqual(raised.exception.code, "catalog-write-failed")
        self.assertIn("No space left on device", str(raised.exception))
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
        self.assertEqual(self.catalog_temporaries(), [])

    def test_catalog_index_is_stamped_when_the_walk_ends(self) -> None:
        drive = self.drive()
        clock = {"now": 1_800_000_000.0}

        def long_walk(event):
            # The walk takes half an hour; the catalog is as old as its end.
            if event["phase"] == "indexing":
                clock["now"] = 1_800_001_800.0

        with mock.patch.object(quickfile.time, "time", side_effect=lambda: clock["now"]):
            result = self.index_drive(drive, long_walk)
        self.assertEqual(result["volume"]["indexedEpoch"], 1_800_001_800)
        with self.lsblk():
            listed = quickfile.volumes_command(argparse.Namespace())["volumes"]
        self.assertEqual(listed[0]["indexedEpoch"], 1_800_001_800)

    def test_catalogs_open_under_a_directory_spelled_with_two_slashes(self) -> None:
        self.index_drive(self.drive())
        spelled = "/" + str(quickfile.catalog_dir())
        self.assertTrue(spelled.startswith("//") and not spelled.startswith("///"))
        # POSIX lets a path start with exactly two slashes; as a URI that
        # would name a host, and every catalog would read as unreadable.
        with mock.patch.dict(os.environ, {"QUICKFILE_CATALOG_DIR": spelled}):
            catalogs = quickfile.catalog_volumes()
        self.assertEqual([(row["volumeId"], row["state"]) for row in catalogs],
                         [("uuid:DRIVE-1", "complete")])
        self.assertGreater(catalogs[0]["entries"], 0)

    def test_catalog_index_refuses_drives_it_cannot_catalog(self) -> None:
        drive = self.drive()
        cases = (
            ((), "volume-missing"),
            ((self.disk(self.partition()),), "catalog-not-mounted"),
            ((self.disk(self.partition(mount=drive, uuid=None), serial="0000000000"),),
             "catalog-no-identity"),
        )
        for disks, code in cases:
            with self.subTest(code=code), self.lsblk(*disks, mounts={str(drive)}), \
                    self.assertRaises(quickfile.QuickfileError) as raised:
                quickfile.catalog_index_command(
                    argparse.Namespace(device="/dev/sdb1"), lambda _event: None)
            self.assertEqual(raised.exception.code, code)
        self.assertFalse(quickfile.catalog_dir().exists())

    def test_catalog_forget_removes_the_file_unless_it_is_being_indexed(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        path = self.catalog_file()
        stem = quickfile.catalog_stem("uuid:DRIVE-1")
        with self.running_indexer() as pid:
            building = path.parent / f".tmp-{stem}-{pid}.sqlite"
            building.write_bytes(b"")
            with self.assertRaises(quickfile.QuickfileError) as raised:
                quickfile.catalog_forget_command(argparse.Namespace(volume_id="uuid:DRIVE-1"))
            self.assertEqual(raised.exception.code, "catalog-busy")
            self.assertEqual(str(raised.exception), "This drive is being indexed")
            self.assertTrue(path.exists())
            with self.assertRaises(quickfile.QuickfileError) as raised:
                self.index_drive(drive)
            self.assertEqual(raised.exception.code, "catalog-busy")
            self.assertTrue(building.exists())
        building.unlink()

        # A build killed outright whose pid now belongs to some other live
        # process (here the one running the tests) is litter, not a walk.
        stranger = path.parent / f".tmp-{stem}-{os.getppid()}.sqlite"
        stranger.write_bytes(b"")
        self.assertTrue(self.index_drive(drive)["ok"])
        self.assertFalse(stranger.exists())
        stranger.write_bytes(b"")
        result = quickfile.catalog_forget_command(argparse.Namespace(volume_id="uuid:DRIVE-1"))
        self.assertEqual(result, {
            "ok": True, "volumeId": "uuid:DRIVE-1", "removed": True, "message": "Forgot “ARCHIVE”",
        })
        self.assertFalse(path.exists())
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.catalog_forget_command(argparse.Namespace(volume_id="uuid:DRIVE-1"))
        self.assertEqual(raised.exception.code, "catalog-missing")
        self.assertEqual(str(raised.exception), "No catalog for this drive")

    def test_catalog_index_sweeps_only_builds_whose_process_is_gone(self) -> None:
        directory = quickfile.ensure_catalog_dir()
        finished = subprocess.Popen([sys.executable, "-c", "pass"])
        finished.wait()
        other = quickfile.catalog_stem("uuid:OTHER")
        dead = directory / f".tmp-{other}-{finished.pid}.sqlite"
        reused = directory / f".tmp-{other}-{os.getppid()}.sqlite"
        dead.write_bytes(b"")
        reused.write_bytes(b"")
        with self.running_indexer() as pid:
            live = directory / f".tmp-{other}-{pid}.sqlite"
            live.write_bytes(b"")
            os.utime(live, (0, 0))
            self.index_drive(self.drive())
            self.assertFalse(dead.exists())
            # A live pid that is no indexer: the build's own process is gone.
            self.assertFalse(reused.exists())
            # However old, a build whose process still runs is kept.
            self.assertTrue(live.exists())

    def test_volumes_list_unreadable_catalogs_instead_of_failing(self) -> None:
        directory = quickfile.ensure_catalog_dir()
        corrupt = directory / (quickfile.catalog_stem("uuid:BROKEN") + ".sqlite")
        corrupt.write_bytes(b"this is not a database at all" * 64)
        newer = directory / (quickfile.catalog_stem("uuid:NEWER") + ".sqlite")
        connection = sqlite3.connect(newer)
        connection.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        connection.execute("INSERT INTO meta VALUES ('volumeId', 'uuid:NEWER')")
        connection.execute("PRAGMA user_version = 99")
        connection.commit()
        connection.close()
        (directory / "not ours.sqlite").write_bytes(b"")
        with self.lsblk():
            result = quickfile.volumes_command(argparse.Namespace())
        self.assertTrue(result["ok"])
        self.assertEqual((result["count"], result["offlineCount"]), (0, 2))
        rows = {row["id"]: row for row in result["volumes"]}
        self.assertEqual(set(rows), {"uuid:BROKEN", "uuid:NEWER"})
        for row in rows.values():
            self.assertEqual(row["catalogState"], "unreadable")
            self.assertTrue(row["offline"])
            self.assertTrue(row["catalogued"])
            self.assertEqual(row["name"], row["catalogVolumeId"])
        forgotten = quickfile.catalog_forget_command(argparse.Namespace(volume_id="uuid:BROKEN"))
        self.assertTrue(forgotten["removed"])
        self.assertFalse(corrupt.exists())

    def test_volumes_without_catalogs_never_open_sqlite(self) -> None:
        with self.lsblk(self.disk(self.partition())), \
                mock.patch.object(quickfile.sqlite3, "connect", side_effect=AssertionError):
            missing = quickfile.volumes_command(argparse.Namespace())
            quickfile.ensure_catalog_dir()
            empty = quickfile.volumes_command(argparse.Namespace())
        for result in (missing, empty):
            self.assertEqual((result["count"], result["offlineCount"]), (1, 0))
            row = result["volumes"][0]
            self.assertFalse(row["catalogued"])
            self.assertEqual((row["indexedAt"], row["indexedEpoch"]), ("", 0))
            self.assertEqual((row["catalogEntries"], row["catalogState"]), (0, ""))
            self.assertFalse(row["offline"])
            self.assertFalse(row["locked"])

    def test_volumes_merge_catalogued_and_offline_drives(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        old = self.root / "old-drive"
        (old / "letters").mkdir(parents=True)
        self.index_drive(old, disks=(self.disk(
            self.partition("sdc1", mount=old, uuid="OLD-1", size=8 * 1024**3),
            name="sdc", model="Old Stick"),), device="/dev/sdc1")
        backup = self.root / "backup"
        backup.mkdir()
        with self.lsblk(
            self.disk(self.partition()),
            self.disk(self.partition("sdd1", mount=backup, uuid="BACK-1", label="BACKUP"),
                      name="sdd"),
        ):
            result = quickfile.volumes_command(argparse.Namespace())
        self.assertEqual((result["count"], result["offlineCount"]), (2, 1))
        rows = result["volumes"]
        # Mounted, then plugged in, then only catalogued.
        self.assertEqual([row["id"] for row in rows], ["uuid:BACK-1", "uuid:DRIVE-1", "uuid:OLD-1"])
        backup_row, archive, orphan = rows
        self.assertFalse(backup_row["catalogued"])
        self.assertEqual(backup_row["name"], "BACKUP")
        self.assertTrue(archive["catalogued"])
        self.assertFalse(archive["offline"])
        self.assertEqual(archive["id"], archive["catalogVolumeId"])
        self.assertEqual(archive["catalogState"], "complete")
        self.assertGreater(archive["catalogEntries"], 0)
        self.assertGreater(archive["indexedEpoch"], 0)
        self.assertEqual(archive["device"], "/dev/sdb1")
        # Both are called ARCHIVE, so both say which one they are.
        self.assertEqual(archive["name"], "ARCHIVE · Pocket Drive · "
                         + quickfile.human_size(63 * 1024**3))
        self.assertEqual(orphan["name"], "ARCHIVE · Old Stick · " + quickfile.human_size(8 * 1024**3))
        self.assertEqual(orphan, dict(orphan, **{
            "id": "uuid:OLD-1", "catalogVolumeId": "uuid:OLD-1", "offline": True,
            "catalogued": True, "locked": False, "device": "", "deviceName": "",
            "mountPath": "", "mountToken": "", "mounted": False, "canMount": False,
            "canUnmount": False, "identityStrength": "strong", "catalogState": "complete",
            "uuid": "OLD-1", "model": "Old Stick", "fstype": "exfat", "transport": "USB",
        }))
        self.assertEqual(set(orphan) - set(archive), set())

        with self.lsblk():
            unplugged = quickfile.volumes_command(argparse.Namespace())
        self.assertEqual([row["id"] for row in unplugged["volumes"]],
                         ["uuid:DRIVE-1", "uuid:OLD-1"])
        self.assertEqual(unplugged["volumes"][0]["catalogVolumeId"], "uuid:DRIVE-1")
        self.assertTrue(all(row["offline"] for row in unplugged["volumes"]))

    def test_locked_luks_drive_is_one_row_matched_to_its_catalog(self) -> None:
        drive = self.drive()
        mapper = {
            "name": "luks-4f2a", "kname": "dm-0", "path": "/dev/mapper/luks-4f2a",
            "type": "crypt", "fstype": "ext4", "label": "VAULT", "uuid": "FS-1",
            "size": 63 * 1024**3 - 16 * 1024**2, "mountpoints": [str(drive)],
            "rm": False, "hotplug": False, "tran": None,
        }
        unlocked = self.disk(self.partition(
            "sdc1", uuid="LUKS-1", fstype="crypto_luks", label=None, children=[mapper],
        ), name="sdc")
        result = self.index_drive(drive, disks=(unlocked,), device="/dev/mapper/luks-4f2a")
        self.assertEqual(result["volume"]["volumeId"], "uuid:FS-1")
        connection = sqlite3.connect(self.catalog_file("uuid:FS-1"))
        try:
            meta = dict(connection.execute("SELECT key, value FROM meta"))
        finally:
            connection.close()
        self.assertEqual(meta["containerUuid"], "LUKS-1")

        with self.lsblk(unlocked, mounts={str(drive)}):
            open_rows = quickfile.volumes_command(argparse.Namespace())
        self.assertEqual([row["id"] for row in open_rows["volumes"]], ["uuid:FS-1"])
        self.assertFalse(open_rows["volumes"][0]["locked"])
        self.assertEqual(open_rows["volumes"][0]["containerUuid"], "LUKS-1")

        locked = self.disk(self.partition(
            "sdc1", uuid="LUKS-1", fstype="crypto_luks", label=None,
        ), name="sdc")
        with self.lsblk(locked):
            result = quickfile.volumes_command(argparse.Namespace())
        self.assertEqual((result["count"], result["offlineCount"]), (1, 0))
        [row] = result["volumes"]
        self.assertTrue(row["locked"])
        self.assertTrue(row["catalogued"])
        self.assertFalse(row["offline"])
        self.assertEqual(row["id"], "uuid:FS-1")
        self.assertEqual(row["catalogVolumeId"], "uuid:FS-1")
        self.assertEqual(row["device"], "/dev/sdc1")
        self.assertEqual(row["name"], "VAULT")

    def test_decode_path_rejects_tokens_outside_the_alphabet(self) -> None:
        for token in ("catalog:x:Y", "a b", "abc=", "a/b", "a+b"):
            with self.subTest(token=token), self.assertRaises(quickfile.QuickfileError) as raised:
                quickfile.decode_path(token)
            self.assertEqual(raised.exception.code, "invalid-path-token")
        for raw in (b"", b"/", b"/tmp/x", "/home/Привет.md".encode(), b"/mnt/caf\xe9\xff\xfe",
                    bytes(range(1, 256))):
            with self.subTest(raw=raw):
                token = quickfile.encode_path(raw)
                self.assertEqual(os.fsencode(quickfile.decode_path(token)), raw)

    # Offline rows in search. A drive's presence is read from /dev/disk and
    # the mount table, both pointed at files of this test: a catalogued drive
    # is disconnected until `plug` gives it a node, and mounted once that node
    # is the source of a mountinfo line.

    def plug(self, uuid: str = "DRIVE-1", mount: Path | None = None, *, node: str = "sdb1",
             root: str = "/") -> Path:
        device = self.root / "dev nodes" / node
        device.parent.mkdir(exist_ok=True)
        device.touch()
        links = Path(os.environ["QUICKFILE_DEV_DISK_DIR"]) / "by-uuid"
        links.mkdir(parents=True, exist_ok=True)
        (links / uuid).symlink_to(device)
        if mount is not None:
            self.mount_line(device, mount, root=root)
        return device

    def mount_line(self, device: Path, mount: Path | bytes, *, root: str = "/") -> None:
        def escaped(value: bytes) -> bytes:
            for raw, code in ((b"\\", b"\\134"), (b" ", b"\\040"), (b"\t", b"\\011"),
                              (b"\n", b"\\012")):
                value = value.replace(raw, code)
            return value

        line = b" ".join((
            b"36 25 8:17", escaped(root.encode()), escaped(os.fsencode(mount)),
            b"rw,relatime shared:1 - exfat", escaped(os.fsencode(device)), b"rw",
        )) + b"\n"
        with open(os.environ["QUICKFILE_MOUNTINFO"], "ab") as stream:
            stream.write(line)

    def search(self, root: Path, query: str, mode: str = "contains", **overrides):
        values = {
            "path": str(root), "path_token": None, "query": query, "mode": mode,
            "smart_plan_json": None, "case_sensitive": False, "show_hidden": False,
            "no_git": True, "limit": 100, "scan_limit": 1000, "timeout": 2.0,
            "content_file_limit": 1024 * 1024, "content_byte_limit": 8 * 1024 * 1024,
        }
        values.update(overrides)
        return quickfile.search_command(argparse.Namespace(**values))

    def elsewhere(self) -> Path:
        # A folder with nothing in it to find: a search there lists only what
        # the catalogs answer.
        root = self.root / "elsewhere"
        root.mkdir(exist_ok=True)
        return root

    def parity_drive(self) -> Path:
        # Built so that every answer is in a name or a path: an offline row
        # has no content, no insides of a pruned tree, and cannot tell where
        # a symlink points.
        drive = self.corpus({
            "Invoices/invoice-2024-03.pdf": b"",
            "Invoices/old/invoice-2019.pdf": b"",
            "Invoices/receipt.txt": b"",
            "Photos/2024/03/beach.jpg": b"",
            "Photos/2024/03/IMG_0042.PNG": b"",
            "Photos/sunset beach.png": b"",
            "Projects/QuickFile/notes.md": b"",
            "Projects/QuickFile/src/main.py": b"",
            "Отпуск 2025/график.pdf": b"",
            "Отпуск 2025/Программа поездки.docx": b"",
            "Documents/D'Artagnan letters.txt": b"",
            "Documents/report-final.docx": b"",
            "Documents/Report Draft.odt": b"",
            "Documents/invocie scan.pdf": b"",
            "Music/song.mp3": b"",
            "notes.txt": b"",
            "README.md": b"",
            ".hidden-notes.txt": b"",
        }, name="drive")
        now = quickfile.dt.datetime.now().astimezone()
        last_month = now.replace(day=1) - quickfile.dt.timedelta(days=10)
        dated = {
            "Invoices/old/invoice-2019.pdf": quickfile.dt.datetime(2019, 6, 1, tzinfo=now.tzinfo),
            "Invoices/invoice-2024-03.pdf": last_month,
            "Photos/2024/03/beach.jpg": quickfile.dt.datetime(2024, 3, 9, tzinfo=now.tzinfo),
            "Photos/2024/03/IMG_0042.PNG": last_month,
            "Documents/report-final.docx": quickfile.dt.datetime(2020, 1, 5, tzinfo=now.tzinfo),
        }
        for relative, when in dated.items():
            os.utime(drive / relative, (when.timestamp(), when.timestamp()))
        return drive

    def scored_search(self, root: Path, query: str, mode: str, **overrides):
        # Pattern rows carry no score, so it is read where it is given: the
        # one helper the walk and the catalog both rank with.
        recorded: dict[str, tuple[str, int]] = {}
        real = quickfile.keyword_match

        def record(name, relative, is_directory, *rest):
            found = real(name, relative, is_directory, *rest)
            if found is not None:
                recorded[relative] = (found[0]["matchKind"], found[1])
            return found

        with mock.patch.object(quickfile, "keyword_match", side_effect=record):
            result = self.search(root, query, mode, **overrides)
        return result, [
            (row["relativePath"], row["matchKind"], recorded[row["relativePath"]][1])
            for row in result["entries"]
        ]

    def test_offline_rows_rank_exactly_as_a_live_search_of_the_drive(self) -> None:
        drive = self.parity_drive()
        self.index_drive(drive)
        elsewhere = self.elsewhere()
        pattern_queries = [
            ("inv", "fuzzy", {}), ("ntxt", "fuzzy", {}), ("пргрм", "fuzzy", {}),
            ("beach", "contains", {}), ("report", "contains", {}), ("отпуск", "contains", {}),
            ("d'art", "contains", {}), ("Report", "contains", {"case_sensitive": True}),
            ("report", "prefix", {}), ("img", "prefix", {}), ("notes.txt", "exact", {}),
            (".pdf", "suffix", {}), (r"^invoice-\d{4}", "regex", {}), (r"\.pdf$", "regex", {}),
            (r"(?i)REPORT", "regex", {}), (r"o.e", "regex", {}),
        ]
        for query, mode, overrides in pattern_queries:
            with self.subTest(query=query, mode=mode):
                live, live_scores = self.scored_search(
                    drive, query, mode, no_catalog=True, **overrides)
                offline, offline_scores = self.scored_search(elsewhere, query, mode, **overrides)
                self.assertTrue(live_scores, "the corpus must answer every query")
                self.assertEqual(offline_scores, live_scores)
                self.assertEqual(
                    [(row["name"], row["isDir"], row["depth"]) for row in offline["entries"]],
                    [(row["name"], row["isDir"], row["depth"]) for row in live["entries"]])
                self.assertTrue(all(
                    row["origin"] == "catalog" and row["available"] is False
                    for row in offline["entries"]))
                self.assertEqual(offline["catalog"]["offlineMatches"], len(live["entries"]))

        def ranked(result):
            return [
                (row["relativePath"], row["matchKind"], row["smartScore"], row["smartReasons"],
                 row["isDir"])
                for row in result["entries"]
            ]

        # A slip counts only while its word is in no name ("reciept"), and
        # not once one name has it as typed ("invocie"); a month is found
        # where a date writes it, and as a folder inside a year's.
        smart_queries = [
            "old invoices", "show images from this month", "beach photos", "invoice",
            "invocie", "reciept", "march", "отпуск", "программа поездки", "quickfile notes",
            "pdf from last month", "projects", "screenshots from last month",
        ]
        for query in smart_queries:
            with self.subTest(query=query, mode="smart"):
                live = self.search(drive, query, "smart", no_catalog=True)
                offline = self.search(elsewhere, query, "smart")
                self.assertEqual(live["smart"]["state"], "fallback")
                self.assertTrue(ranked(live), "the corpus must answer every query")
                self.assertEqual(ranked(offline), ranked(live))
        # The hints the comparison leans on were in the plans it compared.
        hints = quickfile.fallback_plan("old invoices")["hints"]
        self.assertEqual((hints["kind"]["value"], hints["time"]["value"]), ("document", "older"))
        hints = quickfile.fallback_plan("show images from this month")["hints"]
        self.assertEqual((hints["kind"]["value"], hints["time"]["value"]), ("image", "this-month"))

    def test_offline_rows_have_no_content_to_match(self) -> None:
        drive = self.corpus({"memo.txt": "the budget for next year", "budget.md": ""},
                            name="drive")
        self.index_drive(drive)
        live = self.search(drive, "budget", "contains", no_catalog=True)
        self.assertEqual({row["relativePath"]: row["matchKind"] for row in live["entries"]},
                         {"memo.txt": "content", "budget.md": "name"})
        offline = self.search(self.elsewhere(), "budget", "contains")
        self.assertEqual([row["relativePath"] for row in offline["entries"]], ["budget.md"])
        smart = self.search(self.elsewhere(), "budget", "smart")
        self.assertEqual([row["relativePath"] for row in smart["entries"]], ["budget.md"])

    def test_catalog_prefilters_never_drop_a_true_match(self) -> None:
        # SQL narrows a catalog by its folded columns before matches() has
        # its say on the displayed names, so every folding the two disagree
        # on must still leave the row in: apostrophes between letters, ß, a
        # ligature, a decomposed accent, a doubled Cyrillic letter, a soft
        # sign, the dotless ı re matches as i, LIKE's own wildcards, and a
        # byte that is no UTF-8.
        drive = self.corpus({
            "rock'n'roll.mp3": b"", "Straße.txt": b"", "ﬁle.txt": b"", "cafe\u0301.txt": b"",
            "программа.txt": b"", "бульвар.txt": b"", "k\u0131t.txt": b"", "100%_done.txt": b"",
            "wedd\u0131ngs.txt": b"",
        }, name="drive")
        with open(os.path.join(os.fsencode(drive), b"caf\xe9.txt"), "wb"):
            pass
        self.index_drive(drive)
        cases = [
            ("'n'", "contains"), ("n'r", "contains"), ("SS", "contains"), ("fi", "prefix"),
            ("e", "contains"), ("мм", "contains"), ("мм", "fuzzy"), ("ьв", "contains"),
            ("caf?", "contains"), ("caf?.txt", "exact"), ("kit", "regex"),
            ("k[i\u0131]t", "regex"), ("%_", "contains"), ("%_d", "fuzzy"), ("rock'n", "fuzzy"),
            ("STRASSE", "prefix"), ("weddings", "regex"),
        ]
        for query, mode in cases:
            with self.subTest(query=query, mode=mode):
                live = self.search(drive, query, mode, no_catalog=True)
                offline = self.search(self.elsewhere(), query, mode)
                expected = [row["relativePath"] for row in live["entries"]]
                self.assertTrue(expected)
                self.assertEqual([row["relativePath"] for row in offline["entries"]], expected)

    def test_offline_tokens_are_never_path_tokens(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        result = self.search(self.elsewhere(), "caf", "contains")
        [row] = result["entries"]
        stem = quickfile.catalog_stem("uuid:DRIVE-1")
        self.assertEqual(row["token"],
                         "catalog:" + stem + ":" + quickfile.encode_path(b"caf\xe9.txt"))
        self.assertEqual(row["catalogToken"], row["token"])
        encoded = row["token"].split(":")[2]
        self.assertEqual(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)),
                         b"caf\xe9.txt")
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.decode_path(row["token"])
        self.assertEqual(raised.exception.code, "invalid-path-token")
        # Every key a live row has, and what a row without its drive can say.
        live = quickfile.entry_row(str(self.root / "notes.txt"), 0, {"statuses": {}}, set())
        self.assertEqual(set(live) - set(row), set())
        self.assertEqual(row, dict(row, **{
            "name": "caf?.txt", "path": "ARCHIVE:/caf?.txt", "uri": "", "shellQuotedPath": "",
            "depth": 0, "kind": "file", "isDir": False, "isSymlink": False, "isHidden": False,
            "isExecutable": False, "hasChildren": False, "expanded": False, "size": 7,
            "sizeText": "7 B", "permissions": "", "mode": "", "mime": "text/plain", "git": "",
            "relativePath": "caf?.txt", "matchKind": "name", "matchLine": 0, "matchSnippet": "",
            "origin": "catalog", "available": False, "volumeId": "uuid:DRIVE-1",
            "volumeName": "ARCHIVE", "volumeModel": "Pocket Drive",
            "volumeSizeText": quickfile.human_size(63 * 1024**3), "volumeState": "disconnected",
            "catalogState": "complete", "starred": False,
        }))
        self.assertGreater(row["indexedEpoch"], 0)
        self.assertTrue(row["indexedAt"])
        self.assertAlmostEqual(row["modifiedEpoch"],
                               (drive / os.fsdecode(b"caf\xe9.txt")).lstat().st_mtime)
        link = self.search(self.elsewhere(), "photos-link", "exact")["entries"]
        self.assertEqual([(entry["kind"], entry["isSymlink"], entry["mime"]) for entry in link],
                         [("symlink", True, "inode/symlink")])
        folder = self.search(self.elsewhere(), "Photos", "exact")["entries"]
        self.assertEqual([(entry["kind"], entry["isDir"], entry["matchKind"]) for entry in folder],
                         [("directory", True, "folder")])

    def test_live_rows_come_first_and_each_side_keeps_its_own_cap(self) -> None:
        drive = self.drive()
        (drive / "Photos" / "beach-2.jpg").write_bytes(b"j")
        self.index_drive(drive)
        local = self.elsewhere()
        for name in ("beach-a.txt", "beach-b.txt", "beach-c.txt"):
            (local / name).write_text("", encoding="utf-8")
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode):
                result = self.search(local, "beach", mode, limit=2)
                origins = [row.get("origin", "live") for row in result["entries"]]
                # The walk's cap holds its own rows to two and says so; the
                # catalog's rows come after them, all of them.
                self.assertEqual(origins, ["live", "live", "catalog", "catalog"])
                self.assertTrue(result["truncated"])
                self.assertFalse(result["catalog"]["truncated"])
                self.assertEqual(result["catalog"]["offlineMatches"], 2)
                with mock.patch.object(quickfile, "CATALOG_RESULT_LIMIT", 1):
                    capped = self.search(local, "beach", mode)
                origins = [row.get("origin", "live") for row in capped["entries"]]
                self.assertEqual(origins, ["live", "live", "live", "catalog"])
                self.assertTrue(capped["catalog"]["truncated"])
                self.assertTrue(capped["truncated"])
                self.assertEqual(capped["catalog"]["offlineMatches"], 1)
                # The best of them is the one kept.
                self.assertEqual(capped["entries"][-1]["relativePath"],
                                 result["entries"][2]["relativePath"])

    def test_a_drive_mounted_around_the_root_is_left_to_the_walk(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        self.plug(mount=drive)
        inside = self.search(drive / "Photos", "beach", "contains")
        self.assertEqual([row.get("origin") for row in inside["entries"]], [None])
        self.assertEqual(inside["catalog"], quickfile.catalog_stats())
        smart = self.search(drive, "beach", "smart")
        self.assertTrue(smart["entries"])
        self.assertTrue(all("origin" not in row for row in smart["entries"]))
        self.assertEqual(smart["catalog"]["searched"], 0)

    def test_a_mounted_drive_answers_with_live_rows(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        offline = self.search(self.elsewhere(), "beach", "contains")["entries"]
        self.plug(mount=drive)
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode):
                result = self.search(self.elsewhere(), "beach", mode)
                [row] = result["entries"]
                beach = drive / "Photos" / "beach.jpg"
                self.assertEqual(row["token"], quickfile.encode_path(str(beach)))
                self.assertEqual(row["path"], str(beach))
                self.assertEqual(row["uri"], beach.as_uri())
                self.assertEqual(row["permissions"], quickfile.stat.filemode(beach.lstat().st_mode))
                self.assertTrue(row["available"])
                self.assertEqual(row["volumeState"], "mounted")
                self.assertEqual(row["relativePath"], "Photos/beach.jpg")
                # The row the panel showed offline, by the key that outlives
                # its token.
                self.assertEqual(row["catalogToken"], offline[0]["catalogToken"])
                self.assertEqual(result["catalog"]["availableMatches"], 1)
                self.assertEqual(result["catalog"]["offlineMatches"], 0)

        # Gone since the drive was indexed: dropped, as any stale row is.
        (drive / "Photos" / "2024" / "trip.mov").unlink()
        self.assertEqual(self.search(self.elsewhere(), "trip", "contains")["entries"], [])
        self.assertEqual(self.search(self.elsewhere(), "trip", "smart")["entries"], [])

        # A root above the mount walks the drive itself: its rows are listed
        # once, by the walk.
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode, root="above"):
                result = self.search(self.root, "beach", mode)
                tokens = [row["token"] for row in result["entries"]]
                beach = quickfile.encode_path(str(drive / "Photos" / "beach.jpg"))
                self.assertEqual(tokens.count(beach), 1)
                self.assertTrue(all("origin" not in row for row in result["entries"]))
                self.assertEqual(result["catalog"]["availableMatches"], 0)

        # The same through a link above the mount (~/Drives -> /run/media/me):
        # the walk's paths go through the link, the catalog's do not, and the
        # file is still listed once.
        (self.root / "drives").symlink_to(self.root)
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode, root="linked"):
                result = self.search(self.root / "drives", "beach", mode)
                self.assertEqual([row["path"] for row in result["entries"]],
                                 [str(self.root / "drives" / "drive" / "Photos" / "beach.jpg")])
                self.assertEqual(result["catalog"]["availableMatches"], 0)

    def test_a_folder_of_a_drive_bound_elsewhere_is_the_drive(self) -> None:
        drive = self.drive()
        (drive / "Music").mkdir()
        (drive / "Music" / "beachsong.mp3").write_bytes(b"m")
        self.index_drive(drive)
        device = self.plug(mount=drive)
        # Its Music bound at ~/Music: the same files under another path, which
        # resolving links cannot bring together.
        bound = self.root / "home" / "Music"
        bound.mkdir(parents=True)
        (bound / "beachsong.mp3").write_bytes(b"m")
        self.mount_line(device, bound, root="/Music")
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode, root="inside"):
                inside = self.search(bound, "beachsong", mode)
                self.assertEqual([row.get("origin") for row in inside["entries"]], [None])
                self.assertEqual(inside["catalog"]["searched"], 0)
            with self.subTest(mode=mode, root="above"):
                above = self.search(self.root / "home", "beachsong", mode)
                self.assertEqual([row["path"] for row in above["entries"]],
                                 [str(bound / "beachsong.mp3")])
                self.assertEqual(above["catalog"]["searched"], 1)
                self.assertEqual(above["catalog"]["availableMatches"], 0)

    def test_a_mounted_drive_that_does_not_answer_holds_no_search(self) -> None:
        drive = self.drive()
        for number in range(3):
            (drive / "Photos" / f"beach-{number}.jpg").write_bytes(b"j")
        self.index_drive(drive)
        self.plug(mount=drive)
        released = threading.Event()
        self.addCleanup(released.set)
        real_row = quickfile.catalog_live_row
        answered: list[bytes] = []

        def hung(source, record):
            # The first file answers; then the drive stops, as a disk spinning
            # up or failing does, inside an lstat no deadline reaches.
            if answered:
                released.wait(30)
                return None
            answered.append(record[1])
            return real_row(source, record)

        for mode in ("contains", "smart"):
            with self.subTest(mode=mode):
                answered.clear()
                started = time.monotonic()
                with mock.patch.object(quickfile, "catalog_live_row", side_effect=hung):
                    result = self.search(self.elsewhere(), "beach", mode, timeout=2.0)
                self.assertLess(time.monotonic() - started, 1.5)
                rows = result["entries"]
                self.assertEqual(len(rows), 4)
                live = [row for row in rows if row["available"]]
                self.assertEqual([os.fsencode(row["relativePath"]) for row in live], answered)
                # The rest are listed from the catalog, offline although the
                # drive is mounted: opening one searches again.
                waiting = [row for row in rows if not row["available"]]
                self.assertEqual(len(waiting), 3)
                for row in waiting:
                    self.assertEqual(row["volumeState"], "mounted")
                    self.assertTrue(row["token"].startswith("catalog:"))
                    self.assertEqual(row["token"], row["catalogToken"])
                self.assertEqual(result["catalog"]["availableMatches"], 1)
                self.assertEqual(result["catalog"]["offlineMatches"], 3)
                self.assertTrue(result["catalog"]["truncated"])

    def test_offline_rows_keep_the_exact_bytes_of_a_name(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        [offline] = self.search(self.elsewhere(), "caf", "smart")["entries"]
        self.assertEqual(offline["relativePath"], "caf?.txt")
        mount = self.root / "mnt" / os.fsdecode(b"st\xffck")
        mount.parent.mkdir()
        drive.rename(mount)
        self.plug(mount=mount)
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode):
                [row] = self.search(self.elsewhere(), "caf", mode)["entries"]
                self.assertEqual(os.fsencode(quickfile.decode_path(row["token"])),
                                 os.fsencode(mount) + b"/caf\xe9.txt")
                self.assertEqual(row["catalogToken"], offline["catalogToken"])

    def test_hidden_catalog_rows_are_listed_only_when_hidden_files_are(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode):
                self.assertEqual(self.search(self.elsewhere(), "settings", mode)["entries"], [])
                shown = self.search(self.elsewhere(), "settings", mode, show_hidden=True)
                self.assertEqual([row["relativePath"] for row in shown["entries"]],
                                 [".config/settings.json"])
                self.assertTrue(shown["entries"][0]["isHidden"] is False)

    def test_a_catalog_cut_short_by_its_deadline_still_answers_the_search(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        local = self.elsewhere()
        (local / "beach-local.txt").write_text("", encoding="utf-8")
        real_open = quickfile.open_catalog_ro

        class Slow:
            # The entries query starts just past the catalog deadline; only
            # SQLite's progress handler is there to stop it.
            def __init__(self, connection) -> None:
                self.connection = connection

            def execute(self, sql, *args):
                if "FROM entries" in sql:
                    time.sleep(0.15)
                return self.connection.execute(sql, *args)

            def close(self) -> None:
                self.connection.close()

        for mode in ("contains", "smart"):
            with self.subTest(mode=mode), \
                    mock.patch.object(quickfile, "CATALOG_BUDGET_LIMIT", 0.1), \
                    mock.patch.object(quickfile, "CATALOG_PROGRESS_STEPS", 1), \
                    mock.patch.object(quickfile, "open_catalog_ro",
                                      side_effect=lambda *args: Slow(real_open(*args))):
                result = self.search(local, "beach", mode)
            self.assertTrue(result["ok"])
            self.assertEqual([row["relativePath"] for row in result["entries"]],
                             ["beach-local.txt"])
            self.assertEqual(result["catalog"], dict(result["catalog"], searched=1, scanned=0,
                                                     truncated=True, offlineMatches=0))
            self.assertTrue(result["truncated"])

    def test_a_scan_that_runs_out_of_time_leaves_time_to_read_a_mounted_drive(self) -> None:
        drive = self.drive()
        for number in range(4):
            (drive / f"beach-{number}.txt").write_text("", encoding="utf-8")
        self.index_drive(drive)
        self.plug(mount=drive)
        real_records = quickfile.catalog_records

        def slow_records(*args):
            # Every row takes a quarter of a second to score: the scan runs
            # into its deadline after three.
            for found in real_records(*args):
                time.sleep(0.25)
                yield found

        for mode in ("contains", "smart"):
            # A second for the catalogs: a quarter of the four the search has.
            with self.subTest(mode=mode), \
                    mock.patch.object(quickfile, "catalog_records", side_effect=slow_records):
                result = self.search(self.elsewhere(), "beach", mode, timeout=4.0)
                self.assertTrue(result["catalog"]["truncated"])
                self.assertGreaterEqual(result["catalog"]["availableMatches"], 2)
                self.assertTrue(all(row["available"] for row in result["entries"]))

    def test_a_damaged_catalog_is_skipped_by_search(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        directory = quickfile.catalog_dir()
        (directory / (quickfile.catalog_stem("uuid:BROKEN") + ".sqlite")).write_bytes(b"x" * 4096)
        # Readable meta over a table that is not there.
        foreign = directory / (quickfile.catalog_stem("uuid:HALF") + ".sqlite")
        connection = sqlite3.connect(foreign)
        connection.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        connection.executemany("INSERT INTO meta VALUES (?, ?)",
                               [("volumeId", "uuid:HALF"), ("state", "complete")])
        connection.execute("PRAGMA user_version = 1")
        connection.commit()
        connection.close()
        # Readable throughout, but with rows no indexer writes: a path out of
        # the drive, text where bytes and numbers go, an empty folder name.
        odd = directory / (quickfile.catalog_stem("uuid:ODD") + ".sqlite")
        connection = sqlite3.connect(odd)
        for statement in quickfile.CATALOG_SCHEMA:
            connection.execute(statement)
        rows = [
            (b"beach.jpg", b"../beach.jpg", 0, 1.0), ("beach-text.jpg", "beach-text.jpg", 0, 1.0),
            (b"beach-size.jpg", b"beach-size.jpg", "big", 1.0),
            (b"beach-gap.jpg", b"a//beach-gap.jpg", 0, 1.0),
            (b"beach-ok.jpg", b"Photos/beach-ok.jpg", 5, 1.0),
        ]
        connection.executemany(
            "INSERT INTO entries (name, rel, name_fold, rel_fold, is_dir, is_link, hidden,"
            " depth, size, mtime, smart_kind) VALUES (?, ?, ?, ?, 0, 0, 0, 0, ?, ?, 'image')",
            [(name, rel, os.fsdecode(name), os.fsdecode(rel).casefold(), size, mtime)
             for name, rel, size, mtime in rows])
        connection.executemany("INSERT INTO meta VALUES (?, ?)",
                               [("volumeId", "uuid:ODD"), ("state", "complete")])
        connection.execute("PRAGMA user_version = 1")
        connection.commit()
        connection.close()
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode):
                result = self.search(self.elsewhere(), "beach", mode)
                self.assertTrue(result["ok"])
                self.assertEqual(sorted(row["relativePath"] for row in result["entries"]),
                                 ["Photos/beach-ok.jpg", "Photos/beach.jpg"])
                self.assertTrue(result["catalog"]["truncated"])
                self.assertEqual(result["catalog"]["searched"], 3)

    def test_search_without_catalogs_costs_one_listdir(self) -> None:
        real_listdir = os.listdir
        listed: list[str] = []

        def listdir(path="."):
            listed.append(os.fspath(path))
            return real_listdir(path)

        catalogs = str(quickfile.catalog_dir())
        with mock.patch.object(quickfile.os, "listdir", side_effect=listdir), \
                mock.patch.object(quickfile.sqlite3, "connect", side_effect=AssertionError), \
                mock.patch.object(quickfile, "mounts_by_source", side_effect=AssertionError):
            for mode in ("contains", "fuzzy", "regex", "smart"):
                with self.subTest(mode=mode):
                    for prepared in (False, True):
                        if prepared:
                            quickfile.ensure_catalog_dir()
                        listed.clear()
                        result = self.search(self.root, "notes", mode)
                        self.assertEqual(listed.count(catalogs), 1)
                        self.assertEqual(result["catalog"], quickfile.catalog_stats())
                        self.assertIn("notes.txt", [row["name"] for row in result["entries"]])
                    listed.clear()
                    self.search(self.root, "notes", mode, no_catalog=True)
                    self.assertEqual(listed.count(catalogs), 0)

    def test_no_catalog_leaves_offline_drives_out(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        for mode in ("contains", "smart"):
            with self.subTest(mode=mode):
                self.assertTrue(self.search(self.elsewhere(), "beach", mode)["entries"])
                result = self.search(self.elsewhere(), "beach", mode, no_catalog=True)
                self.assertEqual(result["entries"], [])
                self.assertEqual(result["catalog"], {
                    "searched": 0, "offlineMatches": 0, "availableMatches": 0,
                    "truncated": False, "scanned": 0,
                })
        code, lines = self.run_main([
            "search", "--path", str(self.elsewhere()), "--query", "beach", "--mode", "contains",
            "--no-git", "--no-catalog",
        ])
        self.assertEqual(code, 0)
        self.assertEqual(lines[-1]["entries"], [])
        code, lines = self.run_main([
            "search", "--path", str(self.elsewhere()), "--query", "beach", "--mode", "smart",
            "--no-git",
        ])
        self.assertEqual([row["volumeState"] for row in lines[-1]["entries"]], ["disconnected"])

    def test_each_catalog_has_its_share_of_the_search(self) -> None:
        crowded = self.corpus({f"crowded-beach-{number}.txt": b"" for number in range(60)},
                              name="crowded")
        with mock.patch.object(quickfile.time, "time", return_value=2000):
            self.index_drive(crowded, disks=(self.disk(self.partition(mount=crowded,
                                                                      uuid="CROWDED")),))
        quiet = self.corpus({"quiet-beach.txt": b""}, name="quiet")
        with mock.patch.object(quickfile.time, "time", return_value=1000):
            self.index_drive(quiet, disks=(self.disk(self.partition(mount=quiet, uuid="QUIET")),))
        real_record = quickfile.catalog_record

        def slow(record):
            # The newest catalog matches everywhere, slowly: alone it would
            # spend the whole budget before the older one was opened.
            if record[0].startswith(b"crowded"):
                time.sleep(0.02)
            return real_record(record)

        with mock.patch.object(quickfile, "CATALOG_BUDGET_LIMIT", 0.4), \
                mock.patch.object(quickfile, "catalog_record", side_effect=slow):
            for mode in ("contains", "fuzzy", "smart"):
                with self.subTest(mode=mode):
                    result = self.search(self.elsewhere(), "beach", mode)
                    volumes = {row["volumeId"] for row in result["entries"]}
                    self.assertEqual(volumes, {"uuid:CROWDED", "uuid:QUIET"})
                    self.assertEqual(result["catalog"]["searched"], 2)
                    self.assertTrue(result["catalog"]["truncated"])

    def test_names_that_match_are_read_before_paths_that_do(self) -> None:
        drive = self.drive()
        self.index_drive(drive)
        # Past a scan bound of path-only matches, a folder named exactly what
        # is typed, written last.
        connection = sqlite3.connect(self.catalog_file())
        rows = [(f"img_{number}.jpg".encode(), f"Photos/many/img_{number}.jpg".encode(), 0, "image")
                for number in range(30)] + [(b"photo", b"Zed/photo", 1, "folder")]
        connection.executemany(
            "INSERT INTO entries (name, rel, name_fold, rel_fold, is_dir, is_link, hidden,"
            " depth, size, mtime, smart_kind) VALUES (?, ?, ?, ?, ?, 0, 0, 1, 0, 1.0, ?)",
            [(name, rel, os.fsdecode(name), os.fsdecode(rel).casefold(), is_dir, kind)
             for name, rel, is_dir, kind in rows])
        connection.commit()
        connection.close()
        with mock.patch.object(quickfile, "CATALOG_SCAN_LIMIT", 10):
            for mode in ("contains", "fuzzy", "regex", "smart"):
                with self.subTest(mode=mode):
                    result = self.search(self.elsewhere(), "photo", mode)
                    self.assertIn("Zed/photo",
                                  [row["relativePath"] for row in result["entries"]])
        # A regex reads the text either side of an i as it is; a dotless ı
        # in a name still matches it, as re does.
        passes, _order = quickfile.catalog_keyword_filter("weddings", "regex")
        self.assertNotIn("replace(", " ".join(where for where, _params in passes))
        passes, _order = quickfile.catalog_keyword_filter("kit", "regex")
        self.assertIn("replace(", " ".join(where for where, _params in passes))

    def test_newest_first_reads_stop_at_what_a_list_can_use(self) -> None:
        drive = self.corpus({f"report-{number}.pdf": b"%PDF" for number in range(8)},
                            name="papers")
        self.index_drive(drive)
        with mock.patch.object(quickfile, "CATALOG_NEWEST_LIMIT", 3):
            result = self.search(self.elsewhere(), "pdf", "smart")
        self.assertEqual(result["catalog"]["scanned"], 3)
        self.assertEqual(len(result["entries"]), 3)
        self.assertTrue(result["catalog"]["truncated"])
        # A query without a filter reads every row anyway: no lookups to spare.
        with mock.patch.object(quickfile, "CATALOG_NEWEST_LIMIT", 3):
            regex = self.search(self.elsewhere(), "^r.p", "regex")
        self.assertEqual(len(regex["entries"]), 8)

    def test_search_reads_the_mounted_and_newest_catalogs_first(self) -> None:
        drives = {}
        for epoch, uuid in ((1000, "OLDEST"), (2000, "NEWEST"), (1500, "PLUGGED")):
            drive = self.corpus({f"{uuid.lower()}-beach.txt": b""}, name=uuid.lower())
            with mock.patch.object(quickfile.time, "time", return_value=epoch):
                self.index_drive(drive, disks=(self.disk(self.partition(mount=drive, uuid=uuid)),))
            drives[uuid] = drive
        self.plug("PLUGGED", mount=drives["PLUGGED"])
        with mock.patch.object(quickfile, "CATALOG_VOLUME_LIMIT", 2):
            result = self.search(self.elsewhere(), "beach", "contains")
        self.assertEqual(sorted((row["volumeId"], row["available"]) for row in result["entries"]),
                         [("uuid:NEWEST", False), ("uuid:PLUGGED", True)])
        self.assertEqual(result["catalog"]["searched"], 2)
        self.assertTrue(result["catalog"]["truncated"])

    def test_catalog_presence_is_read_from_dev_disk_and_the_mount_table(self) -> None:
        presence = quickfile.catalog_volume_presence
        disk = Path(os.environ["QUICKFILE_DEV_DISK_DIR"])
        # An unlocked LUKS drive: its filesystem's link resolves to dm-0, and
        # the mount table names it by its mapper path.
        dm = self.plug("FS-1", node="dm-0")
        mapper = self.root / "dev nodes" / "mapper"
        mapper.mkdir()
        (mapper / "luks-4f2a").symlink_to(dm)
        mount = os.fsencode(self.root) + b"/media/My Drive\\2024\tx"
        self.mount_line(mapper / "luks-4f2a", mount)
        self.assertEqual(presence({"volumeId": "uuid:FS-1"}),
                         (str(dm), os.fsdecode(mount), "mounted"))
        # Locked: only the header's UUID has a link.
        header = self.plug("LUKS-2", node="sdc1")
        self.assertEqual(presence({"volumeId": "uuid:FS-2", "containerUuid": "LUKS-2"}),
                         (str(header), "", "locked"))
        # A folder of a drive bound somewhere else is not where the drive is,
        # whichever the table lists first; a subvolume alone is.
        plain = self.plug("PLAIN-1", node="sdd1")
        self.assertEqual(presence({"volumeId": "uuid:PLAIN-1"}), (str(plain), "", "unmounted"))
        self.mount_line(plain, self.root / "bound", root="/Photos")
        self.mount_line(plain, self.root / "media" / "PLAIN")
        self.assertEqual(presence({"volumeId": "uuid:PLAIN-1"}),
                         (str(plain), str(self.root / "media" / "PLAIN"), "mounted"))
        volume = self.plug("BTRFS-1", node="sde9")
        self.mount_line(volume, self.root / "media" / "DATA", root="/@data")
        self.assertEqual(presence({"volumeId": "uuid:BTRFS-1"}),
                         (str(volume), str(self.root / "media" / "DATA"), "mounted"))
        self.assertEqual(presence({"volumeId": "uuid:GONE"}), ("", "", "disconnected"))
        (disk / "by-uuid" / "STALE").symlink_to(self.root / "dev nodes" / "sdz9")
        self.assertEqual(presence({"volumeId": "uuid:STALE"}), ("", "", "disconnected"))
        # The tier the catalog is filed under, and no other: a reformatted
        # stick keeps its partition UUID but is no longer the drive.
        (disk / "by-partuuid").mkdir()
        (disk / "by-partuuid" / "0ab1-02").symlink_to(plain)
        self.assertEqual(presence({"volumeId": "uuid:OLD", "partUuid": "0ab1-02"}),
                         ("", "", "disconnected"))
        self.assertEqual(presence({"volumeId": "part:0ab1-02"}),
                         (str(plain), str(self.root / "media" / "PLAIN"), "mounted"))
        (disk / "by-id").mkdir()
        for name, node in (("usb-Pocket_Drive_S4EVNF0M123456X-0:0", "sde"),
                           ("usb-Pocket_Drive_S4EVNF0M123456X-0:0-part2", "sde2"),
                           ("usb-Pocket_Drive_S4EVNF0M123456X-0:0-part1", "sde1"),
                           ("usb-Pocket_Drive_XS4EVNF0M123456X-0:0-part1", "sdf1")):
            target = self.root / "dev nodes" / node
            target.touch()
            (disk / "by-id" / name).symlink_to(target)
        self.assertEqual(presence({"volumeId": "serial:S4EVNF0M123456X:1:1000"}),
                         (str(self.root / "dev nodes" / "sde1"), "", "unmounted"))
        self.assertEqual(presence({"volumeId": "serial:S4EVNF0M123456X::1000"}),
                         (str(self.root / "dev nodes" / "sde"), "", "unmounted"))
        self.assertEqual(presence({"volumeId": "serial:S4EVNF0M123456X:p3:1000"}),
                         ("", "", "disconnected"))

    def test_settings_keep_the_offline_search_preference(self) -> None:
        fresh = quickfile.settings_command(argparse.Namespace())
        self.assertTrue(fresh["settings"]["offlineSearchEnabled"])
        saved = quickfile.settings_command(argparse.Namespace(offline_search="false"))
        self.assertTrue(saved["changed"])
        self.assertFalse(saved["settings"]["offlineSearchEnabled"])
        self.assertFalse(quickfile.load_settings_store()["offlineSearchEnabled"])
        again = quickfile.settings_command(argparse.Namespace(offline_search="false"))
        self.assertFalse(again["changed"])
        settings = Path(os.environ["QUICKFILE_SETTINGS_FILE"])
        # A settings file from before the preference existed has it on.
        settings.write_text(json.dumps({"version": 2, "sortOrder": "size"}), encoding="utf-8")
        self.assertTrue(quickfile.load_settings_store()["offlineSearchEnabled"])
        settings.write_text(json.dumps({"version": 2, "offlineSearchEnabled": "no"}),
                            encoding="utf-8")
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.load_settings_store()
        self.assertEqual(raised.exception.code, "settings-invalid")
        settings.unlink()
        code, lines = self.run_main(["settings", "--offline-search", "false"])
        self.assertEqual(code, 0)
        self.assertFalse(lines[-1]["settings"]["offlineSearchEnabled"])
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)
        code, lines = self.run_main(["settings", "--offline-search", "true"])
        self.assertTrue(lines[-1]["settings"]["offlineSearchEnabled"])

    def run_main(self, argv: list[str]) -> tuple[int, list[dict]]:
        output = io.StringIO()
        handlers = (signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGINT))
        try:
            with contextlib.redirect_stdout(output):
                code = quickfile.main(argv)
        finally:
            signal.signal(signal.SIGTERM, handlers[0])
            signal.signal(signal.SIGINT, handlers[1])
            quickfile._operation_cancelled = False
        return code, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_catalog_index_through_main_stops_on_sigterm(self) -> None:
        drive = self.drive()
        real_scandir = os.scandir

        def terminated_scandir(path):
            # The panel's Cancel: the walk is already under way when it lands.
            signal.raise_signal(signal.SIGTERM)
            return real_scandir(path)

        with self.lsblk(self.disk(self.partition(mount=drive)), mounts={str(drive)}), \
                mock.patch.object(quickfile.os, "scandir", terminated_scandir):
            code, lines = self.run_main(["catalog-index", "--device", "/dev/sdb1"])
        self.assertEqual(code, 130)
        self.assertEqual(lines[-1], {
            "ok": False, "error": "Operation cancelled", "code": "cancelled", "event": "result",
        })
        self.assertFalse(self.catalog_file().exists())
        self.assertEqual(self.catalog_temporaries(), [])

        with self.lsblk(self.disk(self.partition(mount=drive)), mounts={str(drive)}):
            code, lines = self.run_main(["catalog-index", "--device", "/dev/sdb1"])
        self.assertEqual(code, 0)
        self.assertEqual(lines[-1]["event"], "result")
        self.assertTrue(lines[-1]["ok"])
        self.assertEqual(lines[-1]["volume"]["volumeId"], "uuid:DRIVE-1")
        self.assertTrue(any(line.get("phase") == "saving" for line in lines))

        with self.lsblk():
            code, lines = self.run_main(["catalog-index", "--device", "/dev/sdb1"])
        self.assertEqual(code, 2)
        self.assertEqual((lines[-1]["code"], lines[-1]["event"]), ("volume-missing", "result"))
        code, lines = self.run_main(["catalog-forget", "--volume-id", "uuid:DRIVE-1"])
        self.assertEqual(code, 0)
        self.assertEqual(lines[-1]["message"], "Forgot “ARCHIVE”")

    def test_tree_sorts_directories_and_hides_dotfiles(self) -> None:
        result = quickfile.tree_command(self.tree_args())
        names = [row["name"] for row in result["entries"]]
        self.assertEqual(names[0], "folder")
        self.assertNotIn(".hidden", names)

    def test_tree_sort_orders_keep_directories_first(self) -> None:
        (self.root / "zebra").mkdir()
        (self.root / "big.bin").write_bytes(b"x" * 4096)
        (self.root / "tiny.bin").write_bytes(b"x")
        os.utime(self.root / "big.bin", (0, 0))
        os.utime(self.root / "tiny.bin", (2_000_000_000, 2_000_000_000))

        def names(order: str) -> list[str]:
            result = quickfile.tree_command(self.tree_args(sort=order))
            return [row["name"] for row in result["entries"] if row["depth"] == 0]

        for order in quickfile.SORT_ORDER:
            listed = names(order)
            self.assertEqual(
                set(listed[:2]), {"folder", "zebra"},
                f"{order} did not keep directories above files",
            )

        self.assertEqual(names("name")[:2], ["folder", "zebra"])
        self.assertEqual(names("name-desc")[:2], ["zebra", "folder"])
        self.assertEqual(names("name")[2:], sorted(names("name")[2:], key=str.casefold))
        self.assertEqual(names("name-desc")[2:], names("name")[2:][::-1])
        self.assertEqual(names("modified")[2], "tiny.bin")
        self.assertEqual(names("modified-asc")[2], "big.bin")
        self.assertEqual(names("size")[2], "big.bin")
        self.assertEqual(
            [name for name in names("type") if name.endswith(".bin")],
            ["big.bin", "tiny.bin"],
        )
        self.assertTrue(names("type").index("big.bin") < names("type").index("notes.txt"))

    def test_tree_rejects_an_unknown_sort_order(self) -> None:
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.tree_command(self.tree_args(sort="whatever"))
        self.assertEqual(raised.exception.code, "invalid-sort-order")

    def test_settings_persist_the_chosen_sort_order(self) -> None:
        saved = quickfile.settings_command(argparse.Namespace(
            active_sessions=None,
            inspector_tab=None,
            sort_order="size",
            module_layout_json=None,
        ))
        self.assertEqual(saved["settings"]["sortOrder"], "size")
        reread = quickfile.settings_command(argparse.Namespace(
            active_sessions=None,
            inspector_tab=None,
            sort_order=None,
            module_layout_json=None,
        ))
        self.assertEqual(reread["settings"]["sortOrder"], "size")
        self.assertFalse(reread["changed"])

    def test_settings_remember_that_smart_onboarding_is_done(self) -> None:
        # A settings file from before the flag existed still loads, not done.
        quickfile.settings_file().parent.mkdir(parents=True, exist_ok=True)
        quickfile.settings_file().write_text(
            json.dumps({"version": 2, "sortOrder": "name"}), encoding="utf-8",
        )
        fresh = quickfile.settings_command(argparse.Namespace())
        self.assertFalse(fresh["settings"]["smartOnboardingDone"])
        saved = quickfile.settings_command(argparse.Namespace(smart_onboarding_done="true"))
        self.assertTrue(saved["changed"])
        reread = quickfile.settings_command(argparse.Namespace())
        self.assertTrue(reread["settings"]["smartOnboardingDone"])
        quickfile.settings_file().write_text(
            json.dumps({"version": 2, "smartOnboardingDone": "yes"}), encoding="utf-8",
        )
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.settings_command(argparse.Namespace())
        self.assertEqual(raised.exception.code, "settings-invalid")

    def test_settings_persist_the_chosen_date_format(self) -> None:
        saved = quickfile.settings_command(argparse.Namespace(
            active_sessions=None, inspector_tab=None, sort_order=None,
            date_format="relative", module_layout_json=None,
        ))
        self.assertEqual(saved["settings"]["dateFormat"], "relative")
        reread = quickfile.settings_command(argparse.Namespace(
            active_sessions=None, inspector_tab=None, sort_order=None,
            date_format=None, module_layout_json=None,
        ))
        self.assertEqual(reread["settings"]["dateFormat"], "relative")
        self.assertFalse(reread["changed"])

    def test_settings_reject_an_unknown_date_format(self) -> None:
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.settings_command(argparse.Namespace(
                active_sessions=None, inspector_tab=None, sort_order=None,
                date_format="whenever", module_layout_json=None,
            ))
        self.assertEqual(raised.exception.code, "settings-invalid")

    def test_settings_default_the_date_format_when_absent(self) -> None:
        store = quickfile.load_settings_store()
        self.assertEqual(store["dateFormat"], "full")

    def test_directory_size_sums_the_tree_like_du(self) -> None:
        (self.root / "folder" / "deep").mkdir()
        (self.root / "folder" / "deep" / "payload.bin").write_bytes(b"x" * 5000)
        result = quickfile.directory_size_command(argparse.Namespace(
            path=str(self.root), path_token=None,
        ))
        expected = 0
        for base, _, names in os.walk(self.root):
            for name in names:
                target = os.path.join(base, name)
                if not os.path.islink(target):
                    expected += os.lstat(target).st_size
        self.assertEqual(result["size"], expected)
        self.assertTrue(result["ok"])
        self.assertFalse(result["truncated"])
        self.assertGreaterEqual(result["directories"], 2)
        self.assertEqual(result["links"], 1)

    def test_directory_size_counts_a_hard_link_once(self) -> None:
        room = self.root / "links"
        room.mkdir()
        (room / "original.bin").write_bytes(b"y" * 4096)
        os.link(room / "original.bin", room / "same.bin")
        result = quickfile.directory_size_command(argparse.Namespace(
            path=str(room), path_token=None,
        ))
        self.assertEqual(result["size"], 4096)
        self.assertEqual(result["files"], 2)

    def test_directory_size_marks_a_walk_that_hit_its_ceiling(self) -> None:
        with mock.patch.object(quickfile, "MEASURE_ENTRY_LIMIT", 2):
            result = quickfile.directory_size_command(argparse.Namespace(
                path=str(self.root), path_token=None,
            ))
        self.assertTrue(result["truncated"])
        # The copy scanner's ceiling is sized for what undo has to journal and
        # would stop a measurement far short of an ordinary home directory.
        self.assertGreater(quickfile.MEASURE_ENTRY_LIMIT,
                           quickfile.OPERATION_ENTRY_LIMIT)

    def test_directory_size_streams_a_directory_instead_of_listing_it(self) -> None:
        # A directory large enough to hurt is the reason the ceiling exists, so
        # the walk has to stop pulling entries at it — not after the kernel has
        # handed over every one of them into a list.
        produced = {"count": 0}

        class Entry:
            def __init__(self, name: str) -> None:
                self.name = name

            def stat(self, follow_symlinks: bool = True) -> os.stat_result:
                return os.stat_result(
                    (0o100644, 1, 1, 1, 0, 0, 8, 0, 0, 0))

            def is_dir(self, follow_symlinks: bool = True) -> bool:
                return False

        class Scan:
            def __enter__(self):
                def entries():
                    for index in range(1000):
                        produced["count"] += 1
                        yield Entry("file-%d.bin" % index)
                return entries()

            def __exit__(self, *_):
                return False

        with mock.patch.object(os, "scandir", lambda _path: Scan()), \
                mock.patch.object(quickfile, "MEASURE_ENTRY_LIMIT", 10):
            result = quickfile.directory_size_command(argparse.Namespace(
                path=str(self.root), path_token=None,
            ))
        self.assertTrue(result["truncated"])
        # One past the ceiling is what it takes to notice it; a listed
        # directory would have produced all thousand.
        self.assertLessEqual(produced["count"], 11)

    def test_directory_size_bounds_the_directory_queue(self) -> None:
        for index in range(4):
            (self.root / ("branch-%d" % index)).mkdir()
        with mock.patch.object(quickfile, "MEASURE_PENDING_LIMIT", 1):
            result = quickfile.directory_size_command(argparse.Namespace(
                path=str(self.root), path_token=None,
            ))
        self.assertTrue(result["truncated"])
        # Every directory is still counted; what the ceiling bounds is what
        # the walk holds on to.
        self.assertGreaterEqual(result["directories"], 5)
        self.assertLess(quickfile.MEASURE_PENDING_LIMIT,
                        quickfile.OPERATION_ENTRY_LIMIT)

    def test_directory_size_bounds_the_hard_link_set(self) -> None:
        room = self.root / "pairs"
        room.mkdir()
        (room / "original.bin").write_bytes(b"z" * 2048)
        os.link(room / "original.bin", room / "same.bin")
        with mock.patch.object(quickfile, "MEASURE_IDENTITY_LIMIT", 0):
            result = quickfile.directory_size_command(argparse.Namespace(
                path=str(room), path_token=None,
            ))
        # Retaining nothing, the walk counts the pair twice. That is an upper
        # bound, and `truncated` is what says so rather than a silent overstatement.
        self.assertEqual(result["size"], 4096)
        self.assertTrue(result["truncated"])
        self.assertLess(quickfile.MEASURE_IDENTITY_LIMIT,
                        quickfile.MEASURE_ENTRY_LIMIT)

    def test_directory_size_refuses_a_file(self) -> None:
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.directory_size_command(argparse.Namespace(
                path=str(self.root / "notes.txt"), path_token=None,
            ))
        self.assertEqual(raised.exception.code, "not-a-directory")

    def test_directory_size_stops_when_cancelled(self) -> None:
        quickfile.request_operation_cancel(0, None)
        try:
            with self.assertRaises(quickfile.OperationCancelled):
                quickfile.directory_size_command(argparse.Namespace(
                    path=str(self.root), path_token=None,
                ))
        finally:
            quickfile._operation_cancelled = False

    def test_tree_expands_only_requested_directory(self) -> None:
        token = quickfile.encode_path(str(self.root / "folder"))
        result = quickfile.tree_command(self.tree_args(expanded=[token]))
        rows = {row["name"]: row for row in result["entries"]}
        self.assertTrue(rows["folder"]["expanded"])
        self.assertEqual(rows["nested.txt"]["depth"], 1)

    def test_tree_watch_tracks_only_visited_directories_and_metadata(self) -> None:
        directory = self.root / "folder"
        initial = quickfile.tree_command(self.tree_args())
        self.assertEqual(initial["watch"]["directories"], [quickfile.encode_path(str(self.root))])
        self.assertIn(
            quickfile.encode_path(str(self.root / "quickfile-metadata.json")),
            initial["watch"]["files"],
        )
        expanded = quickfile.tree_command(self.tree_args(expanded=[quickfile.encode_path(str(directory))]))
        self.assertEqual(set(expanded["watch"]["directories"]), {
            quickfile.encode_path(str(self.root)), quickfile.encode_path(str(directory)),
        })

    def test_search_watch_includes_traversed_directories_without_matches(self) -> None:
        result = quickfile.search_command(argparse.Namespace(
            path=str(self.root), path_token=None, query="absent-needle", mode="exact",
            case_sensitive=False, show_hidden=False, no_git=True, limit=100,
            scan_limit=1000, timeout=2.0,
        ))
        self.assertEqual(result["entries"], [])
        self.assertIn(quickfile.encode_path(str(self.root / "folder")), result["watch"]["directories"])

    def test_knowledge_watch_includes_missing_candidates_and_symlink_targets(self) -> None:
        project = self.root / "project"
        project.mkdir()
        target = self.root / "shared.md"
        target.write_text("instructions")
        (project / "CLAUDE.md").symlink_to(target)
        result = quickfile.knowledge_command(argparse.Namespace(
            path=str(project), path_token=None, limit=128,
        ))
        watched_files = set(result["watch"]["files"])
        for path in (project / "AGENTS.override.md", project / "AGENTS.md", project / "CLAUDE.md", target):
            self.assertIn(quickfile.encode_path(str(path)), watched_files)
        self.assertIn(
            quickfile.encode_path(str(project / ".cursor" / "rules")),
            result["watch"]["directories"],
        )

    def test_watch_dependencies_report_when_coverage_is_bounded(self) -> None:
        with mock.patch.object(quickfile, "WATCH_PATH_LIMIT", 3):
            result = quickfile.knowledge_command(argparse.Namespace(
                path=str(self.root), path_token=None, limit=128,
            ))
        self.assertTrue(result["watch"]["truncated"])
        self.assertEqual(len(result["watch"]["files"]) + len(result["watch"]["directories"]), 3)

    def test_search_supports_fuzzy_and_regex(self) -> None:
        fuzzy_args = argparse.Namespace(
            path=str(self.root), path_token=None, query="ntxt", mode="fuzzy",
            case_sensitive=False, show_hidden=False, no_git=True, limit=100,
            scan_limit=1000, timeout=2.0,
        )
        self.assertIn("nested.txt", [row["name"] for row in quickfile.search_command(fuzzy_args)["entries"]])
        fuzzy_args.query = r"^folder/.+\.txt$"
        fuzzy_args.mode = "regex"
        self.assertEqual(quickfile.search_command(fuzzy_args)["entries"][0]["name"], "nested.txt")

    def test_search_labels_folder_name_file_name_and_content_matches(self) -> None:
        args = argparse.Namespace(
            path=str(self.root), path_token=None, query="folder", mode="exact",
            case_sensitive=False, show_hidden=False, no_git=True, limit=100,
            scan_limit=1000, timeout=2.0,
        )
        folder = quickfile.search_command(args)["entries"][0]
        self.assertEqual(folder["matchKind"], "folder")

        args.query = "notes"
        args.mode = "prefix"
        named = quickfile.search_command(args)["entries"][0]
        self.assertEqual(named["matchKind"], "name")

        args.query = "hello"
        args.mode = "contains"
        content = quickfile.search_command(args)["entries"][0]
        self.assertEqual(content["name"], "notes.txt")
        self.assertEqual(content["matchKind"], "content")
        self.assertEqual(content["matchLine"], 1)
        self.assertEqual(content["matchSnippet"], "hello")

    def test_smart_search_extracts_bilingual_rules_and_keeps_hints_soft(self) -> None:
        plan = quickfile.fallback_plan("PDF с графиком за прошлый месяц")
        self.assertEqual(plan["terms"], ["график"])
        self.assertEqual(plan["hints"]["kind"]["value"], "document")
        self.assertEqual(plan["hints"]["time"]["value"], "last-month")

        # The checkpoint's hints below 0.75 were mostly noise when measured.
        low_confidence = quickfile_smart.merge_laya_answers(
            quickfile.fallback_plan("garden"),
            {"kind": {"choice": "document", "confidence": 0.74},
             "time": {"choice": "older", "confidence": 0.8}},
        )
        self.assertEqual(low_confidence["hints"]["kind"]["value"], "any")
        self.assertEqual(low_confidence["hints"]["time"], {
            "value": "older", "confidence": 0.8, "source": "laya",
        })

        # A deliberately wrong image hint must not hide a strong text match.
        plan = quickfile.fallback_plan("hello")
        plan["hints"]["kind"] = {
            "value": "image", "confidence": 0.99, "source": "laya",
        }
        result = quickfile.search_command(argparse.Namespace(
            path=str(self.root), path_token=None, query="hello", mode="smart",
            smart_plan_json=json.dumps(plan), case_sensitive=False,
            show_hidden=False, no_git=True, limit=100, scan_limit=1000,
            timeout=2.0, content_file_limit=1024 * 1024,
            content_byte_limit=8 * 1024 * 1024,
        ))
        self.assertEqual(result["entries"][0]["name"], "notes.txt")
        self.assertEqual(result["smart"]["state"], "ready")
        self.assertEqual(result["entries"][0]["matchKind"], "content")

    def assert_plans(self, cases: dict[str, tuple[list[str], dict[str, str]]]) -> None:
        for query, (terms, hints) in cases.items():
            with self.subTest(query=query):
                plan = quickfile.fallback_plan(query)
                self.assertEqual(plan["terms"], terms)
                self.assertEqual({
                    field: hint["value"] for field, hint in plan["hints"].items()
                    if hint["value"] != "any"
                }, hints)

    def test_smart_rules_cover_ukrainian_and_keep_topic_words_out_of_dates(self) -> None:
        self.assert_plans({
            "подкаст про стартапы": (["стартап"], {"kind": "audio"}),
            "старые проекты": (["проект"], {"target": "folder", "time": "older"}),
            "недавние архивы": ([], {"kind": "archive", "time": "past-month"}),
            "знайди музику з минулого місяця": ([], {"kind": "audio", "time": "last-month"}),
            "вчерашние заметки": (["заметк"], {"time": "yesterday"}),
            "тека з проєктами": (["проєкт"], {"target": "folder"}),
            "налаштування zorbwm": (["zorbwm"], {"kind": "config"}),
            "файлы за прошлый год": ([], {"target": "file", "time": "last-year"}),
            "old invoices": (["invoices"], {"kind": "document", "time": "older"}),
            # A kind word is a stem and a case ending, never the start of a
            # longer topic word.
            "видеонаблюдение камеры": (["видеонаблюден", "камер"], {}),
            "конфигуратор кухни": (["конфигуратор", "кухн"], {}),
            "скрининг результаты": (["скрининг", "результат"], {}),
            "каталог товаров": (["каталог", "товар"], {}),
            "setting up nginx": (["setting", "up", "nginx"], {}),
            # The kind named first is asked for; an English compound ends in it.
            "видео с музыкой": ([], {"kind": "video"}),
            "photo archive": ([], {"kind": "archive"}),
            "script for photos": ([], {"kind": "code"}),
            # A hint word inside a file name belongs to the name.
            "notes.old": (["notes.old"], {}),
        })

    def test_smart_hint_phrases_are_spent_on_their_hints(self) -> None:
        self.assert_plans({
            "черновик прошлого месяца": (["черновик"], {"time": "last-month"}),
            "notes that mention pricing": (["notes", "pricing"], {"location": "content"}),
            "notes mentioning pricing": (["notes", "pricing"], {"location": "content"}),
            "що згадує оренду офісу": (["оренд", "офіс"], {"location": "content"}),
            "the memo that discusses the lease": (["memo", "lease"], {"location": "content"}),
            # A span is blanked where it was found, whatever casefolding does
            # to the length of the letters before it.
            "Straße Größe yesterday invoice": (
                ["Straße", "Größe", "invoice"], {"kind": "document", "time": "yesterday"}),
            "İİİ last week agenda": (["İİİ", "agenda"], {"time": "last-week"}),
            # "icon sets" is about sets of icons.
            "icon sets": (["icon", "sets"], {}),
        })

    def test_smart_terms_trim_only_safe_inflections(self) -> None:
        self.assertEqual(quickfile.fallback_plan("фотки с отпуска")["terms"], ["отпуск"])
        # Quoted phrases, short words and words without an ending stay verbatim.
        self.assertEqual(
            quickfile.fallback_plan('"отчёт за квартал" Львов договор status class')["terms"],
            ['"отчёт за квартал"', "Львов", "договор", "status", "class"],
        )
        # Adjective endings also end names, and -ок/-ек are as often a
        # nominative as a plural: only long adjectives lose theirs.
        self.assertEqual(
            quickfile.fallback_plan("Вадим Кривых станок список годовых техническим")["terms"],
            ["Вадим", "Кривых", "станок", "список", "годов", "техническ"],
        )
        folder = self.root / "отпуск 2025"
        folder.mkdir()
        (folder / "график.pdf").write_bytes(b"%PDF-1.4")
        result = quickfile.search_command(argparse.Namespace(
            path=str(self.root), path_token=None, query="PDF с графиком за прошлый месяц",
            mode="smart", smart_plan_json=None, case_sensitive=False,
            show_hidden=False, no_git=True, limit=100, scan_limit=1000,
            timeout=2.0, content_file_limit=1024 * 1024,
            content_byte_limit=8 * 1024 * 1024,
        ))
        self.assertEqual(result["entries"][0]["name"], "график.pdf")
        root = self.corpus({
            "книжка-рецептів.pdf": b"%PDF-1.4", "станок-чпу.pdf": b"%PDF-1.4",
            "стандарт-качества.pdf": b"%PDF-1.4", "vad-volume.txt": "",
        })
        # A word with a fleeting vowel meets its other forms, and nothing else,
        # and a name keeps the letters that would make it someone else's.
        self.assertEqual(self.smart_names(root, "книжок"), ["книжка-рецептів.pdf"])
        self.assertEqual(self.smart_names(root, "станок"), ["станок-чпу.pdf"])
        self.assertEqual(self.smart_names(root, "Вадим"), [])

    def test_smart_search_supports_filters_only_without_hiding_other_rows(self) -> None:
        image = self.root / "photo.png"
        image.write_bytes(b"not-a-real-image")
        plan = quickfile.fallback_plan("show images from this month")
        result = quickfile.search_command(argparse.Namespace(
            path=str(self.root), path_token=None, query="show images from this month",
            mode="smart", smart_plan_json=json.dumps(plan), case_sensitive=False,
            show_hidden=False, no_git=True, limit=100, scan_limit=1000,
            timeout=2.0, content_file_limit=1024 * 1024,
            content_byte_limit=8 * 1024 * 1024,
        ))
        names = [row["name"] for row in result["entries"]]
        self.assertEqual(names[0], "photo.png")
        self.assertIn("notes.txt", names)
        self.assertIn("image", result["entries"][0]["smartReasons"])

    def test_smart_search_rejects_untrusted_plan_and_falls_back(self) -> None:
        result = quickfile.search_command(argparse.Namespace(
            path=str(self.root), path_token=None, query="notes", mode="smart",
            smart_plan_json='{"version":99}', case_sensitive=False,
            show_hidden=False, no_git=True, limit=100, scan_limit=1000,
            timeout=2.0, content_file_limit=1024 * 1024,
            content_byte_limit=8 * 1024 * 1024,
        ))
        self.assertEqual(result["smart"]["state"], "fallback")
        self.assertEqual(result["smart"]["fallbackReason"], "invalid-plan")
        self.assertIn("notes.txt", [row["name"] for row in result["entries"]])

        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.search_command(argparse.Namespace(
                path=str(self.root), path_token=None, query="x" * 513, mode="smart",
                smart_plan_json=None, case_sensitive=False, show_hidden=False,
                no_git=True, limit=100, scan_limit=1000, timeout=2.0,
                content_file_limit=1024 * 1024,
                content_byte_limit=8 * 1024 * 1024,
            ))
        self.assertEqual(raised.exception.code, "smart-query-too-large")

    def test_smart_calendar_windows_use_local_calendar_boundaries(self) -> None:
        zone = quickfile.dt.datetime.now().astimezone().tzinfo
        now = quickfile.dt.datetime(2026, 9, 22, 15, 0, tzinfo=zone)
        last_month = quickfile.dt.datetime(2026, 8, 18, 10, 0, tzinfo=zone).timestamp()
        this_month = quickfile.dt.datetime(2026, 9, 1, 0, 0, tzinfo=zone).timestamp()
        self.assertTrue(quickfile.smart_time_matches(last_month, "last-month", now))
        self.assertFalse(quickfile.smart_time_matches(this_month, "last-month", now))

    def smart_search(self, root: Path, query: str, plan: dict | None = None, **overrides):
        values = {
            "path": str(root), "path_token": None, "query": query, "mode": "smart",
            "smart_plan_json": None if plan is None else json.dumps(plan),
            "case_sensitive": False, "show_hidden": False, "no_git": True, "limit": 100,
            "scan_limit": 1000, "timeout": 2.0, "content_file_limit": 1024 * 1024,
            "content_byte_limit": 8 * 1024 * 1024,
        }
        values.update(overrides)
        return quickfile.search_command(argparse.Namespace(**values))

    def smart_names(self, root: Path, query: str, **overrides) -> list[str]:
        result = self.smart_search(root, query, **overrides)
        return [row["relativePath"] for row in result["entries"]]

    def corpus(self, files: dict[str, str | bytes], name: str = "corpus") -> Path:
        root = self.root / name
        for relative, body in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(body, bytes):
                path.write_bytes(body)
            else:
                path.write_text(body, encoding="utf-8")
        return root

    def test_smart_formats_are_explicit_optional_and_validated(self) -> None:
        cases = {
            "network diagram PNGs": (["network", "diagram"], ["png"]),
            "inventory in excel": (["inventory"], ["xlsx"]),
            "PDF с графиком": (["график"], ["pdf"]),
            "презентация pptx отчёт": (["презентаци", "отчёт"], ["pptx"]),
            # Hyphenated to a word for its own kind, a format is asked for.
            "pdf-документ": ([], ["pdf"]),
            "pptx-презентація": ([], ["pptx"]),
            "notes as .md": (["notes"], ["md"]),
            "*.png icons": (["icons"], ["png"]),
            "site backup .tar.gz": (["site", "backup"], ["gz"]),
            # A format word that describes another word is a keyword.
            "csv parser": (["csv", "parser"], []),
            "json schema validator": (["json", "schema", "validator"], []),
            "pdf merge script": (["pdf", "merge"], []),
            "mp4 to gif script": (["mp4", "gif"], []),
            "json-server setup": (["json-server", "setup"], []),
            # Extensions that are also words or names need their dot.
            "magnum opus notes": (["magnum", "opus", "notes"], []),
            "Avi wedding photos": (["Avi", "wedding"], []),
            "tar pit": (["tar", "pit"], []),
            "rss feed parser": (["rss", "feed", "parser"], []),
            # A quoted phrase is searched as typed.
            '"notes on png compression"': (['"notes on png compression"'], []),
        }
        for query, (terms, formats) in cases.items():
            with self.subTest(query=query):
                plan = quickfile.fallback_plan(query)
                self.assertEqual((plan["terms"], plan["formats"]), (terms, formats))
        self.assertEqual(quickfile.fallback_plan("network diagram PNGs")["hints"]["kind"]["value"],
                         "image")
        self.assertEqual(quickfile.fallback_plan("mp4 to gif script")["hints"]["kind"]["value"],
                         "code")
        self.assertIn(".jpeg", quickfile_smart.format_suffixes(["jpg"]))
        self.assertIn(".xls", quickfile_smart.format_suffixes(["xlsx"]))

        legacy = {"version": 1, "terms": ["garden"], "hints": {}}
        self.assertEqual(quickfile.validate_plan(legacy)["formats"], [])
        for formats in (["exe"], "pdf", ["pdf", 1], ["pdf", "png", "jpg", "zip", "mp4"]):
            with self.subTest(formats=formats), self.assertRaises(quickfile.SmartPlanError):
                quickfile.validate_plan({**legacy, "formats": formats})

    def test_smart_format_words_that_are_topics_rank_as_keywords(self) -> None:
        root = self.corpus({
            "tools/mp4_to_gif.py": "", "clips/holiday.mp4": b"\x00",
            "bin/pdf-merge.sh": "", "merge.pdf": b"%PDF-1.4",
            "backups/site-backup.tar.gz": b"\x1f\x8b", "backups/site-backup.zip": b"PK",
        })
        self.assertEqual(self.smart_names(root, "mp4 converter script")[0], "tools/mp4_to_gif.py")
        self.assertEqual(self.smart_names(root, "pdf merge script")[0], "bin/pdf-merge.sh")
        result = self.smart_search(root, "site backup .tar.gz")
        self.assertEqual(result["entries"][0]["relativePath"], "backups/site-backup.tar.gz")
        self.assertIn("format", result["entries"][0]["smartReasons"])

    def test_smart_model_fills_only_the_hints_it_is_asked(self) -> None:
        self.assertEqual(set(quickfile_smart.questions()), set(quickfile_smart.SMART_MODEL_FIELDS))
        merged = quickfile_smart.merge_laya_answers(
            quickfile.fallback_plan("договір оренди гаража"),
            {"kind": {"choice": "video", "confidence": 0.99},
             "time": {"choice": "older", "confidence": 0.9}},
        )
        self.assertEqual(merged["hints"]["kind"]["value"], "document")
        self.assertEqual(merged["hints"]["kind"]["source"], "rule")
        self.assertEqual(merged["hints"]["time"]["source"], "laya")
        merged = quickfile_smart.merge_laya_answers(
            quickfile.fallback_plan("a garden for bees"),
            {"kind": {"choice": "config", "confidence": 0.99}},
        )
        self.assertEqual(merged["hints"]["kind"]["value"], "any")

    def test_smart_matches_words_not_scattered_letters(self) -> None:
        root = self.corpus({
            "zorb-gearbox.svg": "<svg/>\n",
            "LICENSE": "Copyright 2026 Zorb Labs\n",
            "golf-echo-alpha-romeo-bravo-oscar-xray.txt": "nothing to see\n",
            "Sketches/gearbox.md": "Zorb gearbox sketch\n",
            "syntax.md": "The zor-bright syntax of a haiku\n",
            "export-report.txt": "", "support.md": "", "ports.txt": "",
            "controversy.md": "", "rover-photos.md": "",
            "server/requestHandler.js": "", "server/app.js": "const requestHandler = 1\n",
            "notes/pets.txt": "my cat sleeps\n", "notes/list.txt": "category list\n",
            "notes/main.c": "int main(void) { return 0; }\n",
        })
        names = self.smart_names(root, "zorb gearbox")
        # The name with both words, then the one whose text has the other.
        self.assertEqual(names[:2], ["zorb-gearbox.svg", "Sketches/gearbox.md"])
        # g..e..a..r..b..o..x is somewhere in that name, but no word of it
        # matches.
        self.assertNotIn("golf-echo-alpha-romeo-bravo-oscar-xray.txt", names)
        # A text that only mentions the name is found, below the named file.
        result = self.smart_search(root, "zorb")
        names = [row["relativePath"] for row in result["entries"]]
        self.assertEqual(names[0], "zorb-gearbox.svg")
        self.assertIn("LICENSE", names)
        self.assertEqual(result["entries"][names.index("LICENSE")]["matchKind"], "content")
        # A short word has to start a word, and a word of three letters may
        # only add an ending, in text as in names.
        self.assertNotIn("syntax.md", self.smart_names(root, "tax"))
        self.assertEqual(self.smart_names(root, "cat"), ["notes/pets.txt"])
        self.assertEqual(self.smart_names(root, "ai"), [])
        # Only a long word matches inside another: "port" is not in "report",
        # nor "rover" in "controversy", but "handler" is in "requestHandler".
        self.assertEqual(self.smart_names(root, "port"), ["ports.txt"])
        self.assertEqual(self.smart_names(root, "rover"), ["rover-photos.md"])
        self.assertEqual(
            sorted(self.smart_names(root, "handler")),
            ["server/app.js", "server/requestHandler.js"],
        )

    def test_smart_spellings_cross_languages_and_scripts(self) -> None:
        root = self.corpus({
            "Docs/receipt-scan.pdf": b"%PDF-1.4",
            "Docs/invoice-scan.pdf": b"%PDF-1.4",
            "Travel/Lviv trip.md": "",
            "Travel/Одеса-2025.jpg": b"\xff\xd8",
            "Travel/Зорбина notes.md": "",
            "Travel/vine.txt": "", "Travel/vicki.md": "", "Travel/ski.txt": "",
            "Docs/report-q3.md": "Отчет по складу готов\n",
        })
        cases = {
            "квитанції": "Docs/receipt-scan.pdf",
            "поездка Львів": "Travel/Lviv trip.md",
            "фото Одесса": "Travel/Одеса-2025.jpg",
            "odesa": "Travel/Одеса-2025.jpg",
            "Зорбіна": "Travel/Зорбина notes.md",
        }
        for query, expected in cases.items():
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query)[0], expected)
        # Only words of the other script are transliterated: English words
        # are not their neighbours' spellings.
        for query in ("wine", "wiki", "sky"):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query), [])
        # In text too, ё and е, і and и are one letter, with rg and without.
        self.assertIn("Docs/report-q3.md", self.smart_names(root, "отчёт"))
        with mock.patch.object(quickfile.shutil, "which", return_value=None):
            self.assertIn("Docs/report-q3.md", self.smart_names(root, "отчёт"))

    def test_smart_vocabulary_takes_whole_words_with_their_endings(self) -> None:
        for word, group in (
            ("invoices", "invoice"), ("рахунку", "invoice"), ("договору", "contract"),
            ("наради", "meeting"), ("скріни", "screenshot"), ("cv", "resume"),
            ("projections", ""), ("projector", ""), ("записки", ""), ("счетчиков", ""),
            ("insta", ""), ("contractor", ""), ("листопад", ""), ("лист", ""),
        ):
            with self.subTest(word=word):
                self.assertEqual(quickfile_smart.SmartTerm(word).group, group)
        # A letter is a Ukrainian "лист", which typed alone is not a letter.
        self.assertIn("лист", [form[0] for form in quickfile_smart.SmartTerm("письмо").forms])

    def test_smart_months_count_only_where_a_date_writes_them(self) -> None:
        root = self.corpus({
            "Garden/2024/03/seedlings.md": "", "Garden/2024/04/seedlings.md": "",
            "seedlings_20240312.txt": "", "export-2024-04-05_15-03-09.csv": "a,b\n",
            "01 intro.md": "", "jan-notes.md": "", "2026-01-15-plan.md": "",
            "pricing/2026-05-01.md": "",
        })
        # March by a date in the name, or by the month's folder in a year's.
        names = self.smart_names(root, "seedlings march")
        self.assertEqual(set(names[:2]), {"Garden/2024/03/seedlings.md", "seedlings_20240312.txt"})
        # The minutes of a time of day are no month.
        self.assertNotIn("export-2024-04-05_15-03-09.csv", self.smart_names(root, "march"))
        self.assertEqual(self.smart_names(root, "январь"), ["2026-01-15-plan.md"])
        # "may" is a verb; "May" is the month. Neither a planet, a name nor a
        # number is one.
        self.assertEqual(quickfile_smart.SmartTerm("may").month, "")
        self.assertEqual(quickfile_smart.SmartTerm("May").month, "05")
        for word in ("mars", "Jan", "12", "має"):
            with self.subTest(word=word):
                self.assertEqual(quickfile_smart.SmartTerm(word).month, "")
        self.assertNotIn("pricing/2026-05-01.md", self.smart_names(root, "notes that may"))

    def test_smart_forgives_one_typo_only_in_a_word_no_name_has(self) -> None:
        for first, second, expected in (
            ("calender", "calendar", True), ("calendr", "calendar", True), ("teh", "the", True),
            ("calendar", "calendar", False), ("invoice", "invoke", False),
        ):
            with self.subTest(first=first, second=second):
                self.assertEqual(quickfile_smart.within_one_edit(first, second), expected)
        root = self.corpus({
            "calendar/README.md": "", "calculator.md": "", "MoonHarbor.png": b"\x89PNG",
        })
        names = self.smart_names(root, "calender")
        self.assertEqual(names[0], "calendar")
        self.assertNotIn("calculator.md", names)
        # A camelCase hump is a word too.
        self.assertEqual(self.smart_names(root, "moon harbr"), ["MoonHarbor.png"])
        # A word that some name spells is not a slip of its neighbours.
        root = self.corpus({"stats.md": "", "state.md": ""}, "typed")
        self.assertEqual(self.smart_names(root, "state"), ["state.md"])
        root = self.corpus({"stats.md": ""}, "slipped")
        self.assertEqual(self.smart_names(root, "state"), ["stats.md"])

    def test_smart_walk_prunes_machine_written_trees_unless_named(self) -> None:
        root = self.corpus({
            "docs/lantern.md": "lantern\n",
            "app/node_modules/pkg/lantern.js": "lantern\n",
            "app/node_modules/pkg/node-version.txt": "",
            "app/node_modules/pkg/readme.txt": "a lantern inside\n",
            "app/venv/pyvenv.cfg": "home = /usr/bin\n",
            "app/venv/bin/lantern": "#!/bin/sh\n",
            "app/venv/lib/python3.12/site-packages/lantern.py": "lantern\n",
            "app/target/CACHEDIR.TAG": "Signature: 8a477f597d28d172789f06886806bc55\n",
            "app/target/lantern.txt": "lantern\n",
            # `python -m venv .` in a project: its lib/, share/ and sources
            # are still searched.
            "tool/pyvenv.cfg": "home = /usr/bin\n",
            "tool/lib/python3.12/site-packages/lantern_lib.py": "",
            "tool/lib/lantern_invoice.js": "",
            "tool/share/templates/lantern-template.html": "",
            "tool/src/lantern_parser.py": "",
        })
        result = self.smart_search(root, "lantern")
        self.assertEqual(sorted(row["relativePath"] for row in result["entries"]), [
            "docs/lantern.md", "tool/lib/lantern_invoice.js",
            "tool/share/templates/lantern-template.html", "tool/src/lantern_parser.py",
        ])
        # node_modules, venv/bin, both python3.12 libraries and target/.
        self.assertEqual(result["pruned"], 5)
        # A word of a pruned folder's name does not open it; its name does,
        # for the walk and for rg alike.
        self.assertEqual(self.smart_names(root, "node version"), ["app/node_modules"])
        named = self.smart_names(root, "node_modules lantern")
        self.assertIn("app/node_modules/pkg/lantern.js", named)
        self.assertIn("app/node_modules/pkg/readme.txt", named)
        # The root itself is always searched, whatever it is.
        packages = root / "app" / "venv" / "lib" / "python3.12" / "site-packages"
        self.assertEqual(self.smart_names(packages, "lantern"), ["lantern.py"])

    def test_smart_walk_reaches_every_area_before_going_deep(self) -> None:
        deep = "aaa/" + "/".join(f"level{index}" for index in range(8))
        root = self.corpus({
            f"{deep}/filler-{index}.txt": "" for index in range(20)
        } | {"zzz/needle.txt": ""})
        # Two entries at the top, one in each folder below: a depth-first walk
        # into aaa/ would spend this budget before it ever reached zzz/.
        result = self.smart_search(root, "needle", scan_limit=4)
        self.assertTrue(result["truncated"])
        self.assertEqual([row["relativePath"] for row in result["entries"]], ["zzz/needle.txt"])

    def test_smart_walk_keeps_what_a_failing_directory_gave(self) -> None:
        root = self.corpus({"mount/alpha.txt": "", "local/alpha-notes.txt": ""})
        scandir = os.scandir

        class Failing:
            def __init__(self, inner) -> None:
                self.inner = inner

            def __enter__(self):
                return self

            def __exit__(self, *_exc) -> None:
                self.inner.close()

            def __iter__(self):
                yield next(iter(self.inner))
                raise OSError(quickfile.errno.EIO, "Input/output error")

        def flaky(path):
            listing = scandir(path)
            return Failing(listing) if os.path.basename(path) == "mount" else listing

        with mock.patch.object(quickfile.os, "scandir", side_effect=flaky):
            result = self.smart_search(root, "alpha")
        names = [row["relativePath"] for row in result["entries"]]
        self.assertIn("local/alpha-notes.txt", names)
        self.assertIn("mount/alpha.txt", names)
        self.assertTrue(result["truncated"])

    def test_smart_lists_partial_matches_when_no_row_has_every_word(self) -> None:
        # Nothing here is called "режим экономии", so every answer is partial,
        # and a file that names the tool only in its text is one of them.
        root = self.corpus({
            "zorbctl/zorbctl.conf": "theme = dark\n",
            "zorbctl-theme.css": "",
            "settings/display.conf": "# zorbctl display options\nbrightness = 40\n",
        })
        names = self.smart_names(root, "режим экономии zorbctl")
        self.assertIn("settings/display.conf", names)
        self.assertNotEqual(names[0], "settings/display.conf")
        # Asked what a text mentions, the text that has every word comes
        # before a name that has some of them.
        root = self.corpus({
            "log/entry-a.md": "Oiled the quux gearbox again.\n",
            "log/entry-b.md": "Only weather today.\n",
            "quux-gearbox.md": "",
        }, "notes")
        result = self.smart_search(root, "containing quux gearbox oiled")
        names = [row["relativePath"] for row in result["entries"]]
        self.assertEqual(names[:2], ["log/entry-a.md", "quux-gearbox.md"])
        self.assertEqual(result["entries"][0]["matchKind"], "content")
        self.assertEqual(result["entries"][0]["matchLine"], 1)

    def test_smart_content_losses_mark_the_result_truncated(self) -> None:
        body = "zebra\n" + "x" * 3000 + "\n"
        root = self.corpus({f"t/notes-{index}.txt": body for index in range(1, 4)})
        with mock.patch.object(quickfile.shutil, "which", return_value=None):
            result = self.smart_search(root, "zebra", content_byte_limit=6100)
        self.assertEqual(result["contentSearchBackend"], "python")
        self.assertEqual(len(result["entries"]), 2)
        self.assertTrue(result["truncated"])
        # A keyword too short to mean anything in text reads nothing at all.
        with mock.patch.object(quickfile.shutil, "which", return_value=None):
            result = self.smart_search(root, "x")
        self.assertEqual(result["contentBytesScanned"], 0)
        self.assertEqual(result["contentSearchBackend"], "none")

    def test_smart_model_hints_never_decide_what_is_read(self) -> None:
        root = self.corpus({
            **{f"a/zebra-{index}.txt": "zebra " + "x" * 3007 for index in range(5)},
            "deep/b/c/savanna.md": "the zebra lives here\n",
        })
        plan = quickfile.fallback_plan("zebra")
        plan["hints"]["location"] = {"value": "content", "confidence": 0.9, "source": "laya"}
        with mock.patch.object(quickfile.shutil, "which", return_value=None):
            plain = self.smart_names(root, "zebra", content_byte_limit=15070)
            hinted = self.smart_names(root, "zebra", plan=plan, content_byte_limit=15070)
        self.assertIn("deep/b/c/savanna.md", plain)
        self.assertEqual(sorted(plain), sorted(hinted))

    def test_smart_queries_of_symbols_match_names_that_have_them(self) -> None:
        root = self.corpus({
            "hello!!!.txt": "", "plain.txt": "", "smile 😀.png": b"\x89PNG", "user@host.md": "",
        })
        self.assertEqual(self.smart_names(root, "!!!"), ["hello!!!.txt"])
        self.assertEqual(self.smart_names(root, "😀"), ["smile 😀.png"])
        self.assertEqual(self.smart_names(root, "@"), ["user@host.md"])
        self.assertEqual(self.smart_names(root, "((("), [])

    def test_smart_finds_dotfiles_and_unspaced_scripts(self) -> None:
        root = self.corpus({
            ".gitignore": "*.pyc\n", ".env": "KEY=1\n", ".bashrc": "alias ll=ls\n",
            "notes.txt": "", "年度报告2024.pdf": b"%PDF-1.4", "会议记录.txt": "今天的会议\n",
            "docs/summary.txt": "年度报告已完成\n",
        })
        for query in (".gitignore", ".env", ".bashrc"):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query, show_hidden=True)[0], query)
        self.assertEqual(self.smart_names(root, "报告")[:1], ["年度报告2024.pdf"])
        self.assertIn("docs/summary.txt", self.smart_names(root, "报告"))
        self.assertEqual(self.smart_names(root, "会议"), ["会议记录.txt"])

    def test_smart_words_an_entry_type_says(self) -> None:
        root = self.corpus({
            "zorb/zorb-screenshot.png": b"\x89PNG", "zorb/IMG_0001.PNG": b"\x89PNG",
            "zorb/notes.txt": "", "IMG_0002.PNG": b"\x89PNG",
            "projects/quux/README.md": "", "app/main.py": "",
            "Птахи 3.m4a": b"\x00", "Птахи 3 список.md": "",
        })
        # A phone names its screenshots IMG_*: an image says "screenshot",
        # after the ones named so.
        names = self.smart_names(root, "zorb screenshots")
        self.assertEqual(names[:2], ["zorb/zorb-screenshot.png", "zorb/IMG_0001.PNG"])
        # A recording is audio or video, whatever the app called it.
        self.assertEqual(self.smart_names(root, "птахи запис")[0], "Птахи 3.m4a")
        # Alone, the word asks for itself: "my projects" are not all folders.
        names = self.smart_names(root, "мои проекты")
        self.assertEqual(names[0], "projects")
        self.assertNotIn("app", names)
        # A phrase that names a kind of media is said by every file of it,
        # and by nothing else.
        self.assertEqual(quickfile_smart.media_words("voice memo from the lake"),
                         {"voice": "audio", "memo": "audio"})
        root = self.corpus({
            "Recordings/New Recording 3.m4a": b"\x00", "Recordings/New Recording 4.m4a": b"\x00",
            "quux-memo.md": "", "call.mp4": b"\x00",
        }, "voice")
        names = self.smart_names(root, "voice memo")
        self.assertEqual(names[:3], [
            "Recordings/New Recording 3.m4a", "Recordings/New Recording 4.m4a", "quux-memo.md",
        ])
        self.assertNotIn("call.mp4", names)
        # A file listed only because its type says the words is listed only
        # on the date asked for.
        long_ago = quickfile.time.time() - 400 * 86400
        os.utime(root / "Recordings" / "New Recording 4.m4a", (long_ago, long_ago))
        names = self.smart_names(root, "voice memos from this month")
        self.assertEqual(names[0], "Recordings/New Recording 3.m4a")
        self.assertNotIn("Recordings/New Recording 4.m4a", names)

    def test_smart_ranks_whole_names_and_phrases_first(self) -> None:
        root = self.corpus({
            "TaxReturn2025.pdf": b"%PDF-1.4", "tax-notes.md": "", "return-policy.md": "",
            "invoice-template-for-others.pdf": b"%PDF-1.4", "billing/invoice.pdf": b"%PDF-1.4",
            "story.md": "", "cookie-policy.md": "",
        })
        self.assertEqual(self.smart_names(root, "tax return")[0], "TaxReturn2025.pdf")
        self.assertEqual(self.smart_names(root, "invoice")[0], "billing/invoice.pdf")
        self.assertEqual(self.smart_names(root, "stories"), ["story.md"])
        self.assertEqual(self.smart_names(root, "INVOICES")[0], "billing/invoice.pdf")
        self.assertEqual(self.smart_names(root, "cookies"), ["cookie-policy.md"])

    def test_smart_config_lives_in_the_configuration_home(self) -> None:
        root = self.corpus({
            "xdg-config/zorbwm.lua": "", "projects/zorbwm.lua": "",
            "xdg-config/cache.sqlite": b"SQLite format 3\x00",
        }, "")
        # The copy in the configuration home is configuration, the one in a
        # project is not, and only text is: a cache database beside it is not.
        result = self.smart_search(root, "settings")
        self.assertEqual([row["relativePath"] for row in result["entries"]],
                         ["xdg-config/zorbwm.lua"])
        self.assertIn("config", result["entries"][0]["smartReasons"])
        # It is still code for a request for code.
        result = self.smart_search(root, "zorbwm code")
        self.assertTrue(all("code" in row["smartReasons"] for row in result["entries"][:2]))

    def test_smart_hint_only_query_lists_what_its_specific_hints_accept(self) -> None:
        root = self.corpus({"new.txt": "", "old.txt": "", "nested/inner.txt": ""})
        long_ago = quickfile.time.time() - 400 * 86400
        os.utime(root / "old.txt", (long_ago, long_ago))
        names = self.smart_names(root, "updated today")
        # "Updated" implies files, and "today" decides the rows: an old file
        # is not listed, nor a folder whose date only says a file was added.
        self.assertEqual(sorted(names), ["nested/inner.txt", "new.txt"])
        # Asked for folders, a folder's date counts.
        self.assertEqual(self.smart_names(root, "папки за сегодня")[0], "nested")
        self.assertEqual(self.smart_names(root, "папки"), ["nested"])

    def test_smart_hint_only_query_shows_rows_with_every_hint_first(self) -> None:
        root = self.corpus({"now.mp3": b"\x00", "old.mp3": b"\x00", "now.txt": ""})
        long_ago = quickfile.time.time() - 400 * 86400
        os.utime(root / "old.mp3", (long_ago, long_ago))
        names = self.smart_names(root, "music from this month")
        self.assertEqual(names[0], "now.mp3")
        self.assertEqual(set(names), {"now.mp3", "now.txt", "old.mp3"})

    def test_smart_full_list_gives_up_the_weakest_rows(self) -> None:
        root = self.corpus({
            **{f"notes-{index}.txt": "alpha beta\n" for index in range(3)},
            **{f"alpha-{index}.txt": "" for index in range(10)},
        })
        result = self.smart_search(root, "alpha beta", limit=5)
        names = [row["name"] for row in result["entries"]]
        # Every note has both words, if only in its text, so none may be lost
        # to names that have one; losing any row is truncation.
        self.assertEqual(sorted(name for name in names if name.startswith("notes")),
                         [f"notes-{index}.txt" for index in range(3)])
        self.assertEqual(len(names), 5)
        self.assertTrue(result["truncated"])

    def test_smart_model_hints_reorder_but_never_hide_rows(self) -> None:
        root = self.corpus({"alpha-beta.md": "", "alpha/readme.txt": "", "beta-old.txt": ""})
        plain = self.smart_search(root, "alpha beta")
        plan = quickfile.fallback_plan("alpha beta")
        plan["hints"]["target"] = {"value": "folder", "confidence": 0.99, "source": "laya"}
        plan["hints"]["time"] = {"value": "older", "confidence": 0.99, "source": "laya"}
        hinted = self.smart_search(root, "alpha beta", plan=plan)
        self.assertEqual(
            sorted(row["relativePath"] for row in plain["entries"]),
            sorted(row["relativePath"] for row in hinted["entries"]),
        )
        # Nor may a model hint decide which rows fit in a full list.
        plan["hints"] = quickfile.fallback_plan("alpha beta")["hints"]
        plan["hints"]["kind"] = {"value": "code", "confidence": 0.99, "source": "laya"}
        plain = self.smart_names(root, "alpha beta", limit=2)
        hinted = self.smart_names(root, "alpha beta", plan=plan, limit=2)
        self.assertEqual(sorted(plain), sorted(hinted))

    def test_smart_folder_request_gathers_what_one_entry_inside_says(self) -> None:
        root = self.corpus({
            "shed/README.md": "Gearbox and pulley parts, as a list\n",
            "shed/src/main.py": "print('hi')\n",
            "notes/README.md": "A gearbox in the barn\n",
            "Work/alpha/notes.md": "gearbox\n",
            "Work/beta/notes.md": "pulley\n",
        })
        result = self.smart_search(root, "gearbox pulley folders")
        names = [row["relativePath"] for row in result["entries"]]
        self.assertEqual(names[0], "shed")
        self.assertIn("folder", result["entries"][0]["smartReasons"])
        self.assertIn("shed/README.md", names)
        # A folder is not about both because one entry in it mentions each.
        scores = {row["relativePath"]: row["smartScore"] for row in result["entries"]}
        self.assertLess(scores["Work"], scores["shed"])
        self.assertLess(scores["Work"], scores["Work/alpha"])

    def laya_plan(self, query: str, **answers: tuple[str, float]) -> dict:
        return quickfile_smart.merge_laya_answers(quickfile.fallback_plan(query), {
            field: {"choice": choice, "confidence": confidence}
            for field, (choice, confidence) in answers.items()
        })

    def test_smart_finds_a_name_typed_with_its_extension(self) -> None:
        root = self.corpus({
            "docs/notes.md": "", "docs/invoice.pdf": b"%PDF-1.4", "docs/ledger.xlsx": b"PK",
            "docs/Ledger 2025.xlsx": b"PK", "docs/minutes.docx": b"PK",
            "proj/app/package.json": "{}", "docs/zorb-brochure.pdf": b"%PDF-1.4",
            "docs/site-backup.tar.gz": b"\x1f\x8b", "IMG_0042.PNG": b"\x89PNG",
            "report.old": "", "notes-1.2": "", "sub/links.txt": "see invoice.pdf\n",
        })
        for query, expected in (
            ("notes.md", "docs/notes.md"), ("invoice.pdf", "docs/invoice.pdf"),
            ("package.json", "proj/app/package.json"),
            ("zorb-brochure.pdf", "docs/zorb-brochure.pdf"),
            ("site-backup.tar.gz", "docs/site-backup.tar.gz"), ("IMG_0042.PNG", "IMG_0042.PNG"),
            ("report.old", "report.old"), ("notes-1.2", "notes-1.2"),
            ('"ledger.xlsx"', "docs/ledger.xlsx"),
            # The extension on disk may be another spelling of the one typed,
            # and the name alone still names the file.
            ("ledger.xls", "docs/ledger.xlsx"), ("minutes.doc", "docs/minutes.docx"),
            ("site-backup.tgz", "docs/site-backup.tar.gz"), ("notes.txt", "docs/notes.md"),
        ):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query)[:1], [expected])
        # Below the name as typed, a longer name with it is found too.
        self.assertEqual(self.smart_names(root, "ledger.xls"),
                         ["docs/ledger.xlsx", "docs/Ledger 2025.xlsx"])

    def test_smart_model_hints_never_empty_a_query_of_stop_words(self) -> None:
        root = self.corpus({
            "IT/servers.txt": "", "wow!!!.txt": "", "last-will.pdf": b"%PDF-1.4",
            "where-we-were.txt": "", "other.txt": "",
        })
        for query in ("IT", "!!!", "last", "where we were"):
            with self.subTest(query=query):
                plain = self.smart_names(root, query)
                plan = self.laya_plan(query, target=("folder", 0.8), time=("older", 0.9))
                hinted = self.smart_search(root, query, plan=plan)["entries"]
                self.assertTrue(plain)
                self.assertEqual(sorted(plain), sorted(row["relativePath"] for row in hinted))

    def test_smart_change_words_are_keywords_unless_someone_did_them(self) -> None:
        self.assert_plans({
            "CHANGES": (["CHANGES"], {}),
            "change log": (["change", "log"], {}),
            "climate change report": (["climate", "change", "report"], {}),
            "updated": (["updated"], {}),
            "edit account page": (["edit", "account", "page"], {}),
            "all we updated": ([], {"target": "file"}),
            "the notes we updated": (["notes"], {"target": "file"}),
            "recently changed configs": (
                [], {"target": "file", "kind": "config", "time": "past-month"}),
            # "Edited" and "modified" also name folders, as a photo editor's
            # Edited/ does.
            "Edited": (["Edited"], {}),
            "modified": (["modified"], {}),
            "edited files": ([], {"target": "file"}),
            "they edited zorb": (["zorb"], {"target": "file"}),
            "files they modified": ([], {"target": "file"}),
        })
        root = self.corpus({
            "proj/CHANGES.md": "", "proj/CHANGELOG.md": "", "proj/a.txt": "", "b.txt": "",
            "Photos/Edited/IMG_1.jpg": b"\xff\xd8", "Photos/Raw/IMG_2.jpg": b"\xff\xd8",
        })
        self.assertEqual(self.smart_names(root, "change log")[0], "proj/CHANGELOG.md")
        self.assertEqual(self.smart_names(root, "changes")[0], "proj/CHANGES.md")
        self.assertEqual(self.smart_names(root, "Edited")[:2],
                         ["Photos/Edited", "Photos/Edited/IMG_1.jpg"])
        # Spent on what someone did, the word still names a folder on the way.
        names = self.smart_names(root, "edited photos")
        self.assertLess(names.index("Photos/Edited/IMG_1.jpg"), names.index("Photos/Raw/IMG_2.jpg"))

    def test_smart_ordinary_words_do_not_name_media(self) -> None:
        root = self.corpus({
            "music/track01.mp3": b"\x00", "music/track02.mp3": b"\x00", "clips/party.mp4": b"\x00",
            "docs/результаты-голосования.pdf": b"%PDF-1.4", "docs/запись-к-врачу.pdf": b"%PDF-1.4",
        })
        # A vote is not a voice message, nor a doctor's appointment a recording.
        self.assertEqual(self.smart_names(root, "голосование"), ["docs/результаты-голосования.pdf"])
        self.assertEqual(self.smart_names(root, "запись к врачу"), ["docs/запись-к-врачу.pdf"])
        self.assertEqual(self.smart_names(root, "recording"), [])
        # An entry named with the word is still listed.
        self.assertEqual(self.smart_names(root, "запис до лікаря"), ["docs/запись-к-врачу.pdf"])
        # "Голосовые" is one.
        self.assertEqual(quickfile.fallback_plan("голосовые")["hints"]["kind"]["value"], "audio")

    def test_smart_rolling_and_yearly_windows(self) -> None:
        self.assert_plans({
            "музыка за последнюю неделю": ([], {"kind": "audio", "time": "past-week"}),
            "archives from the past week": ([], {"kind": "archive", "time": "past-week"}),
            "музика за останній тиждень": ([], {"kind": "audio", "time": "past-week"}),
            "documents from last 7 days": ([], {"kind": "document", "time": "past-week"}),
            "документы за последний месяц": ([], {"kind": "document", "time": "past-month"}),
            "within the last month": ([], {"time": "past-month"}),
            "архивы в этом году": ([], {"kind": "archive", "time": "this-year"}),
            "архіви цього року": ([], {"kind": "archive", "time": "this-year"}),
            "files from last week": ([], {"target": "file", "time": "last-week"}),
            # A rolling window of another length is the shortest one that
            # holds it, and a word for what is recent is the past month.
            "notes from the past 3 days": (["notes"], {"time": "past-week"}),
            "заметки за последние три дня": (["заметк"], {"time": "past-week"}),
            "нотатки за останні 10 днів": (["нотатк"], {"time": "past-month"}),
            "archives from the last two weeks": ([], {"kind": "archive", "time": "past-month"}),
            "заметки за позавчера": (["заметк"], {"time": "past-week"}),
            "recent archives": ([], {"kind": "archive", "time": "past-month"}),
            "покажи недавние": ([], {"time": "past-month"}),
            # Last year is the calendar year before this one.
            "archives from last year": ([], {"kind": "archive", "time": "last-year"}),
            "архивы за прошлый год": ([], {"kind": "archive", "time": "last-year"}),
            "архіви за минулий рік": ([], {"kind": "archive", "time": "last-year"}),
            # A longer word that begins like a time word is a topic.
            "эта годовщина": (["годовщин"], {}),
            "прошлый неделимый остаток": (["неделим", "остаток"], {}),
            # Windows longer than a month are the past year, the shortest one
            # that holds them.
            "archives from the past year": ([], {"kind": "archive", "time": "past-year"}),
            "архивы за последний год": ([], {"kind": "archive", "time": "past-year"}),
            "архіви за останній рік": ([], {"kind": "archive", "time": "past-year"}),
            "заметки за последние 3 месяца": (["заметк"], {"time": "past-year"}),
            "notes from the past 2 months": (["notes"], {"time": "past-year"}),
            "notes from the last few days": (["notes"], {"time": "past-week"}),
            "заметки за неделю": (["заметк"], {"time": "past-week"}),
            "notes this morning": (["notes"], {"time": "today"}),
            # A verb of searching is no keyword.
            "hunting for png": ([], {"kind": "image"}),
            "i am looking for pdf": ([], {"kind": "document"}),
        })
        zone = quickfile.dt.datetime.now().astimezone().tzinfo
        now = quickfile.dt.datetime(2026, 9, 22, 15, 0, tzinfo=zone)

        def day(month: int, date: int) -> float:
            return quickfile.dt.datetime(2026, month, date, 9, 0, tzinfo=zone).timestamp()

        self.assertTrue(quickfile.smart_time_matches(day(9, 16), "past-week", now))
        self.assertFalse(quickfile.smart_time_matches(day(9, 15), "past-week", now))
        self.assertTrue(quickfile.smart_time_matches(day(8, 24), "past-month", now))
        self.assertFalse(quickfile.smart_time_matches(day(8, 23), "past-month", now))
        self.assertTrue(quickfile.smart_time_matches(day(1, 1), "this-year", now))
        autumn = quickfile.dt.datetime(2025, 9, 23, 9, 0, tzinfo=zone).timestamp()
        self.assertTrue(quickfile.smart_time_matches(autumn, "past-year", now))
        autumn = quickfile.dt.datetime(2025, 9, 22, 9, 0, tzinfo=zone).timestamp()
        self.assertFalse(quickfile.smart_time_matches(autumn, "past-year", now))
        last_year = quickfile.dt.datetime(2025, 6, 14, 9, 0, tzinfo=zone).timestamp()
        self.assertTrue(quickfile.smart_time_matches(last_year, "last-year", now))
        self.assertFalse(quickfile.smart_time_matches(day(6, 14), "last-year", now))
        root = self.corpus({
            "Music/track-01.mp3": b"\x00", "Music/track-02.mp3": b"\x00", "notes.txt": "",
        })
        long_ago = quickfile.time.time() - 40 * 86400
        os.utime(root / "Music" / "track-02.mp3", (long_ago, long_ago))
        self.assertEqual(self.smart_names(root, "музыка за последнюю неделю")[0],
                         "Music/track-01.mp3")
        # Recent files are listed for a request of nothing else.
        self.assertIn("notes.txt", self.smart_names(root, "покажи недавние"))
        self.assertNotIn("Music/track-02.mp3", self.smart_names(root, "покажи недавние"))

    def test_smart_months_are_month_forms_only(self) -> None:
        root = self.corpus({
            "scans/SCAN_20250214_1200.pdf": b"%PDF-1.4", "docs/2025-03-10-inventory.xlsx": b"PK",
            "docs/2025-10-01-minutes.md": "", "docs/Мартынов переулок.pdf": b"%PDF-1.4",
            "Ledger/2025/10/quux.txt": "", "Ledger/2025/09/10/quux.txt": "",
            "Course/10/quux.txt": "",
        })
        for query in ("лютий", "за лютого", "по лютому"):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query)[0], "scans/SCAN_20250214_1200.pdf")
        # Names that begin like a month are names.
        self.assertEqual(self.smart_names(root, "Мартынов"), ["docs/Мартынов переулок.pdf"])
        self.assertEqual(self.smart_names(root, "Августин"), [])
        for word in ("Мартин", "Мартыненко", "Августина"):
            with self.subTest(word=word):
                term = quickfile.fallback_plan(word)["terms"][0]
                self.assertEqual(quickfile_smart.SmartTerm(term).month, "")
        # A folder named "10" is October in a year's folder, not a lecture or
        # a day.
        self.assertEqual(self.smart_names(root, "quux october")[0], "Ledger/2025/10/quux.txt")
        names = self.smart_names(root, "october")
        for other in ("Course/10", "Ledger/2025/09/10", "Ledger/2025/09/10/quux.txt"):
            self.assertNotIn(other, names)

    def test_smart_short_words_meet_their_other_forms(self) -> None:
        root = self.corpus({
            "Дача 2019/grill.jpg": b"\xff\xd8", "Игры/list.txt": "",
            "photos/море.jpg": b"\xff\xd8", "photos/мороз.jpg": b"\xff\xd8",
        })
        for query, expected in (
            ("фото с дачи", "Дача 2019"), ("дачу", "Дача 2019"), ("фото з дачі", "Дача 2019"),
            ("игра", "Игры"),
        ):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query)[0], expected)
        self.assertEqual(self.smart_names(root, "фото моря"), ["photos/море.jpg"])

    def test_smart_kinds_joined_by_and_are_all_asked_for(self) -> None:
        for query, kinds in (
            ("photos and videos", ["image", "video"]), ("фото и видео", ["image", "video"]),
            ("документы и фото", ["document", "image"]), ("видео с музыкой", ["video"]),
        ):
            with self.subTest(query=query):
                self.assertEqual(quickfile.fallback_plan(query)["kinds"], kinds)
        root = self.corpus({
            "media/holiday.jpg": b"\xff\xd8", "media/beach.png": b"\x89PNG",
            "media/holiday.mp4": b"\x00", "media/clip.mov": b"\x00", "media/notes.txt": "",
        })
        self.assertEqual(sorted(self.smart_names(root, "photos and videos")), [
            "media/beach.png", "media/clip.mov", "media/holiday.jpg", "media/holiday.mp4",
        ])
        result = self.smart_search(root, "фото и видео")
        self.assertEqual(result["smart"]["kinds"], ["image", "video"])
        # Optional, bounded and validated like formats.
        legacy = {"version": 1, "terms": ["garden"], "hints": {}}
        self.assertEqual(quickfile.validate_plan(legacy)["kinds"], [])
        for kinds in (["any"], ["photo"], "image", [["image"]], ["image"] * 5):
            with self.subTest(kinds=kinds), self.assertRaises(quickfile.SmartPlanError):
                quickfile.validate_plan({**legacy, "kinds": kinds})

    def test_smart_a_format_named_first_is_the_kind_asked_for(self) -> None:
        cases = {
            "mp4 with music": ([], ["mp4"], "video"),
            "mp4 з музикою": ([], ["mp4"], "video"),
            "pdf з фото паспорта": (["паспорт"], ["pdf"], "document"),
            # A conversion and what something is for are topics.
            "mp3 to wav": (["mp3", "wav"], [], "any"),
            "tools for pdf": (["tools", "pdf"], [], "any"),
        }
        for query, (terms, formats, kind) in cases.items():
            with self.subTest(query=query):
                plan = quickfile.fallback_plan(query)
                self.assertEqual(
                    (plan["terms"], plan["formats"], plan["hints"]["kind"]["value"]),
                    (terms, formats, kind),
                )
        root = self.corpus({
            "mp4/holiday-2025.mp4": b"\x00", "mp4/mp4-codecs.md": "",
            "pdf-tools/merge.py": "", "docs/garden-tools.pdf": b"%PDF-1.4",
        })
        self.assertEqual(self.smart_names(root, "mp4 with music")[0], "mp4/holiday-2025.mp4")
        self.assertEqual(self.smart_names(root, "tools for pdf")[0], "pdf-tools")

    def test_smart_a_format_narrows_the_kind_it_implies(self) -> None:
        root = self.corpus({
            "garden-plan.pdf": b"%PDF-1.4", "quarterly-report.pdf": b"%PDF-1.4",
            "readings.csv": "a,b\n", "notes.md": "", "todo.txt": "", "beach.png": b"\x89PNG",
            "pdf-tools/merge.py": "",
        })
        pdfs = ["garden-plan.pdf", "quarterly-report.pdf"]
        self.assertEqual(sorted(self.smart_names(root, "pdf")), pdfs)
        self.assertEqual(sorted(self.smart_names(root, "pdf and photos")),
                         sorted(pdfs + ["beach.png"]))
        # After a verb of searching, "for" says what is searched for.
        for query in ("looking for pdf", "search for pdf files", "looking for a pdf"):
            with self.subTest(query=query):
                self.assertEqual(quickfile.fallback_plan(query)["formats"], ["pdf"])
                self.assertEqual(sorted(self.smart_names(root, query)), pdfs)
        self.assertEqual(quickfile.fallback_plan("look for png images")["formats"], ["png"])

    def test_smart_exact_word_outranks_a_longer_word_it_begins(self) -> None:
        root = self.corpus({
            "portal.txt": "", "port_scan_results.txt": "",
            "планшет.txt": "", "план_на_неделю.txt": "",
        })
        self.assertEqual(self.smart_names(root, "port")[0], "port_scan_results.txt")
        self.assertEqual(self.smart_names(root, "план")[0], "план_на_неделю.txt")

    def test_smart_an_extension_is_what_a_file_is_not_what_it_is_about(self) -> None:
        root = self.corpus({
            "garden-plan.pdf": b"\x00", "zorb-brochure.pdf": b"\x00",
            "pdf_parser.py": "", "data.csv": "a,b\n", "notes.md": "", "quux.lua": "",
        })
        self.assertEqual(self.smart_names(root, "pdf parser"), ["pdf_parser.py"])
        self.assertNotIn("data.csv", self.smart_names(root, "csv parser"))
        self.assertEqual(self.smart_names(root, "md table formatter"), [])
        # Alone, the word asks for files of its type.
        self.assertEqual(self.smart_names(root, "lua"), ["quux.lua"])
        # An extension says what a file is in either script.
        root = self.corpus({
            "zorb-installer.torrent": "", "zorb-notes.md": "", "typo-fix.patch": "",
            "patchwork.md": "",
        }, "types")
        self.assertEqual(self.smart_names(root, "торрент zorb")[0], "zorb-installer.torrent")
        self.assertEqual(self.smart_names(root, "патч"), ["typo-fix.patch"])

    def test_smart_hidden_trees_wait_for_the_visible_folders(self) -> None:
        root = self.corpus({
            **{f".appstate/cache-{index}/x/y/entry-{index}.txt": "" for index in range(30)},
            "Projects/app/src/lib/deep/zorb-locale.ts": "",
        })
        result = self.smart_search(root, "zorb locale", show_hidden=True, scan_limit=40)
        self.assertTrue(result["truncated"])
        self.assertEqual([row["relativePath"] for row in result["entries"]],
                         ["Projects/app/src/lib/deep/zorb-locale.ts"])

    def test_smart_folders_named_for_a_kind_are_listed_for_it(self) -> None:
        root = self.corpus({"Videos/trip.mp4": b"\x00", "Music/song.mp3": b"\x00", "notes.txt": ""})
        self.assertEqual(self.smart_names(root, "Videos"), ["Videos", "Videos/trip.mp4"])
        self.assertEqual(self.smart_names(root, "Музыка"), ["Music", "Music/song.mp3"])

    def test_smart_query_words_keep_their_meaning(self) -> None:
        self.assert_plans({
            # An apostrophe inside a word quotes nothing: it is part of the
            # word, and an English possessive is the word it follows.
            "Alice's recipes and Bob's notes": (["Alice", "recipes", "Bob", "notes"], {}),
            "м'ясо на п'ятницю": (["м'ясо", "п'ятниц"], {}),
            "'garden draft' notes": (['"garden draft"', "notes"], {}),
            # A full stop is not part of the word before it.
            "графиком.": (["график"], {}),
            # A projector is not a project.
            "инструкция проектора": (["инструкци", "проектор"], {}),
        })
        root = self.corpus({
            "docs/invoice.pdf": b"%PDF-1.4", "docs/invoices-2024.txt": "",
            "lang/c-quux.txt": "", "books/C++ Primer.pdf": b"%PDF-1.4",
            "zorblabs-app/main.kt": "", "docs/Zorb-notes.txt": "",
            "pics/cat.jpg": b"\xff\xd8", "pics/catch.txt": "",
        })
        # Quoted, a word is matched as typed.
        self.assertEqual(self.smart_names(root, '"invoice"'), ["docs/invoice.pdf"])
        self.assertEqual(self.smart_names(root, '"calender"'), [])
        # A language is its symbols, not its letter.
        self.assertEqual(self.smart_names(root, "C++"), ["books/C++ Primer.pdf"])
        # A transliterated name and a short singular add only an ending.
        self.assertEqual(self.smart_names(root, "Зорб"), ["docs/Zorb-notes.txt"])
        self.assertEqual(self.smart_names(root, "cats"), ["pics/cat.jpg"])

    def test_smart_text_matches_alike_with_and_without_rg(self) -> None:
        root = self.corpus({
            "a.txt": "Meeting at Hauptstraße 5\n", "trip.txt": "Встреча в Одеса, порт.\n",
        })
        for query, expected in (("hauptstraße", ["a.txt"]), ("Одесса", ["trip.txt"])):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query), expected)
                with mock.patch.object(quickfile.shutil, "which", return_value=None):
                    self.assertEqual(self.smart_names(root, query), expected)

    def test_smart_model_hints_never_decide_which_lines_are_read(self) -> None:
        root = self.corpus({"a.txt": "the zebra lives here\n", "b.txt": "the zebra lives here\n"})
        long_ago = quickfile.time.time() - 400 * 86400
        os.utime(root / "a.txt", (long_ago, long_ago))

        def lines(plan: dict | None) -> dict[str, int]:
            result = self.smart_search(root, "zebra", plan=plan, content_byte_limit=30)
            return {row["relativePath"]: row["matchLine"] for row in result["entries"]}

        plain = lines(None)
        self.assertEqual(sorted(plain.values()), [0, 1])
        self.assertEqual(lines(self.laya_plan("zebra", time=("today", 0.9))), plain)

    def test_smart_a_read_the_deadline_cut_short_marks_the_result(self) -> None:
        root = self.corpus({"notes.txt": "the zebra lives here\n"})
        read = quickfile.smart_content_match

        def slow(*args):
            answer = read(*args)
            quickfile.time.sleep(0.3)
            return answer

        with mock.patch.object(quickfile.shutil, "which", return_value=None), \
                mock.patch.object(quickfile, "smart_content_match", side_effect=slow):
            result = self.smart_search(root, "zebra", timeout=0.25)
        self.assertTrue(result["truncated"])

    def test_smart_entries_named_with_a_framing_word_are_listed(self) -> None:
        root = self.corpus({
            "Videos/recording-03.mp4": b"\x00", "Videos/Запис 03.mp4": b"\x00",
            "Videos/party.mp4": b"\x00", "notes/physics.md": "", "docs/recording-notes.txt": "",
            "docs/setup-guide.md": "", "Studio/recordings/take-1.m4a": b"\x00",
        })
        # "Recording" only frames a request, but an entry named with it is
        # what the word asks for, below the entries with the other words, and
        # so is a folder named for them.
        names = self.smart_names(root, "physics recording")
        self.assertEqual(names[0], "notes/physics.md")
        self.assertIn("Videos/recording-03.mp4", names)
        self.assertIn("docs/recording-notes.txt", self.smart_names(root, "recording guide"))
        self.assertIn("Videos/Запис 03.mp4", self.smart_names(root, "zorb запис"))
        self.assertIn("Studio/recordings", self.smart_names(root, "physics recordings"))
        # A video that only its type makes a recording is not enough.
        self.assertNotIn("Videos/party.mp4", names)

    def test_smart_translations_of_a_type_word_name_only_that_type(self) -> None:
        root = self.corpus({
            "docs/запис-до-стоматолога.pdf": b"%PDF-1.4", "docs/recording-notes.txt": "",
            "Videos/Запис 03.mp4": b"\x00", "Записи/list.txt": "",
        })
        # "Запис" is an appointment as often as a recording: a translation of
        # "recording" finds a video or a folder of them, not a document.
        names = self.smart_names(root, "recording")
        self.assertIn("Videos/Запис 03.mp4", names)
        self.assertIn("Записи", names)
        self.assertNotIn("docs/запис-до-стоматолога.pdf", names)
        # The word as typed still names anything.
        self.assertIn("docs/запис-до-стоматолога.pdf", self.smart_names(root, "запис"))

    def test_smart_apostrophes_stay_inside_words(self) -> None:
        root = self.corpus({
            "d/мясо.txt": "", "d/пятница.txt": "", "d/обєкт.txt": "", "d/мята.txt": "",
            "d/мʼята.md": "", "d/м'ята-чай.txt": "", "d/dartagnan-notes.md": "",
            "d/D'Artagnan letters.pdf": b"%PDF-1.4", "t/list.txt": "Купити м’ясо на суботу\n",
        })
        for query, expected in (
            ("м'ясо", ["d/мясо.txt", "t/list.txt"]), ("п'ятниця", ["d/пятница.txt"]),
            ("об'єкт", ["d/обєкт.txt"]), ("объект", ["d/обєкт.txt"]),
            ("мясо", ["d/мясо.txt", "t/list.txt"]),
            ("м'ята", ["d/m'ята-чай.txt", "d/мʼята.md", "d/мята.txt"]),
            ("мята", ["d/m'ята-чай.txt", "d/мʼята.md", "d/мята.txt"]),
            ("D'Artagnan", ["d/D'Artagnan letters.pdf", "d/dartagnan-notes.md"]),
        ):
            with self.subTest(query=query):
                self.assertEqual(sorted(self.smart_names(root, query)),
                                 sorted(path.replace("m'", "м'") for path in expected))
                with mock.patch.object(quickfile.shutil, "which", return_value=None):
                    self.assertEqual(sorted(self.smart_names(root, query)),
                                     sorted(path.replace("m'", "м'") for path in expected))

    def test_smart_short_names_with_a_doubled_letter_keep_their_length(self) -> None:
        root = self.corpus({
            "d/Инна-план.pdf": b"%PDF-1.4", "d/письмо Инны.txt": "", "d/иначе.txt": "",
            "d/инаугурация.md": "", "t/talk.txt": "иначе говоря\n", "t/call.txt": "Звонок Инне\n",
            "d/Жанна.pdf": b"%PDF-1.4", "d/жанр.txt": "", "d/Элла-рецепты.pdf": b"%PDF-1.4",
            "d/елань.jpg": b"\xff\xd8", "d/Одесса-2019.jpg": b"\xff\xd8", "t/trip.txt": "Одеса\n",
        })
        # Folding "Инна" to "ина" must not let it run on into any letters:
        # it meets its own case forms only.
        self.assertEqual(sorted(self.smart_names(root, "Инна")),
                         ["d/Инна-план.pdf", "d/письмо Инны.txt", "t/call.txt"])
        self.assertEqual(self.smart_names(root, "Жанна"), ["d/Жанна.pdf"])
        self.assertEqual(self.smart_names(root, "Элла"), ["d/Элла-рецепты.pdf"])
        # A longer word still meets its spelling with one letter.
        self.assertEqual(sorted(self.smart_names(root, "Одесса")),
                         ["d/Одесса-2019.jpg", "t/trip.txt"])

    def test_smart_a_projects_own_python_folder_is_searched(self) -> None:
        root = self.corpus({
            "engine/lib/python3/zorb_bindings.py": "", "engine/src/zorb.c": "",
            "env/pyvenv.cfg": "home = /usr/bin\n",
            "env/lib/python3.12/site-packages/zorb_pkg.py": "",
        })
        result = self.smart_search(root, "zorb bindings")
        self.assertEqual(result["entries"][0]["relativePath"], "engine/lib/python3/zorb_bindings.py")
        # A Python library, which holds site-packages, is still skipped.
        self.assertNotIn("env/lib/python3.12/site-packages/zorb_pkg.py",
                         self.smart_names(root, "zorb"))

    def test_smart_loanwords_meet_their_english_spelling(self) -> None:
        root = self.corpus({
            "music/jazz-standards.txt": "", "docs/computer-setup.md": "",
            "docs/method-notes.md": "", "docs/position-paper.md": "", "docs/graphics-notes.md": "",
            "docs/vine.txt": "",
        })
        for query, expected in (
            ("джаз", "music/jazz-standards.txt"), ("компьютер", "docs/computer-setup.md"),
            ("метод", "docs/method-notes.md"), ("позиция", "docs/position-paper.md"),
            ("графика", "docs/graphics-notes.md"),
        ):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query)[:1], [expected])
        self.assertEqual(self.smart_names(root, "вино"), [])

    def test_smart_words_spent_on_a_kind_still_name_things(self) -> None:
        root = self.corpus({
            "garden/photos/IMG_1.jpg": b"\xff\xd8", "garden/IMG_2.jpg": b"\xff\xd8",
            "tools/zorb/config.toml": "", "tools/zorb.toml": "",
        })
        names = self.smart_names(root, "photos of the garden")
        self.assertLess(names.index("garden/photos/IMG_1.jpg"), names.index("garden/IMG_2.jpg"))
        # Beside one keyword a spent word says a lot: the file named config is
        # the one asked for.
        self.assertEqual(self.smart_names(root, "zorb config")[0], "tools/zorb/config.toml")

    def test_smart_a_name_word_abbreviates_a_long_keyword(self) -> None:
        root = self.corpus({
            "dev-notes.md": "", "development-plan.md": "", "calc-zorb.md": "", "calc-sheet.md": "",
            "d/and-studio-tips.md": "", "d/android-notes.md": "",
            "d/budget-new.xlsx": b"PK", "d/newsletter.md": "",
            "d/sales-rep-list.md": "", "d/reporting-guide.md": "",
        })
        # "dev" is "development" beside another keyword, in the query's order.
        self.assertEqual(self.smart_names(root, "development notes")[0], "dev-notes.md")
        # Alone, a clip is nothing.
        self.assertEqual(self.smart_names(root, "calculator"), [])
        # In the other script, by the Latin spelling.
        self.assertEqual(self.smart_names(root, "калькулятор zorb")[0], "calc-zorb.md")
        # A word that frames a request abbreviates nothing, nor does a clip of
        # three letters in another order than the query's: the entry with the
        # keyword itself comes first.
        for query, expected in (
            ("android studio", "d/android-notes.md"), ("newsletter budget", "d/newsletter.md"),
            ("reporting sales", "d/reporting-guide.md"),
        ):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query)[0], expected)

    def test_smart_a_long_text_answers_a_long_request_less_firmly(self) -> None:
        filler = "\n".join(f"line {index:05} of an unrelated log" for index in range(3500))
        root = self.corpus({
            "a/short.conf": "alpha beta gamma\n",
            "b/long.log": f"alpha\n{filler}\nbeta gamma delta\n",
        })
        # Every word of the request somewhere in a long text says less than
        # most of them in a short one.
        self.assertEqual(self.smart_names(root, "alpha beta gamma delta")[0], "a/short.conf")

    def test_smart_names_meet_their_transliteration_either_way(self) -> None:
        root = self.corpus({
            "en/Zorbiuk-contract.pdf": b"%PDF-1.4", "en/Dzhorbyn-notes.md": "",
            "ru/Зорбюк-договор.pdf": b"%PDF-1.4", "ru/Джорбин.md": "",
        })
        # A name keeps its transliteration beside the borrowed-word spelling:
        # "юк" is "iuk" and "дж" "dzh" as well as "uk" and "j".
        for query, expected in (
            ("Зорбюк", ["en/Zorbiuk-contract.pdf", "ru/Зорбюк-договор.pdf"]),
            ("Zorbiuk", ["en/Zorbiuk-contract.pdf", "ru/Зорбюк-договор.pdf"]),
            ("Джорбин", ["en/Dzhorbyn-notes.md", "ru/Джорбин.md"]),
            ("Dzhorbyn", ["en/Dzhorbyn-notes.md", "ru/Джорбин.md"]),
        ):
            with self.subTest(query=query):
                self.assertEqual(sorted(self.smart_names(root, query)), expected)

    def test_smart_short_common_words_are_not_their_transliteration(self) -> None:
        root = self.corpus({
            "en/most-used.md": "", "en/dom-utils.ts": "", "en/net-config.json": "{}",
            "en/sad-songs.mp3": b"\x00", "en/UIKit.swift": "", "en/lists.csv": "a\n",
            "en/listen-later.md": "", "domain/readme.md": "", "sms/zorb.txt": "",
            "ru/мост через реку.md": "", "ru/отчёт.txt": "Мост закрыт на ремонт\n",
        })
        # A short word typed in lower case meets the other script only as the
        # same whole word or its plural, one of three letters not at all...
        for query in ("дом", "нет", "сад", "кит"):
            with self.subTest(query=query):
                self.assertEqual(self.smart_names(root, query), [])
        self.assertNotIn("domain", self.smart_names(root, "дома"))
        self.assertNotIn("en/listen-later.md", self.smart_names(root, "лист"))
        # ... and for less than the word itself, in a name or in a text.
        self.assertEqual(self.smart_names(root, "мост"),
                         ["ru/мост через реку.md", "ru/отчёт.txt", "en/most-used.md"])
        # An abbreviation has no vowel, and keeps its transliteration.
        self.assertEqual(self.smart_names(root, "смс")[0], "sms")

    def test_smart_a_spent_kind_word_names_only_its_kind(self) -> None:
        root = self.corpus({
            "Photos/beach.jpg": b"\xff\xd8", "Videos/trip.mp4": b"\x00",
            "inbox/IMG_1.jpg": b"\xff\xd8", "inbox/clip.mp4": b"\x00",
            "inbox/video-still.jpg": b"\xff\xd8",
        })
        long_ago = quickfile.time.time() - 400 * 86400
        for old in ("Photos/beach.jpg", "Videos/trip.mp4"):
            os.utime(root / old, (long_ago, long_ago))
        # The folder named for the kind asked for, of any date, does not come
        # before what has the kind and the date...
        self.assertEqual(self.smart_names(root, "photos this month")[0], "inbox/IMG_1.jpg")
        names = self.smart_names(root, "videos this month")
        self.assertEqual(names[0], "inbox/clip.mp4")
        # ... nor a JPG called video before a video.
        self.assertGreater(names.index("inbox/video-still.jpg"), names.index("Videos/trip.mp4"))
        # Nor the folder before the files a typed target asks for.
        self.assertEqual(self.smart_names(root, "edited photos")[0], "Photos/beach.jpg")

    def test_smart_a_kind_asked_alone_comes_before_its_date(self) -> None:
        root = self.corpus({
            "Pictures/IMG_0001.jpg": b"\xff\xd8", "Pictures/IMG_0002.jpg": b"\xff\xd8",
            "Pictures/IMG_0003.jpg": b"\xff\xd8", "docs/report.pdf": b"%PDF-1.4",
            "docs/table.xlsx": b"PK", "docs/todo.txt": "",
        })
        for name, days in (("IMG_0001.jpg", 3), ("IMG_0002.jpg", 40), ("IMG_0003.jpg", 400)):
            stamp = quickfile.time.time() - days * 86400
            os.utime(root / "Pictures" / name, (stamp, stamp))
        images = ["Pictures/IMG_0001.jpg", "Pictures/IMG_0002.jpg", "Pictures/IMG_0003.jpg"]
        documents = ["docs/report.pdf", "docs/table.xlsx", "docs/todo.txt"]
        for query in ("latest photos", "недавние фото", "свежие фото"):
            with self.subTest(query=query):
                names = self.smart_names(root, query)
                self.assertEqual(names[0], "Pictures/IMG_0001.jpg")
                # Every photo, of any date, before a file that has only the date.
                self.assertLess(max(names.index(name) for name in images),
                                min(names.index(name) for name in documents))

    def test_smart_rows_with_a_keyword_come_before_rows_only_their_type_says(self) -> None:
        root = self.corpus({
            **{f"pics/IMG_000{index}.png": b"\x89PNG" for index in range(1, 7)},
            "research/quux-survey/notes.md": "", "research/quux-survey/data/answers.json": "{}",
        })
        # Only its type makes an image a screenshot, and beside a keyword it
        # lacks that ranks below a file under a folder named with the keyword.
        result = self.smart_search(root, "quux screenshots", limit=6)
        names = [row["relativePath"] for row in result["entries"]]
        self.assertIn("research/quux-survey/data/answers.json", names)
        self.assertTrue(result["truncated"])

    def test_smart_an_extension_is_one_word_after_the_last_dot(self) -> None:
        matcher = quickfile.SmartMatcher(quickfile_smart.smart_terms(["final", "lua"], False))
        # After a version's dot the rest of the name is the name's.
        evidence = matcher.name("Budget v1.5 final", False)
        self.assertEqual((evidence.grades[0], evidence.suffix[0]), (1.0, False))
        evidence = matcher.name("quux.lua", False)
        self.assertEqual((evidence.grades[1], evidence.suffix[1]), (0.0, True))
        root = self.corpus({"d/release-notes": "", "d/release-2.0-notes": ""})
        scores = {row["relativePath"]: row["smartScore"]
                  for row in self.smart_search(root, "notes")["entries"]}
        self.assertEqual(scores["d/release-2.0-notes"], scores["d/release-notes"])
        # "Лист" typed is as often a sheet as a letter.
        root = self.corpus({
            "d/лист бюджета.xlsx": b"PK", "d/letter-to-bank.pdf": b"%PDF-1.4",
            "d/письмо-банку.docx": b"PK",
        }, "sheets")
        self.assertEqual(self.smart_names(root, "лист бюджета"), ["d/лист бюджета.xlsx"])

    def test_smart_chips_know_the_kind_of_every_format(self) -> None:
        panel = (ROOT / "Panel.qml").read_text(encoding="utf-8")
        body = panel[panel.index("function smartFormatKind("):
                     panel.index("function smartSummaryLabels(")]
        rules = [
            (quickfile.re.compile(pattern), kind)
            for pattern, kind in quickfile.re.findall(r'match\(/(.+?)/\)\) return "(\w+)"', body)
        ]
        self.assertTrue(rules)
        for value, kind in quickfile_smart.SMART_FORMATS.items():
            with self.subTest(format=value):
                self.assertEqual(
                    next((named for pattern, named in rules if pattern.search(value)), ""), kind)

    def test_semantic_helper_status_is_dependency_free(self) -> None:
        semantic_home = self.root / "semantic"
        result = subprocess.run(
            [sys.executable, str(ROOT / "bin" / "quickfile-semantic"), "status"],
            check=True, capture_output=True, text=True,
            env={**os.environ, "QUICKFILE_SEMANTIC_HOME": str(semantic_home)},
        )
        payload = json.loads(result.stdout)
        self.assertFalse(payload["installed"])
        self.assertEqual(payload["model"], "laya-multilingual")

    def test_semantic_download_is_pinned_and_keeps_its_cache_private(self) -> None:
        fake_modules = self.root / "download-modules"
        fake_modules.mkdir()
        (fake_modules / "huggingface_hub.py").write_text(
            "import json, os\n"
            "from pathlib import Path\n"
            "def snapshot_download(**kwargs):\n"
            "    target = Path(kwargs['local_dir'])\n"
            "    (target / 'multilingual').mkdir(parents=True)\n"
            "    Path(kwargs['cache_dir']).mkdir(parents=True)\n"
            "    (target / '.cache').mkdir()\n"
            "    (target / 'download-call.json').write_text(json.dumps({\n"
            "        'repo': kwargs['repo_id'], 'revision': kwargs['revision'],\n"
            "        'patterns': kwargs['allow_patterns'],\n"
            "        'cache': kwargs['cache_dir'], 'hfHome': os.environ['HF_HOME'],\n"
            "        'telemetry': os.environ['HF_HUB_DISABLE_TELEMETRY']}))\n"
            "    return str(target)\n",
            encoding="utf-8",
        )
        model = self.root / "download" / "model"
        subprocess.run(
            [sys.executable, str(ROOT / "bin" / "quickfile-semantic"),
             "_download", "--destination", str(model)],
            check=True, capture_output=True, text=True,
            env={**os.environ, "PYTHONPATH": str(fake_modules)},
        )
        call = json.loads((model / "download-call.json").read_text(encoding="utf-8"))
        self.assertEqual(call["repo"], "convaiinnovations/laya")
        self.assertEqual(call["revision"], "1c5edc17a7acd8701df6fc341c0d179f1c62c982")
        self.assertEqual(call["patterns"], ["multilingual/*"])
        self.assertEqual(call["telemetry"], "1")
        self.assertFalse((model.parent / ".huggingface-cache").exists())
        self.assertFalse((model / ".cache").exists())

    def test_semantic_install_uses_the_cpu_torch_runtime_first(self) -> None:
        loader = importlib.machinery.SourceFileLoader(
            "quickfile_semantic_cli", str(ROOT / "bin" / "quickfile-semantic"),
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        runtime, package = module.dependency_commands(Path("/venv/bin/python"))
        self.assertEqual(runtime[-3:], [
            "--index-url", "https://download.pytorch.org/whl/cpu", "torch",
        ])
        self.assertEqual(package[-1], "laya==0.3.5")
        self.assertNotIn("--index-url", package)

    def test_semantic_install_keeps_child_temp_files_private_and_cleans_them(self) -> None:
        loader = importlib.machinery.SourceFileLoader(
            "quickfile_semantic_temp_test", str(ROOT / "bin" / "quickfile-semantic"),
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        real_process = module.bounded_process
        for fail in (False, True):
            with self.subTest(fail=fail):
                semantic_home = self.root / ("failure" if fail else "success") / "semantic"
                calls = []

                def fake_step(argv, timeout, *, env):
                    temporary = Path(env["TMPDIR"])
                    staging = temporary.parent
                    self.assertEqual(staging.parent, semantic_home)
                    self.assertEqual(env["TEMP"], str(temporary))
                    self.assertEqual(env["TMP"], str(temporary))
                    self.assertEqual(temporary.stat().st_mode & 0o777, 0o700)
                    # Verify a real child uses this directory even when /tmp
                    # or an inherited TMPDIR would normally be selected.
                    code, error = real_process([
                        sys.executable, "-c",
                        "import os, tempfile; from pathlib import Path; "
                        "assert tempfile.gettempdir() == os.environ['TMPDIR']; "
                        "fd, path = tempfile.mkstemp(); os.close(fd); "
                        "Path(path).write_text('wheel')",
                    ], timeout=10, env=env)
                    self.assertEqual((code, error), (0, ""))
                    calls.append(argv)
                    if fail:
                        return 1, "simulated pip failure"
                    python = staging / "venv" / "bin" / "python"
                    python.parent.mkdir(parents=True, exist_ok=True)
                    python.touch()
                    model = staging / "model" / "multilingual"
                    model.mkdir(parents=True, exist_ok=True)
                    (model / "rl_agent_config.json").touch()
                    (model / "model.safetensors").touch()
                    return 0, ""

                with mock.patch.dict(os.environ, {
                    "QUICKFILE_SEMANTIC_HOME": str(semantic_home),
                    "TMPDIR": "/nonexistent-inherited-temp",
                }), mock.patch.object(module, "bounded_process", side_effect=fake_step), \
                        mock.patch.object(module, "emit"):
                    self.assertEqual(module.install_command(), 1 if fail else 0)
                    self.assertEqual(module.status_payload()["installed"], not fail)
                self.assertEqual(len(calls), 1 if fail else 4)
                self.assertFalse(list(semantic_home.glob(".staging-*")))
                self.assertFalse(list(semantic_home.glob("laya-*/.tmp")))
                if fail:
                    self.assertEqual(list(semantic_home.iterdir()), [])

    def test_semantic_helper_refuses_an_unsafe_data_root(self) -> None:
        unsafe_home = self.root / "unrelated-data"
        unsafe_home.mkdir()
        sentinel = unsafe_home / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(ROOT / "bin" / "quickfile-semantic"), "remove"],
            check=False, capture_output=True, text=True,
            env={**os.environ, "QUICKFILE_SEMANTIC_HOME": str(unsafe_home)},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["code"], "semantic-remove-unsafe")
        self.assertTrue(sentinel.is_file())
        install = subprocess.run(
            [sys.executable, str(ROOT / "bin" / "quickfile-semantic"), "install"],
            check=False, capture_output=True, text=True,
            env={**os.environ, "QUICKFILE_SEMANTIC_HOME": str(unsafe_home)},
        )
        self.assertNotEqual(install.returncode, 0)
        self.assertEqual(json.loads(install.stdout)["code"], "semantic-install-unsafe")
        self.assertTrue(sentinel.is_file())

    def test_semantic_helper_coalesces_requests_with_fake_laya(self) -> None:
        semantic_home = self.root / "semantic"
        install = semantic_home / "install"
        python_path = install / "venv" / "bin" / "python"
        model_path = install / "model"
        (model_path / "multilingual").mkdir(parents=True)
        python_path.parent.mkdir(parents=True)
        python_path.symlink_to(sys.executable)
        (model_path / "multilingual" / "rl_agent_config.json").write_text(
            "{}", encoding="utf-8",
        )
        (model_path / "multilingual" / "model.safetensors").write_bytes(b"fake")
        semantic_home.mkdir(exist_ok=True)
        (semantic_home / "install.json").write_text(json.dumps({
            "version": 1,
            "packageVersion": "0.3.5",
            "revision": "1c5edc17a7acd8701df6fc341c0d179f1c62c982",
            "installPath": str(install),
            "modelPath": str(model_path),
            "pythonPath": str(python_path),
        }), encoding="utf-8")
        fake_modules = self.root / "fake-modules"
        fake_modules.mkdir()
        (fake_modules / "laya.py").write_text(
            "__version__ = '0.3.5'\n"
            "class Agent:\n"
            "    device = 'cpu'\n"
            "    def predict(self, state, questions):\n"
            "        return {'answers': {key: {'choice': 'any', 'confidence': 0.7} "
            "for key in questions}}\n"
            "def load(path, device=None, subfolder=None):\n"
            "    assert device == 'cpu', device\n"
            "    return Agent()\n",
            encoding="utf-8",
        )
        environment = {
            **os.environ,
            "QUICKFILE_SEMANTIC_HOME": str(semantic_home),
            "PYTHONPATH": str(fake_modules),
        }
        process = subprocess.run(
            [sys.executable, str(ROOT / "bin" / "quickfile-semantic"), "serve"],
            input=(json.dumps({"op": "analyze", "id": 1, "query": "first query"}) + "\n"
                   + json.dumps({"op": "analyze", "id": 2, "query": "second query"}) + "\n"),
            check=True, capture_output=True, text=True, env=environment, timeout=5,
        )
        messages = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(messages[0]["event"], "ready")
        analyses = [message for message in messages if message["event"] == "analysis"]
        self.assertEqual(analyses[-1]["id"], 2)
        self.assertEqual(analyses[-1]["plan"]["model"], "laya-multilingual")

    def test_properties_expose_posix_and_filesystem_metadata(self) -> None:
        args = argparse.Namespace(path=str(self.root / "notes.txt"), path_token=None)
        props = quickfile.properties_command(args)["properties"]
        self.assertEqual(props["size"], 5)
        self.assertEqual(props["kind"], "file")
        self.assertIn("owner", props)
        self.assertIn("inode", props)
        self.assertIn("mount", props)
        self.assertIn("gioAttributes", props)
        self.assertEqual(len(props["mode"]), 4)

    def test_knowledge_index_groups_agents_and_symlink_bindings(self) -> None:
        project = self.root / "project"
        project.mkdir()
        project_rule = project / "AGENTS.md"
        project_rule.write_text("project instructions\n" * 20, encoding="utf-8")

        shared_rule = self.root / "shared-rules.md"
        shared_rule.write_text("shared instructions\n" * 10, encoding="utf-8")
        (self.root / ".codex").mkdir()
        (self.root / ".claude").mkdir()
        (self.root / ".codex" / "AGENTS.md").symlink_to(shared_rule)
        (self.root / ".claude" / "CLAUDE.md").symlink_to(shared_rule)

        result = quickfile.knowledge_command(argparse.Namespace(
            path=str(project), path_token=None, limit=128,
        ))

        self.assertEqual(result["count"], 2)
        self.assertGreater(result["totalTokens"], 0)
        project_row = next(row for row in result["entries"] if row["scope"] == "PROJECT")
        self.assertEqual(project_row["agents"], ["codex"])
        shared_row = next(row for row in result["entries"] if row["name"] == "shared-rules.md")
        self.assertEqual(shared_row["agents"], ["codex", "claude"])
        self.assertTrue(shared_row["hasSymlinkBinding"])
        self.assertEqual(len(shared_row["bindings"]), 2)

    def test_arbitrary_file_can_be_registered_for_knowledge_agents(self) -> None:
        project = self.root / "project"
        project.mkdir()
        memory = self.root / "shared-memory.txt"
        memory.write_text("A reusable project memory.\n", encoding="utf-8")

        saved = quickfile.metadata_command(argparse.Namespace(
            path=str(memory),
            path_token=None,
            color=None,
            note=None,
            starred=None,
            knowledge="true",
            agents_json=json.dumps(["gemini", "codex", "gemini"]),
        ))

        self.assertTrue(saved["metadata"]["registeredKnowledge"])
        self.assertEqual(saved["metadata"]["knowledgeAgents"], ["codex", "gemini"])
        indexed = quickfile.knowledge_command(argparse.Namespace(
            path=str(project), path_token=None, limit=128,
        ))
        row = next(item for item in indexed["entries"] if item["name"] == memory.name)
        self.assertEqual(row["scope"], "USER")
        self.assertTrue(row["registeredKnowledge"])
        self.assertEqual(row["knowledgeAgents"], ["codex", "gemini"])
        self.assertEqual(row["agents"], ["codex", "gemini"])

        quickfile.metadata_command(argparse.Namespace(
            path=str(memory),
            path_token=None,
            color=None,
            note=None,
            starred=None,
            knowledge="false",
            agents_json="[]",
        ))
        indexed = quickfile.knowledge_command(argparse.Namespace(
            path=str(project), path_token=None, limit=128,
        ))
        self.assertNotIn(memory.name, [item["name"] for item in indexed["entries"]])

    def test_knowledge_registry_rejects_folders_and_unknown_agents(self) -> None:
        base = dict(
            path=str(self.root / "notes.txt"),
            path_token=None,
            color=None,
            note=None,
            starred=None,
            knowledge="true",
        )
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.metadata_command(argparse.Namespace(
                **base, agents_json=json.dumps(["unknown-agent"]),
            ))
        self.assertEqual(raised.exception.code, "metadata-invalid-agents")

        base["path"] = str(self.root / "folder")
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.metadata_command(argparse.Namespace(
                **base, agents_json="[]",
            ))
        self.assertEqual(raised.exception.code, "knowledge-file-required")

    def test_knowledge_links_preview_then_apply_without_overwriting(self) -> None:
        project = self.root / "linked-project"
        project.mkdir()
        source = self.root / "shared-knowledge.md"
        source.write_text("Shared agent instructions.\n", encoding="utf-8")
        agents = ["codex", "claude", "gemini", "cursor", "copilot", "windsurf"]
        quickfile.metadata_command(argparse.Namespace(
            path=str(source), path_token=None, color=None, note=None, starred=None,
            knowledge="true", agents_json=json.dumps(agents),
        ))
        args = argparse.Namespace(
            source=str(source), source_token=None,
            root=str(project), root_token=None, apply=False,
        )

        preview = quickfile.knowledge_links_command(args)

        self.assertEqual(preview["createCount"], 6)
        self.assertEqual(preview["conflictCount"], 0)
        self.assertTrue(all(item["status"] == "create" for item in preview["entries"]))
        args.apply = True
        applied = quickfile.knowledge_links_command(args)
        self.assertEqual(applied["createdCount"], 6)
        self.assertEqual(applied["connectedCount"], 6)
        for item in applied["entries"]:
            target = Path(quickfile.decode_path(item["targetToken"]))
            self.assertTrue(target.is_symlink())
            self.assertTrue(os.path.samefile(source, target))

    def test_knowledge_link_conflict_is_reported_and_left_untouched(self) -> None:
        project = self.root / "conflict-project"
        project.mkdir()
        existing = project / "AGENTS.md"
        existing.write_text("Existing project instructions.\n", encoding="utf-8")
        source = self.root / "other-knowledge.md"
        source.write_text("Other instructions.\n", encoding="utf-8")
        quickfile.metadata_command(argparse.Namespace(
            path=str(source), path_token=None, color=None, note=None, starred=None,
            knowledge="true", agents_json='["codex"]',
        ))
        args = argparse.Namespace(
            source=str(source), source_token=None,
            root=str(project), root_token=None, apply=False,
        )

        preview = quickfile.knowledge_links_command(args)
        self.assertEqual(preview["conflictCount"], 1)
        self.assertEqual(preview["entries"][0]["status"], "conflict")
        args.apply = True
        applied = quickfile.knowledge_links_command(args)
        self.assertEqual(applied["createdCount"], 0)
        self.assertEqual(existing.read_text(encoding="utf-8"), "Existing project instructions.\n")
        self.assertFalse(existing.is_symlink())

    def test_color_note_and_favorite_are_persisted_and_listed(self) -> None:
        path = str(self.root / "notes.txt")
        saved = quickfile.metadata_command(argparse.Namespace(
            path=path,
            path_token=None,
            color="blue",
            note="Keep this close",
            starred="true",
        ))
        self.assertTrue(saved["metadata"]["starred"])
        metadata_path = Path(os.environ["QUICKFILE_METADATA_FILE"])
        self.assertEqual(metadata_path.stat().st_mode & 0o777, 0o600)

        listing = quickfile.tree_command(self.tree_args())
        row = next(entry for entry in listing["entries"] if entry["name"] == "notes.txt")
        self.assertEqual(row["color"], "blue")
        self.assertEqual(row["note"], "Keep this close")
        self.assertTrue(row["starred"])
        self.assertEqual([entry["name"] for entry in listing["favorites"]], ["notes.txt"])

        properties = quickfile.properties_command(
            argparse.Namespace(path=path, path_token=None)
        )["properties"]
        self.assertEqual(properties["note"], "Keep this close")
        self.assertTrue(properties["starred"])

    def test_metadata_rejects_unknown_theme_colors(self) -> None:
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.metadata_command(argparse.Namespace(
                path=str(self.root / "notes.txt"),
                path_token=None,
                color="chartreuse-ish",
                note=None,
                starred=None,
            ))
        self.assertEqual(raised.exception.code, "metadata-invalid-color")

    def test_metadata_follows_a_rename(self) -> None:
        source = str(self.root / "notes.txt")
        quickfile.metadata_command(argparse.Namespace(
            path=source,
            path_token=None,
            color="#9ece6a",
            note="Renamed note",
            starred="true",
        ))
        renamed = quickfile.action_command(argparse.Namespace(
            action="rename",
            path=source,
            path_token=None,
            path_tokens_json=None,
            name="renamed.txt",
        ))
        metadata = quickfile.properties_command(argparse.Namespace(
            path=renamed["path"], path_token=None
        ))["properties"]
        self.assertEqual(metadata["note"], "Renamed note")
        self.assertEqual(metadata["color"], "#9ece6a")
        self.assertTrue(metadata["starred"])

    def test_batch_copy_uses_path_tokens_without_shell_interpolation(self) -> None:
        destination = self.root / "destination"
        destination.mkdir()
        tokens = [
            quickfile.encode_path(str(self.root / "notes.txt")),
            quickfile.encode_path(str(self.root / "Привет.md")),
        ]
        result = quickfile.action_command(argparse.Namespace(
            action="copy",
            path=None,
            path_token=None,
            path_tokens_json=json.dumps(tokens),
            name=None,
            destination=str(destination),
            destination_token=None,
        ))
        self.assertEqual(len(result["results"]), 2)
        self.assertTrue((destination / "notes.txt").exists())
        self.assertTrue((destination / "Привет.md").exists())

    def test_gio_attribute_parser_preserves_namespaced_keys(self) -> None:
        parsed = quickfile.parse_gio_attributes(
            "display name: demo\nattributes:\n"
            "  standard::content-type: text/plain\n"
            "  time::created: 42\n"
        )
        self.assertEqual(parsed["standard::content-type"], "text/plain")
        self.assertEqual(parsed["time::created"], "42")

    def test_create_and_rename_actions_are_scoped_to_explicit_path(self) -> None:
        create = argparse.Namespace(
            action="touch", path=str(self.root), path_token=None, name="new file.txt"
        )
        created = quickfile.action_command(create)
        self.assertTrue(Path(created["path"]).exists())
        rename = argparse.Namespace(
            action="rename", path=created["path"], path_token=None, name="renamed.txt"
        )
        renamed = quickfile.action_command(rename)
        self.assertTrue(Path(renamed["path"]).exists())
        self.assertFalse(Path(created["path"]).exists())

    def test_rename_never_replaces_an_existing_name(self) -> None:
        source = self.root / "source.txt"
        target = self.root / "target.txt"
        source.write_text("source", encoding="utf-8")
        target.write_text("target", encoding="utf-8")

        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.rename_noreplace(str(source), str(target))

        self.assertEqual(raised.exception.code, "name-conflict")
        self.assertEqual(source.read_text(encoding="utf-8"), "source")
        self.assertEqual(target.read_text(encoding="utf-8"), "target")

    def test_operation_rename_is_persistent_and_undoable(self) -> None:
        source = self.root / "undo-source.txt"
        target = self.root / "undo-target.txt"
        source.write_text("keep", encoding="utf-8")
        args = argparse.Namespace(
            action="rename", path=str(source), path_token=None,
            path_tokens_json=None, name=target.name,
        )

        result = quickfile.operation_command(args, lambda _event: None)
        self.assertTrue(result["ok"])
        self.assertTrue(target.exists())
        self.assertTrue(quickfile.history_command(args)["undoAvailable"])

        undone = quickfile.operation_command(
            argparse.Namespace(action="undo"), lambda _event: None
        )
        self.assertTrue(undone["ok"])
        self.assertTrue(source.exists())
        self.assertFalse(target.exists())
        self.assertFalse(quickfile.history_command(args)["undoAvailable"])

    def test_recursive_copy_reports_progress_and_undo_removes_unchanged_result(self) -> None:
        source = self.root / "copy-tree"
        destination = self.root / "copy-destination"
        source.mkdir()
        destination.mkdir()
        (source / "subfolder").mkdir()
        (source / "subfolder" / "large.bin").write_bytes(b"x" * (2 * 1024 * 1024 + 7))
        (source / "link").symlink_to("subfolder/large.bin")
        events = []
        args = argparse.Namespace(
            action="copy", path=str(source), path_token=None,
            path_tokens_json=None, name=None, destination=str(destination),
            destination_token=None,
        )

        result = quickfile.operation_command(args, events.append)

        copied = destination / source.name
        self.assertTrue(result["ok"])
        self.assertEqual((copied / "subfolder" / "large.bin").stat().st_size,
                         2 * 1024 * 1024 + 7)
        self.assertTrue((copied / "link").is_symlink())
        self.assertTrue(any(event["phase"] == "scanning" for event in events))
        self.assertTrue(any(event["phase"] == "copying" for event in events))

        quickfile.operation_command(argparse.Namespace(action="undo"), lambda _event: None)
        self.assertFalse(copied.exists())
        self.assertTrue(source.exists())

    def test_cancelled_large_copy_removes_partial_target(self) -> None:
        source = self.root / "cancel.bin"
        destination = self.root / "cancel-destination"
        destination.mkdir()
        source.write_bytes(b"z" * (3 * 1024 * 1024))

        def cancel_after_copy_started(event):
            if event.get("phase") == "copying" and event.get("bytesDone", 0) > 0:
                quickfile.request_operation_cancel(15, None)

        with self.assertRaises(quickfile.OperationCancelled):
            quickfile.operation_command(argparse.Namespace(
                action="copy", path=str(source), path_token=None,
                path_tokens_json=None, name=None, destination=str(destination),
                destination_token=None,
            ), cancel_after_copy_started)

        self.assertEqual(list(destination.iterdir()), [])
        self.assertTrue(source.exists())
        self.assertFalse(quickfile.history_command(argparse.Namespace())["undoAvailable"])

    def test_undo_copy_refuses_to_delete_a_changed_result(self) -> None:
        destination = self.root / "changed-destination"
        destination.mkdir()
        source = self.root / "changed-source.txt"
        source.write_text("before", encoding="utf-8")
        quickfile.operation_command(argparse.Namespace(
            action="copy", path=str(source), path_token=None,
            path_tokens_json=None, name=None, destination=str(destination),
            destination_token=None,
        ), lambda _event: None)
        copied = destination / source.name
        copied.write_text("after", encoding="utf-8")

        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.operation_command(argparse.Namespace(action="undo"), lambda _event: None)

        self.assertEqual(raised.exception.code, "undo-target-changed")
        self.assertEqual(copied.read_text(encoding="utf-8"), "after")

    def test_undo_copy_detects_changes_inside_a_copied_folder(self) -> None:
        source = self.root / "guarded-tree"
        destination = self.root / "guarded-destination"
        source.mkdir()
        destination.mkdir()
        (source / "nested.txt").write_text("before", encoding="utf-8")
        quickfile.operation_command(argparse.Namespace(
            action="copy", path=str(source), path_token=None,
            path_tokens_json=None, name=None, destination=str(destination),
            destination_token=None,
        ), lambda _event: None)
        copied = destination / source.name
        (copied / "nested.txt").write_text("after", encoding="utf-8")

        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.operation_command(argparse.Namespace(action="undo"), lambda _event: None)

        self.assertEqual(raised.exception.code, "undo-target-changed")
        self.assertEqual((copied / "nested.txt").read_text(encoding="utf-8"), "after")

    def test_recursive_copy_scan_has_a_hard_item_bound(self) -> None:
        source = self.root / "bounded-tree"
        source.mkdir()
        (source / "one").write_text("1", encoding="utf-8")
        with mock.patch.object(quickfile, "OPERATION_ENTRY_LIMIT", 1):
            with self.assertRaises(quickfile.QuickfileError) as raised:
                quickfile.scan_copy_source(
                    str(source), quickfile.OperationReporter(lambda _event: None)
                )
        self.assertEqual(raised.exception.code, "copy-entry-limit")

    def test_trash_listing_is_bounded_and_uses_fixed_gio_argv(self) -> None:
        output = "trash:///one.txt\t/tmp/one.txt\ntrash:///two.txt\t/tmp/two.txt\n"
        with mock.patch.object(quickfile, "run_bounded", return_value=(0, output, "")) as runner:
            rows = quickfile.trash_rows()
        runner.assert_called_once_with(["gio", "trash", "--list"], timeout=10)
        self.assertEqual([row["uri"] for row in rows], ["trash:///one.txt", "trash:///two.txt"])
        self.assertEqual(rows[0]["originalPath"], "/tmp/one.txt")

    def test_trash_operation_can_be_undone_and_permanent_delete_is_explicit(self) -> None:
        disposable = self.root / "trash-me.txt"
        disposable.write_text("recoverable", encoding="utf-8")
        trash_args = argparse.Namespace(
            action="trash", path=str(disposable), path_token=None,
            path_tokens_json=None,
        )

        trashed_uris = set()
        trash_uri = "trash:///trash-me.txt"

        def fake_gio(argv, *, timeout=quickfile.COMMAND_TIMEOUT, limit=131072):
            if argv == ["gio", "trash", "--list"]:
                output = (f"{trash_uri}\t{disposable}\n" if trash_uri in trashed_uris else "")
                return 0, output, ""
            if argv == ["gio", "trash", "--", str(disposable)]:
                trashed_uris.add(trash_uri)
                return 0, "", ""
            if argv == ["gio", "trash", "--restore", trash_uri]:
                trashed_uris.discard(trash_uri)
                return 0, "", ""
            if argv == ["gio", "remove", trash_uri]:
                trashed_uris.discard(trash_uri)
                return 0, "", ""
            self.fail(f"Unexpected argv: {argv}")

        with mock.patch.object(quickfile, "run_bounded", side_effect=fake_gio):
            trashed = quickfile.operation_command(trash_args, lambda _event: None)
            self.assertTrue(trashed["ok"])
            self.assertTrue(quickfile.history_command(trash_args)["undoAvailable"])

            quickfile.operation_command(argparse.Namespace(action="undo"), lambda _event: None)
            self.assertNotIn(trash_uri, trashed_uris)

            quickfile.operation_command(trash_args, lambda _event: None)
            deleted = quickfile.operation_command(argparse.Namespace(
                action="trash-delete", trash_uri=trash_uri, trash_uris_json=None,
            ), lambda _event: None)
            self.assertTrue(deleted["ok"])
            self.assertNotIn(trash_uri, trashed_uris)
            self.assertFalse(quickfile.history_command(trash_args)["undoAvailable"])

    def test_invalid_child_names_are_rejected(self) -> None:
        with self.assertRaises(quickfile.QuickfileError):
            quickfile.require_name("../escape")

    def test_copy_move_and_duplicate_keep_existing_data(self) -> None:
        destination = self.root / "destination"
        destination.mkdir()
        source = self.root / "notes.txt"

        copied, changed = quickfile.transfer_path(str(source), str(destination), move=False)
        self.assertTrue(changed)
        self.assertEqual(Path(copied).read_text(encoding="utf-8"), "hello")

        copied_again, _ = quickfile.transfer_path(str(source), str(destination), move=False)
        self.assertEqual(Path(copied_again).name, "notes (copy).txt")
        self.assertTrue(Path(copied).exists())

        duplicate, _ = quickfile.transfer_path(str(source), str(self.root), move=False)
        self.assertEqual(Path(duplicate).name, "notes (copy).txt")
        self.assertTrue(source.exists())

        moving = self.root / "move-me.txt"
        moving.write_text("move", encoding="utf-8")
        moved, changed = quickfile.transfer_path(str(moving), str(destination), move=True)
        self.assertTrue(changed)
        self.assertFalse(moving.exists())
        self.assertEqual(Path(moved).read_text(encoding="utf-8"), "move")

    def test_folder_cannot_be_copied_into_itself(self) -> None:
        with self.assertRaises(quickfile.QuickfileError) as raised:
            quickfile.transfer_path(
                str(self.root / "folder"), str(self.root / "folder"), move=False
            )
        self.assertEqual(raised.exception.code, "recursive-transfer")

    @mock.patch.object(quickfile.subprocess, "Popen")
    @mock.patch.object(quickfile.shutil, "which", return_value="/usr/bin/sushi")
    def test_preview_launches_system_sushi_with_fixed_argv(self, _which, popen) -> None:
        popen.return_value.pid = 123
        path = str(self.root / "notes.txt")
        args = argparse.Namespace(
            action="preview", path=path, path_token=None, name=None
        )

        result = quickfile.action_command(args)

        self.assertTrue(result["ok"])
        self.assertEqual(result["pid"], 123)
        self.assertEqual(popen.call_args.args[0], ["/usr/bin/sushi", path])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_search_has_a_hard_scan_bound(self) -> None:
        args = argparse.Namespace(
            path=str(self.root), path_token=None, query="does-not-exist",
            mode="contains", case_sensitive=False, show_hidden=True,
            no_git=True, limit=100, scan_limit=1, timeout=2.0,
        )
        result = quickfile.search_command(args)
        self.assertTrue(result["truncated"])
        self.assertLessEqual(result["scanned"], 2)

    def test_external_drop_accepts_only_bounded_local_file_uris(self) -> None:
        dropped = self.root / "name with spaces.txt"
        dropped.write_text("drop", encoding="utf-8")
        uri = dropped.as_uri()
        args = argparse.Namespace(
            path=None, path_token=None, path_tokens_json=None,
            source_uris_json=json.dumps([uri]),
        )
        self.assertEqual(quickfile.action_paths_from_args(args), [str(dropped)])
        with self.assertRaises(quickfile.QuickfileError) as remote:
            quickfile.local_file_uri_path("file://remote-host/tmp/file")
        self.assertEqual(remote.exception.code, "invalid-source-uri")
        with self.assertRaises(quickfile.QuickfileError):
            quickfile.action_paths_from_args(argparse.Namespace(
                path=None, path_token=None, path_tokens_json=None,
                source_uris_json=json.dumps(["file:///tmp/a"] * 501),
            ))

    def test_external_drop_uses_regular_safe_transfer_operation(self) -> None:
        source = self.root / "drop source.txt"
        destination = self.root / "drop-target"
        source.write_text("dragged", encoding="utf-8")
        destination.mkdir()
        result = quickfile.operation_command(argparse.Namespace(
            action="copy", path=None, path_token=None, path_tokens_json=None,
            source_uris_json=json.dumps([source.as_uri()]), name=None,
            destination=str(destination), destination_token=None,
            conflict_policy="ask",
        ), lambda _event: None)
        self.assertTrue(result["changed"])
        self.assertEqual((destination / source.name).read_text(encoding="utf-8"), "dragged")

    def test_quick_nav_recents_are_private_bounded_tokens(self) -> None:
        visited = self.root / "visited"
        visited.mkdir()
        with mock.patch.object(quickfile, "git_navigation_rows", return_value=[]), \
                mock.patch.object(quickfile, "zoxide_navigation_paths", return_value=[]):
            result = quickfile.quick_nav_command(argparse.Namespace(
                path=str(visited), path_token=None, record=True,
                no_zoxide=False, limit=20,
            ))
        recent = next(row for row in result["entries"] if row["path"] == str(visited))
        self.assertEqual(recent["kind"], "recent")
        state = self.root / "quickfile-recent.json"
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(str(visited), state.read_text(encoding="utf-8"))

    def test_quick_nav_reads_xdg_dirs_and_bounds_optional_tools(self) -> None:
        config = self.root / "xdg-config"
        downloads = self.root / "Downloads"
        config.mkdir()
        downloads.mkdir()
        (config / "user-dirs.dirs").write_text(
            f'XDG_DOWNLOAD_DIR="{downloads}"\nXDG_BOGUS_DIR="/private"\n',
            encoding="utf-8",
        )
        self.assertEqual(quickfile.xdg_user_directories(), [("Downloads", str(downloads))])
        with mock.patch.object(quickfile.shutil, "which", return_value="/usr/bin/zoxide"), \
                mock.patch.object(quickfile, "run_bounded", return_value=(0, str(downloads) + "\n", "")) as runner:
            self.assertEqual(quickfile.zoxide_navigation_paths(quickfile.time.monotonic() + 2),
                             [str(downloads)])
        runner.assert_called_once_with(
            ["/usr/bin/zoxide", "query", "--list"], timeout=2,
            limit=quickfile.QUICK_NAV_COMMAND_LIMIT,
        )

    def test_quick_nav_discovers_git_root_and_worktrees_with_fixed_argv(self) -> None:
        repository = self.root / "repository"
        worktree = self.root / "worktree"
        repository.mkdir()
        worktree.mkdir()
        outputs = [
            (0, str(repository) + "\n", ""),
            (0, f"worktree {repository}\nHEAD deadbeef\n\nworktree {worktree}\nHEAD cafe\n", ""),
        ]
        with mock.patch.object(quickfile, "run_bounded", side_effect=outputs) as runner:
            rows = quickfile.git_navigation_rows(
                [str(repository)], quickfile.time.monotonic() + 2
            )
        self.assertEqual(rows, [("git", str(repository)), ("worktree", str(worktree))])
        self.assertEqual(runner.call_args_list[0].args[0], [
            "git", "-C", str(repository), "rev-parse", "--show-toplevel",
        ])
        self.assertEqual(runner.call_args_list[1].args[0], [
            "git", "-C", str(repository), "worktree", "list", "--porcelain",
        ])

    def make_repository(self) -> Path:
        repository = self.root / "repo"
        (repository / "shown" / "nested").mkdir(parents=True)
        (repository / "elsewhere").mkdir()
        for relative in ("shown/tracked.txt", "shown/nested/deep.txt", "elsewhere/other.txt"):
            (repository / relative).write_text("committed\n", encoding="utf-8")
        environment = {
            **os.environ,
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        }
        for argv in (
            ["git", "init", "--quiet", "--initial-branch", "main", "."],
            ["git", "add", "."],
            ["git", "commit", "--quiet", "-m", "initial"],
        ):
            subprocess.run(argv, cwd=repository, check=True, env=environment,
                           capture_output=True)
        (repository / "shown" / "tracked.txt").write_text("changed\n", encoding="utf-8")
        (repository / "shown" / "nested" / "fresh.txt").write_text("new\n", encoding="utf-8")
        (repository / "elsewhere" / "other.txt").write_text("changed\n", encoding="utf-8")
        return repository

    def test_git_status_scope_matches_full_repository_for_the_displayed_subtree(self) -> None:
        """Scoping status to the shown directory must not lose a single badge.

        Navigation only ever renders paths below the directory it displays, so
        the pathspec that keeps `git status` off the rest of the repository has
        to produce exactly the statuses the unscoped command would.
        """
        if shutil.which("git") is None:
            self.skipTest("git is not installed")
        repository = self.make_repository()
        shown = repository / "shown"
        context = quickfile.git_context(str(shown))
        self.assertEqual(context["root"], str(repository))
        self.assertFalse(context["degraded"])

        unscoped = subprocess.run(
            ["git", "--no-optional-locks", "status", "--porcelain=v1",
             "--untracked-files=all"],
            cwd=repository, capture_output=True, text=True, check=True,
        ).stdout.splitlines()
        expected = {
            str(repository / line[3:]): line[:2]
            for line in unscoped if len(line) >= 4
        }
        within_scope = {
            path: code for path, code in expected.items()
            if path.startswith(str(shown) + os.sep)
        }
        self.assertEqual(context["statuses"], within_scope)
        # The change outside the shown directory is real, and correctly absent.
        self.assertIn(str(repository / "elsewhere" / "other.txt"), expected)
        self.assertNotIn(str(repository / "elsewhere" / "other.txt"), context["statuses"])
        self.assertEqual(
            quickfile.status_for(str(shown / "nested"), context), "??",
            "a directory must still inherit the status of a file below it",
        )

    def test_slow_git_status_is_recorded_once_and_skipped_afterwards(self) -> None:
        """One stalled repository must not cost the deadline on every visit."""
        repository = self.root / "slow"
        repository.mkdir()
        toplevel = (0, str(repository) + "\n", "")
        branch = (0, "main\n", "")
        timed_out = (127, "", "Command timed out after 2s")

        with mock.patch.object(quickfile, "run_bounded",
                               side_effect=[toplevel, branch, timed_out]) as runner:
            first = quickfile.git_context(str(repository))
        self.assertTrue(first["degraded"])
        self.assertEqual(first["statuses"], {})
        self.assertEqual(len(runner.call_args_list), 3)
        self.assertEqual(runner.call_args_list[2].args[0][-2:], ["--", str(repository)])
        self.assertEqual(runner.call_args_list[2].kwargs["timeout"],
                         quickfile.GIT_STATUS_TIMEOUT)

        with mock.patch.object(quickfile, "run_bounded",
                               side_effect=[toplevel, branch]) as runner:
            second = quickfile.git_context(str(repository))
        self.assertTrue(second["degraded"])
        self.assertEqual(second["branch"], "main",
                         "the branch label must survive a skipped status")
        self.assertEqual(len(runner.call_args_list), 2,
                         "a scope known to be slow was asked for status again")

    def test_slow_git_scope_is_forgotten_once_its_entry_expires(self) -> None:
        repository = self.root / "recovered"
        repository.mkdir()
        quickfile.remember_slow_git_scope(str(repository))
        self.assertIn(str(repository), quickfile.load_slow_git_scopes())
        with mock.patch.object(quickfile.time, "time",
                               return_value=quickfile.time.time()
                               + quickfile.GIT_SLOW_SCOPE_TTL + 1):
            self.assertEqual(quickfile.load_slow_git_scopes(), {})

    def test_inline_text_preview_is_bounded(self) -> None:
        document = self.root / "preview.txt"
        document.write_text("a" * 10000, encoding="utf-8")
        result = quickfile.inline_preview_command(argparse.Namespace(
            path=str(document), path_token=None, byte_limit=1024,
        ))["preview"]
        self.assertEqual(result["kind"], "text")
        self.assertEqual(result["bytesRead"], 1024)
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["text"]), 1024)

    def test_inline_image_preview_reads_only_header_and_dimensions(self) -> None:
        image = self.root / "pixel.png"
        image.write_bytes(
            b"\x89PNG\r\n\x1a\n" + b"\x00" * 8
            + (320).to_bytes(4, "big") + (200).to_bytes(4, "big") + b"x" * 4000
        )
        preview = quickfile.inline_preview_command(argparse.Namespace(
            path=str(image), path_token=None, byte_limit=1024,
        ))["preview"]
        self.assertEqual(preview["kind"], "image")
        self.assertEqual((preview["width"], preview["height"]), (320, 200))
        self.assertEqual(preview["bytesRead"], 1024)
        self.assertNotIn("data", preview)

    def test_inline_directory_preview_is_hard_bounded(self) -> None:
        directory = self.root / "preview-folder"
        directory.mkdir()
        for number in range(5):
            (directory / str(number)).write_text("x", encoding="utf-8")
        with mock.patch.object(quickfile, "PREVIEW_DIRECTORY_LIMIT", 2):
            preview = quickfile.inline_preview_command(argparse.Namespace(
                path=str(directory), path_token=None,
            ))["preview"]
        self.assertEqual(preview["kind"], "directory")
        self.assertEqual(len(preview["entries"]), 2)
        self.assertTrue(preview["truncated"])

    def test_operation_ask_reports_all_root_conflicts_before_mutation(self) -> None:
        destination = self.root / "ask-destination"
        destination.mkdir()
        first = self.root / "first.txt"
        second = self.root / "second.txt"
        first.write_text("new-first", encoding="utf-8")
        second.write_text("new-second", encoding="utf-8")
        (destination / first.name).write_text("old-first", encoding="utf-8")
        (destination / second.name).write_text("old-second", encoding="utf-8")
        with self.assertRaises(quickfile.OperationConflict) as raised:
            quickfile.operation_command(argparse.Namespace(
                action="copy", path=None, path_token=None,
                path_tokens_json=json.dumps([
                    quickfile.encode_path(str(first)), quickfile.encode_path(str(second)),
                ]), source_uris_json=None, name=None,
                destination=str(destination), destination_token=None,
                conflict_policy="ask",
            ), lambda _event: None)
        self.assertEqual(len(raised.exception.conflicts), 2)
        self.assertEqual((destination / first.name).read_text(encoding="utf-8"), "old-first")
        self.assertEqual((destination / second.name).read_text(encoding="utf-8"), "old-second")

    def test_operation_skip_and_keep_both_never_overwrite(self) -> None:
        destination = self.root / "policy-destination"
        destination.mkdir()
        source = self.root / "policy.txt"
        source.write_text("new", encoding="utf-8")
        existing = destination / source.name
        existing.write_text("old", encoding="utf-8")
        common = dict(
            action="copy", path=str(source), path_token=None, path_tokens_json=None,
            source_uris_json=None, name=None, destination=str(destination), destination_token=None,
        )
        skipped = quickfile.operation_command(
            argparse.Namespace(**common, conflict_policy="skip"), lambda _event: None
        )
        self.assertFalse(skipped["changed"])
        self.assertEqual(skipped["skippedCount"], 1)
        kept = quickfile.operation_command(
            argparse.Namespace(**common, conflict_policy="keep-both"), lambda _event: None
        )
        self.assertEqual(existing.read_text(encoding="utf-8"), "old")
        self.assertEqual((destination / "policy (copy).txt").read_text(encoding="utf-8"), "new")
        self.assertEqual(kept["conflictPolicyApplied"], "keep-both")

    def test_merge_copies_only_missing_children_and_is_undoable(self) -> None:
        source = self.root / "merge-tree"
        destination = self.root / "merge-destination"
        target = destination / source.name
        source.mkdir()
        destination.mkdir()
        target.mkdir()
        (source / "same.txt").write_text("new", encoding="utf-8")
        (source / "added.txt").write_text("added", encoding="utf-8")
        (target / "same.txt").write_text("old", encoding="utf-8")
        result = quickfile.operation_command(argparse.Namespace(
            action="copy", path=str(source), path_token=None, path_tokens_json=None,
            source_uris_json=None, name=None, destination=str(destination),
            destination_token=None, conflict_policy="merge",
        ), lambda _event: None)
        self.assertTrue(result["changed"])
        self.assertEqual((target / "same.txt").read_text(encoding="utf-8"), "old")
        self.assertEqual((target / "added.txt").read_text(encoding="utf-8"), "added")
        quickfile.operation_command(argparse.Namespace(action="undo"), lambda _event: None)
        self.assertTrue((target / "same.txt").exists())
        self.assertFalse((target / "added.txt").exists())

    def test_merge_never_traverses_an_existing_destination_symlink(self) -> None:
        source = self.root / "symlink-merge"
        destination = self.root / "symlink-merge-destination"
        target = destination / source.name
        outside = self.root / "outside"
        (source / "nested").mkdir(parents=True)
        (source / "nested" / "must-not-escape.txt").write_text("new", encoding="utf-8")
        target.mkdir(parents=True)
        outside.mkdir()
        (target / "nested").symlink_to(outside, target_is_directory=True)
        result = quickfile.operation_command(argparse.Namespace(
            action="copy", path=str(source), path_token=None, path_tokens_json=None,
            source_uris_json=None, name=None, destination=str(destination),
            destination_token=None, conflict_policy="merge",
        ), lambda _event: None)
        self.assertFalse(result["changed"])
        self.assertFalse((outside / "must-not-escape.txt").exists())

    def test_merge_move_leaves_conflicts_and_undoes_transferred_children(self) -> None:
        source = self.root / "move-merge"
        destination = self.root / "move-merge-destination"
        target = destination / source.name
        source.mkdir()
        destination.mkdir()
        target.mkdir()
        (source / "same.txt").write_text("source", encoding="utf-8")
        (source / "moved.txt").write_text("moved", encoding="utf-8")
        (target / "same.txt").write_text("target", encoding="utf-8")
        result = quickfile.operation_command(argparse.Namespace(
            action="move", path=str(source), path_token=None, path_tokens_json=None,
            source_uris_json=None, name=None, destination=str(destination),
            destination_token=None, conflict_policy="merge",
        ), lambda _event: None)
        self.assertTrue(result["changed"])
        self.assertTrue((source / "same.txt").exists())
        self.assertFalse((source / "moved.txt").exists())
        self.assertEqual((target / "same.txt").read_text(encoding="utf-8"), "target")
        quickfile.operation_command(argparse.Namespace(action="undo"), lambda _event: None)
        self.assertEqual((source / "moved.txt").read_text(encoding="utf-8"), "moved")
        self.assertFalse((target / "moved.txt").exists())

    def test_replace_moves_old_target_to_trash_and_undo_restores_it(self) -> None:
        source = self.root / "replace.txt"
        destination = self.root / "replace-destination"
        target = destination / source.name
        backup = self.root / "trashed-replace.txt"
        uri = "trash:///replace.txt"
        destination.mkdir()
        source.write_text("new", encoding="utf-8")
        target.write_text("old", encoding="utf-8")
        in_trash = set()

        def fake_gio(argv, *, timeout=quickfile.COMMAND_TIMEOUT, limit=131072):
            if argv == ["gio", "trash", "--list"]:
                output = f"{uri}\t{target}\n" if uri in in_trash else ""
                return 0, output, ""
            if argv == ["gio", "trash", "--", str(target)]:
                target.rename(backup)
                in_trash.add(uri)
                return 0, "", ""
            if argv == ["gio", "trash", "--restore", uri]:
                backup.rename(target)
                in_trash.discard(uri)
                return 0, "", ""
            self.fail(f"Unexpected argv: {argv}")

        with mock.patch.object(quickfile, "run_bounded", side_effect=fake_gio):
            result = quickfile.operation_command(argparse.Namespace(
                action="copy", path=str(source), path_token=None, path_tokens_json=None,
                source_uris_json=None, name=None, destination=str(destination),
                destination_token=None, conflict_policy="replace",
            ), lambda _event: None)
            self.assertEqual(target.read_text(encoding="utf-8"), "new")
            self.assertTrue(result["changed"])
            quickfile.operation_command(argparse.Namespace(action="undo"), lambda _event: None)
        self.assertEqual(target.read_text(encoding="utf-8"), "old")
        self.assertTrue(source.exists())

    def test_replace_restores_backup_when_copy_fails(self) -> None:
        source = self.root / "failed-replace.txt"
        destination = self.root / "failed-replace-destination"
        target = destination / source.name
        backup = self.root / "failed-replace-backup.txt"
        uri = "trash:///failed-replace.txt"
        destination.mkdir()
        source.write_text("new", encoding="utf-8")
        target.write_text("old", encoding="utf-8")
        in_trash = set()

        def fake_gio(argv, *, timeout=quickfile.COMMAND_TIMEOUT, limit=131072):
            if argv == ["gio", "trash", "--list"]:
                return 0, (f"{uri}\t{target}\n" if uri in in_trash else ""), ""
            if argv == ["gio", "trash", "--", str(target)]:
                target.rename(backup)
                in_trash.add(uri)
                return 0, "", ""
            if argv == ["gio", "trash", "--restore", uri]:
                backup.rename(target)
                in_trash.discard(uri)
                return 0, "", ""
            self.fail(f"Unexpected argv: {argv}")

        with mock.patch.object(quickfile, "run_bounded", side_effect=fake_gio), \
                mock.patch.object(quickfile, "copy_scanned_source", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                quickfile.operation_command(argparse.Namespace(
                    action="copy", path=str(source), path_token=None, path_tokens_json=None,
                    source_uris_json=None, name=None, destination=str(destination),
                    destination_token=None, conflict_policy="replace",
                ), lambda _event: None)
        self.assertEqual(target.read_text(encoding="utf-8"), "old")
        self.assertFalse(in_trash)
        self.assertFalse(quickfile.history_command(argparse.Namespace())["undoAvailable"])

    def test_rg_content_acceleration_uses_fixed_bounded_argv(self) -> None:
        matched = self.root / "notes.txt"
        with mock.patch.object(quickfile.shutil, "which", return_value="/usr/bin/rg"), \
                mock.patch.object(quickfile, "run_bounded", return_value=(0, str(matched) + "\0", "")) as runner:
            candidates = quickfile.rg_content_candidates(
                str(self.root), "hello; touch /tmp/no", "contains", False, False,
                4096, quickfile.time.monotonic() + 2,
            )
        self.assertEqual(candidates, {str(matched)})
        argv = runner.call_args.args[0]
        self.assertIn("--fixed-strings", argv)
        self.assertIn("hello; touch /tmp/no", argv)
        self.assertEqual(argv[-2:], ["--", str(self.root)])
        self.assertNotIn("sh", argv)

    def test_smart_rg_passes_use_fixed_bounded_argv(self) -> None:
        matched = self.root / "notes.txt"
        spellings = [["garden"], ["c++ (draft); touch /tmp/no"], []]
        with mock.patch.object(quickfile.shutil, "which", return_value="/usr/bin/rg"), \
                mock.patch.object(
                    quickfile, "run_bounded", return_value=(0, str(matched) + "\0", "")
                ) as runner:
            found = quickfile.rg_smart_term_files(
                str(self.root), spellings, frozenset({"node_modules"}), False, 4096,
                quickfile.time.monotonic() + 2,
            )
        # One pass per keyword with a spelling; a keyword without one is left
        # for Python, which never reads for it either.
        self.assertEqual(found, [{str(matched)}, {str(matched)}, None])
        self.assertEqual(runner.call_count, 2)
        patterns = []
        for call in runner.call_args_list:
            argv = call.args[0]
            self.assertEqual(argv.count("-e"), 1)
            self.assertIn("!node_modules", argv)
            self.assertEqual(argv[-2:], ["--", str(self.root)])
            self.assertNotIn("sh", argv)
            patterns.append(argv[argv.index("-e") + 1])
        # rg reads a regular expression: the spelling's own symbols are escaped.
        self.assertEqual(sorted(patterns), [r"c\+\+ \(draft\); touch /tmp/no", "garden"])

    def test_search_transparently_falls_back_without_rg(self) -> None:
        args = argparse.Namespace(
            path=str(self.root), path_token=None, query="hello", mode="contains",
            case_sensitive=False, show_hidden=False, no_git=True, limit=100,
            scan_limit=1000, timeout=2.0, content_file_limit=1024 * 1024,
            content_byte_limit=8 * 1024 * 1024,
        )
        with mock.patch.object(quickfile.shutil, "which", return_value=None):
            result = quickfile.search_command(args)
        self.assertEqual(result["engine"], "python")
        self.assertEqual(result["entries"][0]["matchKind"], "content")


if __name__ == "__main__":
    unittest.main()
