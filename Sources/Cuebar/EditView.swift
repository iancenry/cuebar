import SwiftUI
import PromptCore

/// Create surface: title, category, and a markdown-like editor.
/// No transport controls here — Option-Space performs.
struct EditView: View {
    let doc: ScriptDocument
    let tokens: [ScriptToken]
    var wordsPerSecond: Double
    var categories: [String]
    var onRename: (String) -> Void
    var onCategory: (String) -> Void
    @Binding var draftBody: String
    var onBodyCommitted: (String) -> Void
    @State private var pendingSave: Task<Void, Never>?
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""

    private var cueCount: Int { tokens.reduce(0) { $0 + ($1.isCue ? 1 : 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: Binding(
                get: { doc.title },
                set: { onRename($0) }
            ))
            .textFieldStyle(.plain)
            .font(.largeTitle.bold())
            Menu {
                ForEach(categories, id: \.self) { name in
                    Button(name) { onCategory(name) }
                }
                Divider()
                Button("New category…") { showingNewCategory = true }
            } label: {
                Label(doc.category, systemImage: "tag")
                    .font(.callout)
                    .foregroundStyle(CuePalette.muted)
            }
            .menuStyle(.borderlessButton)
            TextEditor(text: $draftBody)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(CuePalette.card, in: RoundedRectangle(cornerRadius: CuePalette.cardRadius))
                .onChange(of: draftBody) { _, new in
                    pendingSave?.cancel()
                    pendingSave = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        onBodyCommitted(new)
                    }
                }
            HStack(spacing: 8) {
                Text("\(doc.wordCount) words")
                Text("·")
                Text(ReadingWindow.durationString(wordCount: doc.wordCount,
                                                 wordsPerSecond: wordsPerSecond))
                if cueCount > 0 {
                    Text("·")
                    Text("\(cueCount) cues")
                }
                Spacer()
                Text("⌘K to insert cues")
                    .foregroundStyle(CuePalette.muted)
                Text("·")
                Text("Option-Space to perform")
                    .foregroundStyle(CuePalette.muted)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(24)
        .alert("New category", isPresented: $showingNewCategory) {
            TextField("Name", text: $newCategoryName)
            Button("Add") {
                let name = newCategoryName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { onCategory(name) }
                newCategoryName = ""
            }
            Button("Cancel", role: .cancel) { newCategoryName = "" }
        }
    }
}
