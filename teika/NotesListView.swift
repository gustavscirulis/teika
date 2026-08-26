import SwiftData
import SwiftUI

struct NotesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.createdAt, order: .reverse) private var notes: [Note]
    /// The detail push goes through the root stack's path rather than local state, so
    /// that a launch request can clear the whole stack in one move.
    @Binding var path: [Route]
    @Binding var showsRecordingShortcutPrompt: Bool
    /// A presentation-only debug override. The SwiftData query and its models remain
    /// untouched, so turning this off reveals the real library again.
    let showsEmptyState: Bool
    /// Debug-only value fixtures for App Store captures. This never changes the query or
    /// its model context, and the sample rows expose no edit or delete actions.
    let showsAppStoreScreenshots: Bool
    @State private var showCopied = false
    @State private var searchText = ""
    @State private var showsRecordingSetup = false
    private let privacyURL = URL(string: "https://teika.app/privacy/")!
    private let supportURL = URL(string: "https://teika.app/support/")!
    private let sourceURL = URL(string: "https://github.com/gustavscirulis/teika")!

    private var filteredNotes: [Note] {
        guard !showsEmptyState else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.text.localizedStandardContains(query) }
    }

    private var displaysEmptyLibrary: Bool {
        showsEmptyState || notes.isEmpty
    }

    private var noteSections: [NoteSection] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let recentWindowStart = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var recentNotes: [Date: [Note]] = [:]
        var olderNotes: [Note] = []

        for note in filteredNotes {
            let day = calendar.startOfDay(for: note.createdAt)
            if day >= recentWindowStart {
                recentNotes[day, default: []].append(note)
            } else {
                olderNotes.append(note)
            }
        }

        var sections = recentNotes.keys.sorted(by: >).map { day in
            NoteSection(
                id: .day(day),
                title: Self.sectionTitle(for: day, calendar: calendar),
                notes: recentNotes[day, default: []],
                showsDate: false
            )
        }

        if !olderNotes.isEmpty {
            sections.append(
                NoteSection(
                    id: .older,
                    title: "Older",
                    notes: olderNotes,
                    showsDate: true
                )
            )
        }

        return sections
    }

    var body: some View {
        Group {
            #if DEBUG
            if showsAppStoreScreenshots {
                screenshotNotesList
            } else {
                libraryContent
            }
            #else
            libraryContent
            #endif
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Link(destination: privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: supportURL) {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: sourceURL) {
                        Label(
                            "View Source",
                            systemImage: "chevron.left.forwardslash.chevron.right"
                        )
                    }
                } label: {
                    Label("About Teika", systemImage: "info.circle")
                }
            }
        }
        .fullScreenCover(isPresented: $showsRecordingSetup) {
            RecordingSetupSheet {
                showsRecordingShortcutPrompt = false
            }
        }
        .overlay(alignment: .bottom) {
            if showCopied {
                Text("Copied to clipboard")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if displaysEmptyLibrary {
            emptyNotesView
        } else {
            notesList
                .searchable(text: $searchText, prompt: "Search notes")
        }
    }

    #if DEBUG
    private var screenshotNoteSections: [ScreenshotNoteSection] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let recentWindowStart = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var recentNotes: [Date: [AppStoreScreenshotContent.SampleNote]] = [:]
        var olderNotes: [AppStoreScreenshotContent.SampleNote] = []

        for note in AppStoreScreenshotContent.notes {
            let day = calendar.startOfDay(for: note.createdAt)
            if day >= recentWindowStart {
                recentNotes[day, default: []].append(note)
            } else {
                olderNotes.append(note)
            }
        }

        var sections = recentNotes.keys.sorted(by: >).map { day in
            ScreenshotNoteSection(
                id: .day(day),
                title: Self.sectionTitle(for: day, calendar: calendar),
                notes: recentNotes[day, default: []],
                showsDate: false
            )
        }

        if !olderNotes.isEmpty {
            sections.append(
                ScreenshotNoteSection(
                    id: .older,
                    title: "Older",
                    notes: olderNotes,
                    showsDate: true
                )
            )
        }

        return sections
    }

    private var screenshotNotesList: some View {
        List {
            ForEach(screenshotNoteSections) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title)
                                .font(.body)
                                .lineLimit(1)
                            Text(
                                note.createdAt.formatted(
                                    date: section.showsDate ? .abbreviated : .omitted,
                                    time: .shortened
                                )
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
    #endif

    private var emptyNotesView: some View {
        ContentUnavailableView(
            "No notes yet",
            systemImage: "mic",
            description: Text("Recorded dictations will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notesList: some View {
        List {
            if showsRecordingShortcutPrompt {
                Section {
                    recordingSetupButton
                }
            }

            if filteredNotes.isEmpty {
                Section {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                ForEach(noteSections) { section in
                    Section(section.title) {
                        ForEach(section.notes) { note in
                            noteRow(note, showsDate: section.showsDate)
                        }
                    }
                }
            }
        }
    }

    private func noteRow(_ note: Note, showsDate: Bool) -> some View {
        Button {
            copy(note)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.body)
                    .lineLimit(1)
                Text(
                    note.createdAt.formatted(
                        date: showsDate ? .abbreviated : .omitted,
                        time: .shortened
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies this note. Swipe for more actions.")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                context.delete(note)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                path.append(.note(note))
            } label: {
                Label("Open", systemImage: "arrow.up.forward.square")
            }
            .tint(.accentColor)
        }
    }

    private static func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var recordingSetupButton: some View {
        Button {
            showsRecordingSetup = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up quick recording")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Lock Screen, Control Center, Watch, and Siri")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set up quick recording")
        .accessibilityHint("Shows how to start Teika from the Lock Screen, Control Center, Apple Watch, or Siri.")
    }

    private func copy(_ note: Note) {
        UIPasteboard.general.string = note.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopied = false }
        }
    }
}

private struct NoteSection: Identifiable {
    enum ID: Hashable {
        case day(Date)
        case older
    }

    let id: ID
    let title: String
    let notes: [Note]
    let showsDate: Bool
}

#if DEBUG
private struct ScreenshotNoteSection: Identifiable {
    enum ID: Hashable {
        case day(Date)
        case older
    }

    let id: ID
    let title: String
    let notes: [AppStoreScreenshotContent.SampleNote]
    let showsDate: Bool
}
#endif

private struct RecordingSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let hidePrompt: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    setupRow(
                        icon: "lock.rectangle",
                        title: "Lock Screen",
                        text: "Touch and hold your Lock Screen, tap Customize, then add Teika’s Start Recording widget below the clock."
                    )

                    setupRow(
                        icon: "switch.2",
                        title: "Control Center",
                        text: "Open Control Center, touch and hold an empty area, tap Add a Control, then choose Teika’s Start Recording control."
                    )

                    setupRow(
                        icon: "applewatch",
                        title: "Apple Watch",
                        text: "Install Teika from the Watch app on your iPhone. Open it on your watch and tap the circle to record."
                    )

                    setupRow(
                        icon: "waveform",
                        title: "Siri",
                        text: "Say “Siri, start recording with Teika” on your iPhone. Teika opens and starts recording."
                    )
                }

                Section {
                    Button {
                        hidePrompt()
                        dismiss()
                    } label: {
                        Text("Don’t show again")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func setupRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    @Previewable @State var path: [Route] = []
    @Previewable @State var showsRecordingShortcutPrompt = true
    NavigationStack(path: $path) {
        NotesListView(
            path: $path,
            showsRecordingShortcutPrompt: $showsRecordingShortcutPrompt,
            showsEmptyState: false,
            showsAppStoreScreenshots: false
        )
    }
    .modelContainer(for: Note.self, inMemory: true)
}
