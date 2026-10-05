import Foundation

/// Rehearsal: which parts of the script the presenter has to remember.
///
/// Practice mode hides spans of the script and lets the presenter fill them
/// in from memory, revealing more each pass. The design decision that makes
/// it worth doing is *what* gets hidden: masking a fixed fraction of words
/// at random produces gaps in the middle of phrases ("we're going to talk
/// about ______ the future of ______"), which rehearses nothing. Hiding
/// whole **clauses** produces gaps where a phrase used to be, which is the
/// thing a presenter actually has to recall.
///
/// Everything here is pure and deterministic: the same script, level and seed
/// always produce the same plan, because a rehearsal that reshuffles its
/// gaps between passes rehearses the wrong thing twice.
public struct PracticePlan: Equatable, Hashable, Sendable {
    /// One gap. Word indices, matching the prompter's.
    public struct Blank: Equatable, Hashable, Sendable {
        public let range: Range<Int>
        public var wordCount: Int { range.count }

        public init(range: Range<Int>) {
            self.range = range
        }
    }

    public var blanks: [Blank]
    /// Words hidden over words in the script, 0...1.
    public var hiddenFraction: Double
    public var totalWords: Int
    public var hiddenWords: Int { blanks.reduce(0) { $0 + $1.wordCount } }

    public var isEmpty: Bool { blanks.isEmpty }

    public init(blanks: [Blank], hiddenFraction: Double, totalWords: Int) {
        self.blanks = blanks
        self.hiddenFraction = hiddenFraction
        self.totalWords = totalWords
    }

    public static func none(totalWords: Int = 0) -> PracticePlan {
        PracticePlan(blanks: [], hiddenFraction: 0, totalWords: totalWords)
    }

    // MARK: - The plan

    /// `level` is 0...1: how much of the script to hide. At 0 nothing is
    /// hidden (reading practice); at 1 as little as can be left standing — and
    /// never literally everything: at least one word stays out of the mask, so
    /// a two-line script is still something a person can read.
    public static func plan(words: [String], level: Double, seed: UInt64) -> PracticePlan {
        let total = words.count
        guard total > 0, level > 0 else { return .none(totalWords: total) }
        let target = Int((Double(total) * min(1, max(0, level))).rounded())
        guard target > 0 else { return .none(totalWords: total) }

        // Gaps get *smaller* as the level rises, not just more numerous.
        // Hiding more and more whole phrases saturates: once every clause is
        // gone there is nowhere left for the level to go, so passes 4, 5 and 6
        // came out identical. Fragmenting instead means the last passes are
        // about stamina rather than about a knob that has stopped moving.
        let granularity = Self.granularity(forLevel: level)
        let clauses = clauses(of: words, minWords: granularity.minWords,
                              maxWords: granularity.maxWords)
        guard !clauses.isEmpty else { return .none(totalWords: total) }

        // A gap longer than this is a paragraph of recall, not a phrase, and
        // a presenter cannot hold it — so an oversized clause is left alone
        // and the level's shortfall is made up elsewhere.
        let cap = granularity.maxWords

        var order = clauses.indices.sorted { lhs, rhs in
            score(clauses[lhs], words: words) != score(clauses[rhs], words: words)
                ? score(clauses[lhs], words: words) > score(clauses[rhs], words: words)
                : lhs < rhs
        }
        // Seeded shuffle: same script and level → same rehearsal.
        var random = SplitMix64(seed: seed)
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            let j = Int(random.next() % UInt64(i + 1))
            order.swapAt(i, j)
        }

