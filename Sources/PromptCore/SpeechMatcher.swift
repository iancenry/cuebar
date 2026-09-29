import Foundation

/// Fuzzy script following for voice tracking. Pure and unit-tested.
///
/// **Tolerant matching** (the default): the transcript doesn't need to be
/// verbatim — skipped words, repeated words, and filler words are all
/// handled gracefully. The algorithm is a greedy subsequence scan: walk
/// through the transcript's canonical words and advance a pointer through
/// the script window whenever a word matches. This naturally handles:
///
/// - *Skipped words*: "today talk about three" matches
///   "today we're going to talk about three" — pointer skips over the
///   non-matching script words.
/// - *Repeated words*: "today we're we're going to talk" — the second
///   "we're" matches the script word, so the pointer advances past it.
/// - *Filler words*: "um", "uh", "ah", "like", "you know" etc. are
///   stripped before matching, so they never interfere.
/// - *Consecutive duplicates*: collapsed before matching (stutters).
///
/// **Strict matching** (`tolerant: false`): the old verbatim contiguous
/// substring search. Useful for testing or when the caller knows the
/// transcript is clean.
///
/// Paraphrasing ("gonna" vs "going to") intentionally falls back to WPM
/// — no string matcher can reliably track rephrased speech, and the WPM
/// fallback in Smart mode handles this gracefully.
///
/// Matching is monotonic by construction — callers only ever confirm
/// forward from the current index, so a restarted recognition session
/// can never move the highlight backwards.
public enum SpeechMatcher: Sendable {
    /// Canonical form: lowercase letters and numbers only. Both sides go
    /// through this, so "Hello!" matches "hello" and "don't" matches "dont".
    public static func canonical(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    public static func tokenize(_ transcript: String) -> [String] {
        transcript.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Last `maxWords` space-separated words of a transcript, space-joined.
    /// Callers pass this to `matchEnd`: drivers hand over the full
    /// accumulated session text on every partial result, but the reading
    /// position only moves forward, so old words are dead weight.
    ///
    /// Scans *backwards* and stops at the `maxWords`-th separator, so the
    /// cost is the length of the tail rather than the length of the session
    /// — `split` here would re-allocate every word of a long take on every
    /// result (O(session²) end to end).
    public static func transcriptTail(_ transcript: String, maxWords: Int) -> String {
        guard maxWords > 0 else { return "" }
        guard !transcript.isEmpty else { return transcript }
        // Walk `String.Index` backwards — O(1) steps into the native string.
        // Materialising `Array(transcript)` was O(session) *and* 16 bytes per
        // character, on every partial recognition result.
        var end = transcript.endIndex
        while end > transcript.startIndex, transcript[transcript.index(before: end)] == " " {
            end = transcript.index(before: end)
        }
        var scan = end
        var words = 0
        while scan > transcript.startIndex {
            guard transcript[transcript.index(before: scan)] == " " else {
                scan = transcript.index(before: scan)
                continue
            }
            while scan > transcript.startIndex,
                  transcript[transcript.index(before: scan)] == " " {
                scan = transcript.index(before: scan)
            }
            guard scan > transcript.startIndex else { break }   // a leading run
            words += 1
            if words == maxWords {
                var begin = scan
                while begin < end, transcript[begin] == " " { begin = transcript.index(after: begin) }
                // Re-join on single spaces: recognizers pad, and the contract
                // is "the last N words", not "the last N characters".
                return String(transcript[begin..<end])
                    .split(separator: " ").joined(separator: " ")
            }
        }
        // The whole transcript is within the tail; hand back the original so
        // nothing is rewritten.
        return transcript
    }

    // MARK: - Tolerant matching

    /// Common English filler words that speech recognition emits but
    /// speakers don't intend as part of the script. Stripped before
    /// matching so they never interfere with position tracking.
    public static let fillers: Set<String> = [
        "um", "uh", "ah", "er", "hmm", "hm",
        "like", "youknow", "yaknow", "kinda", "sorta",
        "well", "right", "okay", "ok", "so",
        "basically", "actually", "literally",
        "im", "ive", "id", "thats", "its",
    ]

    /// Collapse consecutive duplicate words. "we're we're going" →
    /// "we're going". Speech stutters and recognition double-fires are
    /// the primary targets.
    public static func collapseRepeats(_ words: [String]) -> [String] {
        guard !words.isEmpty else { return [] }
        var out: [String] = [words[0]]
        for w in words.dropFirst() {
            if w != out.last { out.append(w) }
        }
        return out
    }

    /// Strip filler words from a canonical word list.
    public static func stripFillers(_ words: [String]) -> [String] {
        words.filter { !fillers.contains($0) }
    }

    /// Prepare a transcript for tolerant matching: canonicalize, strip
    /// fillers, collapse consecutive duplicates.
    public static func prepareTranscript(_ transcript: String) -> [String] {
        collapseRepeats(stripFillers(tokenize(transcript)))
    }

    /// Greedy subsequence match: find the longest prefix of the script
    /// (starting at `fromWordIndex`) that appears as a subsequence of the
    /// transcript. Walks through transcript words and advances a script
    /// pointer whenever a match is found.
    ///
    /// Returns the word index just past the last matched script word
    /// (suitable for `confirmReadThroughWord`), or nil when nothing
    /// convincing matched.
    ///
    /// Minimum match: 2 words (except single-word scripts where 1
    /// suffices). This prevents stray articles from yanking the highlight.
    /// A script, canonicalised once. Recognition fires partial results
    /// dozens of times a second; canonicalising the whole script on each one
    /// cost two `String` allocations per word of the *entire* script (a 5,000
    /// word script: 10,000 allocations per result) to read a 40-word window.
    public struct CanonicalScript: Sendable {
        public struct Entry: Sendable {
            public let index: Int
            public let text: String
        }

        public let entries: [Entry]
        public let wordCount: Int

        public init(words: [String]) {
            wordCount = words.count
            entries = words.enumerated().compactMap { i, w in
                let text = SpeechMatcher.canonical(w)
                return text.isEmpty ? nil : Entry(index: i, text: text)
            }
        }

        public var isEmpty: Bool { entries.isEmpty }

        public func matchEnd(transcript: String,
                             fromWordIndex: Int,
                             windowSize: Int = 40,
                             tolerant: Bool = true) -> Int? {
            let transcriptWords = tolerant
                ? SpeechMatcher.prepareTranscript(transcript)
                : SpeechMatcher.tokenize(transcript)
            guard !transcriptWords.isEmpty, !entries.isEmpty, windowSize > 0 else { return nil }
            guard let first = entries.firstIndex(where: { $0.index >= fromWordIndex }) else { return nil }
            let last = min(first + windowSize, entries.count)
            let minMatch = entries.count == 1 ? 1 : 2

            if !tolerant {
                // Strict: original contiguous substring matching.
                return SpeechMatcher.matchContiguous(
                    transcriptWords: transcriptWords,
                    canon: entries, first: first, last: last, minMatch: minMatch,
                    wordCount: wordCount
                )
            }
            // Tolerant: greedy subsequence scan.
            return SpeechMatcher.matchSubsequence(
                transcriptWords: transcriptWords,
                canon: entries, first: first, last: last, minMatch: minMatch,
                wordCount: wordCount
            )
        }
    }

    /// One-shot convenience. Prefer holding a `CanonicalScript` when matching
    /// repeatedly against the same script.
    public static func matchEnd(
        transcript: String,
        words: [String],
        fromWordIndex: Int,
        windowSize: Int = 40,
        tolerant: Bool = true
    ) -> Int? {
        CanonicalScript(words: words).matchEnd(transcript: transcript,
                                               fromWordIndex: fromWordIndex,
                                               windowSize: windowSize,
                                               tolerant: tolerant)
    }

    // MARK: - Matching strategies

    /// Contiguous substring match (original behavior). The transcript
    /// tail must appear as an unbroken run in the script window.
    fileprivate static func matchContiguous(
        transcriptWords: [String],
        canon: [CanonicalScript.Entry],
        first: Int, last: Int, minMatch: Int,
        wordCount: Int
    ) -> Int? {
        let maxK = min(transcriptWords.count, 12)
        guard maxK >= minMatch else { return nil }
        for k in stride(from: maxK, through: minMatch, by: -1) {
            let suffix = Array(transcriptWords.suffix(k))
            var p = first
            while p + k <= last {
                if canon[p ..< p + k].map(\.text) == suffix {
                    let end = canon[p + k - 1].index + 1
                    return (p + k == canon.count) ? wordCount : end
                }
                p += 1
            }
        }
        return nil
    }

    /// Greedy subsequence match. Walks through transcript words and
    /// advances a script pointer whenever a word matches. The furthest
    /// script position reached is the answer.
    ///
    /// This naturally handles skipped words (pointer jumps), repeated
    /// words (duplicate transcript words match sequential script words),
    /// and filler-stripped transcripts (fillers never reach here).
    fileprivate static func matchSubsequence(
        transcriptWords: [String],
        canon: [CanonicalScript.Entry],
        first: Int, last: Int, minMatch: Int,
        wordCount: Int
    ) -> Int? {
        var si = first  // script pointer
        var matched = 0
        for tw in transcriptWords {
            while si < last {
                if canon[si].text == tw {
                    matched += 1
                    si += 1
                    break
                }
                si += 1
            }
            if si >= last { break }
        }
        guard matched >= minMatch else { return nil }
        let end = canon[si - 1].index + 1
        return (si == last && si - first >= canon.count - first) ? wordCount : end
    }
}
