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
    /// One parse of this script: page arithmetic, cue behaviour and the
    /// token list all come from it, so no body pass walks the script again.
    let index: ScriptIndex
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
    /// Extra bottom room when a floating dock overlays the page (main
    /// window only) so page controls never hide underneath it.
    var bottomInset: CGFloat = 0
    /// Practice mode. Nil in normal reading; the controller when rehearsing.
    var practice: PracticeController? = nil
    /// Room for the floating chrome. The band has no surface of its own —
    /// the canvas runs to the window top under it — so the page is inset
    /// instead of being covered, and stays centred in what is left.
    var topInset: CGFloat = 0

    /// The gaps, minus the word being read.
    ///
    /// A *read*. This used to call `practice.noteCurrentWord(...)` inline,
    /// which mutates observable state while the view is being evaluated —
    /// and since the value it writes feeds the very set being read here,
    /// toggling practice on could invalidate the view mid-evaluation, over
    /// and over. That is the crash on ⌥P. The current word is published by
    /// `PlaybackDriver.tick()` instead: one writer, outside view evaluation.
    private var hiddenWords: Set<Int> {
        guard let practice, practice.isOn else { return [] }
        return practice.revealing ? [] : practice.hiddenWords
    }
    @State private var page = 0
#if os(macOS)
    @State private var wheelMonitor: Any?
#endif

    private var pageSize: Int { settings.settings.clampedPageSize }
    private var fontSize: Double { settings.settings.textSize.points * settings.settings.prompterScale }

    private var metrics: PrompterMetrics {
        PrompterMetrics(index: index, pageSize: pageSize,
                        currentWord: engine.currentWordIndex, follow: follow, page: page)
    }

    /// The main window's TopBar owns status; the overlay keeps its own.
    var showsHeader: Bool = true

    var body: some View {
        let metrics = metrics
        VStack(spacing: 0) {
            if showsHeader {
                header
            }
            ScrollViewReader { proxy in
                ZStack(alignment: .center) {
                    // The guide line marks where the current word tracks
                    // (scroll anchors words to the vertical center). It
                    // renders *behind* the text and fades at the margins —
                    // a hard rule across glyphs read as a stray underline.
                    // Meaningless while browsing with Follow off, and
                    // over an empty document.
                    if settings.settings.showCenterLine, follow, !index.isEmpty {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, CuePalette.peach.opacity(0.18), .clear],
                                    startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(height: 1)
                            .padding(.horizontal, 24)
                            .allowsHitTesting(false)
                    }
                    GeometryReader { geo in
                        ScrollView {
                            Group {
                                if index.isEmpty {
                                    ContentUnavailableView("Nothing to prompt", systemImage: "text.alignleft",
                                        description: Text("Write a script in Edit mode or pick one on the left."))
                                } else {
                                    TokenPageView(engine: engine, index: index,
                                                  page: metrics.visiblePage,
                                                  pageSize: pageSize, settings: settings.settings,
                                                  hiddenWords: hiddenWords)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 24)
                                    .frame(maxWidth: settings.settings.readingWidth ?? .infinity,
                                           alignment: settings.settings.textAlignment == .center ? .center : .leading)
                                }
                            }
                            // On the *Group*, not inside the else. The empty
                            // branch was the only one that never got a
                            // full-width frame, so `ContentUnavailableView`
                            // sized itself to its own text and sat left of
                            // the canvas centre — the one screen a new
                            // script always shows, and the one nobody
                            // looks at closely enough to question.
                            .frame(maxWidth: .infinity, alignment: .center)
                            // Short pages sit centered instead of hugging the
                            // top with a wall of empty space below.
                            .frame(minHeight: geo.size.height, alignment: .center)
                        }
                        .padding(.top, topInset)
                    }
                    // Teleprompter fades: text glides under the chrome at
                    // both edges instead of hard-clipping.
                    VStack {
                        LinearGradient(colors: [surface, surface.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                        Spacer()
                        LinearGradient(colors: [surface.opacity(0), surface],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                    }
                    .allowsHitTesting(false)
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
                .onChange(of: follow) { _, new in
                    // Re-engaging Follow snaps the current word onto the
                    // guide line immediately — otherwise it waited for the
                    // next word change before scrolling at all.
                    guard new else { return }
                    page = metrics.enginePage
                    guard let idx = engine.currentWordIndex else { return }
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
            if showsPageControls, metrics.pageCount > 1 {
                PageControls(page: metrics.visiblePage, count: metrics.pageCount, follow: follow,
                             onPrev: { go(page - 1) }, onNext: { go(page + 1) },
                             onFollow: { follow = true })
                    .padding(.bottom, bottomInset)
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
                .glassSurface(in: RoundedRectangle(cornerRadius: CuePalette.cardRadius))
            }
            }
        .background(surface)
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
            StatusPill(isPlaying: engine.isPlaying, showElapsed: settings.settings.showElapsed,
                       holdRemaining: engine.holdRemaining,
                       pauseReason: engine.pauseReason)
            if settings.settings.guidance.usesVoice {
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
                        settings.settings.setWordsPerMinute($0)
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
        page = min(max(0, p), max(0, metrics.pageCount - 1))
    }
}
