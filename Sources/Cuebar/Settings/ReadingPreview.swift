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
    private static let sampleIndex = ScriptIndex(tokens: sampleTokens)

    /// Demo position: first word read, second current — shows past dimming
    /// plus the current-word highlight style in one glance.
    private var demoCurrentIndex: Int { 1 }

    /// The same tested grouping the prompter uses (paragraph gaps, cue
    /// filtering, pre-interpreted cues) instead of a second implementation
    /// that could drift from it.
    private var paragraphs: [[ReadingWindow.TokenRow]] {
        let pageSize = max(Self.sampleIndex.wordCount, 1)
        return Self.sampleIndex.pageParagraphRows(page: 0, pageSize: pageSize,
                                                 showCues: settings.showCues)
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
                                case .word(let w, let emphasised):
                                    WordPill(word: w,
                                             isPast: row.wordIndex < demoCurrentIndex,
                                             isCurrent: row.wordIndex == demoCurrentIndex,
                                             settings: settings,
                                             fontSize: fontSize,
                                             isEmphasised: emphasised)
                                case .cue:
                                    if let cue = row.cue {
                                        CueBadge(cue: cue, settings: settings, fontSize: fontSize)
                                    }
                                case .section:
                                    SectionHeading(name: row.section?.name ?? "",
                                                    level: row.section?.level ?? 2,
                                                    fontSize: fontSize)
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
            // The preview mirrors when the prompter does, so the Display
            // tab shows the effect instead of describing it.
            .scaleEffect(x: settings.mirror.flipsHorizontally ? -1 : 1,
                         y: settings.mirror.flipsVertically ? -1 : 1)
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
