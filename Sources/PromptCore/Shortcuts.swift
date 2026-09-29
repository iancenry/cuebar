import Foundation

/// Hardware key codes as macOS reports them (`kVK_*`, identical numbering
/// in `NSEvent.keyCode`). Kept literal so PromptCore stays AppKit-free —
/// binding by code rather than by character means the binding survives
/// layout changes.
public enum KeyCode {
    // Only the keys Cuebar binds by default. Display names for
    // *recorded* chords come from the literal table in `KeyChord.names`,
    // so an unlisted key still reads correctly after a rebind.
    public static let a: UInt16 = 0
    public static let s: UInt16 = 1
    public static let f: UInt16 = 3
    public static let h: UInt16 = 4
    public static let q: UInt16 = 12
    public static let w: UInt16 = 13
    public static let r: UInt16 = 15
    public static let o: UInt16 = 31
    public static let j: UInt16 = 38
    public static let k: UInt16 = 40
    public static let n: UInt16 = 45
    public static let m: UInt16 = 46
    public static let rightBracket: UInt16 = 30
    public static let leftBracket: UInt16 = 33
    public static let enter: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
}


/// A physical key plus its modifier flags. Modifiers only — a chord with
/// none would swallow plain typing, so `isValid` rejects it and the
/// recorder refuses to record one.
public struct KeyChord: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        /// Masked to the four bits we understand: a corrupt prefs payload
        /// must not produce a chord that claims a modifier we never render
        /// (which reads as bare, and would then swallow plain typing).
        public init(rawValue: Int) { self.rawValue = rawValue & 0b1111 }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public static let none: Modifiers = []
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers = .none) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Apple-reserved chords, plus the ones this app's own menus already
    /// own (Settings… is ⌘, Help is ⌘/). The key monitor consumes the chords
    /// it handles, so a reserved chord must never be bindable: ⌘Q is the
    /// only way out of the app and ⌘, would shadow the settings window.
    public var isReserved: Bool {
        guard modifiers.contains(.command) else { return false }
        // , / ` - ; ' . = \  — plus quit/close/minimise/hide/window cycling.
        return [KeyCode.q, KeyCode.w, KeyCode.m, KeyCode.h, KeyCode.tab,
                43, 44, 50, 27, 41, 39, 47, 24, 42].contains(keyCode)
    }

    public var isValid: Bool {
        !modifiers.isEmpty && !isReserved
    }

    /// ⌥Space, ⇧⌘↑ … Symbols, AppKit's own glyphs.
    public var description: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + Self.name(for: keyCode)
    }

    public static func name(for keyCode: UInt16) -> String {
        if let known = names[Int(keyCode)] { return known }
        // Printable ASCII we didn't name (⌥-punctuation, etc).
        return "Key \(keyCode)"
    }

    private static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        24: "=", 27: "-", 29: "0", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 115: "↖", 116: "⇞", 117: "⌦",
        119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// Everything the presenter can drive without looking down. Each case is
