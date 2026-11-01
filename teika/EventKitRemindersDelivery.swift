import EventKit
import Foundation

@MainActor
final class EventKitRemindersDelivery: RemindersDelivering {
    private let store = EKEventStore()

    var access: RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    func lists() -> [ReminderList] {
        guard access == .granted else { return [] }
        return store.calendars(for: .reminder)
            .filter { $0.allowsContentModifications }
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func defaultListID() -> String? {
        guard access == .granted,
              let calendar = store.defaultCalendarForNewReminders(),
              calendar.allowsContentModifications else { return nil }
        return calendar.calendarIdentifier
    }

    func save(_ request: ReminderExportRequest) throws -> String {
        guard access == .granted else { throw TaskExportFailure.remindersAccess }
        guard let calendar = store.calendar(withIdentifier: request.listID),
              calendar.allowsContentModifications,
              calendar.allowedEntityTypes.contains(.reminder)
        else { throw TaskExportFailure.reminderListUnavailable }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = request.title
        reminder.notes = request.transcript.isEmpty ? nil : request.transcript
        reminder.startDateComponents = request.dateComponents
        reminder.dueDateComponents = request.dateComponents
        // Do not attach an alarm; the user's Reminders notification preferences apply.
        do { try store.save(reminder, commit: true) }
        catch { throw TaskExportFailure.reminderSave }
        return reminder.calendarItemIdentifier
    }
}
