import SwiftUI
import PromptCore

/// Remappable command keys. Click a row, press a chord, done — the same
/// monitor that runs commands records the new binding, so what you see
/// here is exactly what the prompter listens for.
struct KeyboardTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var hotkeys: HotkeyCenter
    @Bindable var globalHotkeys: GlobalHotkeys

    var body: some View {
        SettingsPage(title: "Keyboard",
                     subtitle: "Every command, and what it is bound to.") {
            if !hotkeys.captureHint.isEmpty {
                SettingsCaption(text: hotkeys.captureHint)
            }
            if !settings.settings.shortcuts.hasUniqueChords {
                // Two commands on one key: the dispatcher refuses to guess, so
                // say so rather than leaving the presenter with a dead key.
                SettingsCaption(text: "Two commands share a key. Reset one of them to give it a chord of its own.")
            }
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                SettingsSection(title: title(for: group)) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }, id: \.self) { action in
                        row(action)
                    }
                }
            }
            SettingsSection(title: "Presenting over another app") {
                ToggleRow(title: "Work while another app is in front",
                          isOn: $globalHotkeys.isEnabled,
                          caption: "Cuebar's keys keep working while Keynote, Zoom or a PDF is in front — but only while the prompter overlay is open. Needs the Accessibility permission, which lets Cuebar see every key press you make. A sandboxed build cannot install a key tap, so this may report itself unavailable.")
                HStack(spacing: 10) {
                    Text(globalHotkeys.status.label)
                        .font(.callout)
                        .foregroundStyle(CuePalette.ink)
                    Spacer()
                    if globalHotkeys.status.needsPermissionHelp {
                        Button("Open System Settings") {
                            globalHotkeys.openPermissionSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            SettingsSection(title: "Defaults") {
                Button("Reset All Shortcuts") {
                    settings.settings.shortcuts.resetAll()
                }
                .buttonStyle(.bordered)
                .disabled(settings.settings.shortcuts.customized.isEmpty)
                SettingsCaption(text: "Every command needs a modifier — a bare key would type into your script instead of driving the prompter. ⌘Q, ⌘W, ⌘M, ⌘H, ⌘Tab, ⌘, and ⌘/ stay with macOS. Taking a key another command already uses swaps the two; a refused press says so here. Esc cancels.")
            }
        }
        .onDisappear {
            // Never leave the monitor listening: with the recorder still
            // armed, the next chord anywhere in the app would be swallowed.
            hotkeys.cancelCapture()
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let isRecording = hotkeys.capturing == action
        let chord = settings.settings.shortcuts.chord(for: action)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.title)
                        .font(.callout)
                        .foregroundStyle(CuePalette.ink)
                    if settings.settings.shortcuts.isCustomized(action) {
                        Text("Custom")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CuePalette.peach)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(CuePalette.peach.opacity(0.16), in: Capsule())
                    }
                }
                Text(action.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                hotkeys.capturing = isRecording ? nil : action
            } label: {
                Text(isRecording ? "Press keys…" : chord.description)
                    .font(.callout.monospaced())
                    .foregroundStyle(isRecording ? CuePalette.peach : CuePalette.ink)
                    .frame(minWidth: 108)
                    .padding(.vertical, 5)
                    .background(CuePalette.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isRecording ? CuePalette.peach.opacity(0.8) : .clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the key combination to use. Esc cancels." : action.help)
            .accessibilityLabel("\(action.title) shortcut")
            if settings.settings.shortcuts.isCustomized(action) {
                Button {
                    settings.settings.shortcuts.reset(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Restore \(action.defaultChord.description)")
            }
        }
    }

    private func title(for group: ShortcutAction.Group) -> String {
        switch group {
        case .playback: return "Playback"
        case .stage: return "Stage"
        case .script: return "Script"
        case .format: return "Format"
        }
    }
}
