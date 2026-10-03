import SwiftUI
import PromptCore

/// ⇧⌘U: fetch a page and turn it into a script.
///
/// A sheet with a preview, not a silent fetch. Three reasons: the URL is
/// usually pasted and pasted URLs are sometimes wrong, the conversion drops
/// a lot of a real page's furniture, and a talk built on the wrong article
/// is a bad way to find out in front of an audience. The preview is the
/// first paragraph, the word count, and the estimated running time — the
/// three things that tell you whether this is the right page.
struct WebImportView: View {
    /// A URL handed over by a `cuebar://` link, consumed on appear. Static
    /// because the sheet is created by the app and this is the only channel
    /// it has; it is cleared on use so a later plain ⇧⌘U opens empty rather
    /// than re-fetching the last thing.
    nonisolated(unsafe) static var pendingURL: String?

    var onImport: (ImportedScript) -> Void
    @State private var address = ""
    @State private var state: State = .idle
    @State private var preview: ImportedScript?
    @Environment(\.dismiss) private var dismiss

    private enum State: Equatable {
        case idle, fetching, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            content
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 520, height: 380)
        .background(CuePalette.surface)
        .preferredColorScheme(.dark)
        .task {
            if let pending = Self.pendingURL {
                Self.pendingURL = nil
                address = pending
            }
            if !address.isEmpty { await fetch() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Import web page")
                    .font(.headline)
                    .foregroundStyle(CuePalette.ink)
                Spacer()
                Text("⇧⌘U")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(CuePalette.inkMuted)
            }
            HStack(spacing: 8) {
                TextField("https://example.com/talk", text: $address)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(CuePalette.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(CuePalette.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(CuePalette.hairline, lineWidth: 1)
                    }
                    .onSubmit { Task { await fetch() } }
                Button("Fetch") { Task { await fetch() } }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty
                              || state == .fetching)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .fetching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching…")
                        .font(.callout)
                        .foregroundStyle(CuePalette.muted)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(CuePalette.peach)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                Text("The page's own text becomes the script. Navigation, scripts and styling are dropped.")
                    .font(.callout)
                    .foregroundStyle(CuePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview {
                Divider().opacity(0.35)
                Text(preview.title)
                    .font(.headline)
                    .foregroundStyle(CuePalette.ink)
                    .lineLimit(2)
                Text(leadingWords(of: preview.body))
                    .font(.caption)
                    .foregroundStyle(CuePalette.inkMuted)
                    .lineLimit(4)
                HStack(spacing: 6) {
                    Text("\(wordCount) words")
                    Text("·")
                    // 150 wpm, the middle of a talk: enough to notice that
                    // the article is forty minutes rather than four.
                    Text("≈ " + ReadingWindow.clockString(seconds: Double(wordCount) / 2.5))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(CuePalette.stone)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Text("Fetched pages keep their title. Nothing is sent but the request.")
                .font(.caption2)
                .foregroundStyle(CuePalette.inkMuted)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Import") {
                if let preview { onImport(preview) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(preview == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var wordCount: Int {
        preview.map { ScriptParser.wordCount($0.body) } ?? 0
    }

    private func leadingWords(of body: String) -> String {
        let words = ScriptParser.words(body)
        let head = words.prefix(70).joined(separator: " ")
        return words.count > 70 ? head + "\u{2026}" : head
    }

    /// Fetch off the main actor, decide on it. The hop is explicit because
    /// the completion comes back on a URLSession queue — see AGENTS.md.
    private func fetch() async {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = WebPage.url(in: text) else {
            state = .failed("That isn't a web address. It needs to start with https://")
            preview = nil
            return
        }
        state = .fetching
        preview = nil
        do {
            let script = try await ScriptWeb.script(for: url)
            preview = script
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}