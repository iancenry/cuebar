import SwiftUI
import PromptCore

/// Bottom transport for Perform mode: progress line, speed, skip/play/skip,
/// follow, pop-out. Keyboard-first (Option-Space); the buttons reinforce
/// rather than lead.
struct TransportBar: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    let index: ScriptIndex
    @Binding var follow: Bool
    /// Rehearsal. Injected so the level control sits next to playback, which
    /// is where a presenter looks when they are about to run the script again.
    var practice: PracticeController? = nil
    /// The rehearsal run. Same reasoning as practice: it belongs next to
    /// playback, which is where the presenter looks before starting.
    var recorder: RunRecorder? = nil

    // MARK: - Height

    // The dock's height, from its parts. `ContentView` passes this as the
    // prompter's `bottomInset`, and it used to be a literal — 112 — that was
    // right until the rehearsal row was added. Nothing said so: the last line
    // of script simply slid underneath it.
    //
    // The rehearsal row: 22pt controls, 8 above and below, and the dock's own
    // 12 underneath.
    static let rehearsalRowHeight: CGFloat = 22 + 16 + 12
    static let progressHeight: CGFloat = 14
    static let controlsHeight: CGFloat = 78

    /// How much of the reading surface the dock covers.
    static func dockHeight(rehearsal: Bool) -> CGFloat {
        progressHeight + controlsHeight + (rehearsal ? rehearsalRowHeight : 0) + 8
    }

    /// Same helper the jump keys use, so a button and a chord skip the same
    /// distance at any reading speed.
    private var skipWords: Int {
        ReadingWindow.jumpWords(forSeconds: 10, wordsPerSecond: engine.wordsPerSecond)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaybackProgress(progress: engine.progress)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .accessibilityLabel("Progress")
            // Transport centred by overlay, not by spacers. Two `Spacer`s
            // only centre the play cluster when the side clusters measure
            // the same — speed+boost is ~70pt wider than Follow+expand, so
            // play sat ~36pt right of true centre and the trailing group
            // was jammed against the edge (worst in fullscreen, where the
            // dock is widest). Pinning the sides and centring the
            // transport on the dock's own midline is width-independent, so
            // no future control can shove it off.
            ZStack {
                HStack(spacing: 10) {
                    SpeedControl(engine: engine, settings: settings)
                    HoldBoostButton(engine: engine, settings: settings)
                    Spacer(minLength: 8)
                    Toggle("Follow", isOn: $follow)
                        .toggleStyle(.switch).controlSize(.small)
                        .tint(CuePalette.peach)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Keep the viewport chasing the highlighted word. Off: browse freely while playback runs — page arrows appear, and scrolling releases Follow automatically.")
                    Button(action: {
                        overlay.toggle(engine: engine, settings: settings,
                                      index: index, voice: voice, practice: practice)
                    }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CuePalette.ink.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(CuePalette.ink.opacity(0.07), in: Circle())
                    .accessibilityLabel(overlay.isShowing ? "Close overlay" : "Pop out overlay")
                    .help(overlay.isShowing ? "Close overlay" : "Pop out overlay")
                }
                HStack(spacing: 12) {
                    SkipButton(icon: "gobackward.10") {
                        engine.jumpRelative(words: -skipWords)
                    }
                    .accessibilityLabel("Back 10 seconds")
                    PlayButton(isPlaying: engine.isPlaying) { engine.toggle() }
                    SkipButton(icon: "goforward.10") {
                        engine.jumpRelative(words: skipWords)
                    }
                    .accessibilityLabel("Forward 10 seconds")
                }
            }
            .frame(height: 58)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
            // Practice and Record share one row and hug their content.
            //
            // Two full-width rows each painted with `CuePalette.card` looked
            // like two flat bars laid across the dock, and — the real damage —
            // a fill on top of Liquid Glass stops reading as glass at all. The
            // dock is the glass surface; these controls sit *on* it, so they
            // bring their own padding and nothing else.
            if practice != nil || recorder != nil {
                HStack(alignment: .center, spacing: 14) {
                    if let practice { PracticeStrip(practice: practice) }
                    if let practice, recorder != nil {
                        Divider().frame(height: 14)
                    }
                    if let recorder { RunHUD(recorder: recorder) }
                    Spacer(minLength: 12)
                    // Paused and Mic-off live here, level with Practice and
                    // Record and at the opposite end of the row. They were in
                    // the top bar, which put the two things a presenter looks
                    // for while speaking — am I playing, is it hearing me — on
                    // opposite edges of the window from the controls that
                    // change them.
                    Divider().frame(height: 14)
                    StatusPill(isPlaying: engine.isPlaying,
                               showElapsed: settings.settings.showElapsed,
                               holdRemaining: engine.holdRemaining,
                               pauseReason: engine.pauseReason,
                               drift: StatusPill.drift(engine: engine,
                                                       targetMinutes: settings.settings.targetMinutes))
                    if settings.settings.guidance.usesVoice {
                        MicStatus(voice: voice, compact: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: 700)
        // A real Liquid Glass dock: text scrolls behind it and blurs,
        // which is what makes the material read as glass instead of a
        // flat gray pill on flat gray chrome.
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

/// Speed cluster: − / value / + in one capsule. The native Stepper's
/// hairline arrows read as broken chrome next to the big play button.
struct SpeedControl: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore

    private var boosting: Bool { engine.boostMultiplier > 1.0 }

    private var display: String {
        let wpm = boosting
            ? settings.settings.wordsPerMinute * engine.boostMultiplier
            : settings.settings.wordsPerMinute
        return "\(Int(wpm.rounded()))"
    }

    var body: some View {
        HStack(spacing: 2) {
            stepButton("minus") { adjust(by: -5) }
            HStack(spacing: 4) {
                Text(display)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(boosting ? CuePalette.peach : CuePalette.ink)
                Text("wpm")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            }
            .frame(minWidth: 58)
            stepButton("plus") { adjust(by: 5) }
        }
        .padding(3)
        .background(CuePalette.ink.opacity(0.07), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading speed")
        .accessibilityValue("\(Int(settings.settings.wordsPerMinute.rounded())) words per minute")
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CuePalette.muted)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "plus" ? "Faster" : "Slower")
    }

    private func adjust(by delta: Double) {
        settings.settings.adjustWordsPerMinute(by: delta)
        engine.setSpeed(settings.settings.wordsPerSecond)
    }
}

/// Hold-to-catch-up: press and hold for a momentary speed multiplier.
/// Releasing eases back via the engine's velocity filter — no jolt.
/// Keyboard twin: hold → (right arrow) in Perform mode.
struct HoldBoostButton: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore
    @State private var holding = false

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "hare.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("\(settings.settings.clampedCatchUpBoost, specifier: "%.1f")×")
                .font(.callout.monospacedDigit().weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
    }

    var body: some View {
        Group {
            if holding {
                label
                    .foregroundStyle(CuePalette.onHighlight)
                    .background(CuePalette.peach, in: Capsule())
            } else {
                label
                    .foregroundStyle(CuePalette.ink.opacity(0.8))
                    .background(CuePalette.ink.opacity(0.07), in: Capsule())
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in press() }
                .onEnded { _ in release() }
        )
        .onDisappear { release() }
        .accessibilityLabel("Hold to temporarily speed up")
        .help("Hold to catch up (\(settings.settings.clampedCatchUpBoost, specifier: "%.1f")×). Keyboard: hold →.")
    }

    private func press() {
        guard !holding else { return }
        holding = true
        engine.setBoost(settings.settings.clampedCatchUpBoost)
    }

    private func release() {
        guard holding else { return }
        holding = false
        engine.setBoost(1.0)
    }
}

struct PlayButton: View {
    let isPlaying: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(CuePalette.onHighlight)
                .offset(x: isPlaying ? 0 : 1.5)
                .frame(width: 58, height: 58)
                .background {
                    Circle()
                        .fill(CuePalette.peach)
                        .shadow(color: CuePalette.peach.opacity(0.35), radius: 14, y: 4)
                }
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .help("Play or pause (Option-Space)")
    }
}

struct SkipButton: View {
    let icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(CuePalette.ink.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(CuePalette.ink.opacity(0.07), in: Circle())
    }
}

/// Quiet track with a peach fill — an instrument, not a scrollbar.
struct PlaybackProgress: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CuePalette.ink.opacity(0.12))
                Capsule()
                    .fill(CuePalette.peach)
                    .frame(width: max(0, geo.size.width * min(1, max(0, progress))))
                    .shadow(color: CuePalette.peach.opacity(0.45), radius: 4)
            }
        }
        .frame(height: 4)
    }
}


