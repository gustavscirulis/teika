#!/bin/bash
# Exercise the actual SwiftData/export sources on macOS, without an iOS simulator.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp/}teika-things-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/Sources/Teika" "$test_dir/Tests/TeikaTests"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ThingsValidation",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Teika"),
        .testTarget(name: "TeikaTests", dependencies: ["Teika"]),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
for source in Note NoteStore TaskExportCoordinator ThingsExportURL TaskExportTypes RemindersDelivery; do
    cp "$task_root/teika/$source.swift" "$test_dir/Sources/Teika/"
done
cp "$task_root/Shared/TeikaURL.swift" "$test_dir/Sources/Teika/"
for test in ThingsExportTests RemindersExportTests NoteEditingTests WatchNoteIdempotencyTests; do
    cp "$task_root/TeikaTests/$test.swift" "$test_dir/Tests/TeikaTests/"
done
swift test --package-path "$test_dir" --disable-sandbox
