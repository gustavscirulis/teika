"""Canonical change ledger and public release projection. Standard library only."""
import json
import re
import subprocess
from pathlib import Path

GROUPS = ("Added", "Changed", "Fixed", "Internal")
STATES = ("prepared", "submitted", "distributed", "abandoned")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def version_tuple(value):
    if not VERSION.fullmatch(value):
        raise RuntimeError("Version must be major.minor.patch")
    return tuple(map(int, value.split(".")))


def entries(root):
    result, seen, group = [], set(), None
    for line in (Path(root) / "changes.md").read_text().splitlines():
        if line.startswith("## "):
            if line[3:] not in GROUPS + ("Releases",):
                raise RuntimeError("Unknown change group: " + line[3:])
            group = line[3:] if line[3:] in GROUPS else None
        elif group and line.startswith("- "):
            match = re.fullmatch(r"- \[([a-z0-9]+(?:-[a-z0-9]+)*)\] (\S.*)", line)
            if not match:
                raise RuntimeError("Change entries need - [unique-kebab-id] Description.")
            identifier, text = match.groups()
            if identifier in seen:
                raise RuntimeError(f"Duplicate change ID: {identifier}")
            seen.add(identifier)
            result.append({"id": identifier, "group": group, "text": text})
    return result


def manifests(root):
    records = []
    for path in sorted((Path(root) / "releases").glob("*/release.json")):
        record = json.loads(path.read_text())
        version_tuple(record["version"])
        if path.parent.name != record["version"] or record["status"] not in STATES:
            raise RuntimeError(f"Invalid release identity/state: {path}")
        records.append(record)
    return records


def changes(root):
    ledger = entries(root)
    known = {entry["id"] for entry in ledger}
    assigned = {}
    for release in manifests(root):
        selected = set()
        for entry in release["changes"]:
            identifier = entry["id"]
            if identifier in selected or identifier not in known:
                raise RuntimeError(f"Duplicate/unknown release change: {identifier}")
            selected.add(identifier)
            if release["status"] != "abandoned":
                if identifier in assigned:
                    raise RuntimeError(f"Change assigned to multiple releases: {identifier}")
                assigned[identifier] = {"version": release["version"], "status": release["status"]}
    return [dict(entry, release=assigned.get(entry["id"])) for entry in ledger]


def pending(root):
    return [{k: v for k, v in entry.items() if k != "release"}
            for entry in changes(root) if entry["release"] is None]


def curated_notes(root, selected_ids):
    """Publish only authored benefits; several detailed changes can share one note."""
    path = Path(root) / "releases/upcoming.json"
    if not path.exists():
        return []
    known = {entry["id"]: entry for entry in entries(root)}
    seen, result = set(), []
    for note in json.loads(path.read_text())["notes"]:
        identifiers, text = note.get("changes"), note.get("text")
        if not isinstance(identifiers, list) or not identifiers or not all(isinstance(value, str) for value in identifiers):
            raise RuntimeError("Public summaries need related change IDs")
        if not isinstance(text, str) or not text.strip() or "\n" in text or len(text) > 4000:
            raise RuntimeError("Public summaries need concise, authored text")
        for identifier in identifiers:
            if identifier in seen or identifier not in known or known[identifier]["group"] == "Internal":
                raise RuntimeError("Duplicate, unknown or Internal public-summary change: " + identifier)
            seen.add(identifier)
        # A partial release needs its own wording; never publish a partly covered claim.
        if set(identifiers).issubset(selected_ids):
            result.append(text)
    if len(result) > 4:
        raise RuntimeError("Combine related public changes into at most four summaries")
    return result


def public_data(root):
    root = Path(root)
    records = []
    for release in sorted(manifests(root), key=lambda item: version_tuple(item["version"]), reverse=True):
        if release["status"] == "abandoned":
            continue
        notes = (root / "releases" / release["version"] / "en-US.txt").read_text()
        records.append({"version": release["version"], "date": release["date"],
                        "notes": [line[2:] for line in notes.splitlines() if line.startswith("• ")]})
    return {"releases": records, "pending": curated_notes(root, {entry["id"] for entry in pending(root)})}


def sync_site(root, check=False):
    path = Path(root) / "site/lib/releases.json"
    text = json.dumps(public_data(root), indent=2, ensure_ascii=False) + "\n"
    if check:
        if not path.exists() or path.read_text() != text:
            raise RuntimeError("Website release data is stale; run ./run.sh changes --sync-site")
    else:
        path.write_text(text)


def check_coverage(root, base, no_release_impact=False):
    """Require a ledger edit, or an explicit no-impact declaration, for meaningful PRs."""
    root = Path(root)
    files = subprocess.check_output(["git", "diff", "--name-only", base + "...HEAD"], cwd=root, text=True).splitlines()
    if not files or no_release_impact or "changes.md" in files:
        return
    record_only = all(path.startswith("releases/") or path in ("site/lib/releases.json", "project.yml") for path in files)
    if not record_only:
        raise RuntimeError("Meaningful changes need a changes.md entry in the same PR, or 'No release impact:' with an explanation in the PR description")
