import Foundation

/// Injectable boundary: host tests never request access to the user's reminders.
@MainActor
protocol RemindersDelivering {
    var access: RemindersAccess { get }
    func requestAccess() async throws -> Bool
    func lists() -> [ReminderList]
    func defaultListID() -> String?
    func save(_ request: ReminderExportRequest) throws -> String
}

@MainActor
struct UnavailableRemindersDelivery: RemindersDelivering {
    var access: RemindersAccess { .denied }
    func requestAccess() async throws -> Bool { false }
    func lists() -> [ReminderList] { [] }
    func defaultListID() -> String? { nil }
    func save(_ request: ReminderExportRequest) throws -> String {
        throw TaskExportFailure.remindersAccess
    }
}
