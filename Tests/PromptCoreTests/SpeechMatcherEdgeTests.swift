import Testing
import PromptCore

@Suite struct SpeechMatcherEdgeTests {
    private let words = ["I", "can't", "quite", "believe", "it,"]

    @Test func nonContiguous() {
        // "can't" canonicalizes to "cant" — transcript must use "cant" to match.
        let words = ["I", "cant", "quite", "believe", "it,"]
        let transcript = "I cant quite believe it"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 5)
    }

    @Test func mixedDigits() {
        // Digits stay as digits after canonicalization.
        let words = ["Top", "5", "mistakes"]
        let transcript = "Top 5 mistakes"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 3)
    }

    @Test func canonicalStripsPunctuationAndCase() {
        let a = SpeechMatcher.canonical("Hello!")
        let b = SpeechMatcher.canonical("hello")
        #expect(a == b)
    }

    // MARK: - Tolerant matching

    @Test func tolerantSkipsUnspokenWords() {
        // Speaker skipped "we're going to" — just said key words.
        let words = ["Today", "we're", "going", "to", "talk", "about", "three", "topics"]
        let transcript = "Today talk about three topics"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 8)
    }

    @Test func tolerantHandlesRepeats() {
        // Speaker stuttered "I I I think" — repeated words collapse.
        let words = ["I", "think", "we", "should", "start"]
        let transcript = "I I I think we should start"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 5)
    }

    @Test func tolerantFiltersFillers() {
        // Filler words "um", "uh", "like" don't prevent matching.
        let words = ["Today", "we", "discuss", "quantum", "physics"]
        let transcript = "um Today uh we like discuss quantum physics"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 5)
    }

    @Test func tolerantMixedSkipsAndFillers() {
        // Real-world: skipped words + fillers + a repeat.
        let words = ["Good", "morning", "everyone", "welcome", "to", "the", "show"]
        let transcript = "uh Good morning everyone um welcome the show"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 7)
    }

    @Test func tolerantConsecutiveDuplicateCollapse() {
        // "we we we're we're" → collapsed to "we we're"
        let result = SpeechMatcher.collapseRepeats(["we", "we", "we're", "we're", "going"])
        #expect(result == ["we", "we're", "going"])
    }

    @Test func tolerantFillerStripping() {
        let result = SpeechMatcher.stripFillers(["um", "hello", "uh", "world", "like"])
        #expect(result == ["hello", "world"])
    }

    @Test func tolerantPrepareTranscript() {
        let result = SpeechMatcher.prepareTranscript("Um, I, I think... uh, we should go")
        // After: lowercase, strip punctuation, tokenize, strip fillers, collapse repeats
        #expect(result == ["i", "think", "we", "should", "go"])
    }

    @Test func tolerantMinimumTwoWords() {
        // Single word scripts need at least 1 match, multi-word need 2.
        let words = ["Hello"]
        let end = SpeechMatcher.matchEnd(transcript: "Hello there", words: words, fromWordIndex: 0)
        #expect(end == 1)
    }

    @Test func tolerantTwoWordMinimumEnforced() {
        let words = ["Good", "morning"]
        // Only "morning" matches — that's 1 word, below the 2-word minimum.
        let end = SpeechMatcher.matchEnd(transcript: "morning", words: words, fromWordIndex: 0)
        #expect(end == nil)
    }

    @Test func tolerantSkippedWordsMatchAsSubsequence() {
        // "talk about three" is a subsequence of "today talk about three topics"
        let words = ["Today", "we", "talk", "about", "three", "topics"]
        let transcript = "Today talk about three topics"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 6)
    }

    @Test func tolerantTranscriptTrailing() {
        // Transcript has extra words at the end — no issue.
        let words = ["Hello", "world"]
        let transcript = "Hello world how are you today"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 0)
        #expect(end == 2)
    }

    @Test func tolerantEmptyTranscript() {
        let end = SpeechMatcher.matchEnd(transcript: "", words: words, fromWordIndex: 0)
        #expect(end == nil)
    }

    @Test func tolerantEmptyWords() {
        let end = SpeechMatcher.matchEnd(transcript: "Hello world", words: [], fromWordIndex: 0)
        #expect(end == nil)
    }

    @Test func tolerantFromWordIndex() {
        let words = ["Hello", "world", "foo", "bar"]
        let transcript = "world foo bar"
        let end = SpeechMatcher.matchEnd(transcript: transcript, words: words, fromWordIndex: 1)
        #expect(end == 4)
    }

    @Test func strictStillWorksAfterRefactor() {
        let words = ["Good", "morning"]
        let end = SpeechMatcher.matchEnd(transcript: "Good morning", words: words, fromWordIndex: 0, tolerant: false)
        #expect(end == 2)
    }

    // MARK: - Filler list coverage

    @Test func fillerListIncludesCommonWords() {
        let expected = ["um", "uh", "ah", "er", "hmm", "like", "youknow", "well", "right", "okay", "ok", "so", "basically"]
        for w in expected {
            #expect(SpeechMatcher.fillers.contains(w), "Missing filler: \(w)")
        }
    }
}

