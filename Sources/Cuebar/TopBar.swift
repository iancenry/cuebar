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
    let index: ScriptIndex
    /// Rehearsal, so the floating prompter hides what the window hides.
    var practice: PracticeController? = nil
    @Binding var mode: PerformMode
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            ModeSwitcher(mode: $mode)
            Spacer()
            StatusPill(isPlaying: engine.isPlaying, showElapsed: settings.settings.showElapsed,
                       holdRemaining: engine.holdRemaining,
                       pauseReason: engine.pauseReason)
            if settings.settings.guidance.usesVoice {
                MicStatus(voice: voice, compact: true)
            }
            Menu {
                Picker("Display", selection: $settings.settings.overlayMode) {
                    Text("Notch").tag(CueSettings.OverlayMode.notch)
                    Text("Floating").tag(CueSettings.OverlayMode.floating)
                    Text("Fullscreen").tag(CueSettings.OverlayMode.fullscreen)
                }
                Button(overlay.isShowing ? "Close Overlay" : "Pop Out") {
                    overlay.toggle(engine: engine, settings: settings, index: index,
                                   voice: voice, practice: practice)
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
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CuePalette.muted)
                    .frame(width: CuePalette.chromeControlHeight,
                           height: CuePalette.chromeControlHeight)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassSurface(in: Circle(), interactive: true)
            .help("Display, follow mode and settings")
            .accessibilityLabel("Display, follow mode and settings")
        }
        .glassGroup(spacing: 12)
        .padding(.horizontal, CuePalette.chromeRowMargin)
        // Fixed, not derived: whatever a control measures, the band stays
        // the title-bar line and the controls centre on it.
        .frame(height: CuePalette.chromeRowHeight)
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
        .padding(2)
        .frame(height: CuePalette.chromeControlHeight)
        .glassSurface(in: Capsule())
    }

    private func segment(_ value: PerformMode, _ title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { mode = value }
        } label: {
            Text(title)
                .font(.callout.weight(mode == value ? .semibold : .regular))
                .foregroundStyle(mode == value ? CuePalette.onHighlight : CuePalette.ink.opacity(0.65))
                .padding(.horizontal, 13)
                .padding(.vertical, 2)
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
