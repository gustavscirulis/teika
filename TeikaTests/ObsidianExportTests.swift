import SwiftData
import XCTest
@testable import Teika

/// The vault in these tests mirrors a real one: Unique note creator writing
/// `YYYY-MM-DD HHmm` notes to the root from `Templates/Journal Template`.
@MainActor
final class ObsidianExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let en = Locale(identifier: "en_US_POSIX")
    /// 2026-11-05 14:32:09.250 UTC, a Thursday.
    private let date = Date(timeIntervalSince1970: 1_793_889_129.25)
    private var vault: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: vault.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vault.appending(path: "Templates"), withIntermediateDirectories: true)
        try write(".obsidian/zk-prefixer.json", #"""
            {"format": "YYYY-MM-DD HHmm", "folder": "/", "template": "Templates/Journal Template"}
            """#)
        try write(".obsidian/templates.json", #"{"folder": "Templates"}"#)
        try write("Templates/Journal Template.md", "---\ncreated: {{date}}\n---\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: moment formats

    func testMomentFormatsCommonObsidianPatterns() {
        func f(_ format: String) -> String {
            MomentFormat.string(from: date, format: format, locale: en, timeZone: utc)
        }
        XCTAssertEqual(f("YYYY-MM-DD HHmm"), "2026-11-05 1432")
        XCTAssertEqual(f("YYYYMMDDHHmm"), "202611051432")
        XCTAssertEqual(f("YYYY-MM-DD"), "2026-11-05")
        XCTAssertEqual(f("HH:mm:ss.SSS"), "14:32:09.250")
        XCTAssertEqual(f("dddd, MMMM Do YYYY"), "Thursday, November 5th 2026")
        XCTAssertEqual(f("ddd D MMM YY"), "Thu 5 Nov 26")
        XCTAssertEqual(f("h:mm A"), "2:32 PM")
        XCTAssertEqual(f("GGGG-[W]WW"), "2026-W45")
        XCTAssertEqual(f("[Voice] YYYY"), "Voice 2026")
        XCTAssertEqual(f("Q"), "4")
        XCTAssertEqual(f("DDDD"), "309")
    }

    // MARK: settings and templates

    func testVaultSettingsFollowTheUniqueNoteCreator() {
        let settings = VaultNoteSettings.fromVault(
            uniqueNoteJSON: Data(#"{"format":"YYYY-MM-DD HHmm","folder":"/","template":"Templates/Journal Template"}"#.utf8),
            templatesJSON: Data(#"{"folder":"Templates"}"#.utf8))
        XCTAssertEqual(settings.filenameFormat, "YYYY-MM-DD HHmm")
        XCTAssertEqual(settings.resolvedFolder(for: date, timeZone: utc), "")
        XCTAssertEqual(settings.resolvedTemplatePath, "Templates/Journal Template.md")
        XCTAssertEqual(settings.dateFormat, "YYYY-MM-DD")
        XCTAssertEqual(settings.timeFormat, "HH:mm")
    }

    func testOverridesWinAndMissingSettingsFallBack() {
        let none = VaultNoteSettings.fromVault(uniqueNoteJSON: nil, templatesJSON: nil)
        XCTAssertEqual(none.filenameFormat, "YYYY-MM-DD HHmm")
        XCTAssertNil(none.resolvedTemplatePath)

        // Obsidian's own default when the plugin is set up without a format.
        let bare = VaultNoteSettings.fromVault(uniqueNoteJSON: Data("{}".utf8), templatesJSON: nil)
        XCTAssertEqual(bare.filenameFormat, "YYYYMMDDHHmm")

        let overridden = VaultNoteSettings.fromVault(
            uniqueNoteJSON: Data(#"{"format":"YYYY-MM-DD HHmm","folder":"/"}"#.utf8),
            templatesJSON: Data(#"{"dateFormat":"DD.MM.YYYY"}"#.utf8),
            overrides: .init(filenameFormat: "[Voice] YYYY-MM-DD HHmm", folder: "Inbox/{{date:YYYY}}/"))
        XCTAssertEqual(overridden.baseName(for: date, timeZone: utc), "Voice 2026-11-05 1432")
        XCTAssertEqual(overridden.resolvedFolder(for: date, timeZone: utc), "Inbox/2026")
        XCTAssertEqual(overridden.dateFormat, "DD.MM.YYYY")
    }

    func testTemplateRendersLikeObsidianAndPlacesTheTranscript() {
        let settings = VaultNoteSettings()
        let after = VaultNoteTemplate.render(
            template: "---\ncreated: {{date}}\n---", title: "2026-11-05 1432", date: date,
            settings: settings, timeZone: utc)
        XCTAssertEqual(after.content(with: "Call mom."), "---\ncreated: 2026-11-05\n---\nCall mom.")

        let placed = VaultNoteTemplate.render(
            template: "# {{title}}\n{{text}}\n\nat {{time}} on {{date:dddd}} {{unknown}}",
            title: "Note", date: date, settings: settings, timeZone: utc)
        XCTAssertEqual(
            placed.content(with: "Hello"), "# Note\nHello\n\nat 14:32 on Thursday {{unknown}}")

        XCTAssertEqual(
            VaultNoteTemplate.render(
                template: nil, title: "x", date: date, settings: settings
            ).content(with: "Just text"),
            "Just text")
    }

    func testFileNamesDropCharactersObsidianRejects() {
        XCTAssertEqual(VaultNoteTemplate.sanitizedName("a/b:c*d?e|f#g^h[i]"), "a-b-c-d-e-f-g-h-i-")
        XCTAssertEqual(VaultNoteTemplate.sanitizedName("..hidden"), "hidden")
    }

    // MARK: writer

    func testCreatesAUniqueNoteFromTheVaultsTemplate() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let first = try writer.create(text: "Buy oat milk.", date: date, overrides: .init(), timeZone: utc)
        let second = try writer.create(text: "Second thought.", date: date, overrides: .init(), timeZone: utc)

        XCTAssertEqual(first.path, "2026-11-05 1432.md")
        XCTAssertEqual(second.path, "2026-11-05 1432 2.md")
        XCTAssertEqual(try read(first.path), "---\ncreated: 2026-11-05\n---\nBuy oat milk.")
        XCTAssertEqual(try read(second.path), "---\ncreated: 2026-11-05\n---\nSecond thought.")
    }

    func testFolderOverrideIsCreated() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let record = try writer.create(
            text: "x", date: date, overrides: .init(folder: "Inbox/Voice"), timeZone: utc)
        XCTAssertEqual(record.path, "Inbox/Voice/2026-11-05 1432.md")
        XCTAssertEqual(try read(record.path), "---\ncreated: 2026-11-05\n---\nx")
    }

    func testUpdatesOnlyAFileNobodyElseChanged() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let record = try writer.create(text: "First draft", date: date, overrides: .init(), timeZone: utc)

        guard case .saved(let updated) = try writer.update(record, text: "First draft, fixed") else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(try read(record.path), "---\ncreated: 2026-11-05\n---\nFirst draft, fixed")

        try write(record.path, "---\ncreated: 2026-11-05\n---\nEdited in Obsidian")
        XCTAssertEqual(try writer.update(updated, text: "Teika again"), .editedElsewhere)
        XCTAssertEqual(try read(record.path), "---\ncreated: 2026-11-05\n---\nEdited in Obsidian")
    }

    func testFollowsANoteRenamedInObsidianAndReportsDeletedOnes() throws {
        let writer = VaultWriter(root: vault, scoped: false)
        let record = try writer.create(text: "Trip idea", date: date, overrides: .init(), timeZone: utc)
        try FileManager.default.moveItem(
            at: vault.appending(path: record.path), to: vault.appending(path: "Trip idea.md"))

        guard case .saved(let followed) = try writer.update(record, text: "Trip idea: Lisbon") else {
            return XCTFail("expected the renamed file to be found")
        }
        XCTAssertEqual(followed.path, "Trip idea.md")
        XCTAssertEqual(try read("Trip idea.md"), "---\ncreated: 2026-11-05\n---\nTrip idea: Lisbon")

        try FileManager.default.removeItem(at: vault.appending(path: "Trip idea.md"))
        XCTAssertEqual(try writer.update(followed, text: "gone"), .missing)
    }

    // MARK: exporter

    func testNewNotesAndEditsReachTheVault() async throws {
        let (store, exporter) = try makeExporter()
        let note = try store.add(text: "Remember the dentist", createdAt: date)
        await exporter.flush()

        XCTAssertEqual(note.vaultState, .saved)
        let path = try XCTUnwrap(note.vaultPath)
        XCTAssertTrue(try read(path).hasSuffix("---\nRemember the dentist"))
        XCTAssertEqual(exporter.createdSerial, 1)

        note.text = "Remember the dentist on Friday"
        exporter.noteEdited(note, delay: .milliseconds(10))
        await exporter.flush()
        XCTAssertTrue(try read(path).hasSuffix("---\nRemember the dentist on Friday"))
        XCTAssertEqual(exporter.createdSerial, 1, "an edit must not create a second file")

        try write(path, "changed in Obsidian")
        note.text = "Teika edit"
        exporter.noteEdited(note, delay: .zero)
        await exporter.flush()
        XCTAssertEqual(note.vaultState, .editedElsewhere)
        XCTAssertEqual(try read(path), "changed in Obsidian")

        exporter.saveAsNewNote(note)
        await exporter.flush()
        XCTAssertEqual(note.vaultState, .saved)
        XCTAssertNotEqual(note.vaultPath, path)
        XCTAssertTrue(try read(try XCTUnwrap(note.vaultPath)).hasSuffix("---\nTeika edit"))
    }

    func testNotesFromBeforeTheVaultWasSetUpStayOut() async throws {
        let defaults = UserDefaults(suiteName: "obsidian-\(UUID().uuidString)")!
        let store = try NoteStore(inMemory: true, defaults: defaults)
        let old = try store.add(text: "Before", createdAt: date)
        defaults.set(true, forKey: ObsidianExporter.enabledKey)
        defaults.set(Data([1]), forKey: ObsidianExporter.bookmarkKey)
        let exporter = ObsidianExporter(store: store) { [vault] in VaultWriter(root: vault!, scoped: false) }
        await exporter.flush()
        XCTAssertNil(old.vaultState)
        XCTAssertNil(old.vaultPath)

        exporter.send(old)
        await exporter.flush()
        XCTAssertEqual(old.vaultState, .saved)
    }

    // MARK: helpers

    private func makeExporter() throws -> (NoteStore, ObsidianExporter) {
        let defaults = UserDefaults(suiteName: "obsidian-\(UUID().uuidString)")!
        defaults.set(true, forKey: ObsidianExporter.enabledKey)
        // Any bookmark counts as set up; the injected writer stands in for it.
        defaults.set(Data([1]), forKey: ObsidianExporter.bookmarkKey)
        let store = try NoteStore(inMemory: true, defaults: defaults)
        let exporter = ObsidianExporter(store: store) { [vault] in VaultWriter(root: vault!, scoped: false) }
        return (store, exporter)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: vault.appending(path: path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: vault.appending(path: path), encoding: .utf8)
    }
}
