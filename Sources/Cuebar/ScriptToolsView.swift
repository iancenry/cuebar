import SwiftUI
import PromptCore

/// "Script Tools…" (⌥⇧A).
///
/// Three tools, in the order a presenter actually reaches for them:
///
/// 1. **Tidy for the ear** — offline, instant, no key. Strips the markup that
///    would otherwise be read aloud ("star star"), flattens links, turns
///    parentheticals into cues.
/// 2. **Pacing notes** — the same diagnosis as ⌥A, listed rather than
///    modified, because a finding you cannot see is not a finding.
/// 3. **Send to a model** — the user's own key, their own endpoint, and a
///    preview they have to accept before anything is written.
///
/// Nothing here writes to the script without a diff on screen. That is the
/// whole design: the tidying is safe enough to be automatic but not obvious
/// enough to be silent, and a model's rewrite is neither safe nor obvious.
struct ScriptToolsView: View {
    let script: String
    let settings: AISettings
    /// The pace the presenter will actually read at. "Trim to five minutes"
    /// budgeted the request at a hardcoded 140 wpm while the prompter runs at
    /// the user's own setting (150 by default), so the model was asked for a
    /// script a shade too long and the count on screen did not match the talk.
    var wordsPerMinute: Int = 140
    var onApply: (String) -> Void

    @State private var client = AIClient()
    @State private var task: AIScriptTask = .conversational
    /// Whether a key is stored. Read once on appear: `body` runs on every
    /// state change, and a keychain lookup is a Security.framework round trip
    /// that has no business being on the hot path of a diff preview.
    @State private var hasKey = false
    /// The offline proposal only. A model's answer lives in the client and
    /// is read straight from it: @Observable re-renders this view when it
    /// changes, so copying it into @State needed a 100 ms polling loop to
    /// notice — 600 wakeups to watch one value arrive.
    @State private var tidyProposal: String?
    @State private var notes: [ScriptAnalysis.Note] = []
    @State private var showsTidy = false
    @State private var showsNotes = false
    @Environment(\.dismiss) private var dismiss

