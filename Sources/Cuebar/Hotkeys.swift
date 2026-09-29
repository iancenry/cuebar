import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
#endif

/// App-level commands that live above ContentView: the draft text and the
/// cue sheet are CuebarApp state, so the keyboard reaches them through this
/// bridge instead of ContentView owning a second copy.
struct AppCommandBridge {
    var showCuePalette: () -> Void
    var newScript: () -> Void
    var importScripts: () -> Void
    var exportScript: () -> Void
}

/// Everything a command needs from the view tree. `mode` is a binding so
/// the dispatcher edits live state, not a copy of it. This half dies with
/// the window; `AppCommandBridge` (above) does not.
///
/// Note what is *not* here: follow. It used to be a `Binding<Bool>` on this
/// struct, which meant the dispatcher held a second copy of a flag the
/// overlay already owned — and the phone remote, which also outlives the
/// view, had to hold a third. Live state that outlives a view belongs on
/// something app-lifetime, so follow lives on `OverlayController` and every
/// writer goes through `setFollow`.
struct CommandContext {
    var engine: PromptEngine
    var voice: VoiceTracker
    var overlay: OverlayController
    /// One slide position for the whole app, shared with the tick loop.
    var slides: SlideSyncing
    var mode: Binding<PerformMode>
    /// The parsed script. Commands read pages and cues from here rather than
    /// re-walking tokens.
    var index: ScriptIndex
}

/// One dispatcher for the whole app: the menu rows and the key monitor both
/// call `perform(_:)`, so a rebind moves the command with its menu row and
/// there is never a second, subtly different path.
@MainActor
@Observable
final class HotkeyCenter {
    /// Live while Settings → Keyboard is listening for a new chord. While
    /// set, key events are bindings to record, never commands to run.
    var capturing: ShortcutAction? {
        didSet { if capturing != oldValue { refresh() } }
    }
    /// Shown in the recording row when a chord is refused, so a dead press
    /// is never silent.
    private(set) var captureHint: String = ""

    private var context: CommandContext?
    private let settings: SettingsStore
    private var app: AppCommandBridge?
    /// Placement to restore when fullscreen is toggled off.
    private var modeBeforeFullscreen: CueSettings.OverlayMode = .floating

    #if os(macOS)
    @ObservationIgnored private var monitor: Any?
    #endif

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func bind(app: AppCommandBridge) {
        self.app = app
    }

    func install(_ context: CommandContext) {
        self.context = context
        refresh()
    }

    func updateIndex(_ index: ScriptIndex) {
        guard var context else { return }
        context.index = index
        self.context = context
    }

    /// The main window went away. The context holds bindings into that view
    /// tree, so it is dropped and any armed recording cancelled — but the
    /// monitor stays, because the script commands (New, Import, Export,
    /// Insert Cue) never touched the window and must keep working. ⌘N is
    /// deliberately *not* ours, so macOS's New Window still brings it back.
    func clear() {
        context = nil
        cancelCapture()
        refresh()
    }

    // MARK: - Recording

    func cancelCapture() {
        capturing = nil
        captureHint = ""
    }

    /// Bind a recorded chord. Refusals never reach here: the policy has
    /// already turned them into a `.refuse`, which is what keeps ⌘Q from
    /// quitting the app mid-rebind.
    func record(_ chord: KeyChord, for action: ShortcutAction) {
        guard capturing == action else { return }
        cancelCapture()
        var map = settings.settings.shortcuts
        map.bind(chord, to: action)
        settings.settings.shortcuts = map
        // `cancelCapture` refreshed with the *old* map; make the new one
        // live immediately rather than waiting for the re-render.
        refresh()
    }

    // MARK: - Dispatch

    func perform(_ action: ShortcutAction) {
        // App-level commands never touch the view tree, so they keep working
        // with the main window closed.
        switch action {
        case .newScript: app?.newScript(); return
        case .importScripts: app?.importScripts(); return
        case .exportScript: app?.exportScript(); return
        case .insertCue: app?.showCuePalette(); return
        default: break
        }
        guard let context else { return }
        let engine = context.engine
        switch action {
        case .playPause:
            // Asked for from the editor, Option-Space starts the prompter —
            // and the editor's own footer says so. Toggling the engine
            // while the editor is on screen would move a highlight nobody
            // can see, so take the reader to it instead. Option-Space no
            // longer types a non-breaking space here, which is the trade.
            if context.mode.wrappedValue == .edit {
                context.mode.wrappedValue = .perform
            }
            engine.toggle()
        case .speedUp:
            Self.adjustWPM(by: 10, settings: settings, engine: engine)
        case .speedDown:
            Self.adjustWPM(by: -10, settings: settings, engine: engine)
        case .fineSpeedUp:
            Self.adjustWPM(by: 1, settings: settings, engine: engine)
        case .fineSpeedDown:
            Self.adjustWPM(by: -1, settings: settings, engine: engine)
        case .jumpForward:
            Self.jump(seconds: 10, engine: engine)
        case .jumpBack:
            Self.jump(seconds: -10, engine: engine)
        case .restart:
            engine.restart()
        case .nextSlide:
            context.slides.step(1)
        case .previousSlide:
            context.slides.step(-1)
        case .nextCue:
            jumpToCue(forward: true, context: context)
        case .previousCue:
            jumpToCue(forward: false, context: context)
        case .toggleFollow:
            // One writer: the overlay controller owns the flag, and it is
            // the same flag the Mac's switches, the phone and "resume
            // follow" all write. The old code kept a second copy in the
            // view and made *this* case responsible for both, which is
            // precisely the arrangement where a toggle can work in one
            // place and read as "no change" in another.
            context.overlay.setFollow(!context.overlay.isFollowing)
        case .toggleMicrophone:
            context.voice.isMutedByUser.toggle()
        case .toggleOverlay:
            context.overlay.toggle(engine: engine, settings: settings,
                                  index: context.index, voice: context.voice)
        case .toggleFullscreen:
            toggleFullscreen()
        case .insertCue, .newScript, .importScripts, .exportScript:
            break // handled above
        }
    }

