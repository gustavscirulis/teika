import Foundation
import Observation
import SwiftData

/// Owns delivery, while NoteStore atomically queues both phone and Watch inserts.
/// Success requires a correlated Things callback or a committed Reminders save.
@MainActor
@Observable
final class TaskExportCoordinator {
    static let enabledKey = "addsNewNotesToThings"
    static let destinationKey = "thingsExportDestination"
    static let appKey = "taskExportApp"
    static let reminderListKey = "reminderExportListID"
    static let reminderScheduleKey = "reminderExportSchedule"

    private(set) var app: TaskExportApp
    var isEnabled: Bool { app != .off }
    private(set) var destination: ThingsDestination
    private(set) var reminderSchedule: ReminderSchedule
    private(set) var reminderListID: String?
    private(set) var reminderLists: [ReminderList] = []
    private(set) var remindersAccess: RemindersAccess = .notDetermined
    private(set) var remindersSetupError: String?
    private(set) var isRequestingAccess = false
    private(set) var queue: [Note] = []
    private(set) var storageError: String?
    private(set) var successSerial = 0
    private(set) var successApp: TaskExportApp = .things
    var successMessage: String { "Added to \(successApp.receiptName)" }
    var showsSuccess = false

    private let store: NoteStore
    private let openURL: @MainActor (URL) async -> Bool
    private let isReady: @MainActor () -> Bool
    private let reminders: any RemindersDelivering
    private let now: () -> Date
    private var isActive = false
    private var canDispatch = false
    private var isOpening = false

    init(
        store: NoteStore,
        reminders: (any RemindersDelivering)? = nil,
        now: @escaping () -> Date = Date.init,
        isReady: @escaping @MainActor () -> Bool = { true },
        openURL: @escaping @MainActor (URL) async -> Bool
    ) {
        self.store = store
        self.openURL = openURL
        self.isReady = isReady
        self.reminders = reminders ?? UnavailableRemindersDelivery()
        self.now = now
        app = TaskExportApp.selected(in: store.defaults)
        destination = store.defaults.string(forKey: Self.destinationKey)
            .flatMap(ThingsDestination.init(rawValue:)) ?? .today
        reminderSchedule = store.defaults.string(forKey: Self.reminderScheduleKey)
            .flatMap(ReminderSchedule.init(rawValue:)) ?? .today
        reminderListID = store.defaults.string(forKey: Self.reminderListKey)
        store.onNoteSaved = { [weak self] in self?.refresh() }
        refreshReminders()
        refresh()
        // A terminated process may have lost the receipt after either app saved.
        recoverUnconfirmedDeliveries()
    }

    var pendingCount: Int { queue.count }

    var blockedNote: Note? {
        queue.first {
            !$0.isDeleted && $0.modelContext != nil && $0.exportState != .pending
        }
    }

    var needsAttention: Bool {
        storageError != nil || (blockedNote != nil && blockedNote?.exportState != .inFlight)
    }

    func setEnabled(_ enabled: Bool) {
        setApp(enabled ? (app == .off ? .things : app) : .off)
    }

    func setApp(_ app: TaskExportApp) {
        self.app = app
        store.defaults.set(app.rawValue, forKey: Self.appKey)
        store.defaults.set(app == .things, forKey: Self.enabledKey)
        refresh()
    }

    func setReminderList(_ id: String) {
        reminderListID = id.isEmpty ? nil : id
        store.defaults.set(reminderListID, forKey: Self.reminderListKey)
    }

    func setReminderSchedule(_ schedule: ReminderSchedule) {
        reminderSchedule = schedule
        store.defaults.set(schedule.rawValue, forKey: Self.reminderScheduleKey)
    }

    func refreshReminders() {
        remindersAccess = reminders.access
        reminderLists = remindersAccess == .granted ? reminders.lists() : []
        // Initialize once from the system default. Never replace an unavailable
        // user-selected list with another list silently.
        if reminderListID == nil, remindersAccess == .granted,
           let id = reminders.defaultListID(), reminderLists.contains(where: { $0.id == id }) {
            setReminderList(id)
        }
    }

