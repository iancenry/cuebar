import Foundation

/// Interpreted cue directive. A `[...]` span is more than a label: its
/// first word selects a kind, and timing cues can carry a duration
/// (`[pause 2s]`, `[hold 500ms]`, `[breath 1.5]`) that the teleprompter
/// executes. Pure and unit-tested.
public struct ScriptCue: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        // Timing family: the teleprompter acts on these.
        case pause, wait, hold, breath, stop
        // Direction family: rendered distinctly, not executed.
        case smile, look, emphasis, demo, drink, slide
        case other

        /// Timing cues parse durations and can freeze playback.
        public var isTiming: Bool {
            switch self {
            case .pause, .wait, .hold, .breath, .stop: return true
            default: return false
            }
        }
    }

    public let kind: Kind
    /// Duration parsed from a timing cue. `[pause 2s]` → 2.0; bare
    /// `[pause]` → nil (manual resume, governed by the pause-cues
    /// setting).
    public let seconds: TimeInterval?
    /// Display text without brackets, as written ("pause 2s").
    public let label: String

    public init(kind: Kind, seconds: TimeInterval?, label: String) {
        self.kind = kind
        self.seconds = seconds
        self.label = label
    }

    public static func interpret(_ raw: String) -> ScriptCue {
        var inner = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        let label = inner.trimmingCharacters(in: .whitespaces)
        let parts = label.split(separator: " ", omittingEmptySubsequences: true)
        let head = parts.first.map(String.init)?.lowercased() ?? ""
        let kind = Kind(rawValue: head) ?? .other
        var seconds: TimeInterval? = nil
        if kind.isTiming {
            for part in parts.dropFirst() {
                if let s = parseSeconds(String(part)) {
                    seconds = s
                    break
                }
            }
        }
        return ScriptCue(kind: kind, seconds: seconds, label: label)
    }

    /// "2s" → 2, "500ms" → 0.5, "1.5" → 1.5, "2 sec" → 2. Capped at an
    /// hour so a typo can't park the prompter for a day — the cap applies to
    /// every suffix, not just the bare number.
    static func parseSeconds(_ raw: String) -> TimeInterval? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let seconds: TimeInterval?
        if s.hasSuffix("ms"), let v = Double(s.dropLast(2)) { seconds = v / 1000 }
        else if s.hasSuffix("sec"), let v = Double(s.dropLast(3)) { seconds = v }
        else if s.hasSuffix("s"), let v = Double(s.dropLast(1)) { seconds = v }
        else { seconds = Double(s) }
        guard let seconds, seconds > 0, seconds <= Self.maxSeconds else { return nil }
        return seconds
    }

    /// Longest wait a cue can ask for.
    static let maxSeconds: TimeInterval = 3600
}

/// Shared kind → SF Symbol map (badges + the cue palette).
extension ScriptCue {
    public static func iconName(for cue: String) -> String {
        switch interpret(cue).kind {
        case .pause: return "pause.fill"
        case .wait: return "hourglass"
        case .hold: return "hand.raised.fill"
        case .breath: return "wind"
        case .stop: return "stop.fill"
        case .smile: return "face.smiling"
        case .look: return "eye"
        case .emphasis: return "exclamationmark"
        case .demo: return "play.rectangle"
        case .drink: return "drop"
        case .slide: return "rectangle.on.rectangle"
        case .other: return "tag"
        }
    }
}
