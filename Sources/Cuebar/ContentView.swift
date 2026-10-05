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
    /// One slide position for the whole app: the tick loop fires cues into
    /// it and the dispatcher/phone step it, so the deck and the prompter
    /// can't each keep their own count.
    let slideSync: SlideSyncing
    /// Rehearsal state: which words are gaps right now.
    @Bindable var practice: PracticeController
    /// The rehearsal run. App-lifetime, fed by the tick loop in the
    /// background — so a run keeps its samples with the window closed.
    @Bindable var recorder: RunRecorder
    @State private var mode: PerformMode = .perform
    /// Follow is not state here: it belongs to the app-lifetime
    /// `OverlayController`, and this is just the view's handle on it. See
    /// `OverlayController.isFollowing`.
    private var follow: Binding<Bool> { overlay.followBinding }
    @State private var windowState = WindowState()
    /// Measured, not assumed: the user can drag the divider, and the dock's
    /// fullscreen centring is derived from it.
    @State private var sidebarWidth: CGFloat = 240
    @State private var sharing = SharingGuard()
    /// The window is a drop target for files. Text is *not* handled here:
    /// a drop that lands on the writing surface belongs in the writing
    /// surface, and the editor claims it first.
    @State private var windowDropTargeted = false
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
                         settings: settings, voice: voice, follow: follow,
                         showsFooter: false, showsPageControls: true,
                         // Computed from the dock's parts: it gained a
                         // rehearsal row, and a remembered constant is how
                         // the last line of script ends up underneath it.
                         bottomInset: TransportBar.dockHeight(rehearsal: true),
                         practice: practice,
                         topInset: CuePalette.chromeRowHeight,
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
                     voice: voice, index: index, follow: follow, practice: practice,
                     recorder: recorder)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .offset(x: windowState.isFullscreen ? -sidebarWidth / 2 : 0)
    }

    var body: some View {
        HSplitView {
            SidebarView(scripts: scripts, index: index, engine: engine,
                        wordsPerSecond: engine.wordsPerSecond,
                        onPick: pick, onNew: {
                            pick(scripts.add(folder: settings.settings.defaultFolderID).id)
                        },
                        onExport: { ScriptIO.export($0) },
                        confirmBeforeDeleting: settings.settings.confirmBeforeDeleting)
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
                       practice: practice, mode: $mode)
            }
            .ignoresSafeArea(.container, edges: .top)
            .background(CuePalette.chrome)
            .frame(minWidth: 520)
        }
        // The whole window takes a drop, because a dropped document is now
        // the main way a script gets in. The sidebar's own drop area sits
        // inside this one and wins where it applies — a folder row *files*
        // the file there — and everywhere else the file is imported beside
        // the current script.
        .scriptDropArea(onTargetedChange: { windowDropTargeted = $0 }) { drop in
            ScriptIntake.handle(drop, scripts: scripts)
        }
        .dropHighlight(windowDropTargeted, radius: 0)
        .background {
            WindowConfigurator(state: windowState)
        }
        .background {
            PlaybackDriver(engine: engine, scripts: scripts, settings: settings,
                           overlay: overlay, voice: voice, index: index,
                           mode: $mode, practice: practice, positions: app.positions,
                           trackingConfirmations: voice,
                           recorder: recorder, pick: pick, slideSync: slideSync)
        }
        .background {
            BoostKeys(engine: engine, settings: settings, mode: $mode)
        }
        .background {
            HotkeyWiring(hotkeys: hotkeys, globalHotkeys: globalHotkeys, app: app,
                         shortcuts: settings.settings.shortcuts, index: index,
                         context: CommandContext(engine: engine, voice: voice,
                                                 overlay: overlay, slides: slideSync,
                                                 mode: $mode, index: index,
                                                 recorder: recorder),
                         mode: $mode)
        }
        .modifier(ContentLifecycle(scripts: scripts, index: index, settings: settings,
                                   engine: engine, voice: voice, overlay: overlay,
                                   remote: remote, hotkeys: hotkeys,
                                   globalHotkeys: globalHotkeys, slides: slideSync,
                                   practice: practice, recorder: recorder,
                                   positions: app.positions,
                                   sharing: sharing,
                                   draftBody: $draftBody, tokens: $tokens,
                                   indexBinding: $index,
                                   showDraft: showDraft, doc: doc,
                                   presentNewScript: { mode = .perform },
                                   armRemote: armRemote))
    }

    private var editor: some View {
        Group {
            if let doc = scripts.selected {
                EditView(doc: doc, index: index,
                         wordsPerSecond: engine.wordsPerSecond,
                         folderPath: scripts.folderName(doc.folderID),
                         wordsPerMinute: settings.settings.wordsPerMinute,
                         shortcuts: settings.settings.shortcuts,
                         onRename: { scripts.rename(doc.id, title: $0) },
                         onPasteScript: { app.newScriptFromClipboard() },
                         onWebImport: { app.importFromWeb() },
                         onImportFiles: { urls in
                             let outcome = ScriptIO.importFiles(urls, existingTitles: scripts.titles)
                             ScriptIntake.land(outcome, in: scripts)
                             ScriptIO.reportRejected(outcome)
                         },
                         draftBody: $draftBody,
                         onBodyCommitted: { commit($0, for: doc.id) },
                         saveFailure: scripts.unsavedScripts.contains(doc.id)
                            ? "Not saved — check the folder's permissions"
                            : nil,
                         unreadableCount: scripts.unreadableFiles.count,
                         onRevealLibrary: { ScriptIntake.revealLibrary() },
                         changedOnDisk: scripts.externalChanges.contains(doc.id),
                         onAcceptDiskVersion: {
                             scripts.acceptExternalChange(doc.id)
                             if let body = scripts.localBody(doc.id) {
                                 draftBody = body
                                 adopt(body: body, preservingPosition: true)
                             }
                         },
                         onKeepLocalVersion: {
                             scripts.keepLocalVersion(doc.id)
                         })
            } else {
                // The empty window is the other half of the import story:
                // a first run has no script *and* no list to put one in.
                ContentUnavailableView {
                    Label("No script selected", systemImage: "doc.text")
                } description: {
                    Text("Import a script, or drop a file anywhere on this window.")
                } actions: {
                    HStack(spacing: 8) {
                        Button("Import…") { app.importScripts() }
                            .buttonStyle(.borderedProminent)
                        Button("New Script") { pick(scripts.add().id) }
                    }
                }
            }
        }
        .frame(minWidth: 420)
    }

    private func showDraft(_ doc: ScriptDocument) {
        app.setDraft(doc.body, doc.id)
        adopt(body: doc.body, preservingPosition: false)
        // "Never lose your place." Reopen where the presenter was reading rather
        // than at the top — refused for a script edited much shorter, and for
        // word zero, which is where a fresh script opens anyway.
        //
        // This was missing entirely once: `showDraft` reset the engine on every
        // selection, so the position was recorded faithfully and never restored.
        let words = ScriptParser.wordCount(doc.body)
        if settings.settings.restoreLastPosition,
           let positions = app.positions,
           let stored = positions.position(for: doc.id),
           let target = stored.resumeIndex(into: words) {
            engine.jumpTo(wordIndex: target)
        }
    }

    /// A jump the presenter made on purpose is recorded as its own position:
    /// it is not where the prompter had got to by reading, and restoring that
    /// instead would be wrong every time they scrolled back to re-read
    /// something.
    private func recordManualJump(_ wordIndex: Int, for id: UUID) {
        app.positions?.recordManualView(
            wordIndex: wordIndex, for: id,
            totalWords: ScriptParser.wordCount(scripts.selected?.body ?? ""))
    }

    private func commit(_ body: String, for id: UUID) {
        scripts.updateBody(id, body: body)
        // Parse once to decide whether anything the prompter reads has
        // actually changed, rather than paying for the full re-parse twice.
        let parsed = ScriptParser.parse(body)
        if parsed == tokens {
            // Identical tokens: the same words, cues and headings, so only
            // the prose around them moved. Reloading the engine here cancelled
            // any *running timed hold* — and a cue staged with ⌘K writes
            // `draftBody`, which arms this debounce, so staging a `[pause 2s]`
            // cancelled the very pause it had just written, 400 ms later.
            // `loadScript` is what clears a hold, so not loading is the fix.
            voice.recycle()
            return
        }
        apply(parsed, body: body, preservingPosition: true)
    }

    /// Parse once, into the one structure everything else reads.
    private func adopt(body: String, preservingPosition: Bool) {
        apply(ScriptParser.parse(body), body: body, preservingPosition: preservingPosition)
    }

    private func apply(_ parsed: [ScriptToken], body: String, preservingPosition: Bool) {
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
        // **Only app-lifetime objects are captured here.** These closures
        // outlive this call, and a `@Binding` captured into them can be
        // orphaned by a re-created `@State` box — reads freeze at the value
        // from arm time while the dispatcher keeps writing the live one, so
        // a toggle works and the display says it didn't. Two of those
        // (`$index`, `$follow`) were the cause; the state now reads them
        // from the overlay, and the command closures read `index` from it
        // too. Everything captured below is a class, and cannot go stale.
        remote.arm(
            state: {
                RemoteSnapshot(title: scripts.selected?.title ?? "", engine: engine,
                               index: overlay.currentIndex,
                               isFollowing: overlay.isFollowing,
                               isMicMuted: voice.isMutedByUser,
                               slide: slideSync.slide)
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
                                                  index: overlay.currentIndex)
                    engine.jumpTo(wordIndex: snapshot.wordIndex(forProgress: fraction))
                case .sectionOffset(let step):
                    jumpSection(by: step, in: overlay.currentIndex)
                }
            },
            advertise: settings.settings.advertiseRemote)
    }

    /// Next or previous section. The arithmetic lives in the snapshot, so
    /// the greyed-out pager on the phone and this press are the same
    /// question asked twice.
    private func jumpSection(by step: Int, in index: ScriptIndex) {
        let snapshot = RemoteSnapshot(title: "", engine: engine, index: index)
        guard let target = snapshot.wordIndexForSection(offset: step, in: index) else { return }
        engine.jumpTo(wordIndex: target)
        if let id = scripts.selectedID { recordManualJump(target, for: id) }
    }

    private func pick(_ id: UUID) {
        scripts.select(id)
    }



    private func doc(matching id: UUID) -> ScriptDocument? {
        scripts.scripts.first(where: { $0.id == id })
    }
}
