import SwiftUI
import PromptCore

/// Slim content-column strip: mode switcher left, live status right.
/// No app title — the menu bar and Dock already carry the name, and the
/// traffic lights live over the sidebar.
struct TopBar: View {
    @Bindable var settings: SettingsStore
    @Bindable var engine: PromptEngine
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    let tokens: [ScriptToken]
    @Binding var mode: PerformMode
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 12) {
            ModeSwitcher(mode: $mode)
            Spacer()
            StatusPill(isPlaying: engine.isPlaying, showElapsed: settings.settings.showElapsed,
                       holdRemaining: engine.holdRemaining)
            if settings.settings.guidance.usesVoice {
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
                Picker("Follow mode", selection: $settings.settings.guidance) {
                    Text("Traditional").tag(CueSettings.GuidanceMode.classic)
                    Text("Smart (word tracking)").tag(CueSettings.GuidanceMode.wordTracking)
                    Text("Voice (speak/pause)").tag(CueSettings.GuidanceMode.voiceActivated)
                    Text("Auto (WPM)").tag(CueSettings.GuidanceMode.auto)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(CuePalette.muted)
            }
            .menuStyle(.borderlessButton)
            .help("Display, follow mode and settings")
            .accessibilityLabel("Display, follow mode and settings")
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Compact Perform/Edit switch — a branded two-segment capsule instead
/// of the chunky native segmented control.
struct ModeSwitcher: View {
    @Binding var mode: PerformMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.perform, "Perform")
            segment(.edit, "Edit")
        }
        .padding(3)
        .glassSurface(in: Capsule())
    }

    private func segment(_ value: PerformMode, _ title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { mode = value }
        } label: {
            Text(title)
                .font(.callout.weight(mode == value ? .semibold : .regular))
                .foregroundStyle(mode == value ? CuePalette.onHighlight : CuePalette.ink.opacity(0.65))
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background {
                    if mode == value {
                        Capsule().fill(CuePalette.peach)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}
