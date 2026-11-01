import Foundation

enum TaskExportApp: String, CaseIterable {
    case off, reminders, things

    var title: String {
        switch self {
        case .off: "Off"
        case .things: "Things"
        case .reminders: "Apple Reminders"
        }
    }

    var receiptName: String { self == .reminders ? "Reminders" : "Things" }

    @MainActor static func selected(in defaults: UserDefaults) -> Self {
        if let raw = defaults.string(forKey: TaskExportCoordinator.appKey) {
            return Self(rawValue: raw) ?? .off
        }
        return defaults.bool(forKey: TaskExportCoordinator.enabledKey) ? .things : .off
    }
}

enum ReminderSchedule: String, CaseIterable {
    case noDate, today

    var title: String { self == .today ? "Today" : "No date" }

    func dateComponents(at date: Date, timeZone: TimeZone = .current) -> DateComponents? {
        guard self == .today else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.calendar = calendar
        components.timeZone = timeZone
        return components
    }
}

struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String

    func displayName(in lists: [Self]) -> String {
        lists.filter { $0.title == title }.count > 1 ? "\(title) (\(account))" : title
    }
}

enum RemindersAccess { case notDetermined, granted, denied, restricted }

struct ReminderExportRequest {
    let title: String
    let transcript: String
    let listID: String
    let dateComponents: DateComponents?
}

enum TaskExportFailure: String, Error {
    case remindersAccess, reminderListUnavailable, reminderSave
}
