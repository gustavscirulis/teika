"""Capture release screenshots on dedicated simulators; no personal device data."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time

# Apple's supported portrait sizes for these display classes. Never resize captures.
SIZES = {
    "APP_IPHONE_69": {(1320, 2868), (1290, 2796), (1260, 2736)},
    "APP_IPAD_PRO_3GEN_129": {(2048, 2732), (2064, 2752)},
    "APP_WATCH_SERIES_7": {(396, 484)},
}
FAMILIES = {
    "iphone": ("iOS", ["iPhone 17 Pro Max", "iPhone 16 Pro Max"], "Teika", "APP_IPHONE_69", ["recording", "transcript", "notes", "settings"]),
    "ipad": ("iOS", ["iPad Pro 13-inch (M5)", "iPad Pro 13-inch (M4)", "iPad Pro (12.9-inch) (6th generation)"], "Teika", "APP_IPAD_PRO_3GEN_129", ["transcript", "notes", "settings"]),
    "watch": ("watchOS", ["Apple Watch Series 9 (45mm)"], "TeikaWatch", "APP_WATCH_SERIES_7", ["recording", "queued"]),
}


def create_simulator(available, family):
    platform, preferred, _, _, _ = FAMILIES[family]
    runtimes = sorted(
        [item for item in available["runtimes"] if item.get("isAvailable") and platform in item["identifier"]],
        key=lambda item: tuple(map(int, item["version"].split("."))), reverse=True)
    device_types = [item for label in preferred for item in available["devicetypes"] if item["name"] == label]
    for runtime in runtimes:
        for device_type in device_types:
            result = subprocess.run(
                ["xcrun", "simctl", "create", "Teika release " + family,
                 device_type["identifier"], runtime["identifier"]],
                capture_output=True, text=True)
            if result.returncode == 0:
                udid = result.stdout.strip()
                if not udid:
                    raise RuntimeError("Simulator creation returned no device identifier")
                print(f"Capturing {device_type['name']} on {runtime['version']}", flush=True)
                return udid
            if result.returncode == 147 and "domain=com.apple.CoreSimulator.SimError, code=403" in result.stderr:
                print(f"Skipping incompatible {device_type['name']} / {runtime['version']}", flush=True)
                continue
            raise RuntimeError("Simulator creation failed: " + (result.stderr.strip() or str(result.returncode)))
    raise RuntimeError(f"No compatible {family} simulator/runtime pair is installed; see scripts/screenshots.py device choices")


def validate_png(path, display):
    data = Path(path).read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise RuntimeError("Invalid screenshot PNG: " + str(path))
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) not in SIZES.get(display, set()):
        raise RuntimeError(f"Unsupported {display} screenshot dimensions: {width}x{height}")
    # App Store assets must not have an alpha channel or a transparency chunk.
    if data[25] not in (0, 2):
        raise RuntimeError("Screenshot must be an opaque RGB or grayscale PNG: " + str(path))
    offset, ended = 8, False
    while offset + 12 <= len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if offset + size + 12 > len(data):
            raise RuntimeError("Truncated screenshot PNG: " + str(path))
        if kind == b"tRNS":
            raise RuntimeError("Screenshot must not contain transparency: " + str(path))
        offset += size + 12
        if kind == b"IEND":
            ended = True
            break
    if not ended:
        raise RuntimeError("Incomplete screenshot PNG: " + str(path))
    return width, height


def capture(root, version, family, dry_run=False):
    from release import logged, run, write_json, release_path
    directory = release_path(version)
    if not (directory / "release.json").exists():
        raise RuntimeError("Prepare the release before capturing screenshots")
    families = list(FAMILIES) if family == "all" else [family]
    if dry_run:
        print(json.dumps({name: {"display": FAMILIES[name][3], "scenes": FAMILIES[name][4]} for name in families}, indent=2))
        return
    run(["xcodegen", "generate"])
    available = json.loads(run(["xcrun", "simctl", "list", "-j"], capture=True))
    plan_path = directory / "screenshots.json"
    plan = json.loads(plan_path.read_text())
    plan.update(mode="refresh", reviewed=False, reason="Capture current UI; inspect every file before setting reviewed to true")
    output = directory / "screenshots"
    output.mkdir(exist_ok=True)
    for name in families:
        platform, _, scheme, display, scenes = FAMILIES[name]
        udid = create_simulator(available, name)
        try:
            run(["xcrun", "simctl", "boot", udid])
            run(["xcrun", "simctl", "bootstatus", udid, "-b"])
            # Hide variable carrier/battery/time in iOS captures.
            if platform == "iOS":
                run(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100"])
            logged(["xcodebuild", "-project", "Teika.xcodeproj", "-scheme", scheme, "-configuration", "Debug",
                    "-destination", "id=" + udid, "-derivedDataPath", root / "DerivedData", "build"], output / (name + "-build.log"))
            sdk = "watchsimulator" if name == "watch" else "iphonesimulator"
            app = root / "DerivedData/Build/Products" / ("Debug-" + sdk) / (scheme + ".app")
            bundle = "com.gustavscirulis.teika" + (".watchkitapp" if name == "watch" else "")
            run(["xcrun", "simctl", "install", udid, app])
            files = []
            for scene in scenes:
                subprocess.run(["xcrun", "simctl", "terminate", udid, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                run(["xcrun", "simctl", "launch", udid, bundle, "-teika-release-screenshot", scene])
                time.sleep(3)
                path = output / (name + "-" + scene + ".png")
                run(["xcrun", "simctl", "io", udid, "screenshot", path])
                validate_png(path, display)
                files.append({"path": str(path.relative_to(directory)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
            plan["sets"] = [item for item in plan.get("sets", []) if item["display"] != display] + [{"display": display, "files": files}]
            write_json(plan_path, plan)
        finally:
            subprocess.run(["xcrun", "simctl", "shutdown", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["xcrun", "simctl", "delete", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("Inspect every captured image, then set reviewed to true in " + str(plan_path))
