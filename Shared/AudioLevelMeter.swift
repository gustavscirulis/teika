import Foundation

final class AudioLevelMeter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value: Float = 0

    func report(_ level: Float) {
        os_unfair_lock_lock(&lock)
        value = level
        os_unfair_lock_unlock(&lock)
    }

    func read() -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }

    func reset() {
        report(0)
    }
}