        var chosen: [Blank] = []
        var hidden = 0
        for position in order {
            guard hidden < target else { break }
            let clause = clauses[position]
            let size = clause.count
            guard size <= cap else { continue }
            // Stop before overshooting the target by more than half a
            // clause: a plan that hides 40% when asked for 30% is a plan the
            // presenter will describe as "level 4" when it is level 3.
            guard hidden + size <= target + max(1, size / 2) else { continue }
            chosen.append(Blank(range: clause))
            hidden += size
        }
        chosen.sort { $0.range.lowerBound < $1.range.lowerBound }
        // A short script must not go from "nothing hidden" to "everything
        // hidden" between two passes. A four-word script cannot be split into
        // phrases, so its one candidate span overshoots the target at the first
        // level and is skipped — and taken whole at the next, which leaves the
        // presenter one word and three gaps. Keeping at least one word out of
        // the mask costs nothing on a real talk (where the plan hides dozens of
        // phrases) and keeps a two-line script rehearsable.
        if !chosen.isEmpty, chosen.reduce(0, { $0 + $1.range.count }) >= total {
            chosen.removeLast()
        }
        return PracticePlan(blanks: chosen,
                            hiddenFraction: total > 0 ? Double(hidden) / Double(total) : 0,
                            totalWords: total)
    }

    /// Gap size for a level. Phrases low down, fragments high up.
    public static func granularity(forLevel level: Double) -> (minWords: Int, maxWords: Int) {
        level <= 0.5 ? (3, 8) : (2, 4)
    }

    /// Hideable spans, in order: sentence-aware, clause-aligned, and sized
    /// so every gap is sayable.
    ///
    /// Three passes, because no single split rule is enough. Splitting only
    /// at commas and connectives leaves a 30-word clause with nothing inside
    /// it, so the whole thing gets skipped as unsayable and the level knob
    /// stops mattering; splitting only at sentence ends leaves one gap the
    /// size of the opening line.
    static func clauses(of words: [String],
                        minWords: Int = 3,
                        maxWords: Int = 8) -> [Range<Int>] {
        guard words.count >= minWords else { return [] }
        var out: [Range<Int>] = []

        for sentence in sentences(of: words) {
            // Everything here is in *absolute* word indices. Mixing the
            // sentence-relative offset with the absolute loop index is how
            // every clause after the first came out as nonsense.
            var pieceStart = sentence.lowerBound
            func close(_ end: Int) {
                guard end > pieceStart else { return }
                let range = pieceStart..<min(end, words.count)
                if range.count >= minWords {
                    out.append(range)
                    pieceStart = range.upperBound
                }
            }
            for i in sentence {
                guard i >= pieceStart else { continue }
                let word = words[i]
                let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
                let endsClause = word.last == "," || word.last == ";" || word.last == ":"
                    || bare == "and" || bare == "but" || bare == "so"
                let startsClause = connectives.contains(bare)
                let size = i - pieceStart + 1
                // Oversized: cut at the last word that fit, so a gap does not
                // land more often mid-phrase than it must.
                // `>=`, not `>`: the cut happens *after* this word, so
                // firing one word late produces chunks of maxWords + 1 — and
                // then a "4 word" granularity quietly hides five words each
                // time, which is how pass 3 ended up hiding less than pass 2.
                let tooLong = size >= maxWords
                if tooLong
                    || (endsClause && size >= minWords)
                    || (startsClause && size >= maxWords / 2) {
                    close(i + 1)
                }
            }
            close(sentence.upperBound)
        }
        return mergeRunts(out, in: words.count, minWords: minWords)
    }

    /// Sentence spans: a word ending a sentence, or the end of the script.
    /// A heading line or a cue is not a sentence boundary that matters, and a
    /// full stop inside a number ("3.5") is not one either — hence the digit
    /// check on the following word.
    static func sentences(of words: [String]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in words.indices {
            guard let last = words[i].last else { continue }
            guard last == "." || last == "!" || last == "?" else { continue }
            let following = i + 1 < words.count ? words[i + 1] : ""
            let afterDecimal = last == "." && following.first?.isNumber == true
            if afterDecimal { continue }
            out.append(start..<(i + 1))
            start = i + 1
        }
        if start < words.count { out.append(start..<words.count) }
        return out
    }

    static let connectives: Set<String> = [
        "and", "but", "so", "which", "that", "because", "while", "when", "if",
        "then", "or", "yet", "although", "though", "since", "unless", "before",
        "after", "whereas", "however",
    ]

    /// Fold one- and two-word spans into a neighbour. A gap that is just
    /// "and then" teaches nothing and costs the presenter a stumble.
    static func mergeRunts(_ ranges: [Range<Int>], in total: Int, minWords: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for range in ranges {
            if let last = out.last, range.count < minWords {
                out[out.count - 1] = last.lowerBound..<range.upperBound
            } else {
                out.append(range)
            }
        }
        // A short trailing span joins the one before it.
        if out.count > 1, let last = out.last, last.count < minWords {
            out.removeLast()
            if let previous = out.last {
                out[out.count - 1] = previous.lowerBound..<last.upperBound
            }
        }
        return out.filter { $0.upperBound <= total }
    }

    /// How worth hiding a clause is: long clauses carry more, and clauses
    /// full of content words carry more than connective tissue. Normalised to
    /// 0...1-ish so the sort is stable and readable.
    static func score(_ range: Range<Int>, words: [String]) -> Double {
        let slice = words[range]
        guard !slice.isEmpty else { return 0 }
        let content = slice.filter { !stopWords.contains($0.lowercased()) }.count
        return Double(slice.count) * 0.5 + Double(content)
    }

    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "for", "with",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these",
        "those", "as", "at", "by", "from", "we", "you", "they", "he", "she", "i",
    ]

    // MARK: - Progression

    /// How much to hide on pass `n` (zero-based).
    ///
    /// Front-loaded on purpose: the jump from reading to a third of the script
    /// missing is the biggest one and it should happen first. Then it eases
    /// toward everything, because the last passes are about stamina rather
    /// than about learning any more words.
    public static func level(forPass pass: Int) -> Double {
        let ladder: [Double] = [0, 0.25, 0.45, 0.6, 0.75, 0.85, 0.95]
        let index = max(0, min(ladder.count - 1, pass))
        return ladder[index]
    }

    /// The number of passes that are useful, for a level indicator.
    public static var passCount: Int { 7 }

    /// Re-run the same plan with one more pass hidden. The seed is folded
    /// with the pass so each pass hides *different* spans — otherwise a
    /// presenter would rehearse the same gap five times and call it practice.
    public static func planForPass(words: [String], pass: Int, seed: UInt64) -> PracticePlan {
        plan(words: words, level: level(forPass: pass), seed: seed &+ UInt64(bitPattern: Int64(pass)) &* 0x9E37_79B9_7F4A_7C15)
    }

    /// The word indices hidden, minus the one being read.
    ///
    /// The current word is never hidden: the presenter arrives at a gap and
    /// has to *say* the words in it — masking it on arrival deletes the
    /// sentence they are in the middle of.
    public func hiddenWords(excluding current: Int?) -> Set<Int> {
        var out: Set<Int> = []
        for blank in blanks {
            for word in blank.range where word != current {
                out.insert(word)
            }
        }
        return out
    }
}

/// A seeded, portable generator. `Swift.SystemRandomNumberGenerator` would
/// make a plan unreproducible, which is exactly what a rehearsal must not be.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}