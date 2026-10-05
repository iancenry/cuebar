import Foundation
import Testing
@testable import PromptCore

@Suite struct ScriptAnalysisTests {
    private func notes(_ body: String) -> [ScriptAnalysis.Note] {
        ScriptAnalysis.analyse(words: ScriptParser.words(body))
    }

    @Test func aLongSentenceIsFlagged() {
        let found = notes("""
        Our organisation is committed to delivering innovative solutions that facilitate growth \
        for our customers in every region we operate in across the whole of the portfolio.
        """)
        let long = found.filter { $0.kind == .longSentence }
        #expect(long.count == 1, "one long sentence, one note")
        #expect(long[0].reason.contains("words"))
    }

    @Test func aShortSentenceIsNot() {
        let found = notes("This is fine. It is short. Good.")
        #expect(found.filter { $0.kind == .longSentence }.isEmpty)
    }

    @Test func writtenTalkOpenersAreFlagged() {
        let found = notes("""
        However, we rebuilt the engine last quarter.
        Moreover, the latency dropped by half.
        """)
        let stiff = found.filter { $0.kind == .stiffTransition }
        #expect(stiff.count == 2)
        #expect(stiff.allSatisfy { $0.reason.contains("written-talk") })
    }

    @Test func aPlainOpenerIsNotFlagged() {
        let found = notes("We rebuilt the engine last quarter, and it paid off.")
        #expect(found.filter { $0.kind == .stiffTransition }.isEmpty)
    }

    @Test func hardConsonantClustersAreFlagged() {
        let found = notes("The strengths of the sixth wristwatch shipment shipped.")
        #expect(found.contains { $0.kind == .tongueTwister })
    }

    @Test func ordinaryWordsAreNotTongueTwisters() {
        let found = notes("The implementation replaced the pipeline safely.")
        #expect(found.filter { $0.kind == .tongueTwister }.isEmpty)
        // Real ones, for the record: strengths(s-t-r-n-g-t-h-s) is 5.
        #expect(ScriptAnalysis.hardestRun("strengths") >= ScriptAnalysis.consonantRun)
        #expect(ScriptAnalysis.hardestRun("wristwatch") < ScriptAnalysis.consonantRun)
    }

    @Test func aCommaFreeRunIsFlaggedAsBreathless() {
        let words = ScriptParser.words(
            "We measured the latency of the rewritten billing engine before we shipped it to production.")
        let found = ScriptAnalysis.analyse(words: words)
        #expect(found.contains { $0.kind == .breathless })
    }

    @Test func commasBreakTheRun() {
        let words = ScriptParser.words(
            "We measured the latency, of the rewritten billing engine, before we shipped it.")
        let found = ScriptAnalysis.analyse(words: words)
        #expect(found.filter { $0.kind == .breathless }.isEmpty)
    }

    @Test func shortPointedLinesAreFlaggedForEmphasis() {
        let found = notes("""
        The engine was the last thing standing in the way.

        We rebuilt it. Every invoice settled in 200 milliseconds.
        """)
        #expect(found.contains { $0.kind == .emphasis })
    }

    @Test func everyNotePointsAtARealWord() {
        let body = """
        # Rebuilding billing

        However, the engine we inherited in 2019 could not settle an invoice in under two seconds.

        The sixth wristwatch shipment shipped late, which surprised everyone in the room.

        We rebuilt it.
        """
        let words = ScriptParser.words(body)
        let found = ScriptAnalysis.analyse(words: words)
        #expect(!found.isEmpty)
        for note in found {
            #expect(note.wordIndex >= 0 && note.wordIndex < words.count,
                    "note at \(note.wordIndex) with \(words.count) words")
            #expect(!note.reason.isEmpty)
            #expect(note.cue?.isEmpty == false)
        }
        // And in reading order, so the presenter can walk them top to bottom.
        #expect(found.map(\.wordIndex) == found.map(\.wordIndex).sorted())
    }

    @Test func aCueIsChosenForEveryKind() {
        #expect(ScriptAnalysis.Note(kind: .longSentence, wordIndex: 0,
                                     suggestion: "", reason: "").cue == "breath 1.5s")
        #expect(ScriptAnalysis.Note(kind: .tongueTwister, wordIndex: 0,
                                     suggestion: "", reason: "").cue == "emphasis")
    }

    @Test func emptyAndTinyScriptsSurvive() {
        #expect(ScriptAnalysis.analyse(words: []).isEmpty)
        #expect(ScriptAnalysis.analyse(words: ["Hi"]).isEmpty)
        #expect(notes("Hmm. Right.").allSatisfy { $0.wordIndex < 3 })
    }

    @Test func sentencesSkipDecimals() {
        // "3.5 seconds" is not two sentences.
        let words = ScriptParser.words("It settled in 3.5 seconds, which was fine.")
        let sentences = ScriptAnalysis.sentences(of: words)
        #expect(sentences.count == 1)
    }

    @Test func dependentClausesAreFlagged() {
        let found = notes("""
        That the team shipped on Friday surprised everybody.
        """)
        #expect(found.contains { $0.kind == .tangledClause })
        #expect(notes("We shipped on Friday.").filter { $0.kind == .tangledClause }.isEmpty)
    }

    @Test func fuzzedScriptsNeverProduceAnImpossibleNote() {
        var random = SplitMix64(seed: 3)
        let alphabet = ["the", "engine,", "latency", "however", "sixth", "wristwatch",
                        "and", "that", "we", "shipped", "3.5", "billing", "."]
        for _ in 0..<200 {
            let count = Int(random.next() % 120) + 1
            let words = (0..<count).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }
            let found = ScriptAnalysis.analyse(words: words)
            for note in found {
                #expect(note.wordIndex >= 0 && note.wordIndex < words.count)
                #expect(!note.suggestion.isEmpty)
            }
            #expect(found.map(\.wordIndex) == found.map(\.wordIndex).sorted())
        }
    }
}