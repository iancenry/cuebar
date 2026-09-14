import SwiftUI
import PromptCore

/// Perform-first top bar: script switcher, mode, one-glance status.
/// Display configuration lives under the gear menu — not in the
/// primary navigation.
struct TopBar: View {
    @Bindable var settings: SettingsStore
    @Bindable var engine: PromptEngine
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    let tokens: [ScriptToken]
    @Binding var mode: PerformMode
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 14) {
            Text("Cuebar")
                .font(.headline)
                .padding(.leading, 76) // traffic lights with hidden title bar
            Picker("Mode", selection: $mode) {
                Text("Perform").tag(PerformMode.perform)
                Text("Edit").tag(PerformMode.edit)
            }
            .pickerStyle(.segmented)
            .frame(width: 168)
            Spacer()
            StatusPill(isPlaying: engine.isPlaying, showElapsed: settings.settings.showElapsed)
            if settings.settings.guidance != .classic {
                MicStatus(voice: voice, compact: true)
            }
            Text(engine.boostMultiplier > 1.0
                 ? "\(Int((settings.settings.wordsPerMinute * engine.boostMultiplier).rounded())) wpm ▲"
                 : "\(Int(settings.settings.wordsPerMinute.rounded())) wpm")
                .font(.callout).foregroundStyle(engine.boostMultiplier > 1.0 ? CuePalette.peach : CuePalette.muted).monospacedDigit()
                .fixedSize()
            Menu {
                Picker("Display", selection: $settings.settings.overlayMode) {
                    Text("Notch").tag(CueSettings.OverlayMode.notch)
                    Text("Floating").tag(CueSettings.OverlayMode.floating)
                    Text("Fullscreen").tag(CueSettings.OverlayMode.fullscreen)
                }
                Button(overlay.isShowing ? "Close Overlay" : "Pop Out") {
                    if overlay.isShowing {
                        overlay.hide()
                    } else {
                        overlay.show(engine: engine, settings: settings, tokens: tokens, voice: voice)
                    }
                }
                Divider()
                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(CuePalette.muted)
            }
            .menuStyle(.borderlessButton)
            .help("Display and settings")
            .accessibilityLabel("Display and settings")
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