/// Rehearsal controls, under the transport. Only there when practice mode
/// has been asked for — a permanent row of rehearsal controls would be one
/// more thing between a presenter and playing the script.
struct PracticeStrip: View {
    @Bindable var practice: PracticeController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                practice.toggle()
            } label: {
                Label(practice.isOn ? "Practice on" : "Practice",
                      systemImage: practice.isOn ? "eye.slash" : "eye")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(practice.isOn ? CuePalette.peach : CuePalette.ink.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Hide parts of the script and fill them in from memory")

            if practice.isOn {
                Divider().frame(height: 14)
                stepper
                Text(practice.levelDescription)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(CuePalette.inkMuted)
                Divider().frame(height: 14)
                Button {
                    practice.toggleReveal()
                } label: {
                    Label(practice.revealing ? "Hide" : "Reveal",
                          systemImage: practice.revealing ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(practice.revealing ? CuePalette.peach : CuePalette.ink.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Show the hidden text without leaving practice")
            }
        }
        .fixedSize()
    }

    private var stepper: some View {
        HStack(spacing: 2) {
            Button { practice.easier() } label: { chevron("minus", "Hide less") }
            Button { practice.harder() } label: { chevron("plus", "Hide more") }
        }
        .buttonStyle(.plain)
    }

    private func chevron(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(CuePalette.ink.opacity(0.8))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help(help)
            .accessibilityLabel(help)
    }
}
