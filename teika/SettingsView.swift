import Combine
import EventKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var exporter: TaskExportCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsDuplicateWarning = false
    @Environment(ObsidianExporter.self) private var obsidian: ObsidianExporter?
    @State private var choosesVault = false

    var body: some View {
        Form {
            Section {
                Picker("Add notes to", selection: Binding(
                    get: { exporter.app }, set: { app in
                        exporter.setApp(app)
                        if app == .reminders {
                            Task { await exporter.requestRemindersAccess() }
                        }
                    })) {
                    ForEach(TaskExportApp.allCases, id: \.self) { app in
                        Text(app.title).tag(app)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("taskExportApp")

                if exporter.app == .things {
                    Picker("Destination", selection: Binding(
                        get: { exporter.destination }, set: { exporter.setDestination($0) })) {
                        ForEach(ThingsDestination.allCases, id: \.self) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    .pickerStyle(.menu)
                    Link("Get Things", destination: URL(string: "https://culturedcode.com/things/")!)
                } else if exporter.app == .reminders {
                    remindersOptions
                }
            } footer: {
                switch exporter.app {
                case .things: Text("Things opens briefly to add new notes.")
                case .reminders: Text("New notes are added without leaving Teika.")
                case .off: Text("Automatically turn new notes into tasks.")
                }
            }

            if exporter.needsAttention {
                Section {
                    if let error = exporter.storageError {
                        Text(error)
                        Button("Retry") { exporter.retryStorage() }
                    } else if let note = exporter.blockedNote {
                        Text(note.title).font(.headline)
                        Text(message(for: note)).foregroundStyle(.secondary)
                        if note.taskExportFailureRaw == TaskExportFailure.remindersAccess.rawValue {
                            openSettingsLink
                        }
                        Button("Retry") {
                            if note.exportState == .unconfirmed {
                                showsDuplicateWarning = true
                            } else {
                                exporter.retry(note)
                                dismiss()
                            }
                        }
                        .disabled(!exporter.isEnabled)
                        Button("Skip this note") { exporter.skip(note) }
                    }
                }
            }

            if let obsidian { obsidianSections(obsidian) }

            Section {
                Link(destination: URL(string: "https://teika.app/privacy/")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://teika.app/support/")!) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://github.com/gustavscirulis/teika")!) {
                    Label("View Source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosesVault, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { obsidian?.chooseVault(url) }
        }
        .task { await obsidian?.refreshSettings() }
        .task {
            if exporter.app == .reminders { await exporter.requestRemindersAccess() }
            else { exporter.refreshReminders() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { exporter.refreshReminders() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)) { _ in
            exporter.refreshReminders()
        }
        .alert("Retry this note?", isPresented: $showsDuplicateWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Retry anyway") {
                if let note = exporter.blockedNote, note.exportState == .unconfirmed {
                    exporter.retry(note)
                    dismiss()
                }
            }
        } message: {
            Text("Check \(exporter.blockedNote?.exportApp.receiptName ?? "the task app") first. Retrying may create a duplicate. Choose Skip if it’s already there.")
        }
    }

    @ViewBuilder
    private func obsidianSections(_ obsidian: ObsidianExporter) -> some View {
        Section {
            if let name = obsidian.vaultName {
                Toggle("Save notes to Obsidian", isOn: Binding(
                    get: { obsidian.isEnabled }, set: { obsidian.setEnabled($0) }))
                LabeledContent("Vault", value: name)
                Button("Choose another vault…") { choosesVault = true }
                Button("Disconnect vault", role: .destructive) { obsidian.removeVault() }
            } else {
                Button("Choose vault folder…") { choosesVault = true }
            }
            if let error = obsidian.setupError ?? obsidian.lastError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Obsidian")
        } footer: {
            if obsidian.vaultName == nil {
                Text("Pick your vault’s folder, for example iCloud Drive › Obsidian › My Vault. Each new note is saved there as its own Markdown file, without opening Obsidian.")
            } else {
                Text("Each new note becomes its own file. Edits in Teika update it until the file is changed in Obsidian.")
            }
        }

        if obsidian.vaultName != nil {
            Section {
                overrideField(
                    "Folder", placeholder: obsidian.vaultSettings.map {
                        $0.folder.trimmed.isEmpty || $0.folder == "/" ? "Vault root" : $0.folder
                    } ?? "Vault root",
                    text: Binding(get: { obsidian.overrides.folder },
                                  set: { obsidian.overrides.folder = $0 }))
                overrideField(
                    "File name", placeholder: obsidian.vaultSettings?.filenameFormat
                        ?? VaultNoteSettings.defaultFilenameFormat,
                    text: Binding(get: { obsidian.overrides.filenameFormat },
                                  set: { obsidian.overrides.filenameFormat = $0 }))
                overrideField(
                    "Template", placeholder: obsidian.vaultSettings.map {
                        $0.templatePath.trimmed.isEmpty ? "None" : $0.templatePath
                    } ?? "None",
                    text: Binding(get: { obsidian.overrides.templatePath },
                                  set: { obsidian.overrides.templatePath = $0 }))
                if let example = obsidian.examplePath {
                    LabeledContent("Next note", value: example)
                        .font(.footnote)
                }
            } header: {
                Text("New notes")
            } footer: {
                Text("Empty fields use your vault’s Unique note creator settings. File names use Obsidian’s date format (YYYY-MM-DD HHmm); a folder can include {{date:YYYY}}. In the template, {{date}}, {{time}} and {{title}} work as in Obsidian, and {{text}} marks where the transcript goes. Without it, the transcript follows the template.")
            }
        }
    }

    private func overrideField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var remindersOptions: some View {
        if exporter.isRequestingAccess {
            ProgressView("Allow Reminders access…")
        } else if exporter.remindersAccess == .granted {
            Picker("List", selection: Binding(
                get: { exporter.reminderListID ?? "" }, set: { exporter.setReminderList($0) })) {
                if !exporter.reminderLists.contains(where: { $0.id == exporter.reminderListID }) {
                    Text(exporter.reminderListID == nil ? "Choose a list" : "Unavailable list")
                        .tag(exporter.reminderListID ?? "")
                }
                ForEach(exporter.reminderLists) { list in
                    Text(list.displayName(in: exporter.reminderLists)).tag(list.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("reminderExportList")
            Picker("Schedule", selection: Binding(
                get: { exporter.reminderSchedule }, set: { exporter.setReminderSchedule($0) })) {
                ForEach(ReminderSchedule.allCases, id: \.self) { schedule in
                    Text(schedule.title).tag(schedule)
                }
            }
            .pickerStyle(.menu)
            if exporter.reminderLists.isEmpty {
                Text("Create a list in Reminders, then return here.").foregroundStyle(.secondary)
            }
        } else {
            Text(exporter.remindersSetupError ?? "Allow Reminders access to choose a list and add notes.")
                .foregroundStyle(.secondary)
            if exporter.remindersAccess == .notDetermined {
                Button("Allow access") { Task { await exporter.requestRemindersAccess() } }
            } else {
                openSettingsLink
            }
        }
    }

    private var openSettingsLink: some View {
        Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
    }

    private func message(for note: Note) -> String {
        if note.exportState == .unconfirmed {
            return "This task may already be in \(note.exportApp.receiptName). Check before retrying."
        }
        if note.exportState == .cancelled { return "Adding this note was cancelled." }
        if note.exportApp == .things {
            return "Couldn’t add this note. Check that Things is installed and Things URLs are enabled."
        }
        switch note.taskExportFailureRaw.flatMap(TaskExportFailure.init(rawValue:)) {
        case .remindersAccess: return "Allow Reminders access in Settings, then retry."
        case .reminderListUnavailable:
            return "The selected list is unavailable. Choose another list under Apple Reminders above, then retry."
        default: return "Couldn’t save this reminder. Try again."
        }
    }
}
