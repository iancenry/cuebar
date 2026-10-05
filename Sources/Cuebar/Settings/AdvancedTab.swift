import SwiftUI
import AppKit
import PromptCore

/// The page for things you need when something is wrong, and the one place
/// that can undo all of it.
struct AdvancedTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var globalHotkeys: GlobalHotkeys
    @State private var confirmingReset = false

    var body: some View {
        SettingsPage(title: "Advanced",
                     subtitle: "Storage, compatibility, and a way back to the start.") {
            SettingsCard(title: "Storage") {
                SettingRow(label: "Library") {
                    Text(CuebarFiles.scriptsDirectory.path)
                        .font(.caption).monospaced()
                        .foregroundStyle(CuePalette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Label(writable ? "Writable" : "Not writable",
                          systemImage: writable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(writable ? CuePalette.inkMuted : .yellow)
                    Button("Show in Finder") { ScriptIntake.revealLibrary() }
                        .buttonStyle(.link)
                    Button("Reveal Runs") {
                        try? FileManager.default.createDirectory(
                            at: CuebarFiles.runs, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([CuebarFiles.runs])
                    }
                    .buttonStyle(.link)
                }
                SettingsCaption(text: "Cuebar keeps your scripts in ~/Documents/Cuebar, not "
                    + "in a private application folder, so they are yours to back up, "
                    + "sync and open in any editor.")
            }
            SettingsCard(title: "Compatibility") {
                SettingRow(label: "Key tap") {
                    Text(globalHotkeys.status.label)
                        .font(.callout)
                        .foregroundStyle(globalHotkeys.status.needsPermissionHelp
                                         ? .yellow : CuePalette.ink)
                }
                SettingsCaption(text: "The session-level key tap lets Cuebar's commands work "
                    + "while another app is in front. It needs Accessibility, and only runs "
                    + "while the prompter is up. The in-app shortcuts need no permission.")
                SettingRow(label: "Speech") {
                    Text(settings.settings.speechLanguage)
                        .font(.callout)
                        .foregroundStyle(CuePalette.ink)
                }
            }
            SettingsCard(title: "Reset") {
                ToggleRow(title: "Reset all settings",
                          isOn: $confirmingReset,
                          caption: "Puts every preference back to how Cuebar shipped. Your "
                                 + "scripts are not touched.")
                if confirmingReset {
                    HStack(spacing: 10) {
                        Button("Reset everything") {
                            settings.settings = CueSettings()
                            confirmingReset = false
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Cancel") { confirmingReset = false }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    /// Asked of the filesystem rather than remembered: the answer is the
    /// point of the row, and a cached "writable" would lie after a permissions
    /// change.
    private var writable: Bool {
        (try? FileManager.default.createDirectory(
            at: CuebarFiles.scriptsDirectory, withIntermediateDirectories: true)) != nil
    }
}