    func requestRemindersAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        remindersSetupError = nil
        if reminders.access == .notDetermined {
            do { _ = try await reminders.requestAccess() }
            catch { remindersSetupError = "Couldn’t access Reminders. Try again." }
        }
        refreshReminders()
    }

    func setDestination(_ destination: ThingsDestination) {
        self.destination = destination
        store.defaults.set(destination.rawValue, forKey: Self.destinationKey)
    }

    func updateAvailability(isActive: Bool, canDispatch: Bool) {
        let returnedToForeground = isActive && !self.isActive
        self.isActive = isActive
        self.canDispatch = canDispatch
        if returnedToForeground {
            refreshReminders()
            recoverUnconfirmedDeliveries()
        }
        scheduleDelivery()
    }

    func refresh() {
        do {
            queue = try store.container.mainContext.fetch(
                FetchDescriptor<Note>(sortBy: [SortDescriptor(\Note.createdAt)]))
                .filter { note in
                    guard let state = note.exportState else { return false }
                    return state != .exported && state != .skipped
                }
            // A write error is cleared only by a successful write, not a fetch.
        } catch {
            storageError = "Couldn’t read the task export queue. Your notes are still in Teika."
        }
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        Task { [weak self] in
            // Let the save caller present/copy its transcript, and let a scene's
            // recording request settle before deciding whether to leave the app.
            await Task.yield()
            await self?.deliverNextIfPossible()
        }
    }

    func deliverNextIfPossible() async {
        guard isEnabled, isActive, canDispatch, isReady(), !isOpening, storageError == nil,
              blockedNote == nil, let note = queue.first,
              !note.isDeleted, note.modelContext != nil
        else { return }

        // Do not retain/read this model after the async handoff: it may be deleted.
        let operationID = UUID().uuidString
        let exportApp = note.exportApp
        let title = note.title
        let transcript = note.taskNotes
        let previousOperation = note.thingsOperationID
        note.thingsOperationID = operationID
        note.exportState = .inFlight
        note.taskExportFailureRaw = nil
        guard save() else {
            note.thingsOperationID = previousOperation
            note.exportState = .pending
            return
        }

        isOpening = true
        if exportApp == .reminders {
            deliverReminder(title: title, transcript: transcript, operationID: operationID)
            isOpening = false
            refresh()
            return
        }
        let url = ThingsExportURL.add(
            title: title, transcript: transcript, operationID: operationID,
            destination: destination)
        let opened = await openURL(url)
        isOpening = false
        // A callback can arrive before UIKit's completion handler. Never overwrite it.
        if !opened, let current = find(operationID: operationID),
           current.exportState == .inFlight {
            current.exportState = .failed
            _ = save()
        }
        refresh()
    }

    private func deliverReminder(title: String, transcript: String, operationID: String) {
        do {
            refreshReminders()
            guard remindersAccess == .granted else { throw TaskExportFailure.remindersAccess }
            guard let listID = reminderListID, reminderLists.contains(where: { $0.id == listID })
            else { throw TaskExportFailure.reminderListUnavailable }
            let receipt = try reminders.save(ReminderExportRequest(
                title: title, transcript: transcript, listID: listID,
                dateComponents: reminderSchedule.dateComponents(at: now())))
            guard let note = find(operationID: operationID) else { return }
            guard !receipt.isEmpty else {
                note.exportState = .unconfirmed
                _ = save()
                return
            }
            note.reminderID = receipt
            note.exportState = .exported
            if save() { confirmSuccess(for: .reminders) }
        } catch {
            guard let note = find(operationID: operationID) else { return }
            note.exportState = .failed
            note.taskExportFailureRaw = (error as? TaskExportFailure ?? .reminderSave).rawValue
            _ = save()
        }
    }

    private func confirmSuccess(for app: TaskExportApp) {
        successApp = app
        successSerial += 1
        showsSuccess = true
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let callback = ThingsExportURL.Callback(url: url),
              let note = find(operationID: callback.operationID),
              note.exportApp == .things,
              note.exportState == .inFlight || note.exportState == .unconfirmed
        else { return false }

        switch callback.result {
        case "success":
            note.thingsTaskID = callback.taskID
            note.exportState = .exported
        case "cancel": note.exportState = .cancelled
        default: note.exportState = .failed
        }
        let saved = save()
        if saved, callback.result == "success" {
            confirmSuccess(for: .things)
        }
        refresh()
        return true
    }

    func retry(_ note: Note) {
        guard !note.isDeleted, note.modelContext != nil,
              [.failed, .cancelled, .unconfirmed].contains(note.exportState)
        else { return }
        note.exportState = .pending
        note.thingsOperationID = nil
        guard save() else { return }
        refresh()
    }

    func skip(_ note: Note) {
        guard !note.isDeleted, note.modelContext != nil else { return }
        note.exportState = .skipped
        guard save() else { return }
        refresh()
    }

    func retryStorage() {
        guard save() else { return }
        refresh()
    }

    private func recoverUnconfirmedDeliveries() {
        let unfinished = queue.filter { $0.exportState == .inFlight }
        guard !unfinished.isEmpty else { return }
        for note in unfinished { note.exportState = .unconfirmed }
        _ = save()
        // Preserve operation IDs so a late success can still resolve uncertainty.
    }

    private func find(operationID: String) -> Note? {
        do {
            return try store.container.mainContext.fetch(FetchDescriptor<Note>(
                predicate: #Predicate { $0.thingsOperationID == operationID })).first
        } catch {
            storageError = "Couldn’t read the task export queue. Your notes are still in Teika."
            return nil
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try store.container.mainContext.save()
            storageError = nil
            return true
        } catch {
            storageError = "Couldn’t save the task delivery status. Automatic export is paused."
            return false
        }
    }
}
