import Foundation

/// Fuzzy script following for voice tracking. Pure and unit-tested.
///
/// Strategy: take the transcript's tail and find the longest run that
/// appears verbatim in the upcoming script window. Runs of at least two
/// words are required (stray articles like "the" must not yank the
/// highlight); a one-word script is the only exception. Earliest
/// occurrence wins so re-reading a sentence holds position instead of
/// running away (cf. Textream issue #22).
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

    /// Returns the word index just past the matched speech (suitable for
    /// `PromptEngine.confirmReadThroughWord`), or nil when nothing
    /// convincing matched. A match running through the last canonical
    /// word completes the script, swallowing trailing punctuation-only
    /// tokens that can never be spoken.
    public static func matchEnd(
        transcript: String,
        words: [String],
        fromWordIndex: Int,
        windowSize: Int = 40
    ) -> Int? {
        let tail = tokenize(transcript)
        guard !tail.isEmpty, !words.isEmpty, windowSize > 0 else { return nil }
        let canon: [(index: Int, text: String)] = words.enumerated().compactMap { i, w in
            let c = canonical(w)
            return c.isEmpty ? nil : (i, c)
        }
        guard let first = canon.firstIndex(where: { $0.index >= fromWordIndex }) else { return nil }
        let last = min(first + windowSize, canon.count)
        let minK = canon.count == 1 ? 1 : 2
        let maxK = min(tail.count, 12)
        guard maxK >= minK else { return nil }
        for k in stride(from: maxK, through: minK, by: -1) {
            let suffix = Array(tail.suffix(k))
            var p = first
            while p + k <= last {
                if canon[p ..< p + k].map(\.text) == suffix {
                    let end = canon[p + k - 1].index + 1
                    return (p + k == canon.count) ? words.count : end
                }
                p += 1
            }
        }
        return nil
    }
}
