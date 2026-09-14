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

    // MARK: - Pause cues

    /// Word indices that follow a [pause]/[wait]/[hold]-style cue. The
    /// driver auto-pauses when the highlight steps onto one of these.
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
                if isPauseCue(c) { armed = true }
            case .paragraphBreak:
                break
            }
        }
        return out
    }

    public static func isPauseCue(_ cue: String) -> Bool {
        let text = cue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return text.contains("pause") || text.contains("wait")
            || text.contains("hold") || text == "stop"
            || text.contains("breath") || text.contains("break")
    }
}
