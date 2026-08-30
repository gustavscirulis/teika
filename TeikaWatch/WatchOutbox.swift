import Foundation

/// A Watch recording owned by the app until WatchConnectivity confirms delivery.
struct WatchOutboxClip: Codable, Equatable {
    let clipID: String
    let duration: TimeInterval
    let recordedAt: Date

    static let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WatchClipOutbox", isDirectory: true)
    }()

    var audioURL: URL { audioURL(in: Self.directory) }
    var sidecarURL: URL { sidecarURL(in: Self.directory) }

    func audioURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(clipID).m4a")
    }

    func sidecarURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(clipID).json")
    }

    var metadata: [String: Any] {
        [
            ClipTransfer.Keys.clipID: clipID,
            ClipTransfer.Keys.duration: duration,
            ClipTransfer.Keys.recordedAt: recordedAt.timeIntervalSince1970,
        ]
    }

    static func adopt(
        _ recording: WatchRecorder.Recording, in directory: URL = Self.directory
    ) throws -> WatchOutboxClip {
        let clip = WatchOutboxClip(
            clipID: UUID().uuidString,
            duration: recording.duration,
            recordedAt: recording.recordedAt)
        let fm = FileManager.default
        try prepareDirectory(at: directory)
        let audioURL = clip.audioURL(in: directory)
        let sidecarURL = clip.sidecarURL(in: directory)
        try fm.moveItem(at: recording.url, to: audioURL)
        do {
            try JSONEncoder().encode(clip).write(to: sidecarURL, options: .atomic)
        } catch {
            try? fm.moveItem(at: audioURL, to: recording.url)
            throw error
        }
        return clip
    }

    static func restoreAll(in directory: URL = Self.directory) -> [WatchOutboxClip] {
        let fm = FileManager.default
        try? prepareDirectory(at: directory)
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let clip = try? JSONDecoder().decode(WatchOutboxClip.self, from: data),
                      fm.fileExists(atPath: clip.audioURL(in: directory).path)
                else {
                    try? fm.removeItem(at: url)
                    return nil
                }
                return clip
            }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    static func needingTransfer(
        _ clips: [WatchOutboxClip], outstandingIDs: Set<String>
    ) -> [WatchOutboxClip] {
        clips.filter { !outstandingIDs.contains($0.clipID) }
    }

    func discard(from directory: URL = Self.directory) {
        let fm = FileManager.default
        try? fm.removeItem(at: audioURL(in: directory))
        try? fm.removeItem(at: sidecarURL(in: directory))
    }

    private static func prepareDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)
    }
}
