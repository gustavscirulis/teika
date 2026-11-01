import UIKit

/// Keep the external app effect outside the queue so delivery can be tested
/// without launching Things or needing a running iOS scene.
extension TaskExportCoordinator {
    convenience init(store: NoteStore, isReady: @escaping @MainActor () -> Bool = { true }) {
        self.init(store: store, reminders: EventKitRemindersDelivery(), isReady: {
            UIApplication.shared.applicationState == .active && isReady()
        }) { url in
            guard UIApplication.shared.canOpenURL(url) else { return false }
            return await withCheckedContinuation { continuation in
                UIApplication.shared.open(url, options: [:]) { opened in
                    continuation.resume(returning: opened)
                }
            }
        }
    }
}
