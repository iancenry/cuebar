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
    /// Live chord text for the two import buttons below. Read only — no
    /// `.keyboardShortcut` on either, because the key monitor is the single
    /// owner of every chord in the app.
    var shortcuts: ShortcutMap = .default
    var onRename: (String) -> Void
    /// The two ways to bring in a script that are not the file panel. They
    /// live here because this is the surface somebody with a document in
    /// front of them is looking at, and a command with no button and no
    /// chord they would guess is a command that does not exist.
    var onPasteScript: () -> Void = {}
    var onWebImport: () -> Void = {}
    /// Files that arrived as a path in the text and turned out to be
    /// documents. One more entry point into the same import pipeline.
    var onImportFiles: ([URL]) -> Void = { _ in }
    @Binding var draftBody: String
    var onBodyCommitted: (String) -> Void
    /// Set when this script's file could not be written. A teleprompter that
    /// loses an edit without saying so is the worst thing this app can do, so
    /// it says so here, on the script it happened to.
    var saveFailure: String? = nil
    var unreadableCount: Int = 0
    var onRevealLibrary: () -> Void = {}
    /// Set when this script's file was changed by somebody else while Cuebar
    /// had it open. Cuebar will not silently pick a winner: the text in the
    /// editor is the presenter's, and the text in the file is whatever they
    /// wrote in their own editor an instant ago.
    var changedOnDisk: Bool = false
    var onAcceptDiskVersion: () -> Void = {}
    var onKeepLocalVersion: () -> Void = {}
    @State private var pendingSave: Task<Void, Never>?

    private var cueCount: Int { index.cues.filter { $0 != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if changedOnDisk {
                LibraryWarning(kind: .changedOnDisk,
                               onReveal: { },
                               onAccept: onAcceptDiskVersion,
                               onKeep: onKeepLocalVersion)
            } else if saveFailure != nil || unreadableCount > 0 {
                LibraryWarning(kind: .library(saveFailure: saveFailure,
                                              unreadableCount: unreadableCount),
                               onReveal: onRevealLibrary,
                               onAccept: {}, onKeep: {})
            }
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
                // Bold and italic, next to the heading menu: three ways to
                // say something, no more. Lists and quotes are deliberately
                // absent — a `- ` or `> ` at the start of a line is read aloud
                // today, and supporting them properly means the parser, the
                // prompter and export all change. That is a later decision, not
                // a button.
                Button { insertEmphasis(marker: "**") } label: {
                    Label("Bold", systemImage: "bold")
                }
                .help("Bold the selection, or the word at the caret")
                Button { insertEmphasis(marker: "*") } label: {
                    Label("Italic", systemImage: "italic")
                }
                .help("Italicise the selection, or the word at the caret")
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
                // No drop handler of our own here. Text drops are the text
                // view's own job and it does them well. Files were the
                // problem: `NSTextView` answers a file drop by inserting the
                // file's *path* as text, before any drop target is asked,
                // so a dropped `.docx` landed in the script as its own
                // filename. The change handler below takes the path back out
                // and imports the document instead — the text view's
                // `readablePasteboardTypes` has no setter, so there is no
                // way to stop it wanting files in the first place.
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
                .onChange(of: draftBody) { old, new in
                    // A dropped file arrives as its own path, typed into the
                    // script by the text view before any drop target was
                    // asked. Take it back out and import the document
                    // instead. The existence check is here rather than in
                    // `ScriptText.droppedFile` because that one is pure.
                    if let path = ScriptText.droppedFile(from: old, to: new),
                       FileManager.default.fileExists(atPath: path) {
                        draftBody = old
                        onImportFiles([URL(fileURLWithPath: path)])
                        return
                    }
                    pendingSave?.cancel()
                    pendingSave = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        onBodyCommitted(new)
                    }
                }
            // An empty script is where somebody with a Word document in
            // front of them lands, so the ways in are named *here* rather
            // than only in a menu. A drop target nobody can see is a target
            // that reads as broken.
            if index.wordCount == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                            .font(.callout)
                            .foregroundStyle(CuePalette.peach)
                        Text("Drop a .docx, .pdf, .md or .txt anywhere on this window.")
                            .font(.callout)
                            .foregroundStyle(CuePalette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        importButton("Paste as New Script",
                                     icon: "doc.on.clipboard",
                                     chord: shortcuts.chord(for: .newScriptFromClipboard),
                                     action: onPasteScript)
                        importButton("Import Web Page…",
                                     icon: "globe",
                                     chord: shortcuts.chord(for: .importFromWeb),
                                     action: onWebImport)
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
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
                let slides = index.cuePlan.slideCueCount
                if slides > 0 {
                    Text("·")
                    Text("\(slides) slide\(slides == 1 ? "" : "s")")
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

    /// One of the two import buttons. A `Menu` in this window's chrome is
    /// not an option: a SwiftUI `Menu` with `.onHover` on it never opened,
    /// which is how three commands sat there doing nothing. Buttons.
    private func importButton(_ title: String, icon: String, chord: KeyChord,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.callout.weight(.medium))
                Text(chord.description)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CuePalette.inkMuted)
            }
            .foregroundStyle(CuePalette.peach)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(CuePalette.card, in: Capsule())
            .overlay { Capsule().strokeBorder(CuePalette.hairline, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title + " (" + chord.description + ")")
    }

    /// Dropped text goes in at the caret, through the binding — never by
    /// assigning `textView.string`, which is how a caret ends up in two
    /// places (see `insertSection`).
    private func insertDroppedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = draftBody as NSString
        let view = editorTextView
        let location = min(view?.selectedRange().location ?? current.length, current.length)
        let replacement = ScriptText.trimLineIndents(trimmed)
        draftBody = current.replacingCharacters(in: NSRange(location: location, length: 0),
                                                with: replacement)
        let caret = location + (replacement as NSString).length
        DispatchQueue.main.async {
            view?.setSelectedRange(NSRange(location: caret, length: 0))
        }
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
    private func insertEmphasis(marker: String) {
        guard let view = editorTextView else { return }
        let plan = EmphasisInsert.plan(for: view.string, selection: view.selectedRange(),
                                      marker: marker)
        draftBody = plan.text
        let clamped = min(plan.caret, plan.text.utf16.count)
        // The next turn, once the new text has landed — the same reason
        // `insertSection` defers rather than setting the range immediately.
        DispatchQueue.main.async {
            view.setSelectedRange(plan.selected ?? NSRange(location: clamped, length: 0))
        }
    }

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


/// A library problem, said plainly.
///
/// Three facts the sidebar has no room for and the editor does: an edit that
/// could not be written to disk, files in the library that could not be read,
/// and — the one that needs a decision — a script that changed underneath us.
/// All non-modal, because stopping a presenter mid-run to explain a
/// permissions bit would be worse than the problem. None silent, because a
/// teleprompter that quietly loses a script is not a teleprompter.
private struct LibraryWarning: View {
    enum Kind {
        case changedOnDisk
        case library(saveFailure: String?, unreadableCount: Int)
    }

    var kind: Kind
    var onReveal: () -> Void
    var onAccept: () -> Void
    var onKeep: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .foregroundStyle(CuePalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(10)
        .background(CuePalette.card, in: RoundedRectangle(cornerRadius: CuePalette.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: CuePalette.cardRadius)
                .strokeBorder(CuePalette.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch kind {
        case .changedOnDisk:
            // "Use the file" is the left button because it is the one that
            // keeps work somebody else just did, and losing that is the
            // outcome nobody can undo.
            Button("Use the File", action: onAccept)
                .buttonStyle(.link)
                .font(.callout)
            Button("Keep Mine", action: onKeep)
                .buttonStyle(.link)
                .font(.callout)
        case .library:
            Button("Show Files", action: onReveal)
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private var message: String {
        switch kind {
        case .changedOnDisk:
            return "This script changed on disk."
        case .library(let saveFailure, let unreadableCount):
            var parts: [String] = []
            if saveFailure != nil { parts.append("Not saved") }
            if unreadableCount == 1 { parts.append("1 file in the library could not be read") }
            else if unreadableCount > 1 {
                parts.append("\(unreadableCount) files in the library could not be read")
            }
            return parts.joined(separator: " · ")
        }
    }
}
