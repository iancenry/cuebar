import SwiftUI
import PromptCore

/// Bottom transport for Perform mode: progress line, skip/play/skip,
/// speed, follow, pop-out. Keyboard-first (Option-Space); the buttons
/// reinforce rather than lead.
struct TransportBar: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    let tokens: [ScriptToken]
    @Binding var follow: Bool

    private var skipWords: Int {
        max(5, Int((10 * engine.wordsPerSecond).rounded()))
    }

    private var boosting: Bool { engine.boostMultiplier > 1.0 }

    var body: some View {
        VStack(spacing: 0) {
            PlaybackProgress(progress: engine.progress)
                .padding(.horizontal)
                .padding(.top, 10)
                .accessibilityLabel("Progress")
            HStack {
                HStack(spacing: 4) {
                    Text(boosting
                         ? "\(Int((settings.settings.wordsPerMinute * engine.boostMultiplier).rounded())) wpm ▲"
                         : "\(Int(settings.settings.wordsPerMinute.rounded())) wpm")
                        .font(.callout).foregroundStyle(boosting ? CuePalette.peach : CuePalette.muted).monospacedDigit()
                        .fixedSize()
                    Stepper("Speed", value: Binding(
                        get: { settings.settings.wordsPerMinute },
                        set: {
                            settings.settings.wordsPerMinute = min(480, max(30, $0))
                            engine.setSpeed(settings.settings.wordsPerSecond)
                        }
                    ), in: 30...480, step: 5)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityValue("\(Int(settings.settings.wordsPerMinute.rounded())) words per minute")
                    HoldBoostButton(engine: engine, settings: settings)
                }
                Spacer()
                SkipButton(icon: "backward.fill", caption: "10s") {
                    engine.jumpRelative(words: -skipWords)
                }
                .accessibilityLabel("Back 10 seconds")
                Button(action: { engine.toggle() }) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(CuePalette.onHighlight)
                        .frame(width: 56, height: 56)
                        .background(CuePalette.peach, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                .help("Play or pause (Option-Space)")
                SkipButton(icon: "forward.fill", caption: "10s") {
                    engine.jumpRelative(words: skipWords)
                }
                .accessibilityLabel("Forward 10 seconds")
                Spacer()
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.switch).controlSize(.small)
                    .tint(CuePalette.peach)
                    .fixedSize(horizontal: true, vertical: false)
                Button(action: {
                    if overlay.isShowing {
                        overlay.hide()
                    } else {
                        overlay.show(engine: engine, settings: settings,
                                     tokens: tokens, voice: voice)
                    }
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(CuePalette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(overlay.isShowing ? "Close overlay" : "Pop out overlay")
                .help(overlay.isShowing ? "Close overlay" : "Pop out overlay")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(alignment: .top) {
                Divider().opacity(0.35)
            }
        }
    }
}

/// Hold-to-catch-up: press and hold for a momentary speed multiplier.
/// Releasing eases back via the engine's velocity filter — no jolt.
/// Keyboard twin: hold → (right arrow) in Perform mode.
struct HoldBoostButton: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore
    @State private var holding = false

    var body: some View {
        Group {
            if holding {
                Text("\(settings.settings.clampedCatchUpBoost, specifier: "%.1f")×")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(CuePalette.onHighlight)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CuePalette.peach, in: Capsule())
            } else {
                Text("\(settings.settings.clampedCatchUpBoost, specifier: "%.1f")×")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(CuePalette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassSurface(in: Capsule(), interactive: true)
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

struct SkipButton: View {
    let icon: String
    let caption: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.title3)
                Text(caption)
                    .font(.caption2)
            }
            .foregroundStyle(CuePalette.muted)
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
    }
}

/// Rounded progress capsule with a quiet track, tinted peach.
struct PlaybackProgress: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CuePalette.muted.opacity(0.25))
                Capsule()
                    .fill(CuePalette.peach)
                    .frame(width: max(0, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 5)
    }
}
