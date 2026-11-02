#!/usr/bin/env python3
"""Teika release orchestration. Live writes occur only in explicit release actions."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import urllib.request

import ledger
import native_validation

ROOT = Path(__file__).resolve().parents[1]
READ_ONLY = False
APP_ID = "6796609245"
BUNDLE = "com.gustavscirulis.teika"
SUBMITTED = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_DISTRIBUTION",
             "READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}
DISTRIBUTED = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}


def run(args, capture=False, cwd=None):
    return subprocess.run([str(arg) for arg in args], cwd=cwd or ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def private_root():
    path = Path(os.environ.get("TEIKA_RELEASE_STATE_DIR", "~/.appstoreconnect/teika")).expanduser().resolve()
    if path.is_relative_to(ROOT.resolve()):
        raise RuntimeError("Private release state must live outside the repository")
    return path


def asc(command, **options):
    # Build before the API request, so cold compilation does not consume a JWT lifetime.
    scratch = ROOT / ".context/release-tools-build"
    if READ_ONLY:
        binary = scratch / "debug/teika-asc"
        sources = list((ROOT / "tools/ReleaseTools/Sources").rglob("*.swift")) + [ROOT / "tools/ReleaseTools/Package.swift"]
        if not binary.exists() or any(path.stat().st_mtime > binary.stat().st_mtime for path in sources):
            raise RuntimeError("Run ./run.sh release doctor once to compile the helper before a write-free dry run")
    else:
        run(["swift", "build", "--disable-sandbox", "--package-path", ROOT / "tools/ReleaseTools",
             "--scratch-path", scratch, "--product", "teika-asc"], capture=True)
    args = [scratch / "debug/teika-asc", command]
    for key, value in options.items():
        if value is not None:
            args += ["--" + key.replace("_", "-"), str(value)]
    return json.loads(run(args, capture=True))


def settings():
    text = (ROOT / "project.yml").read_text()
    return re.search(r'MARKETING_VERSION: "([^"]+)"', text)[1], int(re.search(r"CURRENT_PROJECT_VERSION: (\d+)", text)[1])


def version_state(version):
    attrs = version.get("attributes", {}) if version else {}
    return attrs.get("appVersionState", attrs.get("appStoreState", "UNKNOWN"))


def release_path(version):
    ledger.version_tuple(version)
    return ROOT / "releases" / version


def select_version(requested=None):
    version = requested or settings()[0]
    if requested is None:
        candidates = [item for item in ledger.manifests(ROOT) if item["status"] not in ("distributed", "abandoned")]
        if len(candidates) == 1:
            return candidates[0]["version"]
        if len(candidates) > 1:
            raise RuntimeError("Several prepared releases exist; pass --version")
    return version


def content_hash(directory):
    digest = hashlib.sha256()
    for name in ("release.json", "en-US.txt", "metadata.json", "screenshots.json"):
        path = directory / name
        if name == "release.json":
            data = json.loads(path.read_text())
            # Read-back status changes do not invalidate a previously uploaded binary.
            data = {key: data[key] for key in ("version", "build", "changes", "previous_version_id", "locale")}
            value = json.dumps(data, sort_keys=True).encode()
        else:
            value = path.read_bytes()
        digest.update(name.encode() + b"\0" + value)
    return digest.hexdigest()


def notes(directory):
    text = (directory / "en-US.txt").read_text()
    lines = [line for line in text.splitlines() if line]
    if not 1 <= len(lines) <= 4 or len(text) > 4000 or not all(line.startswith("• ") and len(line) > 4 for line in lines):
        raise RuntimeError("Agent must author 1–4 concise • bullets (at most 4,000 characters)")
    manifest = json.loads((directory / "release.json").read_text())
    if not manifest.get("notes_reviewed"):
        raise RuntimeError("Review the release notes and set notes_reviewed to true")
    return text


def validate_metadata(data):
    limits = {"description": 4000, "keywords": 100, "promotionalText": 170, "reviewNotes": 4000,
              "supportUrl": 1000, "marketingUrl": 1000, "privacyPolicyUrl": 1000, "copyright": 200,
              "name": 30, "subtitle": 30}
    for field, limit in limits.items():
        value = data.get(field)
        if not isinstance(value, str) or len(value) > limit or (field not in ("keywords", "promotionalText", "subtitle") and not value):
            raise RuntimeError("Missing/oversized metadata field: " + field)
    for field in ("supportUrl", "marketingUrl", "privacyPolicyUrl"):
        if not data[field].startswith("https://"):
            raise RuntimeError("Metadata URLs must use HTTPS")


def prepare(args):
    remote = asc("inspect", local_build=settings()[1])
    released = [version for version in remote["versions"] if version_state(version) in DISTRIBUTED]
    if not released:
        raise RuntimeError("No public Apple release found; initial app submission needs a separate workflow")
    baseline = max(released, key=lambda item: tuple(map(int, item["attributes"]["versionString"].split("."))))
    base_version = baseline["attributes"]["versionString"]
    parts = list(map(int, base_version.split(".")))
    parts += [0] * (3 - len(parts))
    parts[2] += 1
    version = args.version or ".".join(map(str, parts))
    directory = release_path(version)
    if directory.exists():
        raise RuntimeError("Release already exists; resume it or abandon it explicitly")
    if ledger.version_tuple(version) <= tuple(list(map(int, base_version.split("."))) + [0] * (3 - len(base_version.split(".")))):
        raise RuntimeError("Version must be newer than the current public release")
    selected = ledger.pending(ROOT)
    if args.changes:
        requested = set(args.changes.split(","))
        if requested - {entry["id"] for entry in selected}:
            raise RuntimeError("Selected changes are unknown or already assigned")
        selected = [entry for entry in selected if entry["id"] in requested]
    if not any(entry["group"] != "Internal" for entry in selected):
        raise RuntimeError("No pending customer-facing changes selected")
    draft_notes = ledger.curated_notes(ROOT, {entry["id"] for entry in selected})
    if remote["primary_locale"] != "en-US":
        raise RuntimeError("This workflow currently manages the existing en-US listing only")
    metadata = asc("listing", version_id=baseline["id"], locale="en-US")["listing"]
    metadata["reviewNotes"] = (
        "No account is required. On first launch choose Set Up Transcription, then approve the one-time 0.5 GB model download. "
        "Record with two taps; transcription runs on the iPhone. Saved notes are editable from the notes library. "
        "A paired Apple Watch records after iPhone setup and queues recordings while disconnected. "
        "In Notes > Settings, Add notes to defaults to Off. Things (installed separately) supports Inbox/Today; "
        "Apple Reminders requests permission and offers list and No date/Today choices. Only new notes are exported. "
        "If delivery is unconfirmed, check the destination before retrying to avoid duplicates.")
    if "OPTIONAL TASK INTEGRATIONS" not in metadata["description"]:
        metadata["description"] += ("\n\nOPTIONAL TASK INTEGRATIONS\nTurn new voice notes into tasks in Things or Apple Reminders. "
                                "Choose your destination in Notes Settings. Task exports are off until you enable them.")
    metadata.pop("screenshotDisplays", None)
    manifest = {"schema": 1, "version": version, "build": remote["next_build"], "status": "prepared",
                "date": dt.date.today().isoformat(), "locale": "en-US", "previous_version_id": baseline["id"],
                "changes": selected, "notes_reviewed": False, "metadata_reviewed": False}
    # The agent decides which existing images became inaccurate after inspecting the diff.
    screenshots = {"mode": "refresh", "reviewed": False, "reason": "Review UI changes against existing App Store assets", "sets": []}
    if args.dry_run:
        print(json.dumps({"release": manifest, "notes": draft_notes, "metadata": metadata, "screenshots": screenshots}, indent=2))
        return
    write_json(directory / "release.json", manifest)
    write_json(directory / "metadata.json", metadata)
    write_json(directory / "screenshots.json", screenshots)
    (directory / "en-US.txt").write_text("".join("• " + text + "\n" for text in draft_notes))
    text = (ROOT / "project.yml").read_text()
    text = re.sub(r'MARKETING_VERSION: "[^"]+"', f'MARKETING_VERSION: "{version}"', text)
    text = re.sub(r"CURRENT_PROJECT_VERSION: \d+", f'CURRENT_PROJECT_VERSION: {manifest["build"]}', text)
    (ROOT / "project.yml").write_text(text)
    ledger.sync_site(ROOT)
    print(f"Prepared {version} ({manifest['build']}). Author/review notes and metadata, capture/review screenshots, then commit.")


def logged(command, path):
    print("Log: " + str(path), flush=True)
    with path.open("w") as output:
        subprocess.run([str(item) for item in command], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)


def check_archive(path, version, build):
    with (path / "Info.plist").open("rb") as source:
        archive = plistlib.load(source)
    properties = archive["ApplicationProperties"]
    if (properties.get("CFBundleShortVersionString"), properties.get("CFBundleVersion")) != (version, str(build)):
        raise RuntimeError("Archive version/build differs from prepared release")
    app = path / "Products" / properties["ApplicationPath"]
    expected = {BUNDLE, BUNDLE + ".widget", BUNDLE + ".watchkitapp", BUNDLE + ".watchkitapp.widget"}
    seen = set()
    bundles = [app] + [item for item in app.rglob("*") if item.suffix in (".app", ".appex")]
    for bundle in bundles:
        with (bundle / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        if info.get("CFBundleIdentifier") in expected:
            seen.add(info["CFBundleIdentifier"])
            if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (version, str(build)):
                raise RuntimeError("Embedded app/extension version mismatch: " + bundle.name)
            run(["codesign", "--verify", "--strict", bundle], capture=True)
            executable = bundle / info["CFBundleExecutable"]
            if b"-teika-release-screenshot" in executable.read_bytes():
                raise RuntimeError("Debug screenshot launch hook leaked into Release bundle: " + bundle.name)
    if seen != expected:
        raise RuntimeError("Archive is missing an expected phone/Watch/widget bundle")
    return app


def uploaded_build(remote, manifest):
    matching = [item for item in remote["builds"] if item["attributes"].get("version") == str(manifest["build"])
                and item["attributes"].get("teikaMarketingVersion") == manifest["version"]]
    if len(matching) > 1:
        raise RuntimeError("Ambiguous remote build identity")
    return matching[0] if matching else None


def screenshot_plan(directory):
    plan = json.loads((directory / "screenshots.json").read_text())
    if plan.get("reviewed") is not True or not plan.get("reason"):
        raise RuntimeError("Screenshot decision needs a reason and reviewed: true")
    if plan.get("mode") == "reuse":
        if plan.get("sets"):
            raise RuntimeError("Reuse screenshot plan must not contain replacement sets")
        return plan
    if plan.get("mode") != "refresh" or not plan.get("sets"):
        raise RuntimeError("Capture screenshots or explicitly review reuse before submission")
    from screenshots import validate_png
    displays = set()
    for group in plan["sets"]:
        display = group["display"]
        if display in displays or not 1 <= len(group["files"]) <= 10:
            raise RuntimeError("Duplicate display or invalid screenshot count")
        displays.add(display)
        files = []
        dimensions = set()
        for item in group["files"]:
            path = (directory / item["path"]).resolve()
            if not path.is_relative_to(directory.resolve()) or not path.is_file():
                raise RuntimeError("Screenshot path must be inside this release directory")
            dimensions.add(validate_png(path, display))
            if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
                raise RuntimeError("Screenshot changed after review: " + item["path"])
            files.append(str(path))
        if len(dimensions) != 1:
            raise RuntimeError("Use one consistent screenshot size within each display set")
        group["files"] = files
    return plan


def publish(args):
    version = select_version(args.version)
    directory = release_path(version)
    manifest = json.loads((directory / "release.json").read_text())
    if manifest["status"] == "abandoned" or manifest.get("baseline"):
        raise RuntimeError("Cannot publish an abandoned or historical baseline release")
    text = notes(directory)
    metadata = json.loads((directory / "metadata.json").read_text())
    validate_metadata(metadata)
    if manifest.get("metadata_reviewed") is not True:
        raise RuntimeError("Review the listing and set metadata_reviewed to true")
    assets = screenshot_plan(directory)
    ledger.changes(ROOT)
    ledger.sync_site(ROOT, check=True)
    if settings() != (version, manifest["build"]):
        raise RuntimeError("Project settings differ from prepared version/build")
    remote = asc("inspect", local_build=manifest["build"])
    remote_version = next((item for item in remote["versions"] if item["attributes"]["versionString"] == version), None)
    plan = {"action": args.action, "version": version, "build": manifest["build"], "notes": text, "metadata": metadata,
            "screenshots": assets["mode"], "submission": "App Review", "release_type": "AFTER_APPROVAL",
            "website": "Merge release PR and verify Vercel immediately"}
    print(json.dumps(plan, indent=2, ensure_ascii=False), flush=True)
    if args.dry_run:
        return
    if run(["git", "status", "--porcelain"], capture=True).strip():
        raise RuntimeError("Commit the prepared release content before publishing; working tree must be clean")
    state = private_root()
    attempt = state / "releases" / version
    attempt.mkdir(parents=True, exist_ok=True)
    receipt_path = attempt / "receipt.json"
    receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    identity = {"version": version, "build": manifest["build"], "content_sha256": content_hash(directory),
                "native_source_fingerprint": native_validation.fingerprint(ROOT, include_resolution=False)}
    if receipt and any(receipt.get(key) != value for key, value in identity.items()):
        raise RuntimeError("Release source/content changed since the previous attempt; inspect durable receipts")
    receipt.update(identity)
    checkpoint = attempt / "submission.json"
    if not receipt.get("submission_id") and checkpoint.exists():
        saved = json.loads(checkpoint.read_text())
        if saved.get("version_id") == receipt.get("version_id"):
            receipt["submission_id"] = saved["submission_id"]
    build = uploaded_build(remote, manifest)
    if build and not receipt.get("uploaded"):
        raise RuntimeError("A matching Apple build exists without a confirmed local upload receipt; reconcile it before retrying")
    if build and receipt.get("build_id") not in (None, build["id"]):
        raise RuntimeError("Apple build ID differs from receipt")
    state_remote = version_state(remote_version)
    if state_remote in SUBMITTED:
        if not receipt.get("submission_id") or not receipt.get("build_id") or not remote_version:
            raise RuntimeError("Remote version already submitted without matching local submission evidence")
        audit = verify(manifest, directory, receipt)
        save_submission(manifest, directory, receipt, audit)
        print("Already submitted; verified without repeating upload or review submission.")
        return
    if args.action == "publish":
        website(args, version=version)
    if args.action in ("publish", "upload") and not receipt.get("uploaded"):
        if receipt.get("upload_started"):
            raise RuntimeError("Previous upload ended ambiguously. Inspect upload.log and Apple; do not upload again blindly")
        team = os.environ.get("TEIKA_DEVELOPMENT_TEAM")
        if not team:
            raise RuntimeError("Set TEIKA_DEVELOPMENT_TEAM for signing")
        native_validation.validate(ROOT, state)
        receipt["native_fingerprint"] = native_validation.fingerprint(ROOT)
        # Resolution during validation is authoritative for the archive as well.
        archive_dir = attempt / "archives" / str(time.time_ns())
        archive_dir.mkdir(parents=True)
        archive = archive_dir / "Teika.xcarchive"
        logged(["xcodebuild", "-project", "Teika.xcodeproj", "-scheme", "Teika", "-configuration", "Release",
                "-destination", "generic/platform=iOS", "-archivePath", archive, "-derivedDataPath", ROOT / "DerivedData",
                "DEVELOPMENT_TEAM=" + team, "-allowProvisioningUpdates", "-disableAutomaticPackageResolution", "archive"], archive_dir / "archive.log")
        check_archive(archive, version, manifest["build"])
        if native_validation.fingerprint(ROOT) != receipt["native_fingerprint"]:
            raise RuntimeError("Native inputs changed while archiving")
        options = {"method": "app-store-connect", "destination": "upload", "signingStyle": "automatic", "teamID": team,
                   "manageAppVersionAndBuildNumber": False, "uploadSymbols": True}
        plist = archive_dir / "ExportOptions.plist"
        plist.write_bytes(plistlib.dumps(options))
        receipt.update(upload_started=True, archive=str(archive), source_commit=run(["git", "rev-parse", "HEAD"], capture=True).strip())
        write_json(receipt_path, receipt)
        logged(["xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", archive_dir / "export",
                "-exportOptionsPlist", plist, "-allowProvisioningUpdates"], archive_dir / "upload.log")
        receipt["uploaded"] = True
        write_json(receipt_path, receipt)
    if not receipt.get("uploaded"):
        raise RuntimeError("No confirmed upload. Run release upload first")
    if args.action == "upload":
        print("Upload confirmed. Resume with ./run.sh release submit --version " + version)
        return
    deadline = time.monotonic() + args.wait_minutes * 60
    while True:
        remote = asc("status")
        build = uploaded_build(remote, manifest)
        if build:
            processing = build["attributes"].get("processingState")
            if processing == "VALID":
                break
            if processing in ("FAILED", "INVALID"):
                raise RuntimeError("Apple processing failed: " + processing)
        if time.monotonic() >= deadline:
            raise RuntimeError("Processing timed out; upload preserved. Resume release submit later")
        print("Waiting for Apple processing…", flush=True)
        time.sleep(15)
    receipt["build_id"] = build["id"]
    write_json(receipt_path, receipt)
    def unchanged():
        if content_hash(directory) != receipt["content_sha256"] or native_validation.fingerprint(ROOT, include_resolution=False) != receipt["native_source_fingerprint"]:
            raise RuntimeError("Release inputs changed during processing; stop before further Apple writes")
        screenshot_plan(directory)
        if run(["git", "status", "--porcelain"], capture=True).strip():
            raise RuntimeError("Working tree changed during release")
    unchanged()
    staged = asc("stage", version=version, build_id=build["id"], notes=directory / "en-US.txt",
                 metadata=directory / "metadata.json", previous_version_id=manifest["previous_version_id"])
    receipt["version_id"] = staged["version_id"]
    write_json(receipt_path, receipt)
    if assets["mode"] == "refresh":
        asset_plan = attempt / "asset-plan.json"
        write_json(asset_plan, assets)
        asc("assets", version_id=receipt["version_id"], plan=asset_plan, checkpoint=attempt / "assets.json")
    unchanged()
    submission = asc("submit", version_id=receipt["version_id"], checkpoint=attempt / "submission.json")["submission"]
    receipt["submission_id"] = submission["id"]
    write_json(receipt_path, receipt)
    audit = verify(manifest, directory, receipt)
    write_json(attempt / "audit.json", audit)
    save_submission(manifest, directory, receipt, audit)
    print(f"Verified {version} ({manifest['build']}): {audit['version_state']}; automatic publication after approval.")


def verify(manifest, directory, receipt):
    # Recover a submission checkpoint even if the process died before receipt update.
    checkpoint = private_root() / "releases" / manifest["version"] / "submission.json"
    if not receipt.get("submission_id") and checkpoint.exists():
        saved = json.loads(checkpoint.read_text())
        if saved.get("version_id") == receipt.get("version_id"):
            receipt["submission_id"] = saved["submission_id"]
    return asc("verify", version=manifest["version"], version_id=receipt["version_id"], build_id=receipt["build_id"],
               build=manifest["build"], submission_id=receipt["submission_id"], notes=directory / "en-US.txt", metadata=directory / "metadata.json")


def save_submission(manifest, directory, receipt, audit):
    manifest.update(status="distributed" if audit["version_state"] in DISTRIBUTED else "submitted",
                    build_id=receipt["build_id"], version_id=receipt["version_id"], submission_id=receipt["submission_id"])
    write_json(directory / "release.json", manifest)
    write_json(private_root() / "releases" / manifest["version"] / "audit.json", audit)


def website(args, version=None):
    version = version or select_version(args.version)
    release_path(version)
    receipt_path = private_root() / "releases" / version / "website.json"
    saved = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    if args.dry_run:
        print(json.dumps({"website": saved, "action": "Validate, merge release PR, verify Vercel Production and public pages"}, indent=2))
        return
    # This action only runs on explicit publish/website, never during tooling validation.
    if not saved.get("merged_commit"):
        if run(["git", "status", "--porcelain"], capture=True).strip():
            raise RuntimeError("Commit site and release changes before website publication")
        pr = json.loads(run(["gh", "pr", "view", "--json", "number,baseRefName,headRefOid,state,mergeCommit"], capture=True))
        if pr["baseRefName"] != "main":
            raise RuntimeError("Release PR must target main")
        if pr["state"] != "MERGED":
            if pr["headRefOid"] != run(["git", "rev-parse", "HEAD"], capture=True).strip():
                raise RuntimeError("Push the exact prepared release revision before merging")
            # Run local checks even if the repository has no required hosted checks.
            run(["python3", "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"])
            run(["bash", "tests/test_things_exports.sh"])
            run(["swift", "test", "--disable-sandbox", "--package-path", "tools/ReleaseTools"])
            run(["npm", "run", "lint"], cwd=ROOT / "site")
            run(["npm", "run", "build"], cwd=ROOT / "site")
            native_validation.validate(ROOT, private_root())
            # gh exits 8 when no checks are configured; distinguish that from failed checks.
            checks = json.loads(run(["gh", "pr", "view", str(pr["number"]), "--json", "statusCheckRollup"], capture=True))["statusCheckRollup"]
            if any(item.get("conclusion", item.get("state")) not in ("SUCCESS", "NEUTRAL", "SKIPPED") for item in checks):
                raise RuntimeError("PR checks are pending or failed")
            if run(["git", "status", "--porcelain"], capture=True).strip():
                raise RuntimeError("Working tree changed during release validation")
            run(["gh", "pr", "merge", str(pr["number"]), "--merge", "--match-head-commit", pr["headRefOid"]])
            pr = json.loads(run(["gh", "pr", "view", str(pr["number"]), "--json", "mergeCommit"], capture=True))
        saved["merged_commit"] = pr["mergeCommit"]["oid"]
        write_json(receipt_path, saved)
    deadline = time.monotonic() + args.wait_minutes * 60
    while True:
        deployments = json.loads(run(["gh", "api", f"repos/gustavscirulis/teika/deployments?sha={saved['merged_commit']}&environment=Production"], capture=True))
        for deployment in deployments:
            statuses = json.loads(run(["gh", "api", f"repos/gustavscirulis/teika/deployments/{deployment['id']}/statuses"], capture=True))
            if statuses and statuses[0]["state"] in ("failure", "error"):
                raise RuntimeError("Vercel production deployment failed; resume website after fixing it")
            if statuses and statuses[0]["state"] == "success":
                for route in ("", "support/", "privacy/", "updates/"):
                    with urllib.request.urlopen("https://teika.app/" + route, timeout=30) as response:
                        body = response.read().decode()
                        if response.status != 200 or (route == "updates/" and version not in body):
                            raise RuntimeError("Public site verification failed: " + route)
                saved.update(deployment_id=deployment["id"], url=statuses[0].get("environment_url"), status="published")
                write_json(receipt_path, saved)
                print("Website published and verified at https://teika.app")
                return
        if time.monotonic() >= deadline:
            raise RuntimeError("Vercel deployment not confirmed; resume release website later")
        time.sleep(10)


def status(args):
    version = select_version(args.version)
    directory = release_path(version)
    manifest = json.loads((directory / "release.json").read_text())
    remote = asc("status")
    current = next((item for item in remote["versions"] if item["attributes"]["versionString"] == version), None)
    attempt = private_root() / "releases" / version
    receipt = json.loads((attempt / "receipt.json").read_text()) if (attempt / "receipt.json").exists() else {}
    build = uploaded_build(remote, manifest)
    apple_state = version_state(current)
    upload_state = "confirmed" if receipt.get("uploaded") else "unconfirmed" if receipt.get("upload_started") else "observed_in_apple" if build else "not_uploaded"
    result = {"local": manifest["status"], "version": version, "build": manifest["build"], "apple": version_state(current),
              "upload": {"state": upload_state, "build_id": build["id"] if build else receipt.get("build_id"),
                         "processing": build.get("attributes", {}).get("processingState") if build else None},
              "submission": {"state": "submitted" if apple_state in SUBMITTED else "not_submitted", "id": receipt.get("submission_id")},
              "distribution": {"state": "distributed" if apple_state in DISTRIBUTED else "not_distributed"},
              "publication_policy": current.get("attributes", {}).get("releaseType") if current else None,
              "website": json.loads((attempt / "website.json").read_text()) if (attempt / "website.json").exists() else {"status": "not_confirmed"}}
    if args.action == "abandon":
        if current and version_state(current) in SUBMITTED:
            raise RuntimeError("Cannot abandon a submitted/distributed version")
        if (attempt / "receipt.json").exists():
            raise RuntimeError("Release has private upload evidence; reconcile it before abandoning")
        if not args.dry_run:
            manifest["status"] = "abandoned"
            write_json(directory / "release.json", manifest)
            ledger.sync_site(ROOT)
        result["action"] = "Return selected changes to pending"
    elif not args.dry_run and manifest.get("submission_id"):
        audit = verify(manifest, directory, receipt)
        save_submission(manifest, directory, receipt, audit)
        result["local"] = manifest["status"]
        result["verified"] = audit
    print(json.dumps(result, indent=2))


def doctor(args):
    missing = [name for name in ("xcodebuild", "xcodegen", "swift", "xcrun", "codesign", "python3", "git", "gh", "npm") if not shutil.which(name)]
    if missing:
        raise RuntimeError("Missing tools: " + ", ".join(missing))
    remote = asc("inspect", local_build=settings()[1])
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True)
    distribution = [line for line in identities.splitlines() if '"Apple Distribution:' in line or '"iPhone Distribution:' in line]
    print(json.dumps({"app_id": APP_ID, "bundle_id": BUNDLE, "primary_locale": remote["primary_locale"],
                      "next_build": remote["next_build"], "api_read": "verified", "api_write": "not exercised by read-only doctor",
                      "signing_team_configured": bool(os.environ.get("TEIKA_DEVELOPMENT_TEAM")),
                      "distribution_identity_count": len(distribution),
                      "signing": "Profile/archive access is verified by Xcode at archive time",
                      "metadata_review_role": "App Manager or Admin required; server enforces writes",
                      "website": "Existing Vercel Git integration; no CLI token required"}, indent=2))


def main():
    global READ_ONLY
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    changes = commands.add_parser("changes")
    changes.add_argument("--sync-site", action="store_true")
    changes.add_argument("--check", action="store_true")
    changes.add_argument("--json", action="store_true")
    changes.add_argument("--base", help="Require a ledger change compared with this Git base")
    changes.add_argument("--no-release-impact", action="store_true", help="PR explicitly explains why no ledger entry is needed")
    release = commands.add_parser("release")
    release.add_argument("action", choices=("doctor", "prepare", "publish", "upload", "submit", "status", "website", "abandon", "validate", "screenshots"))
    release.add_argument("--version")
    release.add_argument("--changes", help="Comma-separated pending change IDs; default: all")
    release.add_argument("--dry-run", action="store_true")
    release.add_argument("--wait-minutes", type=int, default=30)
    release.add_argument("--fresh", action="store_true")
    release.add_argument("--family", choices=("all", "iphone", "ipad", "watch"), default="all")
    args = parser.parse_args()
    READ_ONLY = bool(getattr(args, "dry_run", False))
    if args.command == "changes":
        items = ledger.changes(ROOT)
        if args.base:
            ledger.check_coverage(ROOT, args.base, args.no_release_impact)
        if args.sync_site:
            ledger.sync_site(ROOT)
        if args.check:
            ledger.sync_site(ROOT, check=True)
        if args.json:
            print(json.dumps(items, indent=2))
        else:
            for item in items:
                assignment = item["release"]
                label = f"{assignment['status']} {assignment['version']}" if assignment else "pending"
                print(f"{label:24} [{item['id']}] {item['text']}")
        return
    if args.wait_minutes <= 0:
        raise RuntimeError("--wait-minutes must be positive")
    # Read-only previews never create lock directories or restore/write evidence.
    if args.dry_run or args.action == "doctor":
        return dispatch(args)
    state = private_root()
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / "release.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another Teika release operation is running")
        return dispatch(args)


def dispatch(args):
    if args.action == "doctor": return doctor(args)
    if args.action == "prepare": return prepare(args)
    if args.action in ("publish", "upload", "submit"): return publish(args)
    if args.action in ("status", "abandon"): return status(args)
    if args.action == "website": return website(args)
    if args.action == "validate":
        if args.dry_run:
            print("Would run/reuse matching iOS + watchOS validation; excludes " + native_validation.EXCLUDED)
            return
        return native_validation.validate(ROOT, private_root(), fresh=args.fresh)
    if args.action == "screenshots":
        from screenshots import capture
        return capture(ROOT, select_version(args.version), args.family, args.dry_run)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, KeyError, ValueError) as error:
        print("Error: " + str(error), file=sys.stderr)
        sys.exit(1)
