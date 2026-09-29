import SwiftUI
import PromptCore

/// Create surface: title, where it lives, and a markdown-like editor.
/// No transport controls here — Option-Space performs.
struct EditView: View {
    let doc: ScriptDocument
    /// The parsed script: the editor's word count comes from here rather
    /// than from re-scanning the body twice per keystroke.
    let index: ScriptIndex
    var wordsPerSecond: Double
    var folderPath: String
    var onRename: (String) -> Void
    @Binding var draftBody: String
    var onBodyCommitted: (String) -> Void
    @State private var pendingSave: Task<Void, Never>?

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
            // Where it lives, read-only. Moving is a library action, and it
            // belongs in the rail where the tree is — a menu of flat names
            // can't express nesting, which is the whole point of folders.
            Label(folderPath, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(CuePalette.muted)
                .help("Move this script from the sidebar")
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

    }
}
