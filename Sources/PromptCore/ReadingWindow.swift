import Foundation

/// Pure, testable reading math for Cuebar. No UI, no AppKit — everything
/// here is unit-tested. UI layers call in; they own no arithmetic.
public enum ReadingWindow: Sendable {
    /// Number of pages for `wordCount` words at `pageSize` per page.
    public static func pageCount(wordCount: Int, pageSize: Int) -> Int {
        guard wordCount > 0, pageSize > 0 else { return 0 }
        return (wordCount + pageSize - 1) / pageSize
    }

    /// Which page a word lives on. Nil (empty script) maps to page 0.
    public static func pageIndex(forWord wordIndex: Int?, wordCount: Int, pageSize: Int) -> Int {
        let count = pageCount(wordCount: wordCount, pageSize: pageSize)
        guard count > 0, pageSize > 0 else { return 0 }
        guard let w = wordIndex else { return 0 }
        return min(max(0, w / pageSize), count - 1)
    }

    /// Word range (end-exclusive) shown on `page`.
    public static func wordRange(page: Int, wordCount: Int, pageSize: Int) -> Range<Int> {
        guard wordCount > 0, pageSize > 0 else { return 0..<0 }
        let count = pageCount(wordCount: wordCount, pageSize: pageSize)
        let p = min(max(0, page), max(0, count - 1))
        let start = p * pageSize
        return start..<min(start + pageSize, wordCount)
    }

    // MARK: - Page rendering groups

    /// One render row for a page: the token plus the tracking word index
    /// (-1 for cues and paragraph breaks, which are never tracked). The cue
    /// is pre-interpreted by `ScriptIndex` — a badge used to parse its cue
    /// string twice per render, per cue on screen.
    public struct TokenRow: Equatable, Sendable {
        public let token: ScriptToken
        public let wordIndex: Int
        public let cue: ScriptCue?
        /// Set only for a heading, so the renderer can draw it as one
        /// without re-interpreting the token.
        public let section: ScriptSection?
        public init(token: ScriptToken, wordIndex: Int, cue: ScriptCue? = nil,
                    section: ScriptSection? = nil) {
            self.token = token
            self.wordIndex = wordIndex
            self.cue = cue
            self.section = section
        }
    }

