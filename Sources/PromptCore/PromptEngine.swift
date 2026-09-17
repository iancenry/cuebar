import Foundation
import Observation

/// Manual-first prompt engine. Voice tracking plugs in later
/// by calling `confirmRead(upTo:)` — manual always wins.
///
/// Human pacing, not pixels-per-second: the engine advances through
/// words at the target WPM, but each word dwells a little longer when
/// it is long or ends a clause (see `pacingFactor`), velocity ramps up
/// on start and eases out on stop, and a momentary boost multiplier
/// lets the reader catch up without changing the saved speed.
///
/// - Note: Character counts are extended-grapheme clusters over the
///   normalized single-space join of `words`. Speech layers that emit
///   UTF-16 offsets must convert before calling `confirmRead`.
/// - Note: Normalized intentionally: runs of whitespace collapse to one
///   space, leading/trailing trimmed. Paragraph breaks are tracked
///   separately (see `paragraphStarts`) for dwell only. English /
///   space-delimited scripts only; CJK without spaces is one token.
@MainActor
@Observable
public final class PromptEngine {
    public private(set) var words: [String] = []
    public private(set) var readCharCount: Int = 0
    /// Persisted target speed. The live velocity is `effectiveWordsPerSecond`.
    public private(set) var wordsPerSecond: Double = 2.5
    /// Smoothed live velocity — ramps toward `wordsPerSecond * boostMultiplier`
    /// (or 0 while easing out). UI readouts showing "current speed" use this.
    public private(set) var effectiveWordsPerSecond: Double = 0
    /// Momentary catch-up multiplier (1.0 = off). Ramps smoothly via the
    /// same velocity filter, so holding/releasing boost never jolts.
    public private(set) var boostMultiplier: Double = 1.0
    /// Word-aware dwell (long words + clause punctuation linger).
    /// Off = constant char rate (legacy/robotic feel).
    public var naturalPacing: Bool = true
    public private(set) var isPlaying: Bool = false
    /// True while easing out after `pause()` — ticks must keep coming or
    /// the stop never settles (voice-gated tickers need this to check).
    public var isStopping: Bool { stopping }
    /// Seconds left in a timed-cue hold, for countdown UIs.
    public private(set) var holdRemaining: TimeInterval?
    public var isHolding: Bool { holdUntil != nil }
    private var holdUntil: Date?

    private var cachedTotal: Int = 0
    private var wordStartOffsets: [Int] = []
    private var charRemainder: Double = 0
    /// Word indices that open a paragraph (for reorient dwell).
    private var paragraphStarts: Set<Int> = []
    /// True while easing out after `pause()` — ticks keep advancing with
    /// decaying velocity until it settles, then playback fully stops.
    private var stopping = false

    private static let minSpeed = 0.5
    private static let maxSpeed = 8.0
    private static let avgCharsPerWord = 5.0
    private static let maxTickDelta = 0.25
    /// Velocity filter time constants: gentle attack, quicker release.
    /// 95% settle ≈ 3τ, so starts bloom over ~1.1s, stops settle in ~0.5s.
    private static let rampUpTau = 0.38
    private static let rampDownTau = 0.16
    private static let stopThreshold = 0.08

    public init() {}