/// one row in Settings → Keyboard and one menu command; both dispatch
/// through the same performer, so a rebind moves the command with it.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case playPause
    case speedUp, speedDown, fineSpeedUp, fineSpeedDown
    case jumpForward, jumpBack
    case restart
    case nextCue, previousCue
    case toggleFollow
    case toggleMicrophone
    case toggleOverlay
    case toggleFullscreen
    case insertCue
    case newScript, importScripts, exportScript

    public enum Group: String, CaseIterable, Sendable {
        case playback, stage, script
    }

    public var group: Group {
        switch self {
        case .playPause, .speedUp, .speedDown, .fineSpeedUp, .fineSpeedDown,
             .jumpForward, .jumpBack, .restart, .nextCue, .previousCue:
            return .playback
        case .toggleFollow, .toggleMicrophone, .toggleOverlay, .toggleFullscreen:
            return .stage
        case .insertCue, .newScript, .importScripts, .exportScript:
            return .script
        }
    }

    public var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .speedUp: return "Speed Up 10 WPM"
        case .speedDown: return "Slow Down 10 WPM"
        case .fineSpeedUp: return "Speed Up 1 WPM"
        case .fineSpeedDown: return "Slow Down 1 WPM"
        case .jumpForward: return "Forward 10 Seconds"
        case .jumpBack: return "Back 10 Seconds"
        case .restart: return "Restart"
        case .nextCue: return "Next Cue"
        case .previousCue: return "Previous Cue"
        case .toggleFollow: return "Toggle Follow"
        case .toggleMicrophone: return "Toggle Microphone"
        case .toggleOverlay: return "Toggle Overlay"
        case .toggleFullscreen: return "Toggle Fullscreen"
        case .insertCue: return "Insert Cue…"
        case .newScript: return "New Script"
        case .importScripts: return "Import Scripts…"
        case .exportScript: return "Export Script…"
        }
    }

    public var help: String {
        switch self {
        case .playPause: return "Start or stop the prompter."
        case .speedUp, .speedDown: return "Reading speed in 10 WPM steps."
        case .fineSpeedUp, .fineSpeedDown: return "Reading speed in 1 WPM steps."
        case .jumpForward, .jumpBack: return "Skip about ten seconds of script."
        case .restart: return "Back to the first word, playing."
        case .nextCue, .previousCue: return "Jump to the word after the next or previous cue."
        case .toggleFollow: return "Stop or resume the viewport chasing the highlight."
        case .toggleMicrophone: return "Mute or unmute transcription."
        case .toggleOverlay: return "Show or hide the always-on-top prompter."
        case .toggleFullscreen: return "Take the prompter fullscreen, or give the display back."
        case .insertCue: return "Open the cue palette."
        case .newScript: return "Start an empty script."
        case .importScripts: return "Import .txt / .md files as scripts."
        case .exportScript: return "Save the selected script."
        }
    }

    /// Commands that don't need an open window (script files, the cue
    /// palette) — they keep working when the main window is closed.
    public var isAppLevel: Bool { group == .script }

    /// Commands that still answer while the editor has focus.
    ///
    /// Stage commands drive the display. `insertCue` belongs here because a
    /// cue is *text*: refusing ⌘K in the editor blocked the one command
    /// that writes into the document being written, while the editor's own
    /// footer advertised it. `playPause` is here because that footer
    /// advertises Option-Space too — and it promotes to Perform so the
    /// result is visible. The cost is that Option-Space stops typing a
    /// non-breaking space in the editor, which is a trade worth naming.
    ///
    /// Everything else stays out. The speed, jump and cue-navigation
    /// chords are real text-navigation bindings (⌘↑ to the document
    /// start, ⌥→ to end of line), and the document commands would swap
    /// the file out from under the caret.
    public var isEditorSafe: Bool {
        switch self {
        case .playPause, .insertCue,
             .toggleFollow, .toggleMicrophone, .toggleOverlay:
            return true
        default:
            return false
        }
    }

    /// The one ⌘-chord that answers in the editor. ⌘ and ⌃ belong to macOS
    /// in a text field — ⌘F is Find, ⌘↑ is the document start — so they
    /// are respected in the editor, with one exception: ⌘K has no macOS
    /// meaning and a cue is text.
    public var isCommandSafeInEditor: Bool { self == .insertCue }

    /// Defaults are the chords the app shipped with. They must stay unique
    /// (locked by a test) — otherwise one key silently drives two commands.
    public var defaultChord: KeyChord {
        switch self {
        case .playPause: return KeyChord(keyCode: KeyCode.space, modifiers: .option)
        case .speedUp: return KeyChord(keyCode: KeyCode.upArrow, modifiers: .command)
        case .speedDown: return KeyChord(keyCode: KeyCode.downArrow, modifiers: .command)
        case .fineSpeedUp: return KeyChord(keyCode: KeyCode.upArrow, modifiers: [.command, .shift])
        case .fineSpeedDown: return KeyChord(keyCode: KeyCode.downArrow, modifiers: [.command, .shift])
        case .jumpForward: return KeyChord(keyCode: KeyCode.rightArrow, modifiers: .option)
        case .jumpBack: return KeyChord(keyCode: KeyCode.leftArrow, modifiers: .option)
        case .restart: return KeyChord(keyCode: KeyCode.r, modifiers: .command)
        case .nextCue: return KeyChord(keyCode: KeyCode.rightBracket, modifiers: .option)
        case .previousCue: return KeyChord(keyCode: KeyCode.leftBracket, modifiers: .option)
        case .toggleFollow: return KeyChord(keyCode: KeyCode.f, modifiers: .option)
        case .toggleMicrophone: return KeyChord(keyCode: KeyCode.m, modifiers: .option)
        case .toggleOverlay: return KeyChord(keyCode: KeyCode.o, modifiers: .option)
        case .toggleFullscreen: return KeyChord(keyCode: KeyCode.f, modifiers: .command)
        case .insertCue: return KeyChord(keyCode: KeyCode.k, modifiers: .command)
        // ⌘N stays with macOS: Cuebar is a single-window app, and if every
        // window closes the user still needs a way back.
        case .newScript: return KeyChord(keyCode: KeyCode.n, modifiers: [.command, .shift])
        case .importScripts: return KeyChord(keyCode: KeyCode.o, modifiers: .command)
        case .exportScript: return KeyChord(keyCode: KeyCode.s, modifiers: .command)
        }
    }
}