    // MARK: - Overlay placement (plain numbers, no AppKit)

    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var midX: Double { x + width / 2 }
        public var maxY: Double { y + height }
        public var midY: Double { y + height / 2 }
    }

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
    }

    /// Top-flush island origin: the panel's top edge meets the screen's
    /// top edge (overlapping the menu bar), centered. The island then
    /// reads as an extension of the notch instead of a window under it.
    public static func notchIslandOrigin(screen: Rect, panelWidth: Double, panelHeight: Double) -> Point {
        Point(x: screen.midX - panelWidth / 2, y: screen.maxY - panelHeight)
    }

    /// Menu-bar thickness: the strip the full frame has but the visible
    /// frame doesn't. The Dock never sits at the top, so the top delta
    /// is the menu bar alone. Falls back to 28pt.
    public static func menuBarHeight(screenHeight: Double, visibleHeight: Double) -> Double {
        let h = screenHeight - visibleHeight
        return h > 0 ? h : 28
    }

    /// Center of `visible` for a floating panel.
    public static func floatingOrigin(visible: Rect, panelWidth: Double, panelHeight: Double) -> Point {
        Point(x: visible.midX - panelWidth / 2, y: visible.midY - panelHeight / 2)
    }

    /// Clamp a fixed-display index to the available screens.
    public static func clampedDisplayIndex(_ i: Int, screenCount: Int) -> Int {
        guard screenCount > 0 else { return 0 }
        return min(max(0, i), screenCount - 1)
    }

    /// Estimated read duration for the sidebar ("12 sec", "4:16").
    public static func durationString(wordCount: Int, wordsPerSecond: Double) -> String {
        guard wordCount > 0, wordsPerSecond.isFinite, wordsPerSecond > 0 else {
            return "0 sec"
        }
        let total = Int((Double(wordCount) / wordsPerSecond).rounded())
        if total < 60 { return "\(total) sec" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `m:ss` (or `h:mm:ss`), the shape a presenter's timeline needs.
    /// `durationString` is the compact form for a row beside a script —
    /// it collapses under a minute to "17 sec", which is right there and
    /// wrong on a timeline where 0:00 is the interesting value.
    public static func clockString(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Cues

    /// Something a cue asks the *app* to do when the reading position
    /// reaches it.
    ///
    /// Distinct from a hold or a pause: nothing here stops the prompter. It
    /// says "the deck should be on 4 by now". PromptCore owns *when* and
    /// stays ignorant of Keynote, PowerPoint or anything else — the app
    /// layer decides what a trigger means, which is why this is a value and
    /// not a closure.
    public enum CueTrigger: Equatable, Sendable {
        /// `[slide]` — move the deck on by one. The bare form is the one
        /// people actually write, and it is the one that survives editing:
        /// numbering every slide means inserting a slide at the front
        /// silently invalidates every number in the script, and nobody
        /// re-numbers a deck they have already rehearsed.
        case advance
        /// `[slide 4]` — go to a specific slide, for a deck that has to be
        /// driven to an exact place (rehearsing a late change, jumping back
        /// to a section).
        case goto(Int)

        public var label: String {
            switch self {
            case .advance: return "SLIDE"
            case .goto(let n): return "SLIDE \(n)"
            }
        }
    }

    /// Everything the cue system needs about a script, in one pass and one
    /// `ScriptCue.interpret` per cue. Three families used to be derived
    /// independently and they disagreed: a direction cue between `[pause 2s]`
    /// and its word cancelled the pending wait, and a trailing cue was
    /// dropped. One structure, one answer — and it is computed once per
    /// script instead of twice per word change.
    public struct CuePlan: Equatable, Sendable {
        /// Word index → seconds to freeze there.
        public var holds: [Int: TimeInterval] = [:]
        /// Word indices that auto-pause (bare timing cues and `[break…]`).
        public var pauses: Set<Int> = []
        /// Every cue target, ascending — where Next/Previous Cue jump to.
        public var indices: [Int] = []
        /// Word index → something the app should do on arrival. Keyed like
        /// the holds, so a `[slide 4]` fires at the first word under it.
        public var triggers: [Int: CueTrigger] = [:]
        public var isEmpty: Bool { indices.isEmpty }

        /// Triggers crossed by a move from one word to another, in script
        /// order.
        ///
        /// Pure arithmetic, so the "when" is testable without an app and
        /// without a presenter. The caller keeps the high-water mark: a
        /// backwards jump re-arms nothing, and a jump *forward* reports
        /// everything it passed, because after that jump the deck and the
        /// script are genuinely out of step and the deck is what should be
        /// corrected.
        public func triggers(from oldWord: Int, to newWord: Int) -> [CueTrigger] {
            guard newWord > oldWord else { return [] }
            return triggers
                .filter { $0.key > oldWord && $0.key <= newWord }
                .sorted { $0.key < $1.key }
                .map(\.value)
        }

        /// How many slide cues the script *carries*, counted as they were
        /// parsed — not the size of `triggers`.
        ///
        /// Those differ, and it showed: two `[slide]` cues in a script with
        /// no words both sit at word 0, so the dictionary held one entry
        /// and the editor reported "1 slide" for two. One trigger per
        /// position is right for *firing* — a cue fires when you arrive —
        /// but the count has to come from the cues, so the parse counts
        /// them as it goes.
        public var slideCueCount: Int = 0

        /// Every absolute slide target, ascending and deduped.
        public var slideNumbers: [Int] {
            Set(triggers.values.compactMap {
                if case .goto(let n) = $0 { return n }
                return nil
            }).sorted()
        }
    }

    /// Thin readers over `ScriptIndex`, which owns the one implementation.
    public static func pauseCueWordIndices(_ tokens: [ScriptToken]) -> Set<Int> {
        ScriptIndex(tokens: tokens).cuePlan.pauses
    }

    public static func timedHoldCues(_ tokens: [ScriptToken]) -> [Int: TimeInterval] {
        ScriptIndex(tokens: tokens).cuePlan.holds
    }

    /// Ascending word indices of the words that *follow* a cue. Cues take no
    /// word slot of their own, so "jump to cue" means landing on the first
    /// word the cue introduces — the badge then sits just off the top of the
    /// viewport with its line on screen.
    public static func cueWordIndices(_ tokens: [ScriptToken]) -> [Int] {
        ScriptIndex(tokens: tokens).cuePlan.indices
    }

    public static func isPauseCue(_ cue: ScriptCue) -> Bool {
        if cue.kind.isTiming { return true }
        return cue.label.lowercased().contains("break")
    }

    /// Words in `seconds` of reading, signed. The transport keys and the
    /// transport buttons both go through here so "skip ten seconds" means one
    /// thing regardless of the current speed.
    public static func jumpWords(forSeconds seconds: TimeInterval, wordsPerSecond wps: Double) -> Int {
        guard seconds.isFinite, wps.isFinite else { return 0 }
        let words = Int((abs(seconds) * wps).rounded())
        return seconds < 0 ? -words : words
    }

    /// Next cue strictly after `index`; wraps to the first cue from the end
    /// so "next cue" from the last line restarts the cue tour instead of
    /// dead-ending. Nil when the script has no cues.
    public static func nextCueWordIndex(after index: Int?, in indices: [Int]) -> Int? {
        guard let first = indices.first else { return nil }
        guard let index else { return first }
        return indices.first { $0 > index } ?? first
    }

    public static func previousCueWordIndex(before index: Int?, in indices: [Int]) -> Int? {
        guard let last = indices.last else { return nil }
        guard let index else { return last }
        return indices.last { $0 < index } ?? last
    }
}
