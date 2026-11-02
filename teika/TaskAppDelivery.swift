import UIKit

/// Keep the external app effect outside the queue so delivery can be tested
/// without launching Things or needing a running iOS scene.
extension TaskExportCoordinator {
    convenience init(store: NoteStore, isReady: @escaping @MainActor () -> Bool = { true }) {
        #if DEBUG
        if AppStoreScreenshotContent.launchScene != nil {
            self.init(store: store, reminders: ScreenshotRemindersDelivery(), isReady: { false }, openURL: { _ in false })
            return
        }
        #endif
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

#if DEBUG
/// Presentation-only data; capture never reads reminders, requests permission, or saves tasks.
@MainActor
private struct ScreenshotRemindersDelivery: RemindersDelivering {
    var access: RemindersAccess { .granted }
    func requestAccess() async throws -> Bool { true }
    func lists() -> [ReminderList] {
        [ReminderList(id: "screenshot-reminders", title: "Reminders", account: "Sample")]
    }
    func defaultListID() -> String? { "screenshot-reminders" }
    func save(_ request: ReminderExportRequest) throws -> String { throw TaskExportFailure.reminderSave }
}
#endif
