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

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .tint(CuePalette.peach)
                .padding(.horizontal)
                .accessibilityLabel("Progress")
            HStack {
                HStack(spacing: 4) {
                    Text("\(Int((engine.wordsPerSecond * 60).rounded())) wpm")
                        .font(.callout).foregroundStyle(CuePalette.muted).monospacedDigit()
                        .fixedSize()
                    Stepper("Speed", value: Binding(
                        get: { engine.wordsPerSecond },
                        set: { engine.setSpeed($0) }
                    ), in: 0.5...8, step: 0.5)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityValue("\(Int((engine.wordsPerSecond * 60).rounded())) words per minute")
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
        }
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
    }
}
