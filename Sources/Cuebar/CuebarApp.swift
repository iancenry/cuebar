import SwiftUI
import PromptCore

@main
struct CuebarApp: App {
    @State private var engine = PromptEngine()
    @State private var scripts = ScriptStore()
    @State private var settings = SettingsStore()
    @State private var draftBody = ""
    @State private var tokens: [ScriptToken] = []
    @State private var overlay = OverlayController()
    @State private var voice = VoiceTracker()

    init() {
        FontLoader.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, scripts: scripts, settings: settings,
                        draftBody: $draftBody, tokens: $tokens, overlay: overlay, voice: voice)
                .frame(minWidth: 1080, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Play / Pause") { engine.toggle() }
                    .keyboardShortcut(.space, modifiers: [.option])
                Button("Speed Up 10 WPM") { adjustWPM(by: 10) }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("Slow Down 10 WPM") { adjustWPM(by: -10) }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                Button("Speed Up 1 WPM (Fine)") { adjustWPM(by: 1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button("Slow Down 1 WPM (Fine)") { adjustWPM(by: -1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                Button("Back 10 Words") { engine.jumpRelative(words: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Forward 10 Words") { engine.jumpRelative(words: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
                Divider()
                Button("New Script") { newScript() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }
        Settings {
            SettingsView(settings: settings)
                .frame(width: 640, height: 700)
        }
    }

    /// Single funnel for keyboard speed changes: settings stay the persisted
    /// source of truth, the engine follows instantly (its ramp smooths it).
    private func adjustWPM(by delta: Double) {
        let next = min(480, max(30, (settings.settings.wordsPerMinute + delta).rounded()))
        settings.settings.wordsPerMinute = next
        engine.setSpeed(settings.settings.wordsPerSecond)
    }

    private func newScript() {
        let doc = scripts.add()
        draftBody = doc.body
        tokens = []
        engine.loadScript("")
        voice.recycle()
    }
}
