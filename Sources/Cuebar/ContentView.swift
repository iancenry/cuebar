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
    @Bindable var remote: RemoteController
    @State private var mode: PerformMode = .perform
    @State private var follow = true
    @State private var windowState = WindowState()
    /// Measured, not assumed: the user can drag the divider, and the dock's
    /// fullscreen centring is derived from it.
    @State private var sidebarWidth: CGFloat = 240
    @State private var sharing = SharingGuard()
    // The remote is owned by the app so the settings scene can show its
    // URL. It is armed by the prompter overlay rather than by a setting:
    // a server that can move a live talk has no business listening while
    // the app is just sitting there.

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
                // Clear the floating chrome. The mode switcher is an
                // overlay on the column, and the editor's own 24pt was
                // measured from the top of the view — so a large title
                // landed underneath the pill and collided with it.
                .padding(.top, CuePalette.chromeRowHeight)
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
            SidebarView(scripts: scripts, index: index, engine: engine,
                        wordsPerSecond: engine.wordsPerSecond,
                        onPick: pick, onNew: {
                            pick(scripts.add().id)
                        },
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
            guard let id = new, let doc = doc(matching: id) else {
                draftBody = ""
                tokens = []
                index = ScriptIndex(tokens: [])
                engine.loadScript("")
                return
            }
            showDraft(doc)
        }
        .onChange(of: overlay.isShowing) { _, showing in
            if showing { armRemote() } else { remote.disarm() }
        }
        .onChange(of: index) { _, new in
            // One index drives the open panel: pages, cues and the empty
            // check all come from it, so a re-render never re-parses.
            if overlay.isShowing { overlay.update(index: new) }
            // The remote captured `$index` when it armed, and a binding
            // outlives the view pass that made it. Re-arm so the phone pages
            // the script you have now, not the one from when you opened it.
            if overlay.isShowing { armRemote() }
        }
        .onChange(of: follow) { _, _ in
            // Same reason, and this one was visible: the phone's Follow
            // light never moved, because the binding the remote held had
            // been left behind by a re-created `@State` box while the
            // dispatcher's context was still writing the live one. Toggles
            // worked, the display lied. Re-arming re-captures the live one.
            if overlay.isShowing { armRemote() }
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
                         folderPath: scripts.folderName(doc.folderID),
                         wordsPerMinute: settings.settings.wordsPerMinute,
                         onRename: { scripts.rename(doc.id, title: $0) },
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
    /// Start the remote for as long as the prompter is up. The state and
    /// the commands both come from here, so a remote button lands in the
    /// same place a key press would.
    private func armRemote() {
        // `$index` and `$follow`, **not the values**. Both closures below
        // outlive this call, and a value captured here is frozen at the
        // moment the prompter opened: the phone's follow light and its
        // section pager were reading a stale copy while the engine — a
        // class, so genuinely live — made position and speed look correct
        // and hid it. A binding reads through to the current value.
        let index = $index
        let follow = $follow
        remote.arm(
            state: {
                RemoteSnapshot(title: scripts.selected?.title ?? "", engine: engine,
                               index: index.wrappedValue,
                               isFollowing: follow.wrappedValue,
                               isMicMuted: voice.isMutedByUser)
            },
            // No `[weak self]`: ContentView is a struct, and the controller
            // is owned by it, so the closure's lifetime is the view's. A
            // remote request cannot outlive the window that armed it.
            perform: { command in
                switch command {
                case .action(let action):
                    // The existing dispatcher, so a rebind in Settings
                    // changes the phone's buttons too.
                    hotkeys.perform(action)
                case .scrub(let fraction):
                    let snapshot = RemoteSnapshot(title: "", engine: engine,
                                                  index: index.wrappedValue)
                    engine.jumpTo(wordIndex: snapshot.wordIndex(forProgress: fraction))
                case .sectionOffset(let step):
                    jumpSection(by: step, in: index.wrappedValue)
                }
            })
    }

    /// Next or previous section. The arithmetic lives in the snapshot, so
    /// the greyed-out pager on the phone and this press are the same
    /// question asked twice.
    private func jumpSection(by step: Int, in index: ScriptIndex) {
        let snapshot = RemoteSnapshot(title: "", engine: engine, index: index)
        guard let target = snapshot.wordIndexForSection(offset: step, in: index) else { return }
        engine.jumpTo(wordIndex: target)
    }

    private func pick(_ id: UUID) {
        scripts.select(id)
    }

    private func doc(matching id: UUID) -> ScriptDocument? {
        scripts.scripts.first(where: { $0.id == id })
    }
}
