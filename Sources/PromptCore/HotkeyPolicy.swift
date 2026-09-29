import Foundation

/// The one answer to "what should happen to this key press?", shared by the
/// local monitor and the global event tap. Both were deciding this inline —
/// which is how the Edit-mode rule and the app-level carve-out ended up
/// untested. Pure, so it can be locked down.
public enum HotkeyPolicy: Sendable {
    /// Where the key press came from. The global tap runs before the app's
    /// own monitor, so the two must agree on who owns a chord or one press
    /// would drive two commands.
    public enum Source: String, Equatable, Sendable {
        /// The app's `NSEvent` monitor.
        case local
        /// A session-level `CGEvent` tap, i.e. another app is in front.
        case global
    }

    public enum Decision: Equatable, Sendable {
        /// Hand the event on untouched.
        case forward
        /// Swallow it and do nothing.
        case ignore
        /// Swallow it and run a command.
        case consume(ShortcutAction)
        /// Swallow it and record this chord for the action being rebound.
        case record(ShortcutAction, KeyChord)
        /// Swallow it and stop recording.
        case cancelRecording
        /// Swallow it, but the chord was refused — `reason` is for the user.
        case refuse(String)

        /// Whether the key press must not reach the rest of the system.
        /// The event handler needs this synchronously, before it can hop to
        /// the main actor, so it lives with the decision.
        public var swallows: Bool {
            switch self {
            case .forward: return false
            case .ignore, .consume, .record, .cancelRecording, .refuse: return true
            }
        }
    }

    /// Everything the decision depends on that the key press itself doesn't
    /// carry. The global tap reads this off the main actor; everything here
    /// is a value, so no state is touched off-task.
    public struct Context: Equatable, Sendable {
        public var source: Source = .local
        /// Cuebar is the frontmost application. A global tap must stand down
        /// and let the local monitor own the press, or both would fire.
        public var isFrontmost: Bool = true
        /// The script editor has focus. Transport and script keys would
        /// fight the caret there, so they are released.
        public var isEditing: Bool = false
        /// The main window is gone: only the app-level commands still mean
        /// anything, and every other chord belongs to whoever has the window.
        public var hasWindow: Bool = true
        public var map: ShortcutMap = .default
        /// While rebinding, key presses are chords to record, never commands.
        public var recording: ShortcutAction? = nil

        public init() {}
    }

    /// The whole context, built in one place. The app's monitor and tap both
    /// snapshot *this*, which is why they can never disagree about what a
    /// chord means — and why a stale value (a mode change nobody
    /// re-snapshotted) is a wiring bug rather than a policy one.
    public static func context(source: Source,
                               map: ShortcutMap,
                               recording: ShortcutAction?,
                               hasWindow: Bool,
                               isEditing: Bool) -> Context {
        var context = Context()
        context.source = source
        context.map = map
        context.recording = recording
        context.hasWindow = hasWindow
        context.isEditing = isEditing
        return context
    }

    public static func decide(_ chord: KeyChord, isRepeat: Bool, context: Context) -> Decision {
        // Recording wins over everything, including the reserved list: a
        // half-finished rebind must not be able to quit the app (⌘Q).
        if let action = context.recording {
            if chord.keyCode == KeyCode.escape, chord.modifiers.isEmpty {
                return .cancelRecording
            }
            guard !isRepeat else { return .ignore }
            guard chord.isValid else { return .refuse(refusal(for: chord)) }
            return .record(action, chord)
        }

        guard chord.isValid, !context.map.claims(of: chord).isEmpty else { return .forward }
        // A chord with two claims is a corrupted map; nobody fires, which is
        // the safe way to be wrong.
        let claims = context.map.claims(of: chord)
        guard claims.count == 1, let action = claims.first else { return .forward }

        // The global tap only exists to cover the presenting case, and only
        // while the prompter is up (see `Context.overlayIsPresenting`).
        if context.source == .global, context.isFrontmost { return .forward }

        if !context.hasWindow, !action.isAppLevel { return .forward }
        // In the editor, only the commands that make sense there answer at
        // all — see `isEditorSafe`. The blanket "⌘ and ⌃ belong to macOS"
        // rule that used to sit here was what stopped ⌘K from working in
        // the editor: it fired for every ⌘-chord, including the cue
        // palette, which the editor's own footer promised. ⌘-chords are now
        // only respected for the commands that aren't editor-safe.
        if context.isEditing {
            guard action.isEditorSafe else { return .forward }
            // ⌘ and ⌃ still belong to macOS in a text field, except for
            // the chord that has no macOS meaning and writes text.
            if chord.modifiers.contains(.command) || chord.modifiers.contains(.control),
               !action.isCommandSafeInEditor {
                return .forward
            }
        }
        // Native shortcuts never repeat, and neither should ours — or holding
        // a rebound key machine-guns its command.
        guard !isRepeat else { return .ignore }
        return .consume(action)
    }

    private static func refusal(for chord: KeyChord) -> String {
        chord.modifiers.isEmpty
            ? "Needs a modifier — that key has to keep typing."
            : "\(chord.description) stays with macOS."
    }
}
