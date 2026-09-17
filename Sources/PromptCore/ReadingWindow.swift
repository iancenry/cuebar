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

    /// Assign every token a page. Cues and paragraph breaks ride with the
    /// next word so a `[pause]` before word N appears on N's page;
    /// trailing cues join the last page. Single pass: word indices are
    /// assigned walking forward, pages walking back. (A previous version
    /// called a linear scan per token — O(n²) on every render. Don't
    /// regress this.)
    public static func tokenPages(_ tokens: [ScriptToken], pageSize: Int) -> [Int] {
        guard pageSize > 0, !tokens.isEmpty else { return tokens.map { _ in 0 } }
        var wordIndexAt = Array(repeating: -1, count: tokens.count)
        var wordCount = 0
        for i in tokens.indices where tokens[i].isWord {
            wordIndexAt[i] = wordCount
            wordCount += 1
        }
        let lastPage = max(0, pageCount(wordCount: wordCount, pageSize: pageSize) - 1)
        var pages = Array(repeating: 0, count: tokens.count)
        var nextWord = wordCount
        for i in tokens.indices.reversed() {
            if !tokens[i].isWord {
                let w = min(nextWord, max(0, wordCount - 1))
                pages[i] = wordCount == 0 ? 0 : min(w / pageSize, lastPage)
            } else {
                nextWord = wordIndexAt[i]
                pages[i] = min(wordIndexAt[i] / pageSize, lastPage)
            }
        }
        return pages
    }

    // MARK: - Page rendering groups

    /// One render row for a page: the token plus the tracking word index
    /// (-1 for cues and paragraph breaks, which are never tracked).
    public struct TokenRow: Equatable, Sendable {
        public let token: ScriptToken
        public let wordIndex: Int
    }

    /// Paragraph groups of rows for one page, in a single pass. Cues hide
    /// when `showCues` is false; paragraph breaks always split groups so a
    /// page renders real gaps. Replaces the old two-pass rows()/paragraphs()
    /// pair, which materialized every token in the script and re-filtered
    /// it twice on every render.
    public static func pageParagraphRows(_ tokens: [ScriptToken],
                                         page: Int,
                                         pageSize: Int,
                                         showCues: Bool) -> [[TokenRow]] {
        let pages = tokenPages(tokens, pageSize: pageSize)
        var groups: [[TokenRow]] = [[]]
        var wordIndex = 0
        for (i, t) in tokens.enumerated() {
            guard pages[i] == page else {
                if t.isWord { wordIndex += 1 }
                continue
            }
            if t.isParagraphBreak {
                groups.append([])
            } else if t.isCue, !showCues {
                continue
            } else {
                groups[groups.count - 1].append(TokenRow(token: t, wordIndex: t.isWord ? wordIndex : -1))
            }
            if t.isWord { wordIndex += 1 }
        }
        // A page boundary can strand a leading break; drop empty groups
        // but keep at least one so empty pages still render.
        let nonEmpty = groups.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? [[]] : nonEmpty
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

    /// Word indices that follow a *bare* timing cue ([pause], [wait],
    /// [hold] — no duration). The driver auto-pauses on these when the
    /// pause-cues setting is on. Timed cues ([pause 2s]) are handled by
    /// `timedHoldCues` instead.
    public static func pauseCueWordIndices(_ tokens: [ScriptToken]) -> Set<Int> {
        var out: Set<Int> = []
        var wordCount = 0
        var armed = false
        for t in tokens {
            switch t {
            case .word:
                if armed { out.insert(wordCount) }
                armed = false
                wordCount += 1
            case .cue(let c):
                armed = isPauseCue(c) && ScriptCue.interpret(c).seconds == nil
            case .paragraphBreak:
                break
            }
        }
        return out
    }

    /// Timed holds: word index that follows the cue → seconds to freeze.
    /// `[smile][pause 2s] word` arms word 0 with 2 s.
    public static func timedHoldCues(_ tokens: [ScriptToken]) -> [Int: TimeInterval] {
        var out: [Int: TimeInterval] = [:]
        var wordCount = 0
        var pending: TimeInterval? = nil
        for t in tokens {
            switch t {
            case .word:
                if let seconds = pending {
                    out[wordCount] = seconds
                    pending = nil
                }
                wordCount += 1
            case .cue(let c):
                let cue = ScriptCue.interpret(c)
                pending = cue.kind.isTiming ? cue.seconds : nil
            case .paragraphBreak:
                break
            }
        }
        return out
    }

    public static func isPauseCue(_ cue: String) -> Bool {
        let c = ScriptCue.interpret(cue)
        if c.kind.isTiming { return true }
        return c.label.lowercased().contains("break")
    }
}
