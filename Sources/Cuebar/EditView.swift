import SwiftUI
import PromptCore

/// Create surface: title, category, and a markdown-like editor.
/// No transport controls here — Option-Space performs.
struct EditView: View {
    let doc: ScriptDocument
    /// The parsed script: the editor's word count comes from here rather
    /// than from re-scanning the body twice per keystroke.
    let index: ScriptIndex
    var wordsPerSecond: Double
    var categories: [String]
    var onRename: (String) -> Void
    var onCategory: (String) -> Void
    @Binding var draftBody: String
    var onBodyCommitted: (String) -> Void
    @State private var pendingSave: Task<Void, Never>?
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""

    private var cueCount: Int { index.cues.filter { $0 != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: Binding(
                get: { doc.title },
                set: { onRename($0) }
            ))
            .textFieldStyle(.plain)
            .font(.largeTitle.bold())
            .foregroundStyle(CuePalette.ink)
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
                .foregroundStyle(CuePalette.ink)
                .scrollContentBackground(.hidden)
                .padding(12)
                // Opaque, not a translucent card: the field is right behind
                // this now, and a 6% white wash over it would put the whole
                // fresco in the writing surface.
                .background(CuePalette.surface, in: RoundedRectangle(cornerRadius: CuePalette.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: CuePalette.cardRadius)
                        .strokeBorder(CuePalette.hairline, lineWidth: 1)
                }
                .onChange(of: draftBody) { _, new in
                    pendingSave?.cancel()
                    pendingSave = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        onBodyCommitted(new)
                    }
                }
            HStack(spacing: 8) {
                Text("\(index.wordCount) words")
                Text("·")
                Text(ReadingWindow.durationString(wordCount: index.wordCount,
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
