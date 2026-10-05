import Foundation

/// Put a cue into the script text at a word.
///
/// Cuebar's other insertion path (⌘K) works on the editor's caret, which is
/// the right model for a person typing. A *diagnosis* has no caret: it has a
/// word index from `ScriptAnalysis`, and it needs to land `[pause 1s]` before
/// that word without anybody finding the place by hand first.
///
/// The word numbering comes from `ScriptParser.wordRanges` — the same single
/// scanner `parse` and `wordCount` use. This file used to carry its own
/// character walk, which counted the words *inside* a `#` heading; every
/// staged cue in a script with a heading therefore landed in the line above
/// the one it was about. A pause in the wrong place is worse than no pause,
/// because it reads as though the script said something it didn't.
public enum CueInsertion {
    /// The **character** offset where a word starts, or nil when the index is
    /// past the end of the script. Mirrors `parse`'s rules.
    ///
    /// Characters, not UTF-16 units — unlike every `NSRange` in Cuebar. The
    /// two are the same for ASCII and differ by one for every emoji, so the
    /// name is the warning: `insert` and `alreadyCued` slice with
    /// `prefix`/`dropFirst`, which count characters, and mixing the two
    /// conventions here lands a cue inside the word before it.
    public static func characterOffset(ofWord index: Int, in body: String) -> Int? {
        let ranges = ScriptParser.wordRanges(in: body)
        guard index >= 0, index < ranges.count else { return nil }
        let start = ranges[index].lowerBound
        return body.distance(from: body.startIndex, to: start)
    }

    /// Insert one cue before the given word.
    public static func inserting(cue: String, beforeWord index: Int, in body: String) -> String {
        guard let at = characterOffset(ofWord: index, in: body) else { return body }
        let snippet = "[\(cue)]"
        // Already staged: a note about a sentence that a previous pass
        // cued must not stack "[pause 1s][pause 1s]" on the same word.
        if alreadyCued(at: at, in: body) { return body }
        return insert(snippet, at: at, in: body)
    }

    /// Several cues at once.
    ///
    /// Applied right to left so every earlier offset stays valid, and one
    /// cue per position — two notes on the same word (a long sentence and a
    /// breathless run) want a single `[breath 1.5s]`, not the same one
    /// twice. Earlier positions win, because they were flagged first and
    /// are therefore the more structural of the pair.
    public static func inserting(cues: [(cue: String, word: Int)], in body: String) -> String {
        var claimed: Set<Int> = []
        var points: [(cue: String, word: Int)] = []
        for point in cues {
            guard !claimed.contains(point.word) else { continue }
            claimed.insert(point.word)
            points.append(point)
        }
        var out = body
        for point in points.sorted(by: { $0.word > $1.word }) {
            out = inserting(cue: point.cue, beforeWord: point.word, in: out)
        }
        return out
    }

    /// The suggestions worth staging, in reading order.
    ///
    /// A pause belongs at the *start* of the sentence it belongs to — a
    /// breath before a line lands where the line is expected, and a cue in
    /// the middle of a sentence interrupts a thought that was going
    /// somewhere. A tongue twister is the exception: the slow-down belongs
    /// on the word itself.
    public static func stagingPoints(for notes: [ScriptAnalysis.Note]) -> [(cue: String, word: Int)] {
        notes.compactMap { note in
            guard let cue = note.cue else { return nil }
            // Only the tongue twister stages on the word itself; everything
            // else stages before its word. The `.emphasis` case that used to
            // be here spelled out `("emphasis", note.wordIndex)`, which is
            // what `default` already does with `note.cue` — a branch that
            // looked like a decision and was not one.
            if note.kind == .tongueTwister { return (cue, note.wordIndex) }
            return (cue, note.wordIndex)
        }
    }

    /// Word `index` is already preceded by a cue?
    ///
    /// "A cue" has to mean an actual cue. Looking only for a `[`…`]` run
    /// treated `array[0]` as one, and — far more often — swallowed the cue
    /// staged for the first word under a heading written `## Notes [draft]`:
    /// one "Stage cues" click did nothing at all and said nothing about why.
    /// `ScriptFile.cueRanges` is the same authority the tidy uses: a bracket
    /// span at the start of a token, not a link label.
    static func alreadyCued(at offset: Int, in body: String) -> Bool {
        let head = body.prefix(offset)
        let ns = head as NSString
        let ranges = ScriptFile.cueRanges(of: String(head))
        guard let last = ranges.last else { return false }
        // Only a cue *immediately* before the word counts; one at the end of
        // the previous paragraph is not this word's cue.
        let gap = ns.substring(from: last.location + last.length)
        return gap.allSatisfy(\.isWhitespace) && !gap.isEmpty
    }

    static func insert(_ snippet: String, at offset: Int, in body: String) -> String {
        let head = body.prefix(offset)
        let tail = body.dropFirst(offset)
        // Start of a line or after punctuation: no leading space needed, and
        // one would read as a stray word in the exported text.
        let needsSpace = !(head.last?.isWhitespace ?? true)
        return head + (needsSpace ? " " : "") + snippet + " " + tail
    }
}