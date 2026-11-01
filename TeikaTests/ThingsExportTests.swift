import Foundation
import SwiftData
import XCTest
@testable import Teika

@MainActor
final class ThingsExportURLTests: XCTestCase {
    func testAddURLPreservesTranscriptAndNestedCallbacks() throws {
        let operation = UUID().uuidString
        let text = "Café + tea & milk? #todo\n日本語 😀 100% https://example.com?a=b&c=d"
        let url = ThingsExportURL.add(title: "Buy + milk & tea", transcript: text, operationID: operation)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value!) })
        XCTAssertEqual(url.scheme, "things")
        XCTAssertEqual(url.path, "/add")
        XCTAssertEqual(items["title"], "Buy + milk & tea")
        XCTAssertEqual(items["notes"], text)
        XCTAssertEqual(items["when"], "today")
        XCTAssertNil(items["deadline"])
        XCTAssertEqual(items["show-quick-entry"], "false")
        XCTAssertEqual(items["reveal"], "false")
        for result in ["success", "error", "cancel"] {
            let callbackURL = try XCTUnwrap(URL(string: try XCTUnwrap(items["x-\(result)"])))
            let callback = try XCTUnwrap(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
            XCTAssertEqual(callback.host, "things-export")
            XCTAssertTrue(callback.queryItems!.contains(URLQueryItem(name: "operation", value: operation)))
            XCTAssertTrue(callback.queryItems!.contains(URLQueryItem(name: "result", value: result)))
        }
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testInboxDoesNotScheduleOrAssignAList() throws {
        let url = ThingsExportURL.add(
            title: "Sort later", transcript: "A thought", operationID: UUID().uuidString,
            destination: .inbox)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        for name in ["when", "deadline", "list", "list-id"] {
            XCTAssertFalse(items.contains { $0.name == name }, name)
        }
        XCTAssertTrue(items.contains(URLQueryItem(name: "show-quick-entry", value: "false")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "reveal", value: "false")))
    }

    func testNotesLimitKeepsGraphemesAndMarksExcerpt() {
        let boundary = String(repeating: "a", count: 10_000)
        XCTAssertEqual(ThingsExportURL.notes(boundary), boundary)
        let long = String(repeating: "👨‍👩‍👧‍👦", count: 10_001)
        let excerpt = ThingsExportURL.notes(long)
        XCTAssertLessThanOrEqual(excerpt.utf16.count, 10_000)
        XCTAssertTrue(excerpt.hasSuffix(ThingsExportURL.shorteningNotice))
        XCTAssertTrue(excerpt.hasPrefix("👨‍👩‍👧‍👦"))
    }

    func testCallbackRejectsMissingMalformedAndAmbiguousParameters() {
        let operation = UUID().uuidString
        for raw in [
            "teika://record?operation=\(operation)&result=success&x-things-id=task",
            "teika://things-export/other?operation=\(operation)&result=success&x-things-id=task",
            "teika://things-export?operation=bad&result=success&x-things-id=task",
            "teika://things-export?operation=\(operation)&result=success",
            "teika://things-export?operation=\(operation)&result=success&x-things-id=one,two",
            "teika://things-export?operation=\(operation)&operation=\(operation)&result=cancel",
            "teika://things-export?operation=\(operation)&result=success&result=error&x-things-id=task",
        ] {
            XCTAssertNil(ThingsExportURL.Callback(url: URL(string: raw)!), raw)
        }
    }
}

@MainActor
final class ThingsExportTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func makeStore(enabled: Bool = false, url: URL? = nil) throws -> NoteStore {
        let suite = "Teika.ThingsTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(enabled, forKey: TaskExportCoordinator.enabledKey)
        return try NoteStore(inMemory: url == nil, defaults: defaults, storeURL: url)
    }

    private func callback(_ note: Note, result: String = "success", taskID: String? = "task-123") -> URL {
        var components = URLComponents(string: "teika://things-export")!
        components.queryItems = [
            URLQueryItem(name: "operation", value: note.thingsOperationID!),
            URLQueryItem(name: "result", value: result),
        ]
        if let taskID { components.queryItems!.append(URLQueryItem(name: "x-things-id", value: taskID)) }
        return components.url!
    }

    func testDefaultOffAndEnablingDoesNotQueueExistingNotes() throws {
        let store = try makeStore()
        let before = try store.add(text: "Already saved")
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in XCTFail(); return false })
        XCTAssertFalse(exporter.isEnabled)
        exporter.setEnabled(true)
        let after = try store.add(text: "New thought")
        XCTAssertNil(before.thingsExportID)
        XCTAssertNil(before.exportState)
        XCTAssertNotNil(after.thingsExportID)
        XCTAssertEqual(after.exportState, .pending)
        XCTAssertEqual(exporter.pendingCount, 1)
    }

    func testTaskNotesOnlyRepeatTitleWhenItWasTruncated() async throws {
        let boundary = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        let long = boundary + "!"
        for (text, expectedNotes) in [
            ("Buy milk", ""),
            ("  Buy milk  ", ""),
            (boundary, ""),
            (long, long),
            ("Buy milk\n\nBring the reusable bag.\nCheck the fridge first.", "Bring the reusable bag.\nCheck the fridge first."),
            (long + "\nExtra detail", long + "\nExtra detail"),
        ] {
            let store = try makeStore(enabled: true)
            var urls: [URL] = []
            let exporter = TaskExportCoordinator(store: store, openURL: { urls.append($0); return true })
            let note = try store.add(text: text)
            exporter.updateAvailability(isActive: true, canDispatch: true)
            await exporter.deliverNextIfPossible()
            let url = try XCTUnwrap(urls.first)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "title" }?.value, note.title)
            XCTAssertEqual(items.first { $0.name == "notes" }?.value, expectedNotes.isEmpty ? nil : expectedNotes)
            XCTAssertEqual(note.text, text)
        }
    }

    func testDestinationDefaultsToTodayAndPersistsWhileDisabled() throws {
        let store = try makeStore()
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in true })
        XCTAssertEqual(exporter.destination, .today)
        exporter.setEnabled(true)
        exporter.setDestination(.inbox)
        exporter.setEnabled(false)
        let restored = TaskExportCoordinator(store: store, openURL: { _ in true })
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.destination, .inbox)
        restored.setEnabled(true)
        XCTAssertEqual(restored.destination, .inbox)

        store.defaults.set("unknown-destination", forKey: TaskExportCoordinator.destinationKey)
        let fallback = TaskExportCoordinator(store: store, openURL: { _ in true })
        XCTAssertEqual(fallback.destination, .today)
    }

    func testSelectedDestinationAppliesToPendingPhoneAndWatchDeliveries() async throws {
        let store = try makeStore(enabled: true)
        var urls: [URL] = []
        let exporter = TaskExportCoordinator(store: store, openURL: { urls.append($0); return true })
        let phone = try store.add(text: "Phone note")
        exporter.setDestination(.inbox)
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        let inboxURL = try XCTUnwrap(urls.first)
        XCTAssertFalse(URLComponents(url: inboxURL, resolvingAgainstBaseURL: false)!
            .queryItems!.contains { $0.name == "when" })
        XCTAssertTrue(exporter.handle(callback(phone)))

        // Changing the destination also applies to notes already waiting to send.
        let watch = try store.addWatchNote(text: "Watch note", createdAt: .now, clipID: "destination-watch")
        exporter.setDestination(.today)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(urls.count, 2)
        let todayURL = try XCTUnwrap(urls.last)
        XCTAssertTrue(URLComponents(url: todayURL, resolvingAgainstBaseURL: false)!
            .queryItems!.contains(URLQueryItem(name: "when", value: "today")))
        XCTAssertEqual(watch.note.exportState, .inFlight)
    }

    func testBackgroundAndBusyScenesDoNotDispatch() async throws {
        let store = try makeStore(enabled: true)
        var opens = 0
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in opens += 1; return true })
        let note = try store.add(text: "Wait until ready")
        exporter.updateAvailability(isActive: false, canDispatch: true)
        await exporter.deliverNextIfPossible()
        exporter.updateAvailability(isActive: true, canDispatch: false)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(note.exportState, .pending)
    }

    func testRecordingStartingBeforeSceneGateUpdatesStillPreventsHandoff() async throws {
        let store = try makeStore(enabled: true)
        var ready = true
        var opens = 0
        let exporter = TaskExportCoordinator(store: store, isReady: { ready }, openURL: { _ in
            opens += 1
            return true
        })
        let note = try store.add(text: "Let the recording start")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        ready = false
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(note.exportState, .pending)
    }

    func testEditingExportedNoteDoesNotSendItAgain() async throws {
        let store = try makeStore(enabled: true)
        var opens = 0
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in opens += 1; return true })
        let note = try store.add(text: "Original")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertTrue(exporter.handle(callback(note)))
        note.text = "Corrected"
        try store.container.mainContext.save()
        exporter.refresh()
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(note.thingsTaskID, "task-123")
        XCTAssertEqual(exporter.pendingCount, 0)
    }

    func testOldestFirstAndOnlyOneHandoffUntilConfirmed() async throws {
        let store = try makeStore(enabled: true)
        var urls: [URL] = []
        let exporter = TaskExportCoordinator(store: store, openURL: { urls.append($0); return true })
        let newer = try store.add(text: "Newer", createdAt: Date(timeIntervalSince1970: 200))
        let older = try store.add(text: "Older", createdAt: Date(timeIntervalSince1970: 100))
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(older.exportState, .inFlight)
        XCTAssertEqual(newer.exportState, .pending)
        XCTAssertFalse(exporter.showsSuccess)
        let success = callback(older)
        XCTAssertTrue(exporter.handle(success))
        XCTAssertEqual(older.thingsTaskID, "task-123")
        XCTAssertEqual(older.exportState, .exported)
        XCTAssertTrue(exporter.showsSuccess)
        XCTAssertFalse(exporter.handle(success))
        XCTAssertEqual(exporter.successSerial, 1)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(urls.count, 2)
    }

    func testMissingThingsPausesQueueUntilRetry() async throws {
        let store = try makeStore(enabled: true)
        var opens = 0
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in opens += 1; return false })
        let note = try store.add(text: "Install Things")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(note.exportState, .failed)
        XCTAssertTrue(exporter.needsAttention)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 1)
        exporter.retry(note)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 2)
    }

    func testErrorAndCancelPauseUntilSkipped() async throws {
        for result in ["error", "cancel"] {
            let store = try makeStore(enabled: true)
            var opens = 0
            let exporter = TaskExportCoordinator(store: store, openURL: { _ in opens += 1; return true })
            let first = try store.add(text: "First", createdAt: Date(timeIntervalSince1970: 100))
            _ = try store.add(text: "Second", createdAt: Date(timeIntervalSince1970: 200))
            exporter.updateAvailability(isActive: true, canDispatch: true)
            await exporter.deliverNextIfPossible()
            XCTAssertTrue(exporter.handle(callback(first, result: result, taskID: nil)))
            XCTAssertEqual(first.exportState, result == "error" ? .failed : .cancelled)
            XCTAssertFalse(exporter.showsSuccess)
            await exporter.deliverNextIfPossible()
            XCTAssertEqual(opens, 1)
            exporter.skip(first)
            await exporter.deliverNextIfPossible()
            XCTAssertEqual(opens, 2)
        }
    }

    func testMissingCallbackBecomesUnconfirmedAndAcceptsLateSuccess() async throws {
        let store = try makeStore(enabled: true)
        var opens = 0
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in opens += 1; return true })
        let note = try store.add(text: "Might already exist")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        let success = callback(note)
        exporter.updateAvailability(isActive: false, canDispatch: false)
        exporter.updateAvailability(isActive: true, canDispatch: true)
        XCTAssertEqual(note.exportState, .unconfirmed)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(exporter.handle(success))
        XCTAssertEqual(note.exportState, .exported)
    }

    func testRetryInvalidatesOldOperationAndUnknownCallbacksAreIgnored() async throws {
        let store = try makeStore(enabled: true)
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in true })
        let note = try store.add(text: "Try again")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        let oldSuccess = callback(note)
        let unknown = URL(string: "teika://things-export?operation=\(UUID().uuidString)&result=success&x-things-id=unknown")!
        XCTAssertFalse(exporter.handle(unknown))
        exporter.updateAvailability(isActive: false, canDispatch: false)
        exporter.updateAvailability(isActive: true, canDispatch: true)
        exporter.retry(note)
        await exporter.deliverNextIfPossible()
        XCTAssertFalse(exporter.handle(oldSuccess))
        XCTAssertEqual(note.exportState, .inFlight)
        XCTAssertTrue(exporter.handle(callback(note)))
    }

    func testDisablingPausesExistingQueueAndNewNotesStayIneligible() async throws {
        let store = try makeStore(enabled: true)
        var opens = 0
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in opens += 1; return true })
        let queued = try store.add(text: "Queued")
        exporter.setEnabled(false)
        let excluded = try store.add(text: "Not queued")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 0)
        XCTAssertNil(excluded.exportState)
        exporter.setEnabled(true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(queued.exportState, .inFlight)
    }

    func testWatchRedeliveryQueuesOnlyOneExportEvenAfterEditing() throws {
        let store = try makeStore(enabled: true)
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in true })
        let first = try store.addWatchNote(text: "Original", createdAt: .now, clipID: "watch-one")
        let exportID = first.note.thingsExportID
        first.note.text = "Edited"
        try store.container.mainContext.save()
        let second = try store.addWatchNote(text: "Original", createdAt: .now, clipID: "watch-one")
        XCTAssertFalse(second.inserted)
        XCTAssertEqual(second.note.thingsExportID, exportID)
        XCTAssertEqual(second.note.text, "Edited")
        XCTAssertEqual(exporter.pendingCount, 1)
    }

    func testDeletingPendingNoteDoesNotExportIt() async throws {
        let store = try makeStore(enabled: true)
        var opens = 0
        let exporter = TaskExportCoordinator(store: store, openURL: { _ in opens += 1; return true })
        let note = try store.add(text: "Deleted")
        store.container.mainContext.delete(note)
        try store.container.mainContext.save()
        exporter.refresh()
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(exporter.pendingCount, 0)
    }

    func testSuccessDuringOpenCompletionIsNotOverwrittenByOpenFailure() async throws {
        let store = try makeStore(enabled: true)
        var exporter: TaskExportCoordinator!
        exporter = TaskExportCoordinator(store: store, openURL: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let raw = items.first { $0.name == "x-success" }!.value! + "&x-things-id=task-race"
            XCTAssertTrue(exporter.handle(URL(string: raw)!))
            return false
        })
        let note = try store.add(text: "Callback first")
        exporter.updateAvailability(isActive: true, canDispatch: true)
        await exporter.deliverNextIfPossible()
        XCTAssertEqual(note.exportState, .exported)
        XCTAssertEqual(note.thingsTaskID, "task-race")
        // Break the test opener's intentional capture cycle.
        exporter = nil
    }

    func testRelaunchPersistsQueueAndRecoversInFlightWithoutResending() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.store")
        let operation = UUID().uuidString
        try autoreleasepool {
            let store = try makeStore(enabled: true, url: url)
            let note = try store.add(text: "Persisted")
            note.exportState = .inFlight
            note.thingsOperationID = operation
            try store.container.mainContext.save()
        }
        let reopened = try makeStore(enabled: true, url: url)
        let exporter = TaskExportCoordinator(store: reopened, openURL: { _ in XCTFail(); return false })
        let note = try XCTUnwrap(exporter.blockedNote)
        XCTAssertEqual(note.exportState, .unconfirmed)
        XCTAssertEqual(note.thingsOperationID, operation)
        XCTAssertTrue(exporter.handle(callback(note)))
        let fresh = ModelContext(reopened.container)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(saved.thingsTaskID, "task-123")
        XCTAssertEqual(saved.exportState, .exported)
    }

    func testLegacyStoreMigratesWithoutQueuingOldNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("legacy.store")
        let date = Date(timeIntervalSince1970: 1_234)
        try autoreleasepool {
            let container = try ModelContainer(
                for: LegacyNotesSchema.Note.self, configurations: ModelConfiguration(url: url))
            container.mainContext.insert(LegacyNotesSchema.Note(
                text: "Existing library", createdAt: date, watchClipID: "old-watch"))
            try container.mainContext.save()
        }
        let store = try makeStore(enabled: true, url: url)
        let old = try XCTUnwrap(store.container.mainContext.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(old.text, "Existing library")
        XCTAssertEqual(old.createdAt, date)
        XCTAssertEqual(old.watchClipID, "old-watch")
        XCTAssertNil(old.thingsExportID)
        XCTAssertNil(old.exportState)
        XCTAssertNil(old.thingsTaskID)
        XCTAssertEqual(try store.add(text: "After upgrade").exportState, .pending)
    }
}

/// Matches the shipped model before the optional Things fields were introduced.
private enum LegacyNotesSchema {
    @Model
    final class Note {
        var text: String
        var createdAt: Date
        var watchClipID: String?

        init(text: String, createdAt: Date, watchClipID: String?) {
            self.text = text
            self.createdAt = createdAt
            self.watchClipID = watchClipID
        }
    }
}
