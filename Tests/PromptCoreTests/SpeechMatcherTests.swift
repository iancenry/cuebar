import Testing
import PromptCore

@Suite struct SpeechMatcherTests {
    private let words = ["Good", "morning,", "and", "thank", "you", "for", "being", "here."]

    // MARK: - Strict (verbatim) matching

    @Test func matchesTailFromStart() {
        #expect(SpeechMatcher.matchEnd(transcript: "good morning", words: words, fromWordIndex: 0, tolerant: false) == 2)
    }

    @Test func matchesMidScript() {
        #expect(SpeechMatcher.matchEnd(transcript: "uh thank you for", words: words, fromWordIndex: 0, tolerant: false) == 6)
    }

    @Test func ignoresCaseAndPunctuation() {
        #expect(SpeechMatcher.matchEnd(transcript: "GOOD MORNING!!!", words: words, fromWordIndex: 0, tolerant: false) == 2)
    }

    @Test func singleWordIsNotEnough() {
        #expect(SpeechMatcher.matchEnd(transcript: "morning", words: words, fromWordIndex: 0, tolerant: false) == nil)
    }

    @Test func repeatHoldsPosition() {
        // Re-reading an earlier sentence matches at-or-after `from`,
        // never behind it.
        #expect(SpeechMatcher.matchEnd(transcript: "good morning", words: words, fromWordIndex: 2, tolerant: false) == nil)
        #expect(SpeechMatcher.matchEnd(transcript: "thank you", words: words, fromWordIndex: 2, tolerant: false) == 5)
    }

    @Test func respectsWindow() {
        #expect(SpeechMatcher.matchEnd(transcript: "being here", words: words, fromWordIndex: 0, windowSize: 2, tolerant: false) == nil)
        #expect(SpeechMatcher.matchEnd(transcript: "being here", words: words, fromWordIndex: 0, windowSize: 40, tolerant: false) == 8)
    }

    @Test func emptyIsSafe() {
        #expect(SpeechMatcher.matchEnd(transcript: "", words: words, fromWordIndex: 0, tolerant: false) == nil)
        #expect(SpeechMatcher.matchEnd(transcript: "hello world", words: [], fromWordIndex: 0, tolerant: false) == nil)
    }

    // MARK: - Transcript tail (bounded matching input)

    @Test func tailKeepsShortTranscriptWhole() {
        #expect(SpeechMatcher.transcriptTail("thank you", maxWords: 20) == "thank you")
        #expect(SpeechMatcher.transcriptTail("", maxWords: 20) == "")
    }

    @Test func tailTrimsToLastWords() {
        let long = (1...50).map { "w\($0)" }.joined(separator: " ")
        #expect(SpeechMatcher.transcriptTail(long, maxWords: 20) == (31...50).map { "w\($0)" }.joined(separator: " "))
    }

    @Test func tailMatchesAfterTrim() {
        // The tail of an accumulated session transcript still matches
        // recent speech — this is exactly how VoiceTracker feeds the
        // matcher, and rescanning the full text is O(session²).
        let session = "good morning and thank you"
        #expect(SpeechMatcher.matchEnd(transcript: SpeechMatcher.transcriptTail(session, maxWords: 2),
                                       words: words, fromWordIndex: 3, tolerant: true) == 5)
    }

    @Test @MainActor func engineConfirmsThroughWord() {
        let e = PromptEngine()
        e.loadScript("Good morning and thank you")
        e.confirmReadThroughWord(2)
        #expect(e.currentWordIndex == 2)
        // Monotonic: a stale transcript can't move it back.
        e.confirmReadThroughWord(0)
        #expect(e.currentWordIndex == 2)
    }
}
