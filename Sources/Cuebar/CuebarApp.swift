import SwiftUI
import PromptCore
import AppKit

@main
struct CuebarApp: App {
    @State private var engine = PromptEngine()
    @State private var scripts = ScriptStore()
    @State private var settings = SettingsStore()
    @State private var draftBody = ""
    @State private var tokens: [ScriptToken] = []
    @State private var overlay = OverlayController()
    @State private var voice = VoiceTracker()
    @State private var showingCuePalette = false

    init() {
        FontLoader.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, scripts: scripts, settings: settings,
                        draftBody: $draftBody, tokens: $tokens, overlay: overlay, voice: voice)
                .frame(minWidth: 1080, minHeight: 660)
                // Camera-facing dark prompter: the palette is tuned for
                // dark surfaces, so the app never follows Light Mode
                // (where paper-white inks wash out on white chrome).
                .preferredColorScheme(.dark)
                .sheet(isPresented: $showingCuePalette) {
                    CuePaletteView { inner in
                        insertCue(inner)
                        showingCuePalette = false
                    }
                }
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
                Button("Import Scripts…") { importScripts() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Export Script…") { exportSelected() }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Insert Cue…") { showingCuePalette = true }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }
        Settings {
            SettingsView(settings: settings)
                .frame(width: 680, height: 700)
                .preferredColorScheme(.dark)
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

    /// ⌘O / File menu: turn .txt/.md files into scripts.
    private func importScripts() {
        guard let parsed = ScriptIO.importScripts(), !parsed.isEmpty else { return }
        var lastID: UUID?
        for item in parsed {
            lastID = scripts.importScript(title: item.title, body: item.body).id
        }
        if let lastID {
            scripts.select(lastID)
        }
    }

    /// ⌘S / File menu: save the selected script wherever the user wants.
    private func exportSelected() {
        guard let doc = scripts.selected else { return }
        ScriptIO.export(doc)
    }

    /// ⌘K: drop a `[cue]` at the editor's caret, or append when nothing
    /// is focused. The editor's draft is the source of truth, so the
    /// insertion flows through the normal commit path.
    private func insertCue(_ inner: String) {
        let snippet = "[\(inner)]"
        var body = draftBody
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            let ns = body as NSString
            let location = min(editor.selectedRange().location, ns.length)
            let length = min(editor.selectedRange().length, ns.length - location)
            body = ns.replacingCharacters(in: NSRange(location: location, length: length),
                                          with: snippet)
        } else {
            if !body.isEmpty { body += " " }
            body += snippet
        }
        draftBody = body
    }
}
