import SwiftUI
import PromptCore

/// Live reading preview shared by every settings tab. Renders the same
/// WordPill / CueBadge primitives as the prompter so typography, reading,
/// and display changes are immediately visible without leaving Settings.
struct ReadingPreview: View {
    let settings: CueSettings

    /// Compact base size keeps the preview inside the 620pt settings window.
    private var fontSize: Double { settings.textSize.points }

    private static let sampleTokens: [ScriptToken] = ScriptParser.parse(
        "Welcome to Cuebar [pause]\n\nRead calmly here, one line at a time."
    )

    /// Demo position: first word read, second current — shows past dimming
    /// plus the current-word highlight style in one glance.
    private var demoCurrentIndex: Int { 1 }

    private var visibleTokens: [ScriptToken] {
        Self.sampleTokens.filter {
            $0.isParagraphBreak || settings.showCues || !$0.isCue
        }
    }

    private struct PreviewRow {
        let token: ScriptToken
        let wordIndex: Int // -1 for cues and breaks
    }

    private var rows: [PreviewRow] {
        var out: [PreviewRow] = []
        var wi = 0
        for t in visibleTokens {
            if t.isWord {
                out.append(PreviewRow(token: t, wordIndex: wi))
                wi += 1
            } else {
                out.append(PreviewRow(token: t, wordIndex: -1))
            }
        }
        return out
    }

    private var paragraphs: [[PreviewRow]] {
        var groups: [[PreviewRow]] = [[]]
        for row in rows {
            if row.token.isParagraphBreak {
                groups.append([])
            } else {
                groups[groups.count - 1].append(row)
            }
        }
        let nonEmpty = groups.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? [[]] : nonEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .center) {
                settings.surfaceStyle.color
                VStack(alignment: settings.textAlignment == .center ? .center : .leading,
                       spacing: fontSize * settings.clampedParagraphSpacing) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                        FlowLayout(spacing: max(6, fontSize * 0.22),
                                   lineSpacing: fontSize * settings.lineSpacing) {
                            ForEach(Array(para.enumerated()), id: \.offset) { _, row in
                                switch row.token {
                                case .word(let w):
                                    WordPill(word: w,
                                             isPast: row.wordIndex < demoCurrentIndex,
                                             isCurrent: row.wordIndex == demoCurrentIndex,
                                             settings: settings,
                                             fontSize: fontSize)
                                case .cue(let c):
                                    CueBadge(text: CueBadge.label(for: c),
                                             settings: settings, fontSize: fontSize)
                                case .paragraphBreak:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: settings.readingWidth.map { min($0, 520) } ?? .infinity,
                       alignment: settings.textAlignment == .center ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                if settings.showCenterLine {
                    Rectangle()
                        .fill(CuePalette.peach.opacity(0.25))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
            .frame(minHeight: 110)

            HStack(spacing: 8) {
                if settings.showProgress {
                    ProgressView(value: 0.4)
                        .progressViewStyle(.linear).tint(CuePalette.peach)
                        .frame(maxWidth: 120)
                    Text("40%")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                Text("\(Int(settings.wordsPerMinute.rounded())) wpm · \(settings.smoothScroll ? "Smooth" : "Stepped")")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preview, \(Int(settings.wordsPerMinute.rounded())) words per minute")
        }
    }
}
