"""Exercise run.sh selection without building or touching real devices."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RunDestinationsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shutil.copy2(Path(__file__).resolve().parents[1] / "run.sh", self.root / "run.sh")
        (self.root / ".run-last-destination").write_text("phone-1")
        (self.root / "Teika.txt").write_text("""
Available destinations for the "Teika" scheme:
    { platform:iOS, id:placeholder, name:Any iOS Device }
    { platform:iOS, arch:arm64e, id:phone-1, name:Test iPhone }
    { platform:iOS Simulator, arch:arm64, id:sim-1, OS:26.5, name:Test iPhone Simulator }
Ineligible destinations for the "Teika" scheme:
    { platform:iOS, id:unavailable-phone, name:Unavailable Phone, error:Device unavailable }
""")
        (self.root / "TeikaWatch.txt").write_text("""
Destinations compatible with the "TeikaWatch" scheme:
    { platform:watchOS, id:placeholder, name:Any watchOS Device }
    { platform:watchOS Simulator, arch:arm64, id:watch-1, OS:26.5, name:Test Apple Watch }
Destinations incompatible with the "TeikaWatch" scheme:
    { platform:macOS, arch:arm64e, id:mac-1, name:My Mac, error:Platform mismatch }
    { platform:iOS, arch:arm64e, id:phone-1, name:Test iPhone, error:Platform mismatch }
    { platform:iOS Simulator, arch:arm64, id:sim-1, OS:26.5, name:Test iPhone Simulator, error:Platform mismatch }
""")
        self.mock("xcodegen", """
from pathlib import Path
Path('Teika.xcodeproj').mkdir(exist_ok=True)
Path('Teika.xcodeproj/project.pbxproj').write_text('SWIFT_ACTIVE_COMPILATION_CONDITIONS')
""")
        self.mock("xcodebuild", """
import json
from pathlib import Path
import sys
args = sys.argv[1:]
scheme = args[args.index('-scheme') + 1]
if '-showdestinations' in args:
    print(Path(f'{scheme}.txt').read_text())
else:
    Path('build-args.json').write_text(json.dumps(args))
    products = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products'
    for sdk in ['iphoneos', 'iphonesimulator', 'watchos', 'watchsimulator']:
        (products / f'Debug-{sdk}' / f'{scheme}.app').mkdir(parents=True, exist_ok=True)
""")
        self.mock("xcrun", """
import json
import sys
with open('launch-args.jsonl', 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
""")
        self.mock("open", "")
        # Close inherited pipes so a cancelled watchdog cannot hold up the test.
        self.mock("sleep", "import os, time\nos.close(1)\nos.close(2)\ntime.sleep(2)")
        (self.bin / "xcbeautify").write_text("#!/bin/sh\ncat\n")
        (self.bin / "xcbeautify").chmod(0o755)

    def mock(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{shutil.which('python3')}\n{source}")
        path.chmod(0o755)

    def run_app(self, *arguments):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   TEIKA_DEVELOPMENT_TEAM="TESTTEAM")
        return subprocess.run(
            ["bash", str(self.root / "run.sh"), "app", *arguments],
            env=env, capture_output=True, text=True, timeout=15,
        )

    def assert_selected(self, query, scheme, destination, bundle):
        result = self.run_app(*([query] if query else []))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = json.loads((self.root / "build-args.json").read_text())
        self.assertEqual(args[args.index("-scheme") + 1], scheme)
        self.assertEqual(args[args.index("-destination") + 1], f"id={destination}")
        self.assertIn(bundle, (self.root / "launch-args.jsonl").read_text())

    def test_remembered_phone_uses_ios_scheme(self):
        self.assert_selected(None, "Teika", "phone-1", "com.gustavscirulis.teika")

    def test_explicit_phone_uses_ios_scheme(self):
        self.assert_selected("phone-1", "Teika", "phone-1", "com.gustavscirulis.teika")

    def test_watch_simulator_uses_watch_scheme(self):
        self.assert_selected("watch-1", "TeikaWatch", "watch-1", "com.gustavscirulis.teika.watchkitapp")

    def test_unavailable_destination_is_rejected_before_building(self):
        result = self.run_app("unavailable-phone")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No destination matched", result.stderr)
        self.assertFalse((self.root / "build-args.json").exists())


if __name__ == "__main__":
    unittest.main()
