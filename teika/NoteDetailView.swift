import SwiftData
import SwiftUI

struct NoteDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    let note: Note

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05)
                .ignoresSafeArea()
            ScrollView {
                Text(note.isDeleted ? "" : note.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
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
                    UIPasteboard.general.string = note.text
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    // Dismiss first: deleting while this view is still on screen leaves
                    // `body` re-evaluating against a destroyed model object.
                    dismiss()
                    context.delete(note)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(note: Note(text: "Hello from Parakeet."))
    }
    .modelContainer(for: Note.self, inMemory: true)
}
