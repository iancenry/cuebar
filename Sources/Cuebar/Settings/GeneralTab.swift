import SwiftUI
import AppKit
import PromptCore
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// General: the app's own behaviour, not the reading of a script.
struct GeneralTab: View {
    @Bindable var settings: SettingsStore
    @State private var loginError: String?

    var body: some View {
        SettingsPage(title: "General",
                     subtitle: "How Cuebar behaves when you are not reading.") {
            SettingsCard(title: "Starting up") {
                ToggleRow(title: "Launch at login",
                          isOn: $settings.settings.launchAtLogin,
                          caption: "Opens Cuebar by itself every time you turn on your Mac.")
                    .onChange(of: settings.settings.launchAtLogin) { _, wanted in
                        applyLaunchAtLogin(wanted)
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ToggleRow(title: "Restore last position",
                          isOn: $settings.settings.restoreLastPosition,
                          caption: "Reopen a script where you were reading it, rather than at "
                                 + "the top. Turn it off if you rehearse something else between runs.")
            }
            SettingsCard(title: "Your scripts") {
                ToggleRow(title: "Confirm before deleting",
                          isOn: $settings.settings.confirmBeforeDeleting,
                          caption: "Deleting a script deletes its file.")
                SettingRow(label: "Library") {
                    Button("Show in Finder") { ScriptIntake.revealLibrary() }
                }
                SettingsCaption(text: "One Markdown file per script in "
                    + "~/Documents/Cuebar/Scripts. Open one in any editor — Cuebar "
                    + "notices the change and offers you both versions.")
            }
            SettingsCard(title: "About") {
                SettingRow(label: "Version") {
                    Text(Self.version)
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(CuePalette.ink)
                }
                SettingRow(label: "Scripts") {
                    Text(CuebarFiles.scriptsDirectory.path)
                        .font(.caption).monospaced()
                        .foregroundStyle(CuePalette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// `SMAppService`, not a login item file: it is the supported way, it needs
    /// no helper bundle, and it reports back when the registration fails —
    /// which a hand-written plist does not.
    private func applyLaunchAtLogin(_ wanted: Bool) {
        #if canImport(ServiceManagement)
        do {
            if wanted, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !wanted, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            // An unsigned dev build cannot register, and saying "failed" beats
            // a switch that silently does nothing.
            loginError = "macOS would not change that: \(error.localizedDescription)"
            settings.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        #endif
    }

    static var version: String {
        let bundle = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(bundle) (\(build))"
    }
}

/// The library: where scripts come from and go to, and where new ones land.
struct ScriptsTab: View {
    @Bindable var settings: SettingsStore
    var scripts: ScriptStore?
    /// A real closure, not `NSApp.sendAction` with a selector string: a renamed
    /// command would silently stop working, and the settings page is not the
    /// place for a magic string.
    var onImport: () -> Void = {}

    var body: some View {
        SettingsPage(title: "Scripts",
                     subtitle: "Your talks are files, not rows in a database.") {
            SettingsCard(title: "New scripts") {
                if let folder = settings.settings.defaultFolderID, let scripts {
                    SettingsCaption(text: "New scripts go to "
                        + "“\(scripts.folderName(folder))”.")
                } else {
                    SettingsCaption(text: "New scripts are filed beside whichever script is "
                        + "open. Pick a folder here to always use one instead.")
                }
                HStack(spacing: 8) {
                    ForEach(scripts?.folderRows() ?? [], id: \.folder.id) { row in
                        let isChosen = settings.settings.defaultFolderID == row.folder.id
                        Button {
                            settings.settings.defaultFolderID = row.folder.id
                        } label: {
                            Text(row.depth == 0 ? row.folder.name
                                 : String(repeating: "  ", count: row.depth) + row.folder.name)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isChosen ? CuePalette.peach.opacity(0.25) : .clear,
                                            in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(
                                        isChosen ? CuePalette.peach : CuePalette.hairline,
                                        lineWidth: 1)
                                }
                                .foregroundStyle(CuePalette.ink)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Beside the open script") {
                        settings.settings.defaultFolderID = nil
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            SettingsCard(title: "Import and export") {
                SettingsCaption(text: "Cuebar reads .txt, .md, .rtf, .docx, .html, .pdf and "
                    + "web pages, and writes .txt, .md, .html, .pdf and .docx. Drop a file "
                    + "anywhere on the window to import it.")
                HStack(spacing: 10) {
                    Button("Reveal Library in Finder") { ScriptIntake.revealLibrary() }
                    Button("Import…") { onImport() }
                }
                .controlSize(.small)
            }
            SettingsCard(title: "Default pace") {
                LabeledSlider(title: "Words per minute",
                              display: "\(Int(settings.settings.clampedWordsPerMinute)) wpm",
                              value: Binding(
                                get: { settings.settings.wordsPerMinute },
                                set: { settings.settings.setWordsPerMinute($0) }),
                              range: 30...480, step: 1)
                SettingsCaption(text: "Used for the reading-time estimate and by Trim to a "
                    + "length. Presets and voice tracking both adjust from here.")
            }
        }
    }
}