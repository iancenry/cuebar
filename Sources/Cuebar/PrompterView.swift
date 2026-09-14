import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
#endif

/// Reading view shared by the main window and the floating overlay.
/// Renders one page at a time (see ReadingWindow) so a 5,000-word
/// script never builds 5,000 views.
struct PrompterBody: View {
    @Bindable var engine: PromptEngine
    let tokens: [ScriptToken]
    @Bindable var settings: SettingsStore
    @Bindable var voice: VoiceTracker
    @Binding var follow: Bool
    /// Reading surface override. The notch island passes black so the
    /// pill melts into the menu bar; otherwise the surfaceStyle setting
    /// decides.
    var surfaceOverride: Color? = nil
    private var surface: Color { surfaceOverride ?? settings.settings.surfaceStyle.color }
    /// Compact drops the speed readout for narrow islands.
    var compact: Bool = false
    /// The overlay keeps its own footer; the main window's transport
    /// bar carries progress instead.
    var showsFooter: Bool = true
    /// Page navigation renders even without the footer — the main
    /// window has no other page controls.
    var showsPageControls: Bool = true
    @State private var page = 0
#if os(macOS)
    @State private var wheelMonitor: Any?
#endif

    private var pageSize: Int { settings.settings.clampedPageSize }
    private var wordCount: Int { tokens.reduce(0) { $0 + ($1.isWord ? 1 : 0) } }
    private var pageCount: Int { ReadingWindow.pageCount(wordCount: wordCount, pageSize: pageSize) }
    private var fontSize: Double { settings.settings.textSize.points * settings.settings.prompterScale }

    private var enginePage: Int {
        ReadingWindow.pageIndex(forWord: engine.currentWordIndex, wordCount: wordCount, pageSize: pageSize)
    }

    private var visiblePage: Int {
        follow ? enginePage : min(max(0, page), max(0, pageCount - 1))
    }

    /// The main window's TopBar owns status; the overlay keeps its own.
    var showsHeader: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
            }
            ScrollViewReader { proxy in
                ZStack(alignment: .center) {
                    ScrollView {
                    if tokens.isEmpty {
                        ContentUnavailableView("No script", systemImage: "text.alignleft",
                            description: Text("Pick a script on the left to start prompting."))
                            .padding(.top, 80)
                    } else {
                        TokenPageView(engine: engine, tokens: tokens, page: visiblePage,
                                      pageSize: pageSize, settings: settings.settings)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: settings.settings.readingWidth ?? .infinity,
                               alignment: settings.settings.textAlignment == .center ? .center : .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                if settings.settings.showCenterLine {
                    Rectangle()
                        .fill(CuePalette.peach.opacity(0.25))
                        .frame(height: 1)
                        .padding(.horizontal, 24)
                        .allowsHitTesting(false)
                }
                }
                .onChange(of: engine.currentWordIndex) { _, new in
                    guard follow, let idx = new else { return }
                    DispatchQueue.main.async {
                        if settings.settings.smoothScroll {
                            withAnimation(.easeOut(duration: settings.settings.scrollAnimationDuration)) {
                                proxy.scrollTo("w-\(idx)", anchor: .center)
                            }
                        } else {
                            proxy.scrollTo("w-\(idx)", anchor: .center)
                        }
                    }
                }
            }
            if showsPageControls, pageCount > 1 {
                PageControls(page: visiblePage, count: pageCount, follow: follow,
                             onPrev: { go(page - 1) }, onNext: { go(page + 1) },
                             onFollow: { follow = true })
            }
            if showsFooter, voice.state == .listening || settings.settings.showProgress {
                HStack(spacing: 12) {
                    if voice.state == .listening {
                        WaveformView(levels: voice.levelHistory)
                    }
                    if settings.settings.showProgress {
                        Text("\(Int(engine.progress * 100))%")
                            .font(.caption).monospacedDigit().foregroundStyle(CuePalette.muted)
                            .frame(minWidth: 40, alignment: .leading)
                        ProgressView(value: engine.progress)
                            .progressViewStyle(.linear).tint(CuePalette.peach)
                            .accessibilityLabel("Progress")
                    }
                }
                .padding()
                .background(CuePalette.card)
            }
            }
        .background(surface)
        .onChange(of: follow) { _, new in
            // Single place where follow re-engages the tracker position,
            // shared by every Follow toggle in every window.
            if new { page = enginePage }
        }
#if os(macOS)
        .onAppear { installWheelMonitor() }
        .onDisappear { removeWheelMonitor() }
#endif
    }

