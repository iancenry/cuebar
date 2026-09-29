import SwiftUI
import PromptCore

/// ⌘K quick cue palette: pick a cue, the bracketed snippet lands at the
/// editor's caret (or appends when the editor isn't up — which is also what
/// happens in Perform mode, where the insertion is committed straight to the
/// script). Rows show the exact text they insert so the syntax teaches itself.
struct CuePaletteView: View {
    var onInsert: (String) -> Void
    @State private var custom = ""
    @Environment(\.dismiss) private var dismiss

    private struct Option: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let snippet: String
    }

    private static let options: [Option] = [
        Option(title: "Pause — 2 seconds", subtitle: "Holds playback, then continues",
               snippet: "pause 2s"),
        Option(title: "Pause — wait for me", subtitle: "Stops and waits for Play",
               snippet: "pause"),
        Option(title: "Stop", subtitle: "Stops and waits for Play, like [pause]",
               snippet: "stop"),
        Option(title: "Breath — 1.5 seconds", subtitle: "Quick beat to breathe",
               snippet: "breath 1.5"),
        Option(title: "Hold — 1 second", subtitle: "Beat before a key line",
               snippet: "hold 1s"),
        Option(title: "Emphasis", subtitle: "Lean into the next line",
               snippet: "emphasis"),
        Option(title: "Smile", subtitle: "Stage direction",
               snippet: "smile"),
        Option(title: "Look at audience", subtitle: "Stage direction",
               snippet: "look at audience"),
        Option(title: "Slide change", subtitle: "Mark your deck position",
               snippet: "slide"),
        Option(title: "Drink", subtitle: "Water break",
               snippet: "drink"),
        Option(title: "Demo", subtitle: "Switch to the live demo",
               snippet: "demo"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Insert cue")
                    .font(.headline)
                Spacer()
                Text("⌘K")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider().opacity(0.35)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Self.options, id: \.id) { option in
                        Button {
                            onInsert(option.snippet)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: ScriptCue.iconName(for: option.snippet))
                                    .font(.callout)
                                    .foregroundStyle(CuePalette.peach)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.title)
                                        .font(.callout)
                                        .foregroundStyle(CuePalette.ink)
                                    Text(option.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(CuePalette.muted)
                                }
                                Spacer()
                                Text("[\(option.snippet)]")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "character.cursor.ibeam")
                            .font(.callout)
                            .foregroundStyle(CuePalette.peach)
                            .frame(width: 18)
                        TextField("Custom cue", text: $custom)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .onSubmit {
                                let text = custom.trimmingCharacters(in: .whitespaces)
                                guard !text.isEmpty else { return }
                                onInsert(text)
                            }
                        Button("Insert") {
                            let text = custom.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }
                            onInsert(text)
                        }
                        .buttonStyle(.borderless)
                        .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
        }
        .frame(width: 340, height: 420)
        .background(CuePalette.surface)
        .preferredColorScheme(.dark)
    }
}
