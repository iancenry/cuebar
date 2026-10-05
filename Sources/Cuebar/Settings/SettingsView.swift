import SwiftUI
import PromptCore

/// A sidebar, not a strip.
///
/// The six tabs this replaced were all still here — nothing was dropped — but
/// a tab strip has to be *remembered*, and a presenter who wants the pause
/// behaviour should not have to open Reading to find out that it lives in
/// Voice. Nine grouped pages with a search field can be navigated without
/// knowing where anything is.
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var hotkeys: HotkeyCenter
    @Bindable var globalHotkeys: GlobalHotkeys
    @Bindable var remote: RemoteController
    /// The library, so the Scripts page can name a folder. Optional because
    /// previews and tests have no store.
    var scripts: ScriptStore? = nil
    var onImportScripts: () -> Void = {}

    @State private var selection = "reading"

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(pages: pages, selection: $selection)
                .frame(maxHeight: .infinity)
            page(for: selection)
                .frame(maxHeight: .infinity)
        }
        // Fills whatever it is given. The size floor belongs to the scene, and
        // it is a floor rather than a size: pinning the content made a taller
        // window centre this block and leave an unpainted strip along the
        // bottom, because the panes stopped short while the window did not.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The same painted field the main window sits on, rather than a flat
        // black rectangle: a settings window is part of the app, and the
        // nearest thing to "unrelated tool" is a bare dark panel.
        .background(ChromeField())
        // The page name rides in the title bar, the way a native settings
        // window does, so the sidebar is navigation rather than the headline.
        .navigationTitle(title(for: selection))
        .navigationSubtitle("Settings")
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private var pages: [SettingsSidebar.Page] {
        [
            // Essentials — what a presenter changes between runs.
            .init(id: "presets", title: "Presets", symbol: "sparkles",
                 keywords: ["profile", "presentation", "podcast", "interview", "recording"],
                 group: .essentials) {
                AnyView(PresetsTab(settings: settings))
            },
            .init(id: "reading", title: "Reading", symbol: "book",
                 keywords: ["speed", "wpm", "words per minute", "highlight", "smooth",
                            "start", "pause", "window", "punctuation"],
                 group: .essentials) {
                AnyView(ReadingTab(settings: settings))
            },
            .init(id: "voice", title: "Voice", symbol: "waveform",
                 keywords: ["microphone", "mic", "follow", "smart pause", "sensitivity",
                            "speech", "language", "engine"],
                 group: .essentials) {
                AnyView(VoiceTab(settings: settings))
            },
            .init(id: "display", title: "Display", symbol: "rectangle.on.rectangle",
                 keywords: ["notch", "floating", "fullscreen", "always on top", "opacity",
                            "overlay", "remote", "privacy"],
                 group: .essentials) {
                AnyView(DisplayTab(settings: settings, remote: remote))
            },
            // Appearance — how it looks, kept together.
            .init(id: "typography", title: "Typography", symbol: "textformat",
                 keywords: ["font", "size", "weight", "colour", "color", "spacing",
                            "dyslexia", "width", "alignment"],
                 group: .appearance) {
                AnyView(TypographyTab(settings: settings))
            },
            .init(id: "theme", title: "Theme", symbol: "paintbrush",
                 keywords: ["theme", "dark", "light", "contrast", "colour", "color",
                            "appearance", "prompter", "surface", "oled"],
                 group: .appearance) {
                AnyView(ThemeTab(settings: settings))
            },
            // Library — the files.
            .init(id: "scripts", title: "Scripts", symbol: "books.vertical",
                 keywords: ["folder", "import", "export", "default", "autosave", "library"],
                 group: .library) {
                AnyView(scripts.map { ScriptsTab(settings: settings, scripts: $0,
                                                   onImport: onImportScripts) }
                    ?? ScriptsTab(settings: settings, scripts: nil,
                                  onImport: onImportScripts))
            },
            .init(id: "scripttools", title: "Script Tools", symbol: "wand.and.stars",
                 keywords: ["ai", "key", "provider", "budget", "model", "tidy"],
                 group: .library) {
                AnyView(ScriptToolsTab(settings: settings))
            },
            // System.
            .init(id: "keyboard", title: "Keyboard", symbol: "command",
                 keywords: ["shortcuts", "chord", "global", "reset", "defaults"],
                 group: .system) {
                AnyView(KeyboardTab(settings: settings, hotkeys: hotkeys,
                                    globalHotkeys: globalHotkeys))
            },
            .init(id: "advanced", title: "Advanced", symbol: "wrench.and.screwdriver",
                 keywords: ["reset", "storage", "permission", "accessibility", "diagnostics",
                            "compatibility", "backup"],
                 group: .system) {
                AnyView(AdvancedTab(settings: settings, globalHotkeys: globalHotkeys))
            },
            .init(id: "general", title: "General", symbol: "gearshape",
                 keywords: ["login", "launch", "delete", "confirm", "restore", "about",
                            "version", "position"],
                 group: .system) {
                AnyView(GeneralTab(settings: settings))
            },
        ]
    }

    private func title(for id: String) -> String {
        pages.first { $0.id == id }?.title ?? "Settings"
    }

    @ViewBuilder
    private func page(for id: String) -> some View {
        if let page = pages.first(where: { $0.id == id }) {
            page.content()
        } else {
            SettingsPage(title: "Not found") {
                SettingsCaption(text: "Pick something on the left.")
            }
        }
    }
}