#if os(macOS)
    /// A nudge of the wheel means "let me look around" — release Follow so
    /// auto-scroll stops fighting the reader. Playback keeps running;
    /// Resume follow jumps back to the highlight. Pass-through: the wheel
    /// event itself is never swallowed.
    private func installWheelMonitor() {
        removeWheelMonitor()
        let followBinding = $follow
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [settings] event in
            guard followBinding.wrappedValue,
                  settings.settings.releaseFollowOnScroll,
                  abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 0.5 else {
                return event
            }
            Task { @MainActor in followBinding.wrappedValue = false }
            return event
        }
    }

    private func removeWheelMonitor() {
        if let m = wheelMonitor { NSEvent.removeMonitor(m) }
        wheelMonitor = nil
    }
#endif

    private var header: some View {
        // Full controls when they fit, slim pills-only row when squeezed.
        // ViewThatFits never compresses either variant, so labels can't
        // collapse into vertical letter stacks.
        ViewThatFits(in: .horizontal) {
            headerRow(showSpeed: !compact)
            headerRow(showSpeed: false)
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 4)
    }

    private func headerRow(showSpeed: Bool) -> some View {
        HStack(spacing: 12) {
            StatusPill(isPlaying: engine.isPlaying, showElapsed: settings.settings.showElapsed)
            if settings.settings.guidance != .classic {
                MicStatus(voice: voice, compact: compact || !showSpeed)
            }
            Spacer()
            if showSpeed {
                Text(engine.boostMultiplier > 1.0
                     ? "\(Int((settings.settings.wordsPerMinute * engine.boostMultiplier).rounded())) wpm ▲"
                     : "\(Int(settings.settings.wordsPerMinute.rounded())) wpm")
                    .font(.callout).foregroundStyle(engine.boostMultiplier > 1.0 ? CuePalette.peach : CuePalette.muted).monospacedDigit()
                    .fixedSize()
                Stepper("Speed", value: Binding(
                    get: { settings.settings.wordsPerMinute },
                    set: {
                        settings.settings.wordsPerMinute = min(480, max(30, $0))
                        engine.setSpeed(settings.settings.wordsPerSecond)
                    }
                ), in: 30...480, step: 5).labelsHidden().controlSize(.small)
                .accessibilityValue("\(Int(settings.settings.wordsPerMinute.rounded())) words per minute")
            }
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.switch).controlSize(.small)
                .tint(CuePalette.peach)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func go(_ p: Int) {
        follow = false
        page = min(max(0, p), max(0, pageCount - 1))
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
        .background(CuePalette.card, in: Capsule())
        .padding(.vertical, 6)
    }
}

/// Maps the token stream to views for one page. Only `.word` tokens
/// consume a tracking index; cues and paragraph breaks ride along for
/// display (cues hide when cues are off — paging math always runs on
/// the full stream).
struct TokenViews: View {
    @Bindable var engine: PromptEngine
    let tokens: [ScriptToken]
    let page: Int
    let pageSize: Int
    let settings: CueSettings

    private var fontSize: Double { settings.textSize.points * settings.prompterScale }

    struct Row {
        let token: ScriptToken
        let wordIndex: Int // -1 for cues and breaks
        let page: Int
    }

    func rows() -> [Row] {
        let pages = ReadingWindow.tokenPages(tokens, pageSize: pageSize)
        var out: [Row] = []
        out.reserveCapacity(tokens.count)
        var wi = 0
        for (i, t) in tokens.enumerated() {
            if t.isWord {
                out.append(Row(token: t, wordIndex: wi, page: pages[i]))
                wi += 1
            } else {
                out.append(Row(token: t, wordIndex: -1, page: pages[i]))
            }
        }
        return out.filter {
            $0.page == page
                && ($0.token.isParagraphBreak || settings.showCues || !$0.token.isCue)
        }
    }

    /// Page rows split on paragraph breaks for VStack rendering.
    func paragraphs() -> [[Row]] {
        var groups: [[Row]] = [[]]
        for row in rows() {
            if row.token.isParagraphBreak {
                groups.append([])
            } else {
                groups[groups.count - 1].append(row)
            }
        }
        // A page boundary can strand a leading break; drop empty groups
        // but keep at least one so empty pages still render.
        let nonEmpty = groups.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? [[]] : nonEmpty
    }

