"""Native validation with durable, content-matched xcresult evidence."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

EXCLUDED = "TeikaUITests/SetupConsentUITests/testAffirmativeActionStartsModelDownload"


def run(args, root, **kwargs):
    return subprocess.run(args, cwd=root, check=True, text=True, **kwargs)


def fingerprint(root, include_resolution=True):
    root = Path(root)
    digest = hashlib.sha256()
    for directory in ("teika", "Shared", "TeikaWatch", "TeikaWidget", "TeikaWatchWidget",
                      "TeikaTests", "TeikaUITests", "TeikaWatchTests"):
        for path in sorted((root / directory).rglob("*")):
            if path.is_file():
                digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
    spec = (root / "project.yml").read_text()
    spec = re.sub(r'MARKETING_VERSION: "[^"]+"', 'MARKETING_VERSION: "NORMALIZED"', spec)
    spec = re.sub(r"CURRENT_PROJECT_VERSION: \d+", "CURRENT_PROJECT_VERSION: NORMALIZED", spec)
    digest.update(spec.encode())
    resolved = root / "Teika.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if include_resolution:
        digest.update(resolved.read_bytes() if resolved.exists() else b"UNRESOLVED")
    digest.update(Path(__file__).read_bytes())
    digest.update(subprocess.check_output(["xcodebuild", "-version"], cwd=root))
    digest.update(EXCLUDED.encode())
    return digest.hexdigest()


def destination(root, platform):
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], cwd=root))
    for runtime, values in sorted(devices["devices"].items(), reverse=True):
        if platform not in runtime:
            continue
        candidates = [device for device in values if device.get("isAvailable")]
        candidates.sort(key=lambda device: (device.get("state") != "Booted", device["name"]))
        if candidates:
            return candidates[0]["udid"]
    raise RuntimeError(f"No available {platform} simulator; install a compatible runtime in Xcode")


def counts(summary):
    passed, failed, skipped = (summary.get(key) for key in ("passedTests", "failedTests", "skippedTests"))
    if not all(isinstance(value, int) for value in (passed, failed, skipped)):
        raise RuntimeError("xcresult summary has no trustworthy test counts")
    if passed <= 0 or failed != 0 or skipped != 0:
        raise RuntimeError(f"Native validation did not pass: {passed} passed, {failed} failed, {skipped} skipped")
    return {"passed": passed, "failed": failed, "skipped": skipped}


def validate(root, state, fresh=False):
    root, state = Path(root), Path(state)
    run(["xcodegen", "generate"], root)
    logs = state / "validation"
    logs.mkdir(parents=True, exist_ok=True)
    with (logs / "resolve.log").open("w") as output:
        run(["xcodebuild", "-resolvePackageDependencies", "-project", "Teika.xcodeproj", "-scheme", "Teika"],
            root, stdout=output, stderr=subprocess.STDOUT)
    identity = fingerprint(root)
    evidence = logs / (identity + ".json")
    previous = json.loads(evidence.read_text()) if evidence.exists() else {}
    if not fresh and previous.get("status") == "passed":
        for suite in ("Teika", "TeikaWatch"):
            counts({"passedTests": previous["suites"][suite]["passed"], "failedTests": previous["suites"][suite]["failed"],
                    "skippedTests": previous["suites"][suite]["skipped"]})
        print("Reusing matching native validation " + identity[:12], flush=True)
        return previous
    attempt = logs / (identity[:12] + "-" + str(time.time_ns()))
    attempt.mkdir()
    record = {"fingerprint": identity, "status": "running", "suites": {}, "excluded": [EXCLUDED]}
    evidence.write_text(json.dumps(record, indent=2) + "\n")
    try:
        for scheme, platform in (("Teika", "iOS"), ("TeikaWatch", "watchOS")):
            result = attempt / (scheme + ".xcresult")
            command = ["xcodebuild", "test", "-project", "Teika.xcodeproj", "-scheme", scheme,
                       "-destination", "id=" + destination(root, platform), "-resultBundlePath", str(result),
                       "-derivedDataPath", str(root / "DerivedData"), "-disableAutomaticPackageResolution"]
            if scheme == "Teika":
                command += ["-skip-testing:" + EXCLUDED]
            print("Validating " + scheme + "; log: " + str(attempt / (scheme + ".log")), flush=True)
            with (attempt / (scheme + ".log")).open("w") as output:
                run(command, root, stdout=output, stderr=subprocess.STDOUT)
            summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], cwd=root))
            record["suites"][scheme] = dict(counts(summary), result=str(result))
        if fingerprint(root) != identity:
            raise RuntimeError("Native inputs changed during validation")
        record["status"] = "passed"
    except BaseException:
        record["status"] = "failed-or-incomplete"
        raise
    finally:
        evidence.write_text(json.dumps(record, indent=2) + "\n")
    return record
