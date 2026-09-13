import Testing
import PromptCore

@Suite struct SpeechMatcherEdgeTests {
    @Test func singleWordScriptTracks() {
        #expect(SpeechMatcher.matchEnd(transcript: "say hello", words: ["hello"], fromWordIndex: 0) == 1)
    }

    @Test func multiWordStillNeedsTwo() {
        #expect(SpeechMatcher.matchEnd(transcript: "hello", words: ["hello", "world"], fromWordIndex: 0) == nil)
    }

    @Test func trailingPunctuationCompletes() {
        #expect(SpeechMatcher.matchEnd(transcript: "hello world",
                                       words: ["hello", "world", "!!!"],
                                       fromWordIndex: 0) == 3)
    }
}
