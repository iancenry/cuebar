import SwiftUI
import PromptCore

/// Shared kind → SF Symbol map (badges + the cue palette).
extension ScriptCue {
    static func iconName(for cue: String) -> String {
        switch interpret(cue).kind {
        case .pause: return "pause.fill"
        case .wait: return "hourglass"
        case .hold: return "hand.raised.fill"
        case .breath: return "wind"
        case .stop: return "stop.fill"
        case .smile: return "face.smiling"
        case .look: return "eye"
        case .emphasis: return "exclamationmark"
        case .demo: return "play.rectangle"
        case .drink: return "drop"
        case .slide: return "rectangle.on.rectangle"
        case .other: return "tag"
        }
    }
}

/// ⌘K quick cue palette: pick a cue, the bracketed snippet lands at the
/// editor's caret (or appends when nothing is focused). Rows show the
/// exact text they insert so the syntax teaches itself.
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
        Option(title: "Pause — wait for me", subtitle: "Auto-pauses until you press Play",
               snippet: "pause"),
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