@Suite struct TranscriptTailTests {
    /// The tail extractor scans backwards; it must agree exactly with the
    /// obvious "split and take the suffix" version, including the awkward
    /// whitespace cases a recognizer emits.
    @Test func tailMatchesTheSplitVersion() {
        let inputs = [
            "", " ", "  ", "one", "one two", "one  two   three",
            "a b c d e f g h i j k l m n o p", "trailing space ",
            "  leading space", "a\tb", "one two three four five",
        ]
        for text in inputs {
            for maxWords in 0...5 {
                let parts = text.split(separator: " ")
                let expected = maxWords == 0 ? ""
                    : (parts.count > maxWords
                       ? parts.suffix(maxWords).joined(separator: " ")
                       : text)
                #expect(SpeechMatcher.transcriptTail(text, maxWords: maxWords) == expected,
                        "tail(\\(text.debugDescription), \\(maxWords))")
            }
        }
    }

    @Test func tailIsCheapOnALongSession() {
        // A long take: the extractor must not care how much came before.
        let long = Array(repeating: "word", count: 20_000).joined(separator: " ")
        #expect(SpeechMatcher.transcriptTail(long, maxWords: 3) == "word word word")
    }
}

// MARK: - Regressions: the matcher has to follow a live reader

@Suite struct SpeechMatcherLiveTests {
    /// Long enough that a 20-word transcript tail sits mostly *behind* the
    /// reading position, which is the steady state of a real read.
    let script = (1...60).map { "w\($0)" }

    @Test func matchesWhenTheTailStartsBehindThePosition() {
        // The reader is at w31; the tail is 20 words, so its first ten are
        // already read. The old scan walked its pointer to the end of the
        // window on that first miss and gave up — matching never worked
        // again once the reader was past the tail length.
        let tail = ((11...30).map { "w\($0)" } + (31...35).map { "w\($0)" }).joined(separator: " ")
        let end = SpeechMatcher.matchEnd(transcript: tail, words: script, fromWordIndex: 30)
        #expect(end == 35)
    }

    @Test func twoStrayWordsCannotConfirmTheDistanceBetweenThem() {
        // "the" sits at w5, "to" at w30. In order, so a plain subsequence
        // scan confirms w30 — noise moves the highlight 25 words ahead and
        // every real word after it stops matching.
        let words = (1...40).map { $0 == 5 ? "the" : ($0 == 30 ? "to" : "w\($0)") }
        let end = SpeechMatcher.matchEnd(transcript: "the to", words: words, fromWordIndex: 0)
        #expect(end == nil)
    }

    @Test func aChainStillSkipsASingleUnspokenWord() {
        // The behaviour the tolerant mode exists for: a skipped word is
        // tolerated, and the run after it confirms.
        let words = ["Today", "we're", "going", "to", "talk", "about", "three", "topics"]
        let end = SpeechMatcher.matchEnd(transcript: "Today talk about three topics",
                                          words: words, fromWordIndex: 0)
        #expect(end == 8)
    }

    @Test func confirmationStopsAtTheLastHeardWord() {
        // The reader said w1…w10 and then something unrelated. The old scan
        // walked the window looking for the trailing words and reported
        // whatever it found; confirmation has to stop at the last word that
        // actually matched, so the highlight tracks the voice instead of
        // running on into the script.
        let tail = "w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 something unrelated entirely"
        let end = SpeechMatcher.matchEnd(transcript: tail, words: script, fromWordIndex: 0)
        #expect(end == 10)
    }
}

@Suite struct SpeechMatcherGarbledSpeechTests {
    /// What the on-device recognizer actually produced for the Welcome
    /// script, logged from a live read: "Cuebar" → "Cuba" and
    /// "Press Option-Space to" → "It's best to". Two wrong words in a row,
    /// then a four-word gap before the next real run.
    static let script = "Welcome to Cuebar. Press Option-Space to play. Click any word to jump straight there."

    @Test func survivesTwoMisheardWords() {
        let end = SpeechMatcher.matchEnd(
            transcript: "welcome to cuba it's best to play click any",
            words: ScriptParser.words(Self.script), fromWordIndex: 2)
        #expect(end == 9)
    }

    @Test func aWholeConfirmationCannotOutrunItsEvidence() {
        // Three words is the floor, and the span they may claim is capped,
        // so noise can nudge the highlight but never fling it down the page.
        let words = (1...40).map { "w\($0)" }
        let end = SpeechMatcher.matchEnd(transcript: "w1 w20 w39", words: words, fromWordIndex: 0)
        #expect(end == nil)
    }
}
