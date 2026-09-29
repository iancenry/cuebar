import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
#endif

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
    @Binding var index: ScriptIndex
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    @Bindable var hotkeys: HotkeyCenter
    @Bindable var globalHotkeys: GlobalHotkeys
    let app: AppCommandBridge
    @State private var mode: PerformMode = .perform
    @State private var follow = true
    @State private var windowState = WindowState()
    /// Measured, not assumed: the user can drag the divider, and the dock's
    /// fullscreen centring is derived from it.
    @State private var sidebarWidth: CGFloat = 240
    @State private var sharing = SharingGuard()

    /// Whatever the mode shows, edge to edge. Split out of `body` because
    /// the overlay, the transport dock and the editor together made one
    /// expression the type-checker gave up on.
    @ViewBuilder private var stage: some View {
        if mode == .perform {
            PrompterBody(engine: engine, index: index,
                         settings: settings, voice: voice, follow: $follow,
                         showsFooter: false, showsPageControls: true,
                         bottomInset: 112, topInset: CuePalette.chromeRowHeight,
                         showsHeader: false)
                .overlay(alignment: .bottom) { transport }
        } else {
            // Paint in the editor's margins and around the page; the page
            // itself is an opaque card, so the writing never sits on it.
            editor
                .background(EditorBackdrop())
        }
    }

    /// The dock rides the bottom of the *column*, so its natural centre is
    /// half a sidebar right of the window's midline — which in fullscreen
    /// means half a sidebar right of the notch. Shifting by half the
    /// measured sidebar puts the play button on the screen's centre line.
    /// Windowed it stays on the column's centre, next to the text it
    /// controls. Fullscreen always sizes the window to the screen, so the
    /// dock (700pt) still clears the sidebar with room to spare and needs
    /// no width clamp.
    private var transport: some View {
        TransportBar(engine: engine, settings: settings, overlay: overlay,
                     voice: voice, index: index, follow: $follow)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .offset(x: windowState.isFullscreen ? -sidebarWidth / 2 : 0)
    }

    var body: some View {
        HSplitView {
            SidebarView(scripts: scripts, wordsPerSecond: engine.wordsPerSecond,
                        onPick: pick, onNew: {
                            pick(scripts.add().id)
                        },
                        onCategory: { setCategory($0, for: $1) },
                        onExport: { ScriptIO.export($0) })
                .background(SidebarBackdrop())
                .background {
                    GeometryReader { _ in
                        Color.clear
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                                sidebarWidth = $0
                            }
                    }
                }
            // The content column owns the (slim) top bar; the traffic
            // lights live over the sidebar like Codex — no app-title
            // strip spanning the window. In Perform the reading canvas
            // runs edge to edge and the chrome floats over it as glass.
            ZStack(alignment: .top) {
                stage
                // Over the canvas, never a row in it: a row would expose the
                // column background above the reading surface and paint the
                // band this layout is trying not to have. The canvas runs to
                // the window top and the chrome floats on it as glass, so
                // the two are one surface.
                TopBar(settings: settings, engine: engine,
                       overlay: overlay, voice: voice, index: index,
                       mode: $mode)
            }
            .ignoresSafeArea(.container, edges: .top)
            .background(CuePalette.chrome)
            .frame(minWidth: 520)
        }
        .background {
            WindowConfigurator(state: windowState)
        }
        .background {
            PlaybackDriver(engine: engine, scripts: scripts, settings: settings,
                           overlay: overlay, voice: voice, index: index,
                           mode: $mode, pick: pick)
        }
        .background {
            BoostKeys(engine: engine, settings: settings, mode: $mode)
        }
        .background {
            HotkeyWiring(hotkeys: hotkeys, globalHotkeys: globalHotkeys, app: app,
                         shortcuts: settings.settings.shortcuts, index: index,
                         context: CommandContext(engine: engine, voice: voice,
                                                 overlay: overlay, follow: $follow,
                                                 mode: $mode, index: index),
                         mode: $mode)
        }
        .onAppear {
            if let doc = scripts.selected { showDraft(doc) }
            // The global key tap needs both collaborators, and neither
            // exists at App-init time.
            globalHotkeys.attach(hotkeys: hotkeys, overlay: overlay)

            sharing.setHidden(settings.settings.hideFromShare)
            // Persisted prefs are the source of truth; the engine starts live.
            engine.setSpeed(settings.settings.wordsPerSecond)
            engine.naturalPacing = settings.settings.naturalPacing
        }
        .onChange(of: scripts.selectedID) { _, new in
            guard let id = new, let doc = doc(matching: id) else {
                draftBody = ""
                tokens = []
                index = ScriptIndex(tokens: [])
                engine.loadScript("")
                return
            }
            showDraft(doc)
        }
        .onChange(of: index) { _, new in
            // One index drives the open panel: pages, cues and the empty
            // check all come from it, so a re-render never re-parses.
            if overlay.isShowing { overlay.update(index: new) }
        }
        .onChange(of: overlay.isShowing) { _, _ in
            // The global tap only runs while presenting.
            globalHotkeys.sync()
        }
        .onChange(of: settings.settings.overlayMode) { _, _ in
            if overlay.isShowing {
                overlay.show(engine: engine, settings: settings, index: index, voice: voice)
            }
        }
        .onChange(of: settings.settings.hideFromShare) { _, hide in
            sharing.setHidden(hide)
        }
        .onChange(of: settings.settings) { _, _ in
            // Transparency, sharing, and size apply live to the open panel
            // — but only when a window-relevant field actually changed.
            if overlay.isShowing { overlay.settingsDidChange(settings.settings) }
        }
    }

    private var editor: some View {
        Group {
            if let doc = scripts.selected {
                EditView(doc: doc, index: index,
                         wordsPerSecond: engine.wordsPerSecond,
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
        adopt(body: doc.body, preservingPosition: false)
    }

    private func commit(_ body: String, for id: UUID) {
        scripts.updateBody(id, body: body)
        adopt(body: body, preservingPosition: true)
    }

    /// Parse once, into the one structure everything else reads.
    private func adopt(body: String, preservingPosition: Bool) {
        let parsed = ScriptParser.parse(body)
        tokens = parsed
        index = ScriptIndex(tokens: parsed)
        engine.loadScript(body, preservingPosition: preservingPosition)
        voice.recycle()
    }

    /// `scripts.select` publishes the change, and the `onChange` above does
    /// the load — loading here too would parse and index the script twice.
    private func pick(_ id: UUID) {
        scripts.select(id)
    }

    private func setCategory(_ name: String, for id: UUID) {
        scripts.setCategory(name, for: id)
    }

    private func doc(matching id: UUID) -> ScriptDocument? {
        scripts.scripts.first(where: { $0.id == id })
    }
}
