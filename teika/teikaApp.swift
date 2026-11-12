//
//  TeikaApp.swift
//  teika
//
//  Created by Gustavs Cirulis on 24/07/2026.
//

import SwiftData
import SwiftUI

@main
struct TeikaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var transcriber: SpeechTranscriber
    /// Built here rather than through `.modelContainer(for:)` because notes no longer
    /// only arrive while a view is on screen: a watch clip can land in an app that iOS
    /// launched into the background, where `ContentView` never appears and there is no
    /// view lifecycle for autosave to ride on.
    @State private var store: NoteStore
    @State private var exporter: TaskExportCoordinator
    @State private var obsidian: ObsidianExporter
    /// Activated at launch for the same reason — a session brought up from a view would
    /// miss every clip delivered to a background launch, which is most of them.
    @State private var watchLink: PhoneWatchLink
    /// The handover point between the two: the link fills it, usually in a background
    /// launch, and `ContentView` empties it the next time the app is on screen.
    @State private var watchInbox: WatchNoteInbox

    init() {
        let transcriber = SpeechTranscriber()
        // Same failure behaviour as the `.modelContainer(for:)` this replaces: a store
        // that cannot open leaves the app with nowhere to put anything.
        #if DEBUG
        let capturing = AppStoreScreenshotContent.launchScene != nil
        let defaults = capturing ? UserDefaults(suiteName: "teika.release-screenshot")! : .standard
        if capturing {
            defaults.removePersistentDomain(forName: "teika.release-screenshot")
            defaults.set("reminders", forKey: "taskExportApp")
        }
        let store = try! NoteStore(inMemory: capturing, defaults: defaults)
        #else
        let store = try! NoteStore()
        #endif
        let exporter = TaskExportCoordinator(store: store, isReady: {
            transcriber.isIdleForExport && RecordingLauncher.shared.pending == nil
        })
        let inbox = WatchNoteInbox()
        let link = PhoneWatchLink(transcriber: transcriber, store: store, inbox: inbox)
        #if DEBUG
        if !capturing { link.activate() }
        #else
        link.activate()
        #endif
        _transcriber = State(initialValue: transcriber)
        _store = State(initialValue: store)
        _exporter = State(initialValue: exporter)
        #if DEBUG
        _obsidian = State(initialValue: Self.makeObsidian(store: store))
        #else
        _obsidian = State(initialValue: ObsidianExporter(store: store))
        #endif
        _watchLink = State(initialValue: link)
        _watchInbox = State(initialValue: inbox)
    }

    #if DEBUG
    /// `-teika-debug-vault <folder>` points the export at a plain folder, so the whole
    /// path from a saved note to a file can be tried in the Simulator without the
    /// document picker. `-teika-debug-note <text>` saves one note at launch.
    private static func makeObsidian(store: NoteStore) -> ObsidianExporter {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let path = value("-teika-debug-vault") else { return ObsidianExporter(store: store) }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        store.defaults.set(true, forKey: ObsidianExporter.enabledKey)
        store.defaults.set(Data([1]), forKey: ObsidianExporter.bookmarkKey)
        store.defaults.set(root.lastPathComponent, forKey: ObsidianExporter.vaultNameKey)
        let obsidian = ObsidianExporter(store: store) { VaultWriter(root: root, scoped: false) }
        if let text = value("-teika-debug-note") { _ = try? store.add(text: text) }
        return obsidian
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView(transcriber: transcriber, store: store, watchInbox: watchInbox, exporter: exporter)
                .preferredColorScheme(.dark)
                .environment(obsidian)
        }
        .modelContainer(store.container)
    }
}
