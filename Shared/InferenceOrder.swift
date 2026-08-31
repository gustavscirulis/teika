import Foundation

/// Pure ordering policy for the speech inference slot. Payload ownership stays with the
/// caller; this type only makes local-next priority and Watch FIFO deterministic.
nonisolated struct InferenceOrder<ID: Hashable> {
    private(set) var active: ID?
    private var local: ID?
    private var watch: [ID] = []

    mutating func enqueueLocal(_ id: ID) {
        local = id
    }

    mutating func enqueueWatch(_ id: ID) {
        watch.append(id)
    }

    mutating func startNext() -> ID? {
        guard active == nil else { return nil }
        let next: ID?
        if let local {
            next = local
            self.local = nil
        } else if !watch.isEmpty {
            next = watch.removeFirst()
        } else {
            next = nil
        }
        active = next
        return next
    }

    mutating func cancelQueuedLocal(_ id: ID) {
        if local == id { local = nil }
    }

    mutating func finish(_ id: ID) {
        if active == id { active = nil }
    }
}
