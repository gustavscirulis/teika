import UIKit

@MainActor
enum Haptics {
    private static let start = UIImpactFeedbackGenerator(style: .medium)
    private static let end = UIImpactFeedbackGenerator(style: .rigid)

    static func recordingStarted() {
        start.prepare()
        start.impactOccurred()
    }

    static func recordingEnded() {
        end.impactOccurred()
    }
}