    public func loadScript(_ text: String, preservingPosition: Bool = false) {
        // Cues like [smile] are stage directions: never tracked as words.
        // One parse feeds both the word list and paragraph-open tracking.
        let tokens = ScriptParser.parse(text)
        words = tokens.compactMap {
            if case .word(let w) = $0 { return w }
            return nil
        }
        paragraphStarts = Self.paragraphStartIndices(in: tokens, wordCount: words.count)
        rebuildIndex()
        cancelHold()
        charRemainder = 0
        stopping = false
        if preservingPosition {
            setReadCharCount(readCharCount)
        } else {
            readCharCount = 0
            isPlaying = false
            effectiveWordsPerSecond = 0
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
        cancelHold()
        if readCharCount >= cachedTotal {
            // Already at the end: restart instead of flashing playing.
            setReadCharCount(0)
            effectiveWordsPerSecond = 0
        }
        stopping = false
        isPlaying = true
    }
    /// Soft stop: velocity eases out over ~0.4s instead of halting dead.
    /// Ticks keep nudging forward with decaying speed until settled.
    /// Cancels any timed hold — manual always wins.
    public func pause() {
        cancelHold()
        guard isPlaying else { return }
        stopping = true
    }
    /// Immediate halt for teardown paths (script switch, hide). Playback
    /// controls should prefer `pause()` for the eased feel.
    public func stopImmediately() {
        cancelHold()
        stopping = false
        isPlaying = false
        effectiveWordsPerSecond = 0
    }
    public func toggle() { isPlaying && !stopping ? pause() : play() }

    // MARK: - Timed holds ([pause 2s])

    /// Freeze the reading position for a timing cue's duration. Ticks
    /// count the hold down instead of advancing; when it expires the
    /// velocity ramps back up from zero like a fresh start. Any manual
    /// control (play/pause/jump) cancels the hold.
    public func hold(for seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0, isPlaying else { return }
        stopping = false
        holdUntil = Date().addingTimeInterval(seconds)
        holdRemaining = seconds
    }

    private func cancelHold() {
        holdUntil = nil
        holdRemaining = nil
    }

    /// Momentary catch-up multiplier (hold-to-boost). Clamped to
    /// 1.0…2.5; the velocity filter smooths press and release.
    public func setBoost(_ value: Double) {
        guard value.isFinite else { return }
        boostMultiplier = min(2.5, max(1.0, value))
    }

    /// Advance by wall-clock time. Safe to call at any rate; fractional
    /// progress accumulates across small ticks. Deltas over 0.25 s are
    /// clamped so backgrounding can't teleport the highlight — callers
    /// should tick at display rate (~60 Hz) for buttery ramps.
    ///
    /// Velocity follows `wordsPerSecond * boostMultiplier` through an
    /// exponential filter (slow attack, fast release), then the advance
    /// is scaled by the current word's pacing factor so long words and
    /// clause ends dwell like a human reader would.
    public func tick(_ delta: Double) {
        guard isPlaying || stopping else { return }
        guard delta.isFinite, delta > 0 else { return }
        let dt = min(delta, Self.maxTickDelta)
        // Timed hold: freeze in place, counting down by tick (so tests
        // and tick cadence stay deterministic). The wall-clock deadline
        // is a backstop for stalled tickers. Expiry releases and the
        // velocity ramp-up below restarts from zero.
        if let until = holdUntil {
            let tickRemaining = (holdRemaining ?? until.timeIntervalSinceNow) - dt
            if tickRemaining > 0, until.timeIntervalSinceNow > 0 {
                holdRemaining = tickRemaining
                effectiveWordsPerSecond = 0
                return
            }
            cancelHold()
        }
        let target = stopping ? 0 : wordsPerSecond * boostMultiplier
        let tau = target > effectiveWordsPerSecond ? Self.rampUpTau : Self.rampDownTau
        let blend = 1 - exp(-dt / tau)
        effectiveWordsPerSecond += (target - effectiveWordsPerSecond) * blend
        if stopping, effectiveWordsPerSecond < Self.stopThreshold {
            stopping = false
            isPlaying = false
            effectiveWordsPerSecond = 0
            return
        }
        let pace = naturalPacing ? pacingFactor(at: currentWordIndex) : 1.0
        charRemainder += effectiveWordsPerSecond * pace * dt * Self.avgCharsPerWord
        let step = Int(charRemainder)
        charRemainder -= Double(step)
        if step > 0 {
            setReadCharCount(readCharCount + step)
        } else if readCharCount >= cachedTotal {
            stopImmediately()
        }
    }

    @discardableResult
    public func jumpTo(wordIndex: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        cancelHold()
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
            stopImmediately()
        }
        if words.isEmpty {
            stopImmediately()
        }
    }

    // MARK: - Human pacing

    /// Dwell factor for a word index: < 1 lingers (long / clause-ending),
    /// > 1 hurries (short glue words). 1.0 when pacing is off or empty.
    public func pacingFactor(at wordIndex: Int?) -> Double {
        guard naturalPacing, let i = wordIndex, words.indices.contains(i) else { return 1.0 }
        return Self.pacingFactor(for: words[i], paragraphStart: paragraphStarts.contains(i))
    }

    /// Pure word → dwell factor, unit-testable without an engine.
    /// - Length: 3-letter glue hurries (~1.09×), 10-letter words linger (~0.81×).
    /// - Clause punctuation: commas breathe (0.75×), sentence ends land (0.55×).
    /// - Paragraph opens reorient briefly (0.85×).
    public nonisolated static func pacingFactor(for word: String, paragraphStart: Bool = false) -> Double {
        let chars = max(1, word.count)
        var factor = 1 / (0.78 + 0.045 * Double(min(chars, 14)))
        let tail = word.reversed().prefix(while: { "\"'”’)}\u{2019}]".contains($0) })
        let meaningful = word.dropLast(tail.count).last
        switch meaningful {
        case ".", "!", "?":
            factor *= 0.55
        case ",", ";", ":":
            factor *= 0.75
        case "—", "–":
            factor *= 0.7
        default:
            if word.hasSuffix("...") || word.hasSuffix("…") { factor *= 0.65 }
        }
        if paragraphStart { factor *= 0.85 }
        return min(1.25, max(0.4, factor))
    }

    /// Word indices that open a paragraph: the first word plus every word
    /// following a blank line in the parsed token stream.
    public nonisolated static func paragraphStartIndices(in tokens: [ScriptToken], wordCount: Int) -> Set<Int> {
        guard wordCount > 0 else { return [] }
        var starts: Set<Int> = [0]
        var wi = 0
        var afterBreak = false
        for t in tokens {
            switch t {
            case .word:
                if afterBreak { starts.insert(wi) }
                afterBreak = false
                wi += 1
            case .paragraphBreak:
                afterBreak = true
            case .cue:
                break
            }
        }
        return starts
    }

    /// String convenience: parses once, then delegates.
    public nonisolated static func paragraphStartIndices(in text: String, wordCount: Int) -> Set<Int> {
        guard wordCount > 0 else { return [] }
        return paragraphStartIndices(in: ScriptParser.parse(text), wordCount: wordCount)
    }
}
