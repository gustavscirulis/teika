import Foundation
import SwiftData
import XCTest
@testable import Teika

@MainActor
private final class FakeRemindersDelivery: RemindersDelivering {
    var access: RemindersAccess = .granted
    var availableLists = [
        ReminderList(id: "personal", title: "Reminders", account: "iCloud"),
        ReminderList(id: "work", title: "Work", account: "Work account"),
    ]
    var defaultID: String? = "personal"
    var grantsAccess = true
    var accessRequests = 0
    var requests: [ReminderExportRequest] = []
    var failure: TaskExportFailure?
    var receipt = "reminder-receipt"
    var beforeSave: (() -> Void)?

    func requestAccess() async throws -> Bool {
        accessRequests += 1
        access = grantsAccess ? .granted : .denied
        return grantsAccess
    }
    func lists() -> [ReminderList] { availableLists }
    func defaultListID() -> String? { defaultID }
    func save(_ request: ReminderExportRequest) throws -> String {
        beforeSave?()
        if let failure { throw failure }
        requests.append(request)
        return receipt
    }
}

@MainActor
final class RemindersExportTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func makeStore(url: URL? = nil) throws -> NoteStore {
        let suite = "Teika.RemindersTests.\(UUID().uuidString)"
        suites.append(suite)
        return try NoteStore(inMemory: url == nil, defaults: UserDefaults(suiteName: suite)!, storeURL: url)
    }

    private func makeExporter(_ store: NoteStore, _ reminders: FakeRemindersDelivery) -> TaskExportCoordinator {
        TaskExportCoordinator(store: store, reminders: reminders, openURL: { _ in
            XCTFail("Reminders must not launch an external app")
            return false
        })
    }

    private func callback(_ note: Note) -> URL {
        URL(string: "teika://things-export?operation=\(note.thingsOperationID!)&result=success&x-things-id=things-receipt")!
    }

    func testExistingPreferencesAndIndependentAppOptionsArePreserved() throws {
        let store = try makeStore()
        store.defaults.set(true, forKey: TaskExportCoordinator.enabledKey)
        store.defaults.set("inbox", forKey: TaskExportCoordinator.destinationKey)
        let reminders = FakeRemindersDelivery()
        let exporter = makeExporter(store, reminders)
        XCTAssertEqual(exporter.app, .things)
        XCTAssertEqual(exporter.destination, .inbox)
        exporter.setApp(.reminders)
        exporter.setReminderList("work")
        exporter.setReminderSchedule(.noDate)
        exporter.setApp(.off)
        let restored = makeExporter(store, reminders)
        XCTAssertEqual(restored.app, .off)
        restored.setApp(.things)
        XCTAssertEqual(restored.destination, .inbox)
        restored.setApp(.reminders)
        XCTAssertEqual(restored.reminderListID, "work")
        XCTAssertEqual(restored.reminderSchedule, .noDate)
    }

    func testFreshInstallIsOffAndNeverQueuesOldNotes() throws {
        let store = try makeStore()
        let exporter = makeExporter(store, FakeRemindersDelivery())
        XCTAssertEqual(exporter.app, .off)
        let old = try store.add(text: "Before enabling")
        exporter.setApp(.reminders)
        let new = try store.add(text: "After enabling")
        XCTAssertNil(old.exportState)
        XCTAssertNil(old.taskExportAppRaw)
        XCTAssertEqual(new.exportApp, .reminders)
        XCTAssertEqual(new.exportState, .pending)
        XCTAssertEqual(exporter.pendingCount, 1)
    }

    func testSwitchingAppsKeepsPendingPhoneAndWatchNotesWithOriginalApp() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        var urls: [URL] = []
        let exporter = TaskExportCoordinator(store: store, reminders: reminders, openURL: { urls.append($0); return true })
        exporter.setApp(.things)
        let things = try store.add(text: "Things first", createdAt: Date(timeIntervalSince1970: 1))
        exporter.setApp(.reminders)
        let watch = try store.addWatchNote(text: "Watch second", createdAt: Date(timeIntervalSince1970: 2), clipID: "switch-watch")
        exporter.setApp(.things)
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(reminders.requests.isEmpty)
        XCTAssertEqual(watch.note.exportApp, .reminders)
        exporter.setApp(.reminders)
        XCTAssertTrue(exporter.handle(callback(things)))
        exporter.setApp(.things)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(reminders.requests.count, 1)
        XCTAssertEqual(watch.note.reminderID, "reminder-receipt")
        XCTAssertEqual(exporter.successMessage, "Added to Reminders")
        XCTAssertEqual(exporter.pendingCount, 0)
    }

    func testReminderSaveGetsFullTranscriptAndPersistsInFlightBeforeCommit() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        let text = "Buy milk\n" + String(repeating: "😀", count: 12_000)
        let note = try store.add(text: text)
        reminders.beforeSave = {
            let fresh = ModelContext(store.container)
            let persisted = try! fresh.fetch(FetchDescriptor<Note>()).first!
            XCTAssertEqual(persisted.exportState, .inFlight)
            XCTAssertEqual(persisted.exportApp, .reminders)
            XCTAssertNotNil(persisted.thingsOperationID)
            XCTAssertFalse(exporter.showsSuccess)
        }
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        let request = try XCTUnwrap(reminders.requests.first)
        XCTAssertEqual(request.title, "Buy milk")
        XCTAssertEqual(request.transcript, String(repeating: "😀", count: 12_000))
        XCTAssertEqual(request.listID, "personal")
        XCTAssertEqual(note.exportState, .exported)
        XCTAssertEqual(note.reminderID, "reminder-receipt")
        XCTAssertNil(note.thingsTaskID)
        XCTAssertEqual(exporter.successSerial, 1)
    }

    func testTaskNotesOnlyRepeatTitleWhenItWasTruncated() async throws {
        let boundary = String(repeating: "é", count: 60)
        let long = boundary + "!"
        for (text, expectedNotes) in [
            ("Buy milk", ""),
            ("  Buy milk  ", ""),
            (boundary, ""),
            (long, long),
            ("Buy milk\nBring the reusable bag.", "Bring the reusable bag."),
            (long + "\nExtra detail", long + "\nExtra detail"),
        ] {
            let store = try makeStore()
            let reminders = FakeRemindersDelivery()
            let exporter = makeExporter(store, reminders)
            exporter.setApp(.reminders)
            let note = try store.add(text: text)
            exporter.updateAvailability(isActive: true, canDispatch: true)
            await exporter.deliverNextIfPossible()
            let request = try XCTUnwrap(reminders.requests.first)
            XCTAssertEqual(request.title, note.title)
            XCTAssertEqual(request.transcript, expectedNotes)
            XCTAssertEqual(note.text, text)
        }
    }

    func testScheduleAndListChangesApplyToWaitingNotes() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        let date = Date(timeIntervalSince1970: 1_730_590_200)
        let exporter = TaskExportCoordinator(store: store, reminders: reminders, now: { date }, openURL: { _ in false })
        exporter.setApp(.reminders)
        XCTAssertEqual(exporter.reminderSchedule, .today)
        _ = try store.add(text: "Today")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        let today = try XCTUnwrap(reminders.requests.first?.dateComponents)
        XCTAssertEqual(today, ReminderSchedule.today.dateComponents(at: date))
        XCTAssertEqual(today.calendar?.identifier, .gregorian)
        XCTAssertNil(today.hour)
        XCTAssertNil(today.minute)
        XCTAssertNil(today.second)
        _ = try store.add(text: "No date")
        exporter.setReminderList("work")
        exporter.setReminderSchedule(.noDate)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(reminders.requests.count, 2)
        XCTAssertEqual(reminders.requests.last?.listID, "work")
        XCTAssertNil(reminders.requests.last?.dateComponents)
    }

    func testTodayUsesLocalCalendarDateAcrossDateAndYearBoundaries() throws {
        let date = ISO8601DateFormatter().date(from: "2026-12-31T23:30:00Z")!
        let east = try XCTUnwrap(ReminderSchedule.today.dateComponents(at: date, timeZone: TimeZone(secondsFromGMT: 7_200)!))
        XCTAssertEqual(east.year, 2027)
        XCTAssertEqual(east.month, 1)
        XCTAssertEqual(east.day, 1)
        let west = try XCTUnwrap(ReminderSchedule.today.dateComponents(at: date, timeZone: TimeZone(secondsFromGMT: -18_000)!))
        XCTAssertEqual(west.year, 2026)
        XCTAssertEqual(west.month, 12)
        XCTAssertEqual(west.day, 31)
        XCTAssertNil(ReminderSchedule.noDate.dateComponents(at: date))
    }

    func testPermissionIsRequestedExplicitlyOnceAndDenialRetainsNotes() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        reminders.access = .notDetermined
        reminders.grantsAccess = false
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        let note = try store.add(text: "Keep locally")
        XCTAssertEqual(reminders.accessRequests, 0)
        await exporter.requestRemindersAccess()
        await exporter.requestRemindersAccess()
        XCTAssertEqual(reminders.accessRequests, 1)
        XCTAssertEqual(exporter.remindersAccess, .denied)
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(note.exportState, .failed)
        XCTAssertEqual(note.taskExportFailureRaw, TaskExportFailure.remindersAccess.rawValue)
        XCTAssertTrue(exporter.needsAttention)
        XCTAssertEqual(note.text, "Keep locally")
        XCTAssertFalse(exporter.showsSuccess)
        reminders.access = .granted
        exporter.refreshReminders()
        await exporter.deliverNextIfPossible()
        XCTAssertTrue(reminders.requests.isEmpty)
        exporter.retry(note)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(note.exportState, .exported)
    }

    func testGrantingFirstUsePermissionLoadsTheDefaultListWithoutPromptingAgain() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        reminders.access = .notDetermined
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        XCTAssertNil(exporter.reminderListID)
        XCTAssertTrue(exporter.reminderLists.isEmpty)
        await exporter.requestRemindersAccess()
        XCTAssertEqual(exporter.remindersAccess, .granted)
        XCTAssertEqual(exporter.reminderListID, "personal")
        XCTAssertEqual(exporter.reminderLists.count, 2)
        await exporter.requestRemindersAccess()
        XCTAssertEqual(reminders.accessRequests, 1)
    }

    func testRevokedAccessAndRestrictedAccessBlockUntilRetry() async throws {
        for access in [RemindersAccess.denied, .restricted] {
            let store = try makeStore()
            let reminders = FakeRemindersDelivery()
            let exporter = makeExporter(store, reminders)
            exporter.setApp(.reminders)
            let note = try store.add(text: "Access revoked")
            reminders.access = access
            exporter.updateAvailability(isActive: true, canDispatch: true)
            await exporter.deliverNextIfPossible()
            XCTAssertEqual(note.exportState, .failed)
            XCTAssertTrue(reminders.requests.isEmpty)
            XCTAssertEqual(exporter.remindersAccess, access)
        }
    }

    func testMissingOrReadOnlyListIsNotSilentlyReplaced() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        exporter.setReminderList("work")
        let note = try store.add(text: "Work list")
        // The adapter omits deleted and read-only lists from its writable lists.
        reminders.availableLists.removeAll { $0.id == "work" }
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(exporter.reminderListID, "work")
        XCTAssertEqual(note.taskExportFailureRaw, TaskExportFailure.reminderListUnavailable.rawValue)
        XCTAssertTrue(reminders.requests.isEmpty)
        exporter.setReminderList("personal")
        exporter.retry(note)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(reminders.requests.last?.listID, "personal")
        XCTAssertEqual(note.exportState, .exported)
    }

    func testNoDefaultListRequiresSelectionRatherThanPickingFirstList() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        reminders.defaultID = nil
        let exporter = makeExporter(store, reminders)
        XCTAssertNil(exporter.reminderListID)
        exporter.setApp(.reminders)
        let note = try store.add(text: "Choose first")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(note.taskExportFailureRaw, TaskExportFailure.reminderListUnavailable.rawValue)
        XCTAssertTrue(reminders.requests.isEmpty)
    }

    func testSaveFailureStopsQueueUntilSkipped() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        reminders.failure = .reminderSave
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        let first = try store.add(text: "First", createdAt: Date(timeIntervalSince1970: 1))
        let second = try store.add(text: "Second", createdAt: Date(timeIntervalSince1970: 2))
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(first.exportState, .failed)
        XCTAssertEqual(second.exportState, .pending)
        XCTAssertFalse(exporter.showsSuccess)
        reminders.failure = nil
        await exporter.deliverNextIfPossible()
        XCTAssertTrue(reminders.requests.isEmpty)
        exporter.skip(first)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(first.exportState, .skipped)
        XCTAssertEqual(second.exportState, .exported)
    }

    func testOffPausesBothAppsAndExcludesNewNotes() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        let waiting = try store.add(text: "Waiting")
        exporter.setApp(.off)
        let excluded = try store.add(text: "Excluded")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertTrue(reminders.requests.isEmpty)
        XCTAssertNil(excluded.exportState)
        exporter.setApp(.things)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(waiting.exportState, .exported)
        XCTAssertEqual(waiting.exportApp, .reminders)
    }

    func testWatchRedeliveryAndEditingDoNotCreateAnotherReminder() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        let original = try store.addWatchNote(text: "Watch note", createdAt: .now, clipID: "same-clip")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        original.note.text = "Edited locally"
        try store.container.mainContext.save()
        exporter.setApp(.things)
        let duplicate = try store.addWatchNote(text: "Watch note", createdAt: .now, clipID: "same-clip")
        XCTAssertFalse(duplicate.inserted)
        XCTAssertEqual(duplicate.note.exportApp, .reminders)
        exporter.refresh()
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(reminders.requests.count, 1)
        XCTAssertEqual(original.note.text, "Edited locally")
    }

    func testBackgroundAndRecordingGatesAlsoApplyToReminders() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        var ready = true
        let exporter = TaskExportCoordinator(store: store, reminders: reminders, isReady: { ready }, openURL: { _ in false })
        exporter.setApp(.reminders)
        let note = try store.add(text: "Wait")
        exporter.updateAvailability(isActive: false, canDispatch: true)
        await exporter.deliverNextIfPossible()
        exporter.updateAvailability(isActive: true, canDispatch: false)
        await exporter.deliverNextIfPossible()
        exporter.updateAvailability(isActive: true, canDispatch: true)
        ready = false
        await exporter.deliverNextIfPossible()
        XCTAssertTrue(reminders.requests.isEmpty)
        XCTAssertEqual(note.exportState, .pending)
        ready = true
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(reminders.requests.count, 1)
    }

    func testEmptyReceiptIsUnconfirmedAndCannotBeConfirmedByThingsCallback() async throws {
        let store = try makeStore()
        let reminders = FakeRemindersDelivery()
        reminders.receipt = ""
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        let note = try store.add(text: "No durable receipt")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(note.exportState, .unconfirmed)
        XCTAssertFalse(exporter.handle(callback(note)))
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(reminders.requests.count, 1)
        XCTAssertFalse(exporter.showsSuccess)
    }

    func testRelaunchRecoversInterruptedReminderWithoutResending() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.store")
        try autoreleasepool {
            let store = try makeStore(url: url)
            let exporter = makeExporter(store, FakeRemindersDelivery())
            exporter.setApp(.reminders)
            let note = try store.add(text: "Interrupted after commit")
            note.exportState = .inFlight
            note.thingsOperationID = UUID().uuidString
            try store.container.mainContext.save()
        }
        let reopened = try makeStore(url: url)
        let reminders = FakeRemindersDelivery()
        let exporter = makeExporter(reopened, reminders)
        let note = try XCTUnwrap(exporter.blockedNote)
        XCTAssertEqual(note.exportApp, .reminders)
        XCTAssertEqual(note.exportState, .unconfirmed)
        XCTAssertNil(note.reminderID)
        XCTAssertFalse(exporter.handle(callback(note)))
        XCTAssertTrue(reminders.requests.isEmpty)
    }

    func testReminderReceiptPersistsAndIsNotReExportedOnRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try makeStore(url: folder.appendingPathComponent("notes.store"))
        let reminders = FakeRemindersDelivery()
        let exporter = makeExporter(store, reminders)
        exporter.setApp(.reminders)
        _ = try store.add(text: "Durable receipt")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        let fresh = try NoteStore(defaults: store.defaults, storeURL: folder.appendingPathComponent("notes.store"))
        let restored = makeExporter(fresh, reminders)
        restored.updateAvailability(isActive: true, canDispatch: true)
        await restored.deliverNextIfPossible()
        XCTAssertEqual(reminders.requests.count, 1)
        let saved = try XCTUnwrap(fresh.container.mainContext.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(saved.reminderID, "reminder-receipt")
        XCTAssertEqual(saved.exportState, .exported)
        XCTAssertEqual(saved.exportApp, .reminders)
    }

    func testDuplicateListTitlesIncludeAccountName() {
        let personal = ReminderList(id: "1", title: "Tasks", account: "iCloud")
        let work = ReminderList(id: "2", title: "Tasks", account: "Work")
        XCTAssertEqual(personal.displayName(in: [personal, work]), "Tasks (iCloud)")
        XCTAssertEqual(work.displayName(in: [personal, work]), "Tasks (Work)")
        XCTAssertEqual(personal.displayName(in: [personal]), "Tasks")
    }

    func testPreviousThingsSchemaMigratesWithoutRedirectingPendingTasks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("old-things.store")
        try autoreleasepool {
            let container = try ModelContainer(for: PreviousThingsSchema.Note.self, configurations: ModelConfiguration(url: url))
            let note = PreviousThingsSchema.Note(text: "Queued for Things")
            note.thingsExportID = "stable-export-id"
            note.thingsExportStateRaw = "pending"
            container.mainContext.insert(note)
            try container.mainContext.save()
        }
        let store = try makeStore(url: url)
        let exporter = makeExporter(store, FakeRemindersDelivery())
        exporter.setApp(.reminders)
        let migrated = try XCTUnwrap(exporter.queue.first)
        XCTAssertEqual(migrated.exportApp, .things)
        XCTAssertEqual(migrated.exportState, .pending)
        XCTAssertEqual(migrated.thingsExportID, "stable-export-id")
        XCTAssertNil(migrated.taskExportAppRaw)
        XCTAssertNil(migrated.reminderID)
    }
}

private enum PreviousThingsSchema {
    @Model final class Note {
        var text: String
        var createdAt: Date
        var watchClipID: String?
        var thingsExportID: String?
        var thingsExportStateRaw: String?
        var thingsOperationID: String?
        var thingsTaskID: String?
        init(text: String) { self.text = text; createdAt = .now }
    }
}