    /// Single funnel for speed changes: settings stay the persisted source
    /// of truth, the engine follows instantly (its ramp smooths it).
    static func adjustWPM(by delta: Double, settings: SettingsStore, engine: PromptEngine) {
        settings.settings.adjustWordsPerMinute(by: delta)
        engine.setSpeed(settings.settings.wordsPerSecond)
    }

    /// Jump by reading time, not word count: ten words is four seconds of
    /// script, useless as a "get me out of this paragraph" key.
    static func jump(seconds: TimeInterval, engine: PromptEngine) {
        engine.jumpRelative(words: ReadingWindow.jumpWords(forSeconds: seconds,
                                                           wordsPerSecond: engine.wordsPerSecond))
    }

    private func jumpToCue(forward: Bool, context: CommandContext) {
        let indices = context.index.cuePlan.indices
        let current = context.engine.currentWordIndex
        let target = forward
            ? ReadingWindow.nextCueWordIndex(after: current, in: indices)
            : ReadingWindow.previousCueWordIndex(before: current, in: indices)
        guard let target else { return }
        context.engine.jumpTo(wordIndex: target)
    }

    private func toggleFullscreen() {
        if settings.settings.overlayMode == .fullscreen {
            settings.settings.overlayMode = modeBeforeFullscreen
        } else {
            modeBeforeFullscreen = settings.settings.overlayMode
            // ContentView re-presents the panel on this change; doing it here
            // too would build the NSPanel twice.
            settings.settings.overlayMode = .fullscreen
        }
    }

    /// The policy input for one key press. Read on the main actor and
    /// handed to the (possibly off-main) decision as a value.
    private func policyContext(source: HotkeyPolicy.Source) -> HotkeyPolicy.Context {
        HotkeyPolicy.context(source: source,
                             map: settings.settings.shortcuts,
                             recording: capturing,
                             hasWindow: context != nil,
                             isEditing: context?.mode.wrappedValue == .edit)
    }

    /// Run one decision. Returns whether the key was swallowed, so the
    /// monitor can hand the event on when it wasn't.
    @discardableResult
    private func apply(_ decision: HotkeyPolicy.Decision) -> Bool {
        switch decision {
        case .forward, .refuse:
            // A refusal is still swallowed: it must not reach the app (⌘Q
            // would quit), but it does need the hint the caller sets.
            if case .refuse(let reason) = decision { captureHint = reason }
            return false
        case .ignore:
            return true
        case .cancelRecording:
            cancelCapture()
            return true
        case .record(let action, let chord):
            record(chord, for: action)
            return true
        case .consume(let action):
            perform(action)
            return true
        }
    }

    #if os(macOS)
    /// Rebuild the monitor so the closure captures the map, capture mode and
    /// edit-mode binding as plain *values* — the handler must not read
    /// MainActor state off a task, and `MainActor.assumeIsolated` from a
    /// monitor is the SIGBUS trap in AGENTS.md. Reinstalling is also how a
    /// rebind reaches the monitor.
    func refresh() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let decisionContext = policyContext(source: .local)
        let center = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let chord = KeyChord(keyCode: event.keyCode,
                                 modifiers: KeyChord.Modifiers(event.modifierFlags))
            let decision = HotkeyPolicy.decide(chord, isRepeat: event.isARepeat,
                                               context: decisionContext)
            // The decision is made from captured values only — the handler
            // runs before any MainActor hop — and the effect is applied on
            // the main actor right after. Returning the event unchanged is
            // how "forward" is expressed; anything else is swallowed.
            Task { @MainActor in center.apply(decision) }
            return decision.swallows ? nil : event
        }
    }
    #endif
}


/// Invisible wiring view: owns the command context's lifetime and keeps the
/// key monitor in step with the script and the shortcut map. Separate from
/// ContentView's body on purpose — another four `.onChange` modifiers on the
/// layout is what pushes the type checker over.
struct HotkeyWiring: View {
    @Bindable var hotkeys: HotkeyCenter
    @Bindable var globalHotkeys: GlobalHotkeys
    let app: AppCommandBridge
    let shortcuts: ShortcutMap
    let index: ScriptIndex
    let context: CommandContext
    /// Read for observation only: the monitor's decision context captures
    /// whether the editor is up, so a mode change has to reinstall it or the
    /// editor's own ⌘-chords get eaten.
    let mode: Binding<PerformMode>

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                hotkeys.bind(app: app)
                hotkeys.install(context)
            }
            .onDisappear {
                hotkeys.clear()
            }
            .onChange(of: index) { _, new in
                hotkeys.updateIndex(new)
            }
            .onChange(of: shortcuts) { _, _ in
                // The monitor captures the map as a value; a rebind has to
                // reinstall it or the old chord keeps firing.
                hotkeys.refresh()
                globalHotkeys.mapDidChange()
            }
            .onChange(of: mode.wrappedValue) { _, _ in
                hotkeys.refresh()
            }
    }
}

#if os(macOS)
extension KeyChord.Modifiers {
    /// Explicit intersection, not a rawValue cast: caps lock, fn and the
    /// numeric-pad flag are hardware state, not intent, and would make a
    /// plain ⌘K stop matching the moment caps lock came on.
    init(_ flags: NSEvent.ModifierFlags) {
        var out: KeyChord.Modifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.shift) { out.insert(.shift) }
        self = out
    }
}
#endif