    /// Computed once, on demand. It used to be a computed property read inside
    /// the Tidy button's *label*, which SwiftUI evaluates on every render of
    /// the body — so the tidy's cost was paid by every keystroke elsewhere in
    /// the sheet, on the main actor, before the button was ever pressed.
    @State private var tidyCache: String?
    private var tidy: String { tidyCache ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CuePalette.hairline)
            sidebar
            Divider().overlay(CuePalette.hairline)
            footer
        }
        .frame(width: 900, height: 620)
        .background(CuePalette.surface)
        .preferredColorScheme(.dark)
        .onAppear {
            notes = ScriptAnalysis.analyse(words: ScriptParser.words(script))
            hasKey = !(Keychain.read("scripttools") ?? "").isEmpty
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Script Tools")
                    .font(.headline)
                    .foregroundStyle(CuePalette.ink)
                Text("\(ScriptParser.wordCount(script)) words")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            }
            Spacer()
            if client.state == .sending {
                ProgressView().controlSize(.small)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private var sidebar: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                section("Offline")

                Button {
                    let tidied = TeleprompterFriendly.rewritten(script)
                    tidyCache = tidied
                    tidyProposal = tidied
                    showsTidy = true
                } label: {
                    tool("Tidy for the ear",
                         "Markup off, links flattened, asides turned into cues.",
                         symbol: "wand.and.stars",
                         enabled: !script.isEmpty)
                }
                .buttonStyle(.plain)

                Button {
                    tidyProposal = nil
                    showsNotes = true
                } label: {
                    tool("Pacing notes",
                         notes.isEmpty
                            ? "Nothing flagged."
                            : "\(notes.count) places worth a look before you present.",
                         symbol: "list.bullet.rectangle",
                         enabled: !notes.isEmpty)
                }
                .buttonStyle(.plain)

                Divider().overlay(CuePalette.hairline).padding(.vertical, 4)

                section("With your key")
                ForEach(AIScriptTask.allCases, id: \.self) { item in
                    Button {
                        send(item)
                    } label: {
                        tool(item.title, item.help, symbol: symbol(item),
                             enabled: hasKey && client.state != .sending)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                if !hasKey {
                    Text("Add a key in Settings → Script Tools.")
                        .font(.caption)
                        .foregroundStyle(CuePalette.muted)
                }
            }
            .padding(18)
            .frame(width: 320, alignment: .leading)

            Divider().overlay(CuePalette.hairline)

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(CuePalette.muted)
            .textCase(.uppercase)
    }

    private func tool(_ title: String, _ help: String, symbol: String,
                      enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(enabled ? CuePalette.peach : CuePalette.muted)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(enabled ? CuePalette.ink : CuePalette.ink.opacity(0.5))
                Text(help)
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.55)
    }

    private func symbol(_ item: AIScriptTask) -> String {
        switch item {
        case .conversational: return "bubble.left.and.bubble.right"
        case .trim: return "scissors"
        case .plain: return "text.book.closed"
        case .stageDirections: return "pause.circle"
        }
    }

    // MARK: - Preview

    /// What is being proposed right now: the offline tidy, or whatever the
    /// model answered with.
    private var proposal: String? {
        if showsTidy { return tidyProposal }
        return client.result
    }

    @ViewBuilder private var preview: some View {
        if showsNotes {
            NotesPreview(notes: notes, script: script)
        } else if let proposal {
            DiffPreview(original: script, proposed: proposal,
                        title: showsTidy ? "Tidy for the ear" : task.title)
        } else if case .failed(let message) = client.state {
            failure(message)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 26))
                .foregroundStyle(CuePalette.muted)
            Text("Pick a tool")
                .font(.callout.weight(.medium))
                .foregroundStyle(CuePalette.ink)
            Text("Nothing is written until you accept a preview.")
                .font(.caption)
                .foregroundStyle(CuePalette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(CuePalette.peach)
            Text(message)
                .font(.callout)
                .foregroundStyle(CuePalette.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let issue = client.issue {
                Text(issue.recovery)
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            }
            Button("Try again") {
                send(task)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let proposal {
                let changes = ScriptDiff.changeCount(from: script, to: proposal)
                Text("\(changes) change\(changes == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
                if changes == 0 {
                    Text("· nothing to do")
                        .font(.caption)
                        .foregroundStyle(CuePalette.inkMuted)
                }
                Spacer()
                Button("Discard") {
                    tidyProposal = nil
                    showsTidy = false
                    client.reset()
                }
                Button("Apply") {
                    onApply(proposal)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(changes == 0)
            } else {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(18)
    }

    private func send(_ item: AIScriptTask) {
        task = item
        showsNotes = false
        showsTidy = false
        tidyProposal = nil
        // The answer lands in `client.result` and the preview reads it from
        // there: @Observable re-renders this view when it changes, so there is
        // no polling loop and no second copy of the rewrite to fall out of
        // step with the first.
        client.run(item, script: script, settings: settings,
                   wordsPerMinute: wordsPerMinute)
    }

}

/// Old and new, side by side by line. Line-granular on purpose: a
/// character-level diff of a 4000-word talk is a wall of red, and the
/// presenter needs to see the four paragraphs that moved.
struct DiffPreview: View {
    let original: String
    let proposed: String
    let title: String
    var onSelectChunk: ((ScriptDiff.Chunk) -> Void)?

    private var chunks: [ScriptDiff.Chunk] { ScriptDiff.chunks(from: original, to: proposed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CuePalette.ink)
                Spacer()
                HStack(spacing: 10) {
                    label("unchanged", CuePalette.inkMuted)
                    label("changed", CuePalette.peach)
                    label("added", CuePalette.live)
                    label("removed", Color.red.opacity(0.8))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        row(chunk)
                    }
                    if chunks.isEmpty {
                        Text("Identical.")
                            .font(.callout)
                            .foregroundStyle(CuePalette.muted)
                            .padding(18)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
    }

    private func label(_ text: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(CuePalette.muted)
        }
    }

    @ViewBuilder private func row(_ chunk: ScriptDiff.Chunk) -> some View {
        switch chunk {
        case .same(let line):
            Text(line)
                .font(.callout)
                .foregroundStyle(CuePalette.inkMuted)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .changed(let old, let new):
            VStack(alignment: .leading, spacing: 4) {
                Text(old)
                    .font(.callout)
                    .foregroundStyle(Color.red.opacity(0.75))
                    .strikethrough(color: Color.red.opacity(0.4))
                Text(new)
                    .font(.callout)
                    .foregroundStyle(CuePalette.ink)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CuePalette.peach.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .removed(let line):
            Text(line)
                .font(.callout)
                .foregroundStyle(Color.red.opacity(0.75))
                .strikethrough(color: Color.red.opacity(0.4))
                .padding(.vertical, 2)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        case .added(let line):
            Text(line)
                .font(.callout)
                .foregroundStyle(CuePalette.ink)
                .padding(.vertical, 2)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CuePalette.live.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The pacing notes, listed with the sentence each one is about.
struct NotesPreview: View {
    let notes: [ScriptAnalysis.Note]
    let script: String

    private var words: [String] { ScriptParser.words(script) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pacing notes")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CuePalette.ink)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(quote(note))
                            .font(.callout)
                            .foregroundStyle(CuePalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Text(note.reason)
                            if let cue = note.cue {
                                Text("· suggests [\(cue)]")
                                    .foregroundStyle(CuePalette.peach)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(CuePalette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(CuePalette.card, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(18)
        }
    }

    private func quote(_ note: ScriptAnalysis.Note) -> String {
        let lower = max(0, note.wordIndex - 4)
        let upper = min(words.count, note.wordIndex + 14)
        guard lower < upper else { return "" }
        var out = words[lower..<upper].joined(separator: " ")
        if lower > 0 { out = "… " + out }
        if upper < words.count { out += " …" }
        return out
    }
}