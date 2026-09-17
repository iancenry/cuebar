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

    /// "2s" → 2, "500ms" → 0.5, "1.5" → 1.5, "2 sec" → 2 (the bare
    /// number is the token before " sec" anyway). Caps at an hour so a
    /// typo can't park the prompter for a day.
    static func parseSeconds(_ raw: String) -> TimeInterval? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("ms"), let v = Double(s.dropLast(2)), v > 0 { return v / 1000 }
        if s.hasSuffix("sec"), let v = Double(s.dropLast(3)), v > 0 { return v }
        if s.hasSuffix("s"), let v = Double(s.dropLast(1)), v > 0 { return v }
        if let v = Double(s), v > 0, v <= 3600 { return v }
        return nil
    }
}
