from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
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


class BackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.environment = mock.patch.dict(
            os.environ,
            {
                "QUICKFILE_METADATA_FILE": str(self.root / "quickfile-metadata.json"),
                "QUICKFILE_STATE_FILE": str(self.root / "quickfile-operations.json"),
                "QUICKFILE_HOME": str(self.root),
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
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_path_tokens_round_trip(self) -> None:
        path = str(self.root / "Привет.md")
        self.assertEqual(quickfile.decode_path(quickfile.encode_path(path)), path)

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

    def test_tree_sorts_directories_and_hides_dotfiles(self) -> None:
        result = quickfile.tree_command(self.tree_args())
        names = [row["name"] for row in result["entries"]]
        self.assertEqual(names[0], "folder")
        self.assertNotIn(".hidden", names)

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


if __name__ == "__main__":
    unittest.main()
