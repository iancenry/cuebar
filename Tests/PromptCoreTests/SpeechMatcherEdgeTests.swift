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