    var body: some View {
        ForEach(Array(rows().enumerated()), id: \.offset) { _, row in
            switch row.token {
            case .word(let w):
                WordPill(word: w,
                         isPast: row.wordIndex < (engine.currentWordIndex ?? 0),
                         isCurrent: row.wordIndex == (engine.currentWordIndex ?? -1),
                         settings: settings,
                         fontSize: fontSize)
                    .id("w-\(row.wordIndex)")
                    .onTapGesture { engine.jumpTo(wordIndex: row.wordIndex) }
            case .cue(let c):
                CueBadge(text: CueBadge.label(for: c), settings: settings, fontSize: fontSize)
            case .paragraphBreak:
                EmptyView()
            }
        }
    }
}

/// Page renderer with real paragraph gaps. Each paragraph is its own
/// FlowLayout; the VStack spacing is paragraphSpacing × fontSize so the
/// Typography slider is immediately visible in the prompter.
struct TokenPageView: View {
    @Bindable var engine: PromptEngine
    let tokens: [ScriptToken]
    let page: Int
    let pageSize: Int
    let settings: CueSettings

    private var fontSize: Double { settings.textSize.points * settings.prompterScale }

    var body: some View {
        let helper = TokenViews(engine: engine, tokens: tokens, page: page,
                                pageSize: pageSize, settings: settings)
        let paras = helper.paragraphs()
        let current = engine.currentWordIndex ?? -1
        VStack(alignment: settings.textAlignment == .center ? .center : .leading,
               spacing: fontSize * settings.clampedParagraphSpacing) {
            ForEach(Array(paras.enumerated()), id: \.offset) { _, para in
                FlowLayout(spacing: max(6, fontSize * 0.22),
                           lineSpacing: fontSize * settings.lineSpacing) {
                    ForEach(Array(para.enumerated()), id: \.offset) { _, row in
                        switch row.token {
                        case .word(let w):
                            WordPill(word: w,
                                     isPast: row.wordIndex < current,
                                     isCurrent: row.wordIndex == current,
                                     settings: settings,
                                     fontSize: fontSize)
                                .id("w-\(row.wordIndex)")
                                .onTapGesture { engine.jumpTo(wordIndex: row.wordIndex) }
                        case .cue(let c):
                            CueBadge(text: CueBadge.label(for: c), settings: settings, fontSize: fontSize)
                        case .paragraphBreak:
                            EmptyView()
                        }
                    }
                }
            }
        }
    }
}

/// Pink stage-direction badge. Shared by the prompter and the settings preview.
struct CueBadge: View {
    let text: String
    let settings: CueSettings
    let fontSize: Double

    /// "[pause]" renders as a badge reading "pause".
    static func label(for cue: String) -> String {
        var text = cue
        if text.hasPrefix("[") { text.removeFirst() }
        if text.hasSuffix("]") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        Text(text)
            .font(settings.fontFamily.font(size: fontSize * 0.72, weight: .semibold).italic())
            .foregroundStyle(settings.cueColor.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(settings.cueColor.color.opacity(settings.cueBrightness.badgeOpacity),
                        in: Capsule())
            .help("Stage cue — not tracked")
    }
}

struct WordPill: View {
    let word: String
    let isPast: Bool
    let isCurrent: Bool
    let settings: CueSettings
    let fontSize: Double

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

    private var tracking: CGFloat {
        settings.fontFamily.tracking + CGFloat(settings.letterSpacing)
    }

    var body: some View {
        Group {
            switch (highlighted, settings.highlightStyle) {
            case (true, .pill):
                Text(display)
                    .foregroundStyle(CuePalette.onHighlight)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(settings.highlight.color, in: RoundedRectangle(cornerRadius: 12))
            case (true, .underline):
                Text(display)
                    .foregroundStyle(settings.textColor.color)
                    .underline(true, color: settings.highlight.color)
            case (true, .bold), (false, _):
                Text(display)
                    .foregroundStyle(isCurrent ? settings.textColor.color
                        : (isPast ? CuePalette.muted.opacity(0.6) : settings.textColor.color))
            }
        }
        .font(font)
        .tracking(tracking)
        .accessibilityLabel(word)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

struct ElapsedClock: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: 1.0)) { ctx in
            Text(clockString(ctx.date.timeIntervalSince(start)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func clockString(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
