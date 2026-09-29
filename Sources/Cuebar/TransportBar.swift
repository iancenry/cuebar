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
            HStack(spacing: 10) {
                SpeedControl(engine: engine, settings: settings)
                HoldBoostButton(engine: engine, settings: settings)
                Spacer(minLength: 8)
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
                Spacer(minLength: 8)
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.switch).controlSize(.small)
                    .tint(CuePalette.peach)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Keep the viewport chasing the highlighted word. Off: browse freely while playback runs — page arrows appear, and scrolling releases Follow automatically.")
                Button(action: {
                    overlay.toggle(engine: engine, settings: settings,
                                  index: index, voice: voice)
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CuePalette.ink.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.07), in: Circle())
                .accessibilityLabel(overlay.isShowing ? "Close overlay" : "Pop out overlay")
                .help(overlay.isShowing ? "Close overlay" : "Pop out overlay")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: 780)
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
        .background(Color.white.opacity(0.07), in: Capsule())
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
                    .background(Color.white.opacity(0.07), in: Capsule())
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
        .background(Color.white.opacity(0.07), in: Circle())
    }
}

/// Quiet track with a peach fill — an instrument, not a scrollbar.
struct PlaybackProgress: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(CuePalette.peach)
                    .frame(width: max(0, geo.size.width * min(1, max(0, progress))))
                    .shadow(color: CuePalette.peach.opacity(0.45), radius: 4)
            }
        }
        .frame(height: 4)
    }
}
