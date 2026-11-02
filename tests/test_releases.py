"""Exercise release state and failures without Apple writes, signing, or Git pushes."""
import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import ledger
import native_validation
import release
import screenshots


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "repo"
        self.root.mkdir()
        self.private = Path(temp.name) / "private"
        self.root_patch = patch.object(release, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.state_patch = patch.object(release, "private_root", return_value=self.private)
        self.state_patch.start()
        self.addCleanup(self.state_patch.stop)
        (self.root / "site/lib").mkdir(parents=True)
        (self.root / "changes.md").write_text("# Changes\n## Added\n- [tasks] Turn notes into tasks.\n## Internal\n- [tests] Add regression tests.\n")
        (self.root / "project.yml").write_text('MARKETING_VERSION: "1.0.3"\nCURRENT_PROJECT_VERSION: 5\n')
        self.remote = {"primary_locale": "en-US", "next_build": 10, "builds": [], "versions": [
            {"id": "public", "attributes": {"versionString": "1.0.3", "appVersionState": "READY_FOR_DISTRIBUTION"}}]}
        self.listing = {"name": "Teika", "subtitle": "Voice notes", "description": "Voice notes.", "keywords": "notes", "promotionalText": "", "copyright": "2026 Gustavs Cirulis",
                        "supportUrl": "https://teika.app/support/", "marketingUrl": "https://teika.app/", "privacyPolicyUrl": "https://teika.app/privacy/"}

    def args(self, action="prepare", **kwargs):
        return argparse.Namespace(action=action, version=None, changes=None, dry_run=False, wait_minutes=1, **kwargs)

    def api(self, command, **kwargs):
        if command in ("inspect", "status"):
            return self.remote
        if command == "listing":
            return {"listing": dict(self.listing)}
        raise AssertionError("Unexpected Apple write: " + command)

    def prepare(self):
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(self.args())
        directory = self.root / "releases/1.0.4"
        data = json.loads((directory / "release.json").read_text())
        data.update(notes_reviewed=True, metadata_reviewed=True)
        release.write_json(directory / "release.json", data)
        (directory / "en-US.txt").write_text("• Turn voice notes into tasks.\n")
        release.write_json(directory / "screenshots.json", {"mode": "reuse", "reviewed": True, "reason": "Inspected existing UI", "sets": []})
        ledger.sync_site(self.root)
        return directory

    def test_default_patch_uses_apple_build_and_snapshots_changes(self):
        directory = self.prepare()
        manifest = json.loads((directory / "release.json").read_text())
        self.assertEqual(manifest["build"], 10)
        self.assertEqual(release.settings(), ("1.0.4", 10))
        self.assertEqual([entry["id"] for entry in manifest["changes"]], ["tasks", "tests"])
        self.assertEqual(ledger.pending(self.root), [])
        self.assertNotIn("regression", (directory / "en-US.txt").read_text())
        self.assertNotIn("regression", json.dumps(ledger.public_data(self.root)))

    def test_prepare_dry_run_writes_nothing(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        args = self.args(); args.dry_run = True
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(args)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})
        self.assertFalse(self.private.exists())

    def test_cli_dry_run_creates_no_bytecode_or_picker_state(self):
        shutil.copy(REPO / "run.sh", self.root / "run.sh")
        shutil.copytree(REPO / "scripts", self.root / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        subprocess.run(["bash", "run.sh", "release", "validate", "--dry-run"], cwd=self.root, check=True, capture_output=True)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_duplicate_and_malformed_ledger_entries_fail(self):
        for text in ("## Added\n- [same] One.\n- [same] Two.\n", "## Added\n- Missing ID\n", "## Unsupported\n- [lost] Lost.\n"):
            (self.root / "changes.md").write_text(text)
            with self.assertRaises(RuntimeError): ledger.entries(self.root)

    def test_release_assignment_unknown_ids_and_double_assignment_fail(self):
        directory = self.prepare()
        record = json.loads((directory / "release.json").read_text())
        record["changes"][0]["id"] = "unknown"
        release.write_json(directory / "release.json", record)
        with self.assertRaises(RuntimeError): ledger.changes(self.root)
        record["changes"][0]["id"] = "tasks"
        release.write_json(directory / "release.json", record)
        second = dict(record, version="1.0.5")
        release.write_json(self.root / "releases/1.0.5/release.json", second)
        with self.assertRaises(RuntimeError): ledger.changes(self.root)

    def test_unselected_entries_stay_pending(self):
        args = self.args(); args.changes = "tasks"
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(args)
        self.assertEqual([entry["id"] for entry in ledger.pending(self.root)], ["tests"])

    def test_raw_ledger_never_becomes_public_copy(self):
        self.assertEqual(ledger.public_data(self.root)["pending"], [])
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(self.args())
        self.assertEqual((self.root / "releases/1.0.4/en-US.txt").read_text(), "")

    def test_related_changes_share_one_authored_note_and_follow_assignments(self):
        with (self.root / "changes.md").open("a") as output:
            output.write("\n## Added\n- [settings] Configure destination and delivery details.\n")
        summary = "Send new voice notes straight to your task list."
        release.write_json(self.root / "releases/upcoming.json", {"notes": [{"changes": ["tasks", "settings"], "text": summary}]})
        self.assertEqual(ledger.public_data(self.root)["pending"], [summary])
        self.assertEqual(ledger.curated_notes(self.root, {"tasks"}), [])
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(self.args())
        self.assertEqual((self.root / "releases/1.0.4/en-US.txt").read_text(), "• " + summary + "\n")
        self.assertEqual(ledger.public_data(self.root)["pending"], [])
        args = self.args("abandon"); args.version = "1.0.4"
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(io.StringIO()):
            release.status(args)
        self.assertEqual(ledger.public_data(self.root)["pending"], [summary])

    def test_public_summaries_reject_internal_unknown_or_duplicate_ids(self):
        for identifiers in (["tests"], ["unknown"], ["tasks", "tasks"]):
            release.write_json(self.root / "releases/upcoming.json", {"notes": [{"changes": identifiers, "text": "A public benefit."}]})
            with self.assertRaises(RuntimeError): ledger.public_data(self.root)

    def test_abandoned_changes_return_to_pending(self):
        directory = self.prepare()
        args = self.args("abandon"); args.version = "1.0.4"
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(io.StringIO()):
            release.status(args)
        self.assertEqual(len(ledger.pending(self.root)), 2)
        self.assertEqual(json.loads((directory / "release.json").read_text())["status"], "abandoned")

    def test_cannot_abandon_uploaded_or_submitted_release(self):
        self.prepare()
        attempt = self.private / "releases/1.0.4"
        release.write_json(attempt / "receipt.json", {"uploaded": True})
        args = self.args("abandon"); args.version = "1.0.4"
        with patch.object(release, "asc", side_effect=self.api), self.assertRaises(RuntimeError): release.status(args)

    def test_full_publish_dry_run_has_no_mutations(self):
        self.prepare()
        args = self.args("publish"); args.dry_run = True
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with patch.object(release, "asc", side_effect=self.api), patch.object(release, "website") as site, contextlib.redirect_stdout(io.StringIO()):
            release.publish(args)
        site.assert_not_called()
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})
        self.assertFalse(self.private.exists())

    def test_ambiguous_previous_upload_is_not_repeated(self):
        directory = self.prepare()
        receipt = {"version": "1.0.4", "build": 10, "content_sha256": release.content_hash(directory),
                   "native_source_fingerprint": "native", "upload_started": True}
        release.write_json(self.private / "releases/1.0.4/receipt.json", receipt)
        with patch.object(release, "asc", side_effect=self.api), patch.object(release, "run", return_value=""), \
             patch.object(native_validation, "fingerprint", return_value="native"), patch.object(native_validation, "validate") as validate, \
             contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "ambiguously"):
            release.publish(self.args("upload"))
        validate.assert_not_called()

    def test_matching_remote_build_without_receipt_is_not_adopted(self):
        self.prepare()
        self.remote["builds"] = [{"id": "unowned", "attributes": {"version": "10", "teikaMarketingVersion": "1.0.4"}}]
        with patch.object(release, "asc", side_effect=self.api), patch.object(release, "run", return_value=""), \
             patch.object(native_validation, "fingerprint", return_value="native"), contextlib.redirect_stdout(io.StringIO()), \
             self.assertRaisesRegex(RuntimeError, "without a confirmed"):
            release.publish(self.args("upload"))

    def test_confirmed_upload_resumes_submission_without_building(self):
        directory = self.prepare()
        receipt = {"version": "1.0.4", "build": 10, "content_sha256": release.content_hash(directory),
                   "native_source_fingerprint": "native", "uploaded": True}
        release.write_json(self.private / "releases/1.0.4/receipt.json", receipt)
        self.remote["builds"] = [{"id": "build", "attributes": {"version": "10", "teikaMarketingVersion": "1.0.4", "processingState": "VALID"}}]
        calls = []
        def api(command, **kwargs):
            calls.append(command)
            if command == "stage": return {"version_id": "version"}
            if command == "submit": return {"submission": {"id": "review"}}
            if command == "verify": return {"version_state": "WAITING_FOR_REVIEW"}
            return self.api(command, **kwargs)
        with patch.object(release, "asc", side_effect=api), patch.object(release, "run", return_value=""), \
             patch.object(native_validation, "fingerprint", return_value="native"), patch.object(release, "logged") as logged, \
             contextlib.redirect_stdout(io.StringIO()):
            release.publish(self.args("submit"))
        logged.assert_not_called()
        self.assertEqual(calls, ["inspect", "status", "stage", "submit", "verify"])
        self.assertEqual(json.loads((directory / "release.json").read_text())["status"], "submitted")

    def test_changed_notes_block_receipt_resume(self):
        directory = self.prepare()
        receipt = {"version": "1.0.4", "build": 10, "content_sha256": release.content_hash(directory), "native_source_fingerprint": "native", "uploaded": True}
        release.write_json(self.private / "releases/1.0.4/receipt.json", receipt)
        (directory / "en-US.txt").write_text("• Changed after upload.\n")
        ledger.sync_site(self.root)
        with patch.object(release, "asc", side_effect=self.api), patch.object(release, "run", return_value=""), \
             patch.object(native_validation, "fingerprint", return_value="native"), contextlib.redirect_stdout(io.StringIO()), \
             self.assertRaisesRegex(RuntimeError, "changed since"):
            release.publish(self.args("submit"))

    def test_metadata_limits_and_screenshot_review_gate(self):
        directory = self.prepare()
        metadata = json.loads((directory / "metadata.json").read_text())
        metadata["keywords"] = "x" * 101
        with self.assertRaises(RuntimeError): release.validate_metadata(metadata)
        release.write_json(directory / "screenshots.json", {"mode": "refresh", "reviewed": False, "sets": []})
        with self.assertRaises(RuntimeError): release.screenshot_plan(directory)

    def test_positive_native_counts_required(self):
        self.assertEqual(native_validation.counts({"passedTests": 3, "failedTests": 0, "skippedTests": 0})["passed"], 3)
        for summary in ({}, {"passedTests": 0, "failedTests": 0, "skippedTests": 0},
                        {"passedTests": 3, "failedTests": 1, "skippedTests": 0}, {"passedTests": 3, "failedTests": 0, "skippedTests": 1}):
            with self.assertRaises(RuntimeError): native_validation.counts(summary)

    def test_submitted_release_resumes_from_submission_checkpoint(self):
        directory = self.prepare()
        receipt = {"version": "1.0.4", "build": 10, "content_sha256": release.content_hash(directory),
                   "native_source_fingerprint": "native", "uploaded": True, "build_id": "build", "version_id": "version"}
        release.write_json(self.private / "releases/1.0.4/receipt.json", receipt)
        release.write_json(self.private / "releases/1.0.4/submission.json", {"version_id": "version", "submission_id": "review"})
        self.remote["versions"].append({"id": "version", "attributes": {"versionString": "1.0.4", "appVersionState": "WAITING_FOR_REVIEW"}})
        calls = []
        def api(command, **kwargs):
            calls.append(command)
            if command == "verify":
                self.assertEqual(kwargs["submission_id"], "review")
                return {"version_state": "WAITING_FOR_REVIEW"}
            return self.api(command, **kwargs)
        with patch.object(release, "asc", side_effect=api), patch.object(release, "run", return_value=""), \
             patch.object(native_validation, "fingerprint", return_value="native"), contextlib.redirect_stdout(io.StringIO()):
            release.publish(self.args("submit"))
        self.assertEqual(calls, ["inspect", "verify"])

    def test_processing_failure_preserves_upload(self):
        directory = self.prepare()
        path = self.private / "releases/1.0.4/receipt.json"
        receipt = {"version": "1.0.4", "build": 10, "content_sha256": release.content_hash(directory),
                   "native_source_fingerprint": "native", "uploaded": True}
        release.write_json(path, receipt)
        self.remote["builds"] = [{"id": "build", "attributes": {"version": "10", "teikaMarketingVersion": "1.0.4", "processingState": "INVALID"}}]
        with patch.object(release, "asc", side_effect=self.api), patch.object(release, "run", return_value=""), \
             patch.object(native_validation, "fingerprint", return_value="native"), contextlib.redirect_stdout(io.StringIO()), \
             self.assertRaisesRegex(RuntimeError, "processing failed"):
            release.publish(self.args("submit"))
        self.assertTrue(json.loads(path.read_text())["uploaded"])

    def test_distributed_release_is_verified_without_repeating_completed_stages(self):
        directory = self.prepare()
        receipt = {"version": "1.0.4", "build": 10, "content_sha256": release.content_hash(directory),
                   "native_source_fingerprint": "native", "uploaded": True, "build_id": "build", "version_id": "version", "submission_id": "review"}
        release.write_json(self.private / "releases/1.0.4/receipt.json", receipt)
        self.remote["builds"] = [{"id": "build", "attributes": {"version": "10", "teikaMarketingVersion": "1.0.4", "processingState": "VALID"}}]
        self.remote["versions"].append({"id": "version", "attributes": {"versionString": "1.0.4", "appVersionState": "READY_FOR_DISTRIBUTION"}})
        def api(command, **kwargs):
            if command == "verify": return {"version_state": "READY_FOR_DISTRIBUTION"}
            return self.api(command, **kwargs)
        with patch.object(release, "asc", side_effect=api), patch.object(release, "run", return_value=""), \
             patch.object(native_validation, "fingerprint", return_value="native"), patch.object(release, "website") as website, \
             patch.object(release, "logged") as logged, contextlib.redirect_stdout(io.StringIO()):
            release.publish(self.args("publish"))
        logged.assert_not_called()
        website.assert_not_called()
        self.assertEqual(json.loads((directory / "release.json").read_text())["status"], "distributed")

    def test_status_reports_website_upload_submission_and_distribution_separately(self):
        self.prepare()
        args = self.args("status"); args.version = "1.0.4"; args.dry_run = True
        release.write_json(self.private / "releases/1.0.4/receipt.json", {"uploaded": True, "submission_id": "review"})
        release.write_json(self.private / "releases/1.0.4/website.json", {"status": "published"})
        self.remote["versions"].append({"id": "version", "attributes": {"versionString": "1.0.4", "appVersionState": "WAITING_FOR_REVIEW", "releaseType": "AFTER_APPROVAL"}})
        output = io.StringIO()
        with patch.object(release, "asc", side_effect=self.api), contextlib.redirect_stdout(output): release.status(args)
        state = json.loads(output.getvalue())
        self.assertEqual(state["website"]["status"], "published")
        self.assertEqual(state["upload"]["state"], "confirmed")
        self.assertEqual(state["submission"]["state"], "submitted")
        self.assertEqual(state["distribution"]["state"], "not_distributed")
        self.assertEqual(state["publication_policy"], "AFTER_APPROVAL")

    def test_change_coverage_requires_ledger_or_explicit_explanation(self):
        with patch.object(ledger.subprocess, "check_output", return_value="teika/ContentView.swift\n"):
            with self.assertRaises(RuntimeError): ledger.check_coverage(self.root, "origin/main")
            ledger.check_coverage(self.root, "origin/main", no_release_impact=True)
        with patch.object(ledger.subprocess, "check_output", return_value="teika/ContentView.swift\nchanges.md\n"):
            ledger.check_coverage(self.root, "origin/main")
        with patch.object(ledger.subprocess, "check_output", return_value="releases/1.0.4/release.json\nproject.yml\nsite/lib/releases.json\n"):
            ledger.check_coverage(self.root, "origin/main")

    def test_dimensions_are_checked_without_resizing(self):
        path = self.root / "capture.png"
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        def png(color):
            return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">II", 1320, 2868) + bytes([8, color, 0, 0, 0])) + chunk(b"IEND", b"")
        path.write_bytes(png(2))
        self.assertEqual(screenshots.validate_png(path, "APP_IPHONE_69"), (1320, 2868))
        with self.assertRaises(RuntimeError): screenshots.validate_png(path, "APP_WATCH_SERIES_7")
        path.write_bytes(png(6))
        with self.assertRaisesRegex(RuntimeError, "opaque"): screenshots.validate_png(path, "APP_IPHONE_69")

    def test_real_backfill_has_expected_entries_and_baseline(self):
        items = ledger.entries(REPO)
        ids = {entry["id"] for entry in items}
        self.assertTrue({"automatic-task-exports", "task-export-settings", "persistent-task-delivery", "task-delivery-recovery",
                         "task-description-content", "task-export-privacy", "export-regression-coverage"}.issubset(ids))
        self.assertNotIn("saved-note-editing", ids)
        self.assertEqual(ledger.manifests(REPO)[0]["build"], 5)
        ledger.sync_site(REPO, check=True)


if __name__ == "__main__":
    unittest.main()
