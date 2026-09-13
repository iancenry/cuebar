import Foundation
import Observation

/// Manual-first prompt engine. Voice tracking plugs in later
/// by calling `confirmRead(upTo:)` — manual always wins.
///
/// - Note: Character counts are extended-grapheme clusters over the
///   normalized single-space join of `words`. Speech layers that emit
///   UTF-16 offsets must convert before calling `confirmRead`.
/// - Note: Normalized intentionally: runs of whitespace collapse to one
///   space, leading/trailing trimmed, paragraph breaks lost. English /
///   space-delimited scripts only; CJK without spaces is one token.
@MainActor
@Observable
public final class PromptEngine {
    public private(set) var words: [String] = []
    public private(set) var readCharCount: Int = 0
    public private(set) var wordsPerSecond: Double = 2.5
    public private(set) var isPlaying: Bool = false

    private var cachedTotal: Int = 0
    private var wordStartOffsets: [Int] = []
    private var charRemainder: Double = 0

    private static let minSpeed = 0.5
    private static let maxSpeed = 8.0
    private static let avgCharsPerWord = 5.0
    private static let maxTickDelta = 0.25

    public init() {}

    public func loadScript(_ text: String, preservingPosition: Bool = false) {
        // Cues like [smile] are stage directions: never tracked as words.
        words = ScriptParser.words(text)
        rebuildIndex()
        charRemainder = 0
        if preservingPosition {
            setReadCharCount(readCharCount)
        } else {
            readCharCount = 0
            isPlaying = false
            setReadCharCount(0)
        }
    }

    public var totalCharCount: Int { cachedTotal }

    public var progress: Double {
        guard cachedTotal > 0 else { return 0 }
        return min(1, Double(readCharCount) / Double(cachedTotal))
    }

    /// Start offset of every word over the normalized join. Empty -> [].
    private func rebuildIndex() {
        wordStartOffsets = []
        wordStartOffsets.reserveCapacity(words.count)
        var offset = 0
        for (i, w) in words.enumerated() {
            if i > 0 { offset += 1 }
            wordStartOffsets.append(offset)
            offset += w.count
        }
        cachedTotal = words.joined(separator: " ").count
    }

    /// Nil when script is empty. Binary search over cached offsets.
    public var currentWordIndex: Int? {
        guard !words.isEmpty else { return nil }
        if readCharCount >= cachedTotal { return words.count - 1 }
        var lo = 0
        var hi = wordStartOffsets.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if wordStartOffsets[mid] <= readCharCount {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    // MARK: - Manual controls (keyboard / pedal / remote)

    public func play() {
        guard !words.isEmpty else { return }
        if readCharCount >= cachedTotal {
            // Already at the end: restart instead of flashing playing.
            setReadCharCount(0)
        }
        isPlaying = true
    }
    public func pause() { isPlaying = false }
    public func toggle() { isPlaying ? pause() : play() }

    /// Advance by wall-clock time. Safe to call at any rate; fractional
    /// progress accumulates across small ticks. Deltas over 0.25 s are
    /// clamped so backgrounding can't teleport the highlight — callers
    /// should tick faster than 4 Hz for smooth motion.
    public func tick(_ delta: Double) {
        guard isPlaying else { return }
        guard delta.isFinite, delta > 0 else { return }
        let dt = min(delta, Self.maxTickDelta)
        charRemainder += wordsPerSecond * dt * Self.avgCharsPerWord
        let step = Int(charRemainder)
        charRemainder -= Double(step)
        if step > 0 {
            setReadCharCount(readCharCount + step)
        } else if readCharCount >= cachedTotal {
            isPlaying = false
        }
    }

    @discardableResult
    public func jumpTo(wordIndex: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        if wordIndex >= words.count {
            charRemainder = 0
            setReadCharCount(cachedTotal)
            return words.count - 1
        }
        let clamped = max(0, wordIndex)
        charRemainder = 0
        setReadCharCount(wordStartOffsets[clamped])
        return clamped
    }

    public func jumpRelative(words delta: Int) {
        let base = currentWordIndex ?? 0
        _ = jumpTo(wordIndex: base + delta)
    }

    public func setSpeed(_ value: Double) {
        guard value.isFinite else { return }
        wordsPerSecond = min(Self.maxSpeed, max(Self.minSpeed, value))
    }

    public func adjustSpeed(_ delta: Double) {
        guard delta.isFinite else { return }
        setSpeed(wordsPerSecond + delta)
    }

    // MARK: - Voice plug-in point

    /// Voice layer reports confirmed position. Must be called on MainActor —
    /// voice callbacks hop first: `await MainActor.run { engine.confirmRead(upTo:) }`.
    /// Never moves backwards unless `allowBacktrack` (for re-reads).
    public func confirmRead(upTo charCount: Int, allowBacktrack: Bool = false) {
        let clamped = max(0, min(charCount, cachedTotal))
        if allowBacktrack || clamped > readCharCount {
            charRemainder = 0
            setReadCharCount(clamped)
        }
    }

    /// Voice layer: mark words up to (not including) `endIndex` as read.
    /// Index-based twin of `confirmRead(upTo:)` so speech matching never
    /// touches character offsets.
    public func confirmReadThroughWord(_ endIndex: Int, allowBacktrack: Bool = false) {
        guard !words.isEmpty else { return }
        let clamped = max(0, min(endIndex, words.count))
        let offset = clamped >= words.count ? cachedTotal : wordStartOffsets[clamped]
        confirmRead(upTo: offset, allowBacktrack: allowBacktrack)
    }

    private func setReadCharCount(_ value: Int) {
        readCharCount = max(0, min(value, cachedTotal))
        if readCharCount >= cachedTotal, cachedTotal > 0 {
            isPlaying = false
        }
        if words.isEmpty {
            isPlaying = false
        }
    }
}
