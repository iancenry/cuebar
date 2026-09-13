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
                Button("Speed Up") { engine.adjustSpeed(0.5) }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("Slow Down") { engine.adjustSpeed(-0.5) }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
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
                .frame(width: 620, height: 660)
        }
    }

    private func newScript() {
        let doc = scripts.add()
        draftBody = doc.body
        tokens = []
        engine.loadScript("")
        voice.recycle()
    }
}
