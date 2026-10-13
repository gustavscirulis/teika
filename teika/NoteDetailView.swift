import SwiftData
import SwiftUI

struct NoteDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isEditing: Bool
    @State private var didCopy = false
    @State private var isDeleting = false
    @State private var showsSaveError = false

    let note: Note

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05)
                .ignoresSafeArea()
            if canEditNote {
                TextEditor(text: noteText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .focused($isEditing)
                    .accessibilityLabel("Note text")
                    .padding()
                    // Readable measure on iPad and in landscape.
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard canEditNote else { return }
                    UIPasteboard.general.string = note.text
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(!canEditNote)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    guard canEditNote else { return }
                    isDeleting = true
                    isEditing = false
                    // Dismiss first: deleting while this view is still on screen leaves
                    // `body` re-evaluating against a destroyed model object.
                    dismiss()
                    context.delete(note)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!canEditNote)
            }
        }
        .onDisappear {
            saveChanges()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                saveChanges()
            }
        }
        .alert("Couldn’t save changes", isPresented: $showsSaveError) {
            Button("Retry") { saveChanges() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your edits are still here, but couldn’t be saved. Try again.")
        }
    }

    private var canEditNote: Bool {
        !isDeleting && !note.isDeleted && note.modelContext != nil
    }

    /// Guard both sides of the binding: the editor can finish a pending input event
    /// while deletion is dismissing this view.
    private var noteText: Binding<String> {
        Binding(
            get: { canEditNote ? note.text : "" },
            set: { text in
                guard canEditNote, note.text != text else { return }
                note.text = text
                saveChanges()
            }
        )
    }

    private func saveChanges() {
        guard canEditNote, context.hasChanges else { return }
        do {
            try context.save()
            showsSaveError = false
        } catch {
            // Keep the model's unsaved text intact so a retry can persist it.
            showsSaveError = true
        }
    }
}

#Preview {
    let store = try! NoteStore(inMemory: true)
    let note = try! store.add(text: "Hello from Parakeet.")
    NavigationStack {
        NoteDetailView(note: note)
    }
    .modelContainer(store.container)
}
