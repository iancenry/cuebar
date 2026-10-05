import SwiftUI
import PromptCore
import AppKit

@main
struct CuebarApp: App {
    @State private var engine = PromptEngine()
    @State private var scripts = ScriptStore()
    @State private var settings: SettingsStore
    /// Where the presenter was in each script. Owned by the app because both
    /// the window and the driver write to it, and because it has to outlive the
    /// window: the point of it is surviving an *unexpected* quit.
    @State private var positions = PositionStore()
    @State private var draftBody = ""
    /// Which script `draftBody` is the text *of*.
    ///
    /// `draftBody` is app-level state but it is written by the view, so a
    /// selection can change with the window closed — auto-next on the tick, an
    /// import landing from a link, an archive from the menu — and ⌘K would then
    /// append a cue to the previous talk's text and write that into whichever
    /// script is selected now. One writer means one id to check against.
    @State private var draftScriptID: UUID?
    @State private var tokens: [ScriptToken] = []
    /// The parsed script, built once per edit next to `tokens`. Layout,
    /// pages and cue behaviour all read it, so nothing re-parses per frame.
    @State private var index = ScriptIndex(tokens: [])
    @State private var overlay = OverlayController()
    @State private var voice = VoiceTracker()
    @State private var showingCuePalette = false
    /// "Import from Web Page…". A sheet rather than a prompt: the fetch can
    /// fail, and a failure with nowhere to show a URL is a dead end.
    @State private var showingWebImport = false
    /// "Script Tools…" — the model-backed half, behind a key the user
    /// supplies. It is a sheet rather than a command with an immediate
    /// effect because the whole point is to *see* the rewrite first.
    @State private var showingScriptTools = false
    /// The file importer. SwiftUI presents it on the right window itself —
    /// and it has to be SwiftUI: `NSApp.keyWindow` and `NSApp.mainWindow`
    /// are both nil in a `WindowGroup` app like this one (measured), so an
    /// `NSOpenPanel` had no window to attach to and simply never appeared.
    @State private var showingImporter = false
    /// Rehearsal. App-lifetime so a run survives the window closing and
    /// reopening — and so the prompter and the transport read one plan.
    @State private var practice = PracticeController()
    /// A rehearsal run. App-lifetime for the same reason practice is: the
    /// report has to survive the window closing, and the recorder is fed by
    /// the tick loop rather than by anything the window owns.
    @State private var recorder = RunRecorder()
    /// "Pacing Notes" — the offline diagnosis, and the reason a key is not
    /// needed to find out a script is unsayable.
    @State private var showingPacing = false
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

    /// The report sheet needs a binding, and the recorder owns the flag
    /// because it outlives this view. One property, one writer.
    private var showingRunReport: Binding<Bool> {
        Binding(get: { recorder.isShowingReport },
                set: { recorder.isShowingReport = $0 })
    }

    /// The dispatcher's app-level half. ContentView holds Follow and the
    /// perform/edit mode; the draft text and the cue sheet live here.
    private var appBridge: AppCommandBridge {
        AppCommandBridge(setDraft: setDraft, positions: positions,
                         resumeReading: { resumeReading() },
                         showCuePalette: { showingCuePalette = true },
                         newScript: newScript,
                         importScripts: importScripts,
                         exportScript: exportSelected,
                         newScriptFromClipboard: pasteNewScript,
                         importFromWeb: { showingWebImport = true },
                         togglePractice: { practice.toggle() },
                         revealPractice: { practice.toggleReveal() },
                         analyseScript: { showingPacing = true },
                         scriptTools: { showingScriptTools = true },
                         toggleBold: { insertEmphasis(marker: "**") },
                         toggleItalic: { insertEmphasis(marker: "*") })
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, scripts: scripts, settings: settings,
                        draftBody: $draftBody, tokens: $tokens, index: $index,
                        overlay: overlay, voice: voice, hotkeys: hotkeys,
                        globalHotkeys: globalHotkeys, app: appBridge,
                        remote: remote, slideSync: slideSync, practice: practice,
                        recorder: recorder)
                .frame(minWidth: 1080, minHeight: 660)
                // The palette used to be forced dark here. It is not any more:
                // the *reading surface* still never goes light unless the
                // presenter asks for it (see `ThemeChoice.resolveSurface`),
                // while the chrome around it may be light — which is what makes
                // the window pleasant to work in on a bright afternoon.
                .cuebarTheming(settings)
                // The one thing that must not be left to a debounce: a quit.
                // Positions are recorded on every tick, so the store's window is
                // short — but ⌘Q must not exit with a pending write, because
                // "never lose my place" that loses it on quit is a joke.
                .onDisappear { positions.saveNow() }
                .sheet(isPresented: $showingCuePalette) {
                    CuePaletteView { inner in
                        insertCue(inner)
                        showingCuePalette = false
                    }
                }
                .sheet(isPresented: $showingPacing) {
                    if let doc = scripts.selected {
                        PacingNotesView(script: doc.body) { body in
                            applyRewrite(body, to: doc.id)
                        }
                    }
                }
                .sheet(isPresented: showingRunReport) {
                    if let result = recorder.result {
                        RunResultsView(result: result, clip: recorder.recordingURL) {
                            recorder.dismissReport()
                        }
                    }
                }
                .sheet(isPresented: $showingScriptTools) {
                    if let doc = scripts.selected {
                        // The *draft*, not `doc.body`. The editor commits on a
                        // 400 ms debounce, so for up to that long the store is
                        // behind the text on screen — and a diff previewed
                        // against the older body, then applied, discarded those
                        // last keystrokes from both the editor and the store.
                        ScriptToolsView(script: draftBody.isEmpty ? doc.body : draftBody,
                                        settings: settings.settings.ai,
                                        wordsPerMinute: Int(settings.settings.wordsPerMinute)) { body in
                            applyRewrite(body, to: doc.id)
                        }
                    }
                }
                .sheet(isPresented: $showingWebImport) {
                    WebImportView { script in
                        ScriptIntake.land(ScriptImport.Outcome(scripts: [script], rejected: []),
                                          in: scripts)
                        showingWebImport = false
                    }
                }
                // `cuebar://script?url=…`. A custom scheme is an *event*,
                // not a document, so it reuses the window instead of
                // asking for a new one — which is the whole reason document
                // types are not declared.
                .onOpenURL { url in
                    openExternally(url)
                }
                .fileImporter(isPresented: $showingImporter,
                              allowedContentTypes: ScriptIO.importTypes(),
                              allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls):
                        importFiles(urls)
                    case .failure(let error):
                        // A cancelled panel reports a failure; saying so
                        // would put an alert in front of somebody who
                        // simply changed their mind.
                        let code = (error as NSError).code
                        if code != NSUserCancelledError {
                            ScriptIO.report("Couldn't read those files",
                                            error.localizedDescription)
                        }
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
                command(.toggleRecording)
                Divider()
                // Every action with a chord gets a row that spells it out.
                // These two had chords and Settings entries but nothing in the
                // menu, so the invariant "a rebind moves the command *and its
                // row*" did not hold for them and they were undiscoverable.
                command(.nextSlide)
                command(.previousSlide)
                Divider()
                command(.resumeReading)
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
                // No chord, deliberately: a shortcut for "show me my files"
                // would collide with the keyboard for no reason, and the
                // monitor is the only thing allowed to own a chord.
                Button("Reveal Library in Finder") { ScriptIntake.revealLibrary() }
                Divider()
                command(.newScriptFromClipboard)
                command(.importFromWeb)
                Divider()
                command(.togglePractice)
                command(.revealPractice)
                Divider()
                command(.analyseScript)
                command(.scriptTools)
            }
        }
        Settings {
            SettingsView(settings: settings, hotkeys: hotkeys, globalHotkeys: globalHotkeys,
                         remote: remote, scripts: scripts,
                         onImportScripts: importScripts)
                // A *minimum*, not a fixed size. Pinning the content to
                // 880×640 made the window resizable around a block that did
                // not grow with it, so a taller window centred that block and
                // left an unpainted strip along the bottom — the paint and the
                // panes stopped short while the window did not. The size floor
                // belongs to the view, which fills whatever it is given.
                .frame(minWidth: 880, minHeight: 640)
                .cuebarTheming(settings)
                // The one thing that must not be left to a debounce: a quit.
                // Positions are recorded on every tick, so the store's window is
                // short — but ⌘Q must not exit with a pending write, because
                // "never lose my place" that loses it on quit is a joke.
                .onDisappear { positions.saveNow() }
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

    /// ⌘O / File menu: turn .txt, .md, .rtf, .docx, .pdf and .html files
    /// into scripts. Just presenting; the files arrive in `importFiles`
    /// through the importer above.
    private func importScripts() {
        showingImporter = true
    }

    /// Files chosen in the importer, or handed to the app by Finder.
    private func importFiles(_ urls: [URL]) {
        let outcome = ScriptIO.importFiles(urls, existingTitles: scripts.titles)
        ScriptIntake.land(outcome, in: scripts)
        ScriptIO.reportRejected(outcome)
    }

    /// ⇧⌘V: the pasteboard, as a script.
    ///
    /// Async because "a link and nothing else" means a fetch. The command
    /// stays app-level — it works with the main window closed, exactly like
    /// Import — and the store's `lastImportedID` is what brings the result
    /// on stage when a window is there to do it.
    private func pasteNewScript() {
        Task {
            guard let outcome = await ScriptIO.fromClipboard(existingTitles: scripts.titles),
                  !outcome.isEmpty else { return }
            ScriptIntake.land(outcome, in: scripts)
        }
    }

    /// A URL handed to the app: a file, or a `cuebar://` link asking for a
    /// page. The file case exists for `cuebar://script?url=file:///…` and
    /// for a drag onto the Dock icon; ordinary file opening goes through
    /// the panel or a drop, both of which the window owns.
    private func openExternally(_ url: URL) {
        if url.isFileURL {
            importFiles([url])
            return
        }
        // cuebar://script?url=… — the sheet, pre-filled. A link is a
        // request for a specific page, not a general-purpose fetcher, so the
        // URL still has to be typed into the field and confirmed.
        if url.scheme == "cuebar", let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value, !page.isEmpty {
            if showingWebImport {
                // Re-present it. A sheet that is already up does not re-run
                // its `.task`, so the second link was silently dropped — and
                // then fetched by whatever presentation came next, which is
                // not the page the user just clicked on.
                showingWebImport = false
                DispatchQueue.main.async {
                    WebImportView.pendingURL = page
                    showingWebImport = true
                }
                return
            }
            WebImportView.pendingURL = page
            showingWebImport = true
            return
        }
        showingWebImport = true
    }

    /// ⌘S / File menu: save the selected script wherever the user wants.
    private func exportSelected() {
        guard let doc = scripts.selected else { return }
        ScriptIO.export(doc)
    }

    /// A body came back from a tool that rewrote it: store it, adopt it, and
    /// re-index — through exactly one place, because the prompter, the driver
    /// and the overlay all read the index and a second copy of this is how
    /// they end up disagreeing.
    ///
    /// The engine reloads only when the *words* changed: a staging cue must
    /// not cancel a timed hold that is running.
    /// Called whenever the draft is re-pointed at a script.
    func setDraft(_ body: String, for id: UUID) {
        draftBody = body
        draftScriptID = id
    }

    /// The whole point, as a command: go back to where this script was being
    /// read. Bound to a chord so it is reachable mid-talk with the window
    /// closed, which is exactly when it is needed.
    func resumeReading() {
        guard let id = scripts.selectedID,
              let position = positions.position(for: id),
              let words = engine.words.isEmpty ? nil : engine.words.count,
              let index = position.resumeIndex(into: words) else { return }
        engine.jumpTo(wordIndex: index)
    }



    private func applyRewrite(_ body: String, to id: UUID) {
        // Only the open script can take a rewrite. A sheet outlives a
        // selection change — a `cuebar://` open, a watcher event that dropped
        // the selected file — and writing another script's text into the
        // prompter's draft and engine is not a mistake anybody can undo.
        guard id == scripts.selectedID else { return }
        scripts.updateBody(id, body: body)
        draftBody = body
        let parsed = ScriptParser.parse(body)
        tokens = parsed
        index = ScriptIndex(tokens: parsed)
        if ScriptParser.words(body) != engine.words {
            engine.loadScript(body, preservingPosition: true)
        }
        voice.recycle()
    }

    /// ⌘K: drop a `[cue]` at the editor's caret, or append when the editor
    /// isn't up. The draft is the source of truth, and the store is written
    /// here too — the editor's own commit path is unmounted in Perform mode,
    /// so a cue inserted while presenting would otherwise be discarded.
    private func insertCue(_ inner: String) {
        guard let selectedID = scripts.selectedID,
              draftScriptID == nil || draftScriptID == selectedID else { return }
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
        scripts.updateBody(selectedID, body: body)
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

    /// ⌘B / ⌘I: mark the selection, or the word at the caret.
    ///
    /// Here rather than in `EditView` for the same reason `insertCue` is: the
    /// key monitor is the single owner of every chord, so the command has to
    /// be dispatchable from the app — and the toolbar button it replaces was
    /// the second owner of the same edit.
    ///
    /// The markers stay in the file and come off before anything is said, so
    /// this writes text and nothing else: no engine reload is needed unless
    /// the *words* changed, which for `**` they never do. That is the whole
    /// reason bold is safe in a teleprompter.
    private func insertEmphasis(marker: String) {
        guard let selectedID = scripts.selectedID,
              draftScriptID == nil || draftScriptID == selectedID else { return }
        guard let editor = Self.editorTextView() else { return }
        let plan = EmphasisInsert.plan(for: draftBody, selection: editor.selectedRange(),
                                       marker: marker)
        draftBody = plan.text
        scripts.updateBody(selectedID, body: plan.text)
        tokens = ScriptParser.parse(plan.text)
        index = ScriptIndex(tokens: tokens)
        if ScriptParser.words(plan.text) != engine.words {
            engine.loadScript(plan.text, preservingPosition: true)
        }
        voice.recycle()
        // The next turn, once the new text has landed — the same reason
        // `insertCue` sets the range last.
        DispatchQueue.main.async {
            let clamped = min(plan.caret, (plan.text as NSString).length)
            editor.setSelectedRange(plan.selected ?? NSRange(location: clamped, length: 0))
        }
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
