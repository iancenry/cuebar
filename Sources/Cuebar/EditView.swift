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
    /// Words per *minute*, for the estimate. The engine works in words
    /// per second; a presenter plans in WPM.
    var wordsPerMinute: Double
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
            // Where it lives, and the one structural thing you can add
            // from in here. Moving is a library action and belongs in the
            // rail, where the tree is — a menu of flat names can't express
            // nesting, which is the whole point of folders.
            HStack(spacing: 8) {
                Label(folderPath, systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(CuePalette.muted)
                    .help("Move this script from the sidebar")
                Spacer()
                // A menu, not a button. Two reasons, and the second is the
                // real one: a label reading "Section" doesn't say what
                // happens, and the parser has always understood three levels
                // while the button could only ever insert `##`. Naming the
                // levels teaches the convention *and* makes the whole format
                // reachable — the button was a third of the feature wearing
                // a label that implied all of it.
                Menu {
                    Button("Major section") { insertSection(level: 1) }
                    Button("Section") { insertSection(level: 2) }
                    Button("Sub-section") { insertSection(level: 3) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.divider")
                        Text("Add heading")
                    }
                    .font(.caption)
                    .foregroundStyle(CuePalette.ink.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(CuePalette.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(CuePalette.hairline, lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(editorTextView == nil)
                .help("Insert a heading above the line you're on: #, ## or ###")
                .accessibilityLabel("Add heading")
            }
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
            // The header a presenter actually plans against. Duration is
            // derived from the *live* reading speed, so changing the WPM
            // slider changes the estimate here and in the sidebar at the
            // same moment — the number they are judging is the number that
            // will happen.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(index.wordCount.formatted())
                    .foregroundStyle(CuePalette.ink)
                Text("words")
                Text("·")
                Text(ReadingWindow.clockString(
                    seconds: Double(index.wordCount) / max(wordsPerSecond, 0.01)))
                    .foregroundStyle(CuePalette.ink)
                Text("at \(Int(wordsPerMinute.rounded())) WPM")
                if index.sectionCount > 0 {
                    Text("·")
                    Text("\(index.sectionCount) section\(index.sectionCount == 1 ? "" : "s")")
                }
                if cueCount > 0 {
                    Text("·")
                    Text("\(cueCount) cue\(cueCount == 1 ? "" : "s")")
                }
                Spacer()
                Text("⌘K cues")
                Text("·")
                Text("## adds a section")
            }
            .font(.caption)
            .foregroundStyle(CuePalette.inkMuted)
            .monospacedDigit()
        }
        .padding(24)
    }

    /// The script editor's own `NSTextView`, reached through the responder
    /// chain.
    ///
    /// Not through `TextEditor(text:selection:)`. Binding the selection
    /// looks like the obvious way to learn the caret, but the editor's body
    /// re-runs on every keystroke (the draft is a binding, and the save is
    /// debounced behind it), so a bound selection is re-applied mid-edit and
    /// AppKit grows a second insertion point — a visible duplicate caret on
    /// the line below. Asking the text view itself has no such feedback
    /// loop.
    private var editorTextView: NSTextView? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard let view = window?.firstResponder as? NSTextView, view.isEditable else {
            return nil
        }
        return view
    }

    /// Insert a `##` heading above the caret's line and put the caret in
    /// it.
    ///
    /// The text is changed through the binding, never by assigning
    /// `textView.string`: writing to the view directly and then having
    /// SwiftUI apply the same value back is how a caret ends up in two
    /// places. The caret is restored on the next turn, once the new text has
    /// landed. A button with no caret — the editor not focused — does
    /// nothing, and says so by being disabled.
    private func insertSection(level: Int) {
        guard let view = editorTextView else { return }
        let plan = SectionInsert.plan(for: view.string, caret: view.selectedRange().location,
                                     level: level)
        draftBody = plan.text
        let clamped = min(plan.caret, plan.text.utf16.count)
        DispatchQueue.main.async {
            view.setSelectedRange(NSRange(location: clamped, length: 0))
        }
    }
}
