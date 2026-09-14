import SwiftUI
import PromptCore

enum PerformMode: String, CaseIterable {
    case perform, edit
}

/// Perform-first: slim script rail plus a hero reading surface.
/// Edit replaces the surface with the editor — never both at once.
struct ContentView: View {
    @Bindable var engine: PromptEngine
    @Bindable var scripts: ScriptStore
    @Bindable var settings: SettingsStore
    @Binding var draftBody: String
    @Binding var tokens: [ScriptToken]
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    @State private var mode: PerformMode = .perform
    @State private var follow = true
    @State private var sharing = SharingGuard()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(settings: settings, engine: engine,
                   overlay: overlay, voice: voice, tokens: tokens,
                   mode: $mode)
            Divider().opacity(0.4)
            HSplitView {
                SidebarView(scripts: scripts, wordsPerSecond: engine.wordsPerSecond,
                            onPick: pick, onNew: {
                                pick(scripts.add().id)
                            },
                            onCategory: { setCategory($0, for: $1) })
                if mode == .perform {
                    VStack(spacing: 0) {
                        PrompterBody(engine: engine, tokens: tokens, settings: settings,
                                     voice: voice, follow: $follow,
                                     showsFooter: false, showsPageControls: true, showsHeader: false)
                        TransportBar(engine: engine, settings: settings, overlay: overlay,
                                     voice: voice, tokens: tokens, follow: $follow)
                    }
                    .frame(minWidth: 480)
                } else {
                    editor
                }
            }
        }
        .background {
            PlaybackDriver(engine: engine, scripts: scripts, settings: settings,
                           overlay: overlay, voice: voice, tokens: tokens,
                           mode: $mode, pick: pick)
        }
        .background {
            BoostKeys(engine: engine, settings: settings, mode: $mode)
        }
        .onAppear {
            if let doc = scripts.selected { showDraft(doc) }
            sharing.setHidden(settings.settings.hideFromShare)
            // Persisted prefs are the source of truth; the engine starts live.
            engine.setSpeed(settings.settings.wordsPerSecond)
            engine.naturalPacing = settings.settings.naturalPacing
        }
        .onChange(of: scripts.selectedID) { _, new in
            guard let id = new, let doc = doc(matching: id) else {
                draftBody = ""
                tokens = []
                engine.loadScript("")
                return
            }
            showDraft(doc)
        }
        .onChange(of: tokens) { _, new in
            if overlay.isShowing { overlay.update(tokens: new) }
        }
        .onChange(of: settings.settings.overlayMode) { _, _ in
            if overlay.isShowing {
                overlay.show(engine: engine, settings: settings, tokens: tokens, voice: voice)
            }
        }
        .onChange(of: settings.settings.hideFromShare) { _, hide in
            sharing.setHidden(hide)
            // Re-sync overlay chrome: the guard restores captured
            // originals, the overlay re-applies the current setting.
            if overlay.isShowing { overlay.applyChrome() }
        }
        .onChange(of: settings.settings) { _, _ in
            // Transparency, sharing, and size apply live to the open panel.
            if overlay.isShowing { overlay.applyChrome() }
        }
    }

    private var editor: some View {
        Group {
            if let doc = scripts.selected {
                EditView(doc: doc, tokens: tokens, wordsPerSecond: engine.wordsPerSecond,
                         categories: scripts.knownCategories,
                         onRename: { scripts.rename(doc.id, title: $0) },
                         onCategory: { setCategory($0, for: doc.id) },
                         draftBody: $draftBody,
                         onBodyCommitted: { commit($0, for: doc.id) })
            } else {
                ContentUnavailableView("No script selected", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 420)
    }

    private func showDraft(_ doc: ScriptDocument) {
        draftBody = doc.body
        tokens = ScriptParser.parse(doc.body)
        engine.loadScript(doc.body)
        voice.recycle()
    }

    private func commit(_ body: String, for id: UUID) {
        scripts.updateBody(id, body: body)
        engine.loadScript(body, preservingPosition: true)
        tokens = ScriptParser.parse(body)
        voice.recycle()
    }

    private func pick(_ id: UUID) {
        scripts.select(id)
        if let doc = doc(matching: id) {
            showDraft(doc)
        }
    }

    private func setCategory(_ name: String, for id: UUID) {
        scripts.setCategory(name, for: id)
    }

    private func doc(matching id: UUID) -> ScriptDocument? {
        scripts.scripts.first(where: { $0.id == id })
    }
}
