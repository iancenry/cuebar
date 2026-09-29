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
        public init(token: ScriptToken, wordIndex: Int, cue: ScriptCue? = nil) {
            self.token = token
            self.wordIndex = wordIndex
            self.cue = cue
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

    // MARK: - Cues

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
        public var isEmpty: Bool { indices.isEmpty }
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