/// User bindings, stored sparsely: a case with no entry is on its default.
/// Sparse storage is what makes "reset one command" a single deletion and
/// keeps future defaults free — a user who never touched a row still picks
/// up changes to it.
public struct ShortcutMap: Codable, Equatable, Sendable {
    private var bindings: [ShortcutAction: KeyChord]

    public static let `default` = ShortcutMap()

    public init(bindings: [ShortcutAction: KeyChord] = [:]) {
        self.bindings = bindings.filter { $0.key.defaultChord != $0.value }
    }

    public func chord(for action: ShortcutAction) -> KeyChord {
        bindings[action] ?? action.defaultChord
    }

    public func isCustomized(_ action: ShortcutAction) -> Bool {
        bindings[action] != nil
    }

    public var customized: Set<ShortcutAction> { Set(bindings.keys) }

    /// Bind a chord, swapping with whoever held it: taking ⌘K for Play/Pause
    /// hands ⌥Space to Insert Cue rather than leaving two commands on one
    /// key (or silently disarming one of them).
    public mutating func bind(_ key: KeyChord, to action: ShortcutAction) {
        guard key.isValid else { return }
        let previous = chord(for: action)
        // Search defaults too: the action being displaced is usually still
        // on its shipped chord, which is not in `bindings` at all. Every
        // claimant gets the freed chord — repairing only the first would
        // leave a collision and silently disarm the new binding.
        for other in claims(of: key) where other != action {
            store(previous, for: other)
        }
        store(key, for: action)
    }

    /// Sparse storage invariant: a chord equal to the default is never
    /// stored, so `isCustomized` stays honest and a later default change
    /// still reaches the user.
    private mutating func store(_ chord: KeyChord, for action: ShortcutAction) {
        if chord == action.defaultChord {
            bindings.removeValue(forKey: action)
        } else {
            bindings[action] = chord
        }
    }

    /// Back to the shipped chord. If a *customized* command had been
    /// parked on that chord, it takes the one this action is giving up —
    /// otherwise two commands would claim one key and the dispatcher (rightly)
    /// would let neither fire.
    public mutating func reset(_ action: ShortcutAction) {
        let previous = chord(for: action)
        for other in claims(of: action.defaultChord) where other != action {
            store(previous, for: other)
        }
        bindings.removeValue(forKey: action)
    }

    public mutating func resetAll() {
        bindings.removeAll()
    }

    /// Owner of a chord, ignoring one action. Nil means the chord is free.
    public func holder(of key: KeyChord, excluding action: ShortcutAction? = nil) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && chord(for: $0) == key }
    }

    /// Every command pointing at a chord. Usually one. The key monitor
    /// insists on exactly one claim before it acts: a command still on its
    /// shipped chord is owned by its native menu shortcut, and two claims
    /// mean a rebind landed somewhere ambiguous — better that nothing fires
    /// than that one keypress drives two commands.
    public func claims(of key: KeyChord) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { chord(for: $0) == key }
    }

    /// Guards the invariant the dispatcher assumes: one chord, one command.
    public var hasUniqueChords: Bool {
        let chords = ShortcutAction.allCases.map { chord(for: $0) }
        return Set(chords).count == chords.count
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var out: [ShortcutAction: KeyChord] = [:]
        for action in ShortcutAction.allCases {
            guard let chord = try? container.decodeIfPresent(KeyChord.self,
                                                              forKey: .init(action.rawValue)),
                  chord.isValid, chord != action.defaultChord else { continue }
            // Self-healing for a hand-edited file: an override that lands on
            // another command's shipped chord (or on an earlier override)
            // would leave both commands unreachable — the dispatcher
            // correctly refuses a chord with two claims. Keep the defaults.
            let stealsADefault = ShortcutAction.allCases.contains {
                $0 != action && $0.defaultChord == chord
            }
            if stealsADefault || out.values.contains(chord) { continue }
            out[action] = chord
        }
        self.init(bindings: out)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Fixed order: two equal maps must serialise identically.
        for action in ShortcutAction.allCases {
            if let chord = bindings[action] {
                try container.encode(chord, forKey: .init(action.rawValue))
            }
        }
    }

    /// Dynamic key: every action has a slot, present only when customized.
    private struct CodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
