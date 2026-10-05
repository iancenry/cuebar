import SwiftUI
import PromptCore

/// "Pacing Notes" (⌥A): what in this script is hard to *say*, found without a
/// key, a network or a model.
///
/// The findings are the deliverable, not the fixes. Somebody handed a talk
/// that has a 30-word sentence in it usually knows what to do about the
/// sentence; what they cannot do by eye is find all of them. So every note
/// can stage its own cue, and the batch button is there for the script that
/// needs five, but the sheet never edits the text behind their back.
struct PacingNotesView: View {
    let script: String
    var onApply: (String) -> Void

    @State private var notes: [ScriptAnalysis.Note] = []
    @State private var staged: Set<Int> = []
    /// Parsed once, here, rather than by a computed property.
    ///
    /// It was computed, and `quote` reads it three times per row — so a body
    /// pass re-parsed the script once per row plus once for the header. The
    /// list is an eager `VStack`, so every row was evaluated: measured at
    /// ~334 ms per pass for a 1200-word script with 96 notes, re-run on every
    /// click and every invalidation, on the main actor.
    @State private var words: [String] = []
    @Environment(\.dismiss) private var dismiss

    /// Parse and analyse together, once per script.
    private func analyse() {
        words = ScriptParser.words(script)
        notes = ScriptAnalysis.analyse(words: words)
        staged = Set(notes.indices.filter { notes[$0].cue != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CuePalette.hairline)
            if notes.isEmpty {
                empty
            } else {
                list
            }
            Divider().overlay(CuePalette.hairline)
            footer
        }
        .frame(width: 620, height: 520)
        .background(CuePalette.surface)
        .preferredColorScheme(.dark)
        .onAppear { analyse() }
        .onChange(of: script) { _, _ in analyse() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pacing Notes")
                    .font(.headline)
                    .foregroundStyle(CuePalette.ink)
                Text(notes.isEmpty
                     ? "\(words.count) words, nothing flagged"
                     : "\(notes.count) of \(words.count) words worth a look")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(CuePalette.live)
            Text("This reads out of the box")
                .font(.callout.weight(.medium))
                .foregroundStyle(CuePalette.ink)
            Text("No long sentences, no breathless runs, nothing written-talk.")
                .font(.caption)
                .foregroundStyle(CuePalette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(notes.enumerated()), id: \.offset) { offset, note in
                    row(offset: offset, note: note)
                    if offset < notes.count - 1 {
                        Divider().overlay(CuePalette.hairline.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func row(offset: Int, note: ScriptAnalysis.Note) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(note.kind))
                .font(.system(size: 13))
                .foregroundStyle(tint(note.kind))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(quote(note))
                    .font(.callout)
                    .foregroundStyle(CuePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note.reason)
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            }
            Spacer(minLength: 8)
            if let cue = note.cue {
                Button(staged.contains(offset) ? "Cued" : "Add cue") {
                    if staged.contains(offset) { staged.remove(offset) } else { staged.insert(offset) }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(staged.contains(offset) ? CuePalette.live : CuePalette.peach)
                .buttonStyle(.plain)
                .help("Stage [\(cue)] before this line")
            }
        }
        .padding(.vertical, 11)
    }

    /// The words the note is about, with a little context either side — the
    /// presenter recognises a line far faster than a sentence number.
    private func quote(_ note: ScriptAnalysis.Note) -> String {
        let lower = max(0, note.wordIndex - 4)
        let upper = min(words.count, note.wordIndex + 12)
        guard lower < upper else { return "" }
        var out = words[lower..<upper].joined(separator: " ")
        if lower > 0 { out = "… " + out }
        if upper < words.count { out += " …" }
        return out
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if staged.isEmpty {
                Text("Select notes to stage their cues.")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            } else {
                Text("\(staged.count) selected")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            }
            Spacer()
            Button("Stage \(staged.count) cues") {
                let points = CueInsertion.stagingPoints(
                    for: notes.enumerated().filter { staged.contains($0.offset) }.map(\.element))
                onApply(CueInsertion.inserting(cues: points, in: script))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(staged.isEmpty)
        }
        .padding(18)
    }

    private func icon(_ kind: ScriptAnalysis.Note.Kind) -> String {
        switch kind {
        case .longSentence: return "text.line.first.and.arrowtriangle.forward"
        case .breathless: return "lungs"
        case .tongueTwister: return "mouth"
        case .stiffTransition: return "arrow.turn.down.right"
        case .tangledClause: return "arrow.triangle.branch"
        case .emphasis: return "bolt"
        }
    }

    private func tint(_ kind: ScriptAnalysis.Note.Kind) -> Color {
        switch kind {
        case .emphasis: return CuePalette.live
        case .stiffTransition, .tangledClause: return CuePalette.peach
        case .longSentence, .breathless, .tongueTwister: return CuePalette.stone
        }
    }
}