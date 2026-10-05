import SwiftUI
import PromptCore

/// The pieces the reading surface is built from: page metrics, the
/// page nav bar, and the token rows (words + cue badges). Shared with
/// the settings preview, so they cannot live inside the screen file.
struct PrompterMetrics {
    let pageCount: Int
    let enginePage: Int
    let visiblePage: Int

    /// Pure arithmetic on the index — no token walk, so the cost does not
    /// grow with script length.
    init(index: ScriptIndex, pageSize: Int, currentWord: Int?, follow: Bool, page: Int) {
        pageCount = index.pageCount(pageSize: pageSize)
        enginePage = index.page(forWord: currentWord, pageSize: pageSize)
        visiblePage = follow ? enginePage : min(max(0, page), max(0, pageCount - 1))
    }
}

struct PageControls: View {
    let page: Int
    let count: Int
    let follow: Bool
    var onPrev: () -> Void
    var onNext: () -> Void
    var onFollow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPrev) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(page <= 0)
                .accessibilityLabel("Previous page")
            Text("Page \(page + 1) of \(count)")
                .font(.caption).foregroundStyle(CuePalette.muted).monospacedDigit()
            Button(action: onNext) { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(page >= count - 1)
                .accessibilityLabel("Next page")
            if !follow {
                Button("Resume follow", action: onFollow)
                    .font(.caption).buttonStyle(.link)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassSurface(in: Capsule())
        .padding(.vertical, 6)
    }
}

/// Page renderer with real paragraph gaps. Each paragraph is its own
/// FlowLayout; the VStack spacing is paragraphSpacing × fontSize so the
/// Typography slider is immediately visible in the prompter. Rows come
/// from ReadingWindow.pageParagraphRows (one tested pass; cues filtered).

struct TokenPageView: View {
    @Bindable var engine: PromptEngine
    let index: ScriptIndex
    let page: Int
    let pageSize: Int
    let settings: CueSettings
    /// Word indices practice mode has hidden. Empty in normal reading.
    var hiddenWords: Set<Int> = []

    private var fontSize: Double { settings.textSize.points * settings.prompterScale }

    var body: some View {
        // One page's rows — the index walks only the tokens on it, and each
        // cue arrives already interpreted.
        let groups = index.pageParagraphRows(page: page, pageSize: pageSize,
                                             showCues: settings.showCues)
        let current = engine.currentWordIndex ?? -1
        VStack(alignment: settings.textAlignment == .center ? .center : .leading,
               spacing: fontSize * settings.clampedParagraphSpacing) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, para in
                FlowLayout(spacing: max(6, fontSize * 0.22),
                           lineSpacing: fontSize * settings.lineSpacing) {
                    ForEach(Array(para.enumerated()), id: \.offset) { _, row in
                        switch row.token {
                        case .word(let w, let emphasised):
                            WordPill(word: w,
                                     isPast: row.wordIndex < current,
                                     isCurrent: row.wordIndex == current,
                                     settings: settings,
                                     fontSize: fontSize,
                                     isMasked: hiddenWords.contains(row.wordIndex),
                                     isEmphasised: emphasised)
                                .id("w-\(row.wordIndex)")
                                .onTapGesture { engine.jumpTo(wordIndex: row.wordIndex) }
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
    }
}

/// Pink stage-direction badge. Shared by the prompter and the settings
/// preview. Each cue kind gets its own symbol so a script reads at a
/// glance: [pause] shows the pause glyph, [drink] a drop, [slide] the
/// slides — all tinted by the configured cue color.
struct CueBadge: View {
    /// The interpreted cue from the row: parsing happened once, when the
    /// script was indexed.
    let cue: ScriptCue
    let settings: CueSettings
    let fontSize: Double

    private var text: String { cue.label }

    /// A slide cue is an instruction, not a stage direction, so it reads
    /// as a destination — "SLIDE 4", upright and boxed like a slide — where
    /// every other badge is a note to the presenter. It also stays on screen
    /// as the honest record of what the deck *should* be showing, whether or
    /// not anything moved it.
    private var isInstruction: Bool { cue.kind == .slide }

    /// "SLIDE" for the bare form, "SLIDE 4" when a slide is named. A
    /// right-pointing arrow on the bare form is the whole difference
    /// between "advance the deck" and "here is a number" — worth the glyph.
    private var instructionText: String {
        guard isInstruction else { return text }
        return cue.slideNumber.map { "SLIDE \($0)" } ?? "SLIDE →"
    }

    private var icon: String? {
        switch cue.kind {
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

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(settings.fontFamily.font(size: fontSize * 0.55, weight: .semibold))
            }
            if isInstruction {
                // The font helper takes no italic — `Font.italic()` on a
                // built size is macOS 26+ — so the instruction is set in the
                // caps its text already carries, and every other badge keeps
                // the italic it has always had.
                Text(instructionText)
                    .font(settings.fontFamily.font(size: fontSize * 0.62, weight: .bold))
                    .tracking(0.8)
            } else {
                Text(text)
                    .font(settings.fontFamily.font(size: fontSize * 0.72, weight: .semibold).italic())
            }
        }
        .foregroundStyle(settings.cueColor.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(settings.cueColor.color.opacity(settings.cueBrightness.badgeOpacity),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(isInstruction
              ? (cue.slideNumber == nil
                 ? "Advance the deck one slide here"
                 : "Go to slide \(cue.slideNumber ?? 0) here")
              : "Stage cue — timed cues hold playback automatically")
    }
}

struct WordPill: View {
    let word: String
    let isPast: Bool
    let isCurrent: Bool
    let settings: CueSettings
    let fontSize: Double
    /// Practice mode: this word is a gap. The *layout* keeps the word's width
    /// so the page does not reflow the moment somebody peeks — a gap that
    /// changes the line breaks would make every rehearsal look like a
    /// different script.
    var isMasked: Bool = false
    /// The author wrote `**like this**`. The markers are gone from the text by
    /// the time it reaches here — that is the whole point of them being file
    /// syntax — so without this flag the Bold button would insert something
    /// that changes nothing a presenter can see.
    var isEmphasised: Bool = false

    private var highlighted: Bool { isCurrent && settings.highlightCurrent }

    private var display: String {
        guard settings.hidePunctuation else { return word }
        let stripped = word.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        return stripped.isEmpty ? word : stripped
    }

    private var font: Font {
        settings.fontFamily.font(size: fontSize,
                                 weight: isCurrent ? .bold : settings.fontWeight.weight)
    }

    /// The colour this word is drawn in.
    ///
    /// Emphasis is the reading accent, and **never** a heavier weight: weight
    /// changes a word's width, and on the prompter the line breaks *are* the
    /// presenter's cue structure. `MaskedWordWidth` exists because a word whose
    /// width changes re-wraps the page, so an editor button that silently
    /// re-wrapped the script every time it was used would be its own bug.
    /// Colour costs nothing and reads at three metres.
    ///
    /// A word already behind the playhead dims like any other — emphasis that
    /// outlived its moment is noise.
    private var ink: Color {
        if isEmphasised && !isPast && !highlighted { return CuePalette.readingAccent }
        return isPast ? CuePalette.muted.opacity(0.6) : settings.textColor.color
    }

    private var tracking: CGFloat {
        settings.fontFamily.tracking + CGFloat(settings.letterSpacing)
    }

    /// A gap. Drawn as a slot rather than a redaction bar: the presenter
    /// needs to see that *something* goes here and how long it is.
    private func maskedBody(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(settings.textColor.color.opacity(0.16))
            .frame(height: max(4, fontSize * 0.34))
            .frame(width: max(28, width))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(settings.textColor.color.opacity(0.28))
                    .frame(height: 1)
            }
    }

    var body: some View {
        Group {
            if isMasked && !isCurrent {
                maskedBody(width: displayWidth)
            } else {
            switch (highlighted, settings.highlightStyle) {
            case (true, .pill):
                Text(display)
                    .foregroundStyle(CuePalette.onHighlight)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(settings.highlight.color, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: settings.highlight.color.opacity(0.35), radius: 12, y: 2)
            case (true, .underline):
                Text(display)
                    .foregroundStyle(ink)
                    .underline(true, color: settings.highlight.color)
            case (true, .bold), (false, _):
                // The current word keeps its own colour under the pill: the
                // highlight is the stronger signal, and tinting the word the
                // pill is drawn in would make the two fight.
                Text(display)
                    .foregroundStyle(isCurrent && highlighted ? settings.textColor.color : ink)
            }
            }
        }
        .font(font)
        .tracking(tracking)
        .accessibilityLabel(isMasked && !isCurrent ? "gap" : word)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// Roughly the space the word occupied, so a gap does not reflow the page.
    /// The width of the gap that stands in for this word.
    ///
    /// Measured with CoreText, never by bridging a SwiftUI `Font` to AppKit:
    /// `Font.custom("OpenDyslexic-Bold")` has no `NSFont` to bridge to, and
    /// the bridge threw inside AppKit's window-layout pass — an Objective-C
    /// exception on the display cycle is an unconditional `abort`, so practice
    /// mode crashed on any script with words in it, because masking is the
    /// only path that reaches this line. See `MaskedWordWidth`.
    ///
    /// Arithmetic (half an em per character) was safe from that crash and
    /// wrong everywhere else: ~21% wide on ordinary prose and ~40% narrow on
    /// capitals, CJK and emoji. Nothing clipped — the mask is a rectangle — but
    /// the page re-wrapped whenever a word was unmasked, in a mode whose whole
    /// promise is that the page does not move.
    private var displayWidth: CGFloat {
        MaskedWordWidth.width(of: display, family: settings.fontFamily,
                              size: fontSize, bold: isCurrent,
                              tracking: tracking)
    }
}


/// A section heading in the reading surface. Quiet on purpose — it is a
/// landmark, not a thing to read — but never silent: a script read from
/// across a room needs to show where it is.
struct SectionHeading: View {
    let name: String
    let level: Int
    let fontSize: Double

    var body: some View {
        HStack(spacing: 8) {
            // Level is used rather than discarded: `#` is a major break and
            // `###` a minor one, so the reader's eye finds the big ones
            // first from across a room. A rule always follows, so the depth
            // is carried by weight and rule opacity instead of by size —
            // the words underneath are already large enough.
            Text(name.uppercased())
                .font(.system(size: max(9, fontSize * (level <= 1 ? 0.46 : 0.40)),
                              weight: level <= 1 ? .bold : .semibold))
                .tracking(level <= 1 ? 1.4 : 0.9)
                .foregroundStyle(CuePalette.ink.opacity(level <= 1 ? 0.85 : 0.6))
            Rectangle()
                .fill(CuePalette.hairline.opacity(level <= 1 ? 1.0 : 0.6))
                .frame(height: level <= 1 ? 1 : 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, level <= 1 ? fontSize * 0.9 : fontSize * 0.5)
        .padding(.bottom, fontSize * 0.2)
    }
}
