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
    let armRemote: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let doc = scripts.selected { showDraft(doc) }
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
                guard let id = new, let found = doc(id) else {
                    draftBody = ""
                    tokens = []
                    indexBinding = ScriptIndex(tokens: [])
                    engine.loadScript("")
                    return
                }
                showDraft(found)
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
                // One index drives the open panel: pages, cues and the empty
                // check all come from it, so a re-render never re-parses.
                if overlay.isShowing { overlay.update(index: new) }
                slideLoad()
            }
            .onChange(of: settings.settings.overlayMode) { _, _ in
                if overlay.isShowing {
                    overlay.show(engine: engine, settings: settings,
                                 index: indexBinding, voice: voice)
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
        slides.load(indexBinding.cuePlan)
    }
}
