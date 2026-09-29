import SwiftUI
import PromptCore
import AppKit

@main
struct CuebarApp: App {
    @State private var engine = PromptEngine()
    @State private var scripts = ScriptStore()
    @State private var settings: SettingsStore
    @State private var draftBody = ""
    @State private var tokens: [ScriptToken] = []
    /// The parsed script, built once per edit next to `tokens`. Layout,
    /// pages and cue behaviour all read it, so nothing re-parses per frame.
    @State private var index = ScriptIndex(tokens: [])
    @State private var overlay = OverlayController()
    @State private var voice = VoiceTracker()
    @State private var showingCuePalette = false
    @State private var hotkeys: HotkeyCenter
    @State private var globalHotkeys: GlobalHotkeys
    /// Phone remote. App-level rather than owned by the main window,
    /// because the one place a presenter reads the URL is Settings, and a
    /// controller the settings scene cannot see is a controller they cannot
    /// use.
    @State private var remote = RemoteController()
    /// App-lifetime, and shared by the tick loop and the dispatcher: both
    /// move the deck, and two counters is how they end up disagreeing.
    @State private var slideSync = SlideSync()

    init() {
        FontLoader.register()
        // One store, shared: the shortcut map is persisted inside settings,
        // so the dispatcher has to read the very instance Settings writes to.
        let store = SettingsStore()
        _settings = State(initialValue: store)
        _hotkeys = State(initialValue: HotkeyCenter(settings: store))
        _globalHotkeys = State(initialValue: GlobalHotkeys(settings: store))
    }

    /// The dispatcher's app-level half. ContentView holds Follow and the
    /// perform/edit mode; the draft text and the cue sheet live here.
    private var appBridge: AppCommandBridge {
        AppCommandBridge(showCuePalette: { showingCuePalette = true },
                         newScript: newScript,
                         importScripts: importScripts,
                         exportScript: exportSelected)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, scripts: scripts, settings: settings,
                        draftBody: $draftBody, tokens: $tokens, index: $index,
                        overlay: overlay, voice: voice, hotkeys: hotkeys,
                        globalHotkeys: globalHotkeys, app: appBridge,
                        remote: remote, slideSync: slideSync)
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
            CommandMenu("Playback") {
                command(.playPause)
                command(.restart)
                Divider()
                command(.speedUp)
                command(.speedDown)
                command(.fineSpeedUp)
                command(.fineSpeedDown)
                Divider()
                command(.jumpBack)
                command(.jumpForward)
                command(.previousCue)
                command(.nextCue)
                Divider()
                command(.toggleFollow)
                command(.toggleMicrophone)
                command(.toggleOverlay)
                command(.toggleFullscreen)
                Divider()
                command(.insertCue)
            }
            // `after`, not `replacing`: Cuebar is single-window, and macOS's
            // New Window is the way back if the window is ever closed.
            CommandGroup(after: .newItem) {
                command(.newScript)
            }
            CommandGroup(after: .importExport) {
                command(.importScripts)
                command(.exportScript)
            }
        }
        Settings {
            SettingsView(settings: settings, hotkeys: hotkeys, globalHotkeys: globalHotkeys,
                         remote: remote)
                .frame(width: 680, height: 700)
                .preferredColorScheme(.dark)
        }
    }

    /// One row per command, with the live chord spelled out in the title.
    /// No `.keyboardShortcut` anywhere: the key monitor is the single owner
    /// of every Cuebar chord, so a press can't reach two commands, and a
    /// rebind can't leave a stale chord in the menu bar.
    private func command(_ action: ShortcutAction) -> some View {
        Button("\(action.title)  \(settings.settings.shortcuts.chord(for: action).description)") {
            hotkeys.perform(action)
        }
    }

    private func newScript() {
        let doc = scripts.add()
        draftBody = doc.body
        // Both artifacts, always: this command works with the window closed,
        // where no ContentView will rebuild the index for us.
        tokens = []
        index = ScriptIndex(tokens: [])
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

    /// ⌘K: drop a `[cue]` at the editor's caret, or append when the editor
    /// isn't up. The draft is the source of truth, and the store is written
    /// here too — the editor's own commit path is unmounted in Perform mode,
    /// so a cue inserted while presenting would otherwise be discarded.
    private func insertCue(_ inner: String) {
        let snippet = "[\(inner)]"
        let editor = Self.editorTextView()
        let ns = draftBody as NSString
        var body = ns as String
        var selection: NSRange?
        if let editor {
            let location = min(editor.selectedRange().location, ns.length)
            let length = min(editor.selectedRange().length, ns.length - location)
            body = ns.replacingCharacters(in: NSRange(location: location, length: length),
                                          with: snippet)
            // A cue that ends in a space is a blank waiting to be filled —
            // `[slide ]` from the palette — and the caret belongs *inside*
            // the brackets, not after them. Landing it past the `]` would
            // have the number typed outside the cue, where it reads as
            // ordinary script text.
            let caretOffset = inner.hasSuffix(" ")
                ? inner.utf16.count + 1
                : (snippet as NSString).length
            selection = NSRange(location: location + caretOffset, length: 0)
        } else {
            if !body.isEmpty { body += " " }
            body += snippet
        }
        draftBody = body
        if let id = scripts.selectedID {
            scripts.updateBody(id, body: body)
        }
        // A cue is not a word: re-parse for the badge and the cue plan, but
        // don't reload the engine unless the words themselves changed — a
        // reload cancels any timed hold and can stop playback at the tail.
        tokens = ScriptParser.parse(body)
        index = ScriptIndex(tokens: tokens)
        if ScriptParser.words(body) != engine.words {
            engine.loadScript(body, preservingPosition: true)
        }
        voice.recycle()
        // A second ⌘K in a row should land next to the first one.
        if let selection { editor?.setSelectedRange(selection) }
    }

    /// The script editor, wherever it lives. `NSApp.keyWindow` is the cue
    /// palette while ⌘K is being handled, so ask every window instead —
    /// but skip field editors (a title field's editor is an `NSTextView`
    /// too, and splicing a cue at *its* caret would corrupt the script).
    private static func editorTextView() -> NSTextView? {
        for window in NSApp.windows where window.isVisible {
            guard let text = window.firstResponder as? NSTextView,
                  !text.isFieldEditor else { continue }
            return text
        }
        return nil
    }
}
