import SwiftUI
import PromptCore

/// Everything ContentView reacts to, in one place.
///
/// Two reasons this is a modifier rather than a tail of `.onChange` calls
/// on `body`:
///
/// - **`body` had stopped type-checking.** Chaining eight change handlers
///   onto an already-large expression put the compiler over its budget, and
///   the failure is a wall of "unable to type-check in reasonable time" with
///   no hint which handler caused it. Each closure is now checked in a small
///   context.
/// - **Two handlers were watching `overlay.isShowing`.** One armed the
///   remote, one synced the global key tap. Both worked, and they were one
///   merge away from someone adding a third thing to the "arm" handler and
///   wondering why it needed the other one too. Every reaction to the
///   prompter appearing or going away now happens in one block.
struct ContentLifecycle: ViewModifier {
    let scripts: ScriptStore
    let index: ScriptIndex
    let settings: SettingsStore
    let engine: PromptEngine
    let voice: VoiceTracker
    let overlay: OverlayController
    let remote: RemoteController
    let hotkeys: HotkeyCenter
    let globalHotkeys: GlobalHotkeys
    let slides: SlideSyncing
    /// What the deck was last told, so a re-index that did not change the
    /// slide cues does not reset it. A box rather than `@State` because this
    /// modifier is a struct recreated on every update: `@State` would be reset
    /// with it, and a store would be writing to the heap on the hot path.
    private final class SlideLoadMemory: @unchecked Sendable {
        var plan: [Int: ReadingWindow.CueTrigger] = [:]
        var scriptID: UUID?
    }
    private let slideMemory = SlideLoadMemory()
    /// Rehearsal state. The plan is rebuilt whenever the script changes —
    /// gaps from one script over another would be nonsense.
    let practice: PracticeController
    /// The rehearsal recorder. It needs the script's shape (word count and
    /// section starts) so a report started from the transport can say "of 812
    /// words, you reached 640" without the transport knowing what a word is.
    let recorder: RunRecorder
    /// Saved reading positions, so a deleted script's place goes with it.
    var positions: PositionStore? = nil
    let sharing: SharingGuard
    /// The selected script, cleared when there isn't one. Bound rather than
    /// passed so the handler can clear the draft, the index and the engine
    /// together — the three of which have to agree or the prompter renders a
    /// different script from the one the driver is cueing.
    @Binding var draftBody: String
    @Binding var tokens: [ScriptToken]
    @Binding var indexBinding: ScriptIndex
    let showDraft: (ScriptDocument) -> Void
    let doc: (UUID) -> ScriptDocument?
    /// Put the prompter on stage. Called when a script arrives from outside
    /// the app — the reason it is a closure is that `mode` is ContentView's
    /// state and the import commands run above the view tree.
    let presentNewScript: () -> Void
    let armRemote: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let doc = scripts.selected {
                    showDraft(doc)
                    let words = ScriptParser.words(doc.body)
                    practice.prepare(scriptID: doc.id, words: words)
                    recorder.describe(words: words.count, sections: indexBinding.sections)
                }
                slides.connect(settings.settings.deckApp.driver)
                slideLoad()
                // The global key tap needs both collaborators, and neither
                // exists at App-init time.
                globalHotkeys.attach(hotkeys: hotkeys, overlay: overlay)
                // Reopening the window with the prompter already up must not
                // leave the remote disarmed: `onChange` only sees edges, and
                // `arm` is idempotent, so asking again is free.
                if overlay.isShowing { armRemote() }
                sharing.setHidden(settings.settings.hideFromShare)
                // Persisted prefs are the source of truth; the engine starts live.
                engine.setSpeed(settings.settings.wordsPerSecond)
                engine.naturalPacing = settings.settings.naturalPacing
            }
            .onChange(of: scripts.selectedID) { _, new in
                if let id = new, let found = doc(id) {
                    let words = ScriptParser.words(found.body)
                    practice.prepare(scriptID: id, words: words)
                    recorder.describe(words: words.count, sections: indexBinding.sections)
                }
                guard let id = new, let found = doc(id) else {
                    draftBody = ""
                    tokens = []
                    indexBinding = ScriptIndex(tokens: [])
                    engine.loadScript("")
                    return
                }
                showDraft(found)
            }
            .onChange(of: scripts.lastImportedID) { _, id in
                // "Paste and go": a script that came from the clipboard, a
                // file, a drop or a web page is *already* the thing being
                // presented, so the editor would be a step between the user
                // and the stage. Watched by id rather than read on
                // selection, because selecting a script the user then went
                // back to must not yank them out of the editor later.
                guard id != nil else { return }
                presentNewScript()
                scripts.clearImported()
            }
            .onChange(of: scripts.scripts.map(\.id)) { before, after in
                // A deleted script's saved place goes with it, so a large
                // library does not accumulate positions for talks that no
                // longer exist.
                let remaining = Set(after)
                for gone in Set(before).subtracting(remaining) { positions?.forget(gone) }
            }
            .onChange(of: overlay.isShowing) { _, showing in
                // Everything that depends on the prompter being up, in one
                // place: the remote's server, the global key tap, and the
                // deck driver.
                if showing {
                    armRemote()
                    overlay.update(index: indexBinding)
                    slideLoad()
                } else {
                    remote.disarm()
                }
                globalHotkeys.sync()
            }
            .onChange(of: settings.settings.deckApp) { _, app in
                // Rebuilding the driver is the only way the setting takes
                // effect, and doing it here rather than per-tick keeps the
                // AppleScript object off the hot path.
                slides.connect(app.driver)
            }
            .onChange(of: settings.settings.advertiseRemote) { _, _ in
                // A live listener can't start or stop advertising in place,
                // so changing this rebuilds it — and the address moves.
                if overlay.isShowing { armRemote() }
            }
            .onChange(of: indexBinding) { _, new in
                // The report's denominator and its section list, from the
                // one parse everything else reads. A run that started before
                // the script was re-indexed would otherwise report against
                // whatever was loaded when it began.
                recorder.describe(words: indexBinding.wordTokenIndices.count,
                                  sections: new.sections)
                // One index drives the open panel: pages, cues and the empty
                // check all come from it, so a re-render never re-parses.
                if overlay.isShowing { overlay.update(index: new) }
                // Only reload the deck when the *slide cues* changed.
                // Reloading builds a fresh `SlidePosition`, which starts at
                // slide 1 and clears the crossed history — so staging a cue
                // with ⌘K, or committing any edit, rewound the deck mid-talk and
                // the next bare `[slide]` then jumped the presenter's actual
                // deck backwards. Comparing the script id as well as the plan
                // matters: two different talks can have identical cue plans,
                // and switching scripts must still start the new deck at 1.
                let triggers: [Int: ReadingWindow.CueTrigger] = new.cuePlan.triggers
                let planChanged: Bool = triggers != slideMemory.plan
                    || scripts.selectedID != slideMemory.scriptID
                if planChanged {
                    slideLoad()
                }
            }
            .onChange(of: settings.settings.overlayMode) { _, _ in
                if overlay.isShowing {
                    overlay.show(engine: engine, settings: settings,
                                 index: indexBinding, voice: voice, practice: practice)
                }
            }
            .onChange(of: settings.settings.hideFromShare) { _, hide in
                sharing.setHidden(hide)
            }
            .onChange(of: settings.settings) { _, _ in
                // Transparency, sharing, and size apply live to the open
                // panel — but only when a window-relevant field actually
                // changed.
                if overlay.isShowing { overlay.settingsDidChange(settings.settings) }
            }
    }

    /// A new script is a new deck position: keeping the old one would leave
    /// the phone on "slide 7" for a talk that opens on its title slide.
    /// Wired through the shared sync so the driver and the stepper can't
    /// disagree about where the deck is.
    private func slideLoad() {
        slideMemory.plan = indexBinding.cuePlan.triggers
        slideMemory.scriptID = scripts.selectedID
        slides.load(indexBinding.cuePlan)
    }
}
