import Foundation

/// Read a script the way a presenter reads it aloud: what is hard to say,
/// where they will run out of breath, and where a pause or a beat would do
/// the work a paragraph is doing.
///
/// This is deliberately **not** AI. The judgement "that sentence is 34 words
/// long and nobody says 34 words without a breath" is arithmetic, it is
/// right every time, it costs nothing, and it works with the radio off. The
/// model is for rewriting; the *diagnosis* stays here, where it can be
/// tested and where being wrong is visible rather than plausible.
public enum ScriptAnalysis {
    /// One finding, with the word it belongs to, so the prompter can point at
    /// it and the suggestion can be applied in place.
    public struct Note: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            /// A sentence longer than a breath.
            case longSentence
            /// A run of words with no pause in it — the mouth gets ahead of
            /// the brain here.
            case breathless
            /// A cluster of hard consonants that the mouth will trip over.
            case tongueTwister
            /// A sentence opening with a transition that is read as written.
            case stiffTransition
            /// A clause with a relative clause or a subordinate stack that
            /// has to be held in the head.
            case tangledClause
            /// A short sentence carrying the point. Worth leaning on.
            case emphasis
        }

        public let kind: Kind
        /// Word index the note is about.
        public let wordIndex: Int
        /// What to do, in the script's own language.
        public let suggestion: String
        /// One line for the presenter: why this was flagged.
        public let reason: String

        public init(kind: Kind, wordIndex: Int, suggestion: String, reason: String) {
            self.kind = kind
            self.wordIndex = wordIndex
            self.suggestion = suggestion
            self.reason = reason
        }

        /// The cue to insert, if this note is one Cuebar can stage.
        public var cue: String? {
            switch kind {
            case .longSentence, .breathless: return "breath 1.5s"
            case .tongueTwister: return "emphasis"
            case .stiffTransition: return "pause 1s"
            case .tangledClause: return "breath 1.5s"
            case .emphasis: return "emphasis"
            }
        }
    }

    public struct Sentence: Equatable, Sendable {
        public let range: Range<Int>
        public let text: String
        public var words: Int { range.count }
    }

    /// A word above this in a sentence is a mouthful.
    public static let longSentenceWords = 22
    /// A clause above this needs air inside it.
    public static let breathlessRunWords = 14
    /// Consonant letters in a row before a word needs slowing down.
    public static let consonantRun = 5

    /// The findings for a script, in order.
    public static func analyse(words: [String]) -> [Note] {
        var notes: [Note] = []
        for sentence in sentences(of: words) {
            notes.append(contentsOf: sentenceNotes(sentence, in: words))
        }
        return notes.sorted { $0.wordIndex < $1.wordIndex }
    }

    static func sentenceNotes(_ sentence: Sentence, in words: [String]) -> [Note] {
        var notes: [Note] = []
        let start = sentence.range.lowerBound
        let slice = Array(words[sentence.range])

        if sentence.words > longSentenceWords {
            notes.append(Note(kind: .longSentence, wordIndex: start,
                              suggestion: "Split this sentence",
                              reason: "\(sentence.words) words without a break"))
        }
        if let opener = stiffOpener(slice) {
            notes.append(Note(kind: .stiffTransition, wordIndex: start,
                              suggestion: "Start with the point",
                              reason: "“\(opener)” is written-talk"))
        }
        if hasDependentClause(slice) {
            notes.append(Note(kind: .tangledClause, wordIndex: start + 1,
                              suggestion: "Say the main clause first",
                              reason: "a subordinate clause ahead of the verb"))
        }
        // A breathless run: many content words in a row.
        if let found = breathlessRun(in: slice) {
            // The last word of the run: that is where the presenter runs out
            // of air, and where the pause belongs.
            let index = min(start + found.offset, words.count - 1)
            notes.append(Note(kind: .breathless, wordIndex: max(index, start),
                              suggestion: "Take a breath here",
                              reason: "\(found.length) words without a comma"))
        }
        for (offset, word) in slice.enumerated() {
            if hardestRun(word) >= consonantRun {
                notes.append(Note(kind: .tongueTwister, wordIndex: start + offset,
                                  suggestion: "Slow this word down",
                                  reason: "“\(word)” — hard consonants back to back"))
            }
        }
        // Emphasis: short, declarative, and either the first or last sentence
        // of its paragraph. The point of a talk is usually a short line.
        if sentence.words >= 3, sentence.words <= 9,
           endsWithFullStop(slice), containsStress(slice) {
            notes.append(Note(kind: .emphasis, wordIndex: start,
                              suggestion: "Lean on this",
                              reason: "a short, pointed line"))
        }
        return notes
    }

    /// Sentence spans over the word list.
    public static func sentences(of words: [String]) -> [Sentence] {
        var out: [Sentence] = []
        var start = 0
        for i in words.indices {
            guard let last = words[i].last else { continue }
            let following = i + 1 < words.count ? words[i + 1] : ""
            if last == "." && following.first?.isNumber == true { continue }
            guard last == "." || last == "!" || last == "?" else { continue }
            let range = start..<(i + 1)
            if range.count >= 2 {
                out.append(Sentence(range: range,
                                    text: words[range].joined(separator: " ")))
            }
            start = i + 1
        }
        if start < words.count, words.count - start >= 2 {
            out.append(Sentence(range: start..<words.count,
                                text: words[start..<words.count].joined(separator: " ")))
        }
        return out
    }

    static let stiffOpeners: Set<String> = [
        "however", "moreover", "furthermore", "additionally", "therefore",
        "consequently", "nevertheless", "nonetheless", "thus", "hence",
        "that said", "in conclusion", "to summarise", "to summarize",
        "in addition", "on the other hand", "as such", "in order to",
    ]

    /// A transition word that reads as written-talk when said.
    static func stiffOpener(_ words: [String]) -> String? {
        // Bare, not lowercased: "However," is the word with its comma, and
        // comparing the punctuated form against the list misses every one
        // of them.
        func bare(_ index: Int) -> String {
            (words[index].trimmingCharacters(in: .punctuationCharacters)).lowercased()
        }
        guard let first = words.first.map({ _ in bare(0) }) else { return nil }
        if stiffOpeners.contains(first) { return first }
        // "Additionally, we..." — the comma does not save it.
        if words.count > 1, words[1].hasSuffix(","), stiffOpeners.contains(bare(1)) {
            return bare(1)
        }
        return nil
    }

    static let subordinators: Set<String> = [
        "that", "which", "who", "whose", "where", "when", "because", "although",
        "though", "while", "whereas", "since", "unless", "whether", "if",
    ]

    /// A subordinate clause before the sentence's main verb is the shape
    /// that makes people lose the thread.
    static func hasDependentClause(_ words: [String]) -> Bool {
        let firstVerbish = words.firstIndex { isVerbLike($0) }
        guard let verb = firstVerbish else { return false }
        // Nothing before the verb but a subordinator and a subject.
        let prefix = words[0..<max(1, verb)].map {
            $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
        }
        return prefix.contains { subordinators.contains($0) }
    }

    /// A cheap verb test: an -ing/-ed word, an auxiliary, or a word that is
    /// not a noun-like stop word. Crude on purpose — a POS tagger in a
    /// teleprompter would be both slow and wrong in the same place.
    static func isVerbLike(_ word: String) -> Bool {
        let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
        if ["is", "are", "was", "were", "be", "been", "being", "have", "has",
            "had", "do", "does", "did", "can", "could", "will", "would",
            "shall", "should", "may", "might", "must"].contains(bare) { return true }
        return bare.hasSuffix("ed") && bare.count > 4
    }

    /// The longest run of content words with no comma or conjunction in it,
    /// as an offset from the start of `words`.
    ///
    /// The offset is the point of this. The original returned a *length*, and
    /// the caller added it to the sentence's start as if it were a position:
    /// a 15-word sentence that was its own run produced index 15 — one past
    /// the end — so the staged `[breath]` had no character offset and the cue
    /// silently vanished, and a run inside a longer sentence put the breath on
    /// the first word of the *next* sentence. A breath belongs at the end of
    /// the words that need it.
    static func breathlessRun(in words: [String]) -> (offset: Int, length: Int)? {
        var run = 0
        var best = 0
        var bestOffset = 0
        for (offset, word) in words.enumerated() {
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            let breaks = bare == "and" || bare == "but" || bare == "or"
                || bare == "so" || bare == "which" || bare == "that"
            if word.last == "," || word.last == ";" || breaks {
                if run > best { best = run; bestOffset = offset - 1 }
                run = 0
            } else {
                run += 1
                if run > best { best = run; bestOffset = offset }
            }
        }
        return best > breathlessRunWords ? (bestOffset, best) : nil
    }

    /// The longest run of consonant letters in a word. Vowels and the
    /// letters that glide (`y`, `w`) break a run.
    static func hardestRun(_ word: String) -> Int {
        let consonants = Set("bcdfghjklmnpqrstvxz")
        var best = 0
        var run = 0
        for character in word.lowercased() {
            if character.isLetter && consonants.contains(character) {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    static func endsWithFullStop(_ words: [String]) -> Bool {
        guard let last = words.last?.last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    /// Words that carry stress when said: absolutes, comparatives, and the
    /// few words a presenter leans on because they are the point.
    static let stressWords: Set<String> = [
        "not", "never", "every", "only", "must", "exactly", "literally",
        "always", "nevertheless", "best", "biggest", "hardest", "worst",
        "first", "last", "no", "nothing", "everything", "the",
    ]

    /// A short sentence worth leaning on: it says something rather than
    /// connecting something.
    static func containsStress(_ words: [String]) -> Bool {
        if words.contains(where: { $0.first?.isNumber == true }) { return true }
        for (offset, word) in words.enumerated() {
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if stressWords.contains(bare) { return true }
            // A proper noun: capitalised, and not just the first word of the
            // sentence — "The Engine" is a title, "The" is not.
            if offset > 0, bare.count > 2, word.first?.isUppercase == true { return true }
            if word.count > 2, word.uppercased() == word, bare.count > 2 { return true }
        }
        return false
    }
}