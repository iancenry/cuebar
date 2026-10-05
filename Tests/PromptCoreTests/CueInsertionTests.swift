import Foundation
import Testing
@testable import PromptCore

@Suite struct CueInsertionTests {
    /// Does this word already sit behind a cue?
    private func alreadyStaged(at index: Int, in body: String) -> Bool {
        guard let at = CueInsertion.characterOffset(ofWord: index, in: body) else { return false }
        return CueInsertion.alreadyCued(at: at, in: body)
    }

    @Test func aCueLandsBeforeTheWord() {
        let body = "One two three four"
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 2, in: body)
        #expect(ScriptParser.words(out) == ["One", "two", "three", "four"],
                "a cue is not a word")
        #expect(out == "One two [pause 1s] three four")
    }

    @Test func theFirstWordCanBeCued() {
        #expect(CueInsertion.inserting(cue: "pause 1s", beforeWord: 0,
                                       in: "One two") == "[pause 1s] One two")
    }

    @Test func anOutOfRangeIndexChangesNothing() {
        let body = "One two"
        #expect(CueInsertion.inserting(cue: "pause 1s", beforeWord: 9, in: body) == body)
        #expect(CueInsertion.inserting(cue: "pause 1s", beforeWord: -1, in: body) == body)
    }

    @Test func existingCuesDoNotShiftTheWordCount() {
        // The walk has to agree with the parser about what a word is, or a
        // note about word 3 stages its cue in the wrong place.
        let body = "One [smile] two [pause 1s] three four five"
        #expect(ScriptParser.words(body) == ["One", "two", "three", "four", "five"])
        let offset = CueInsertion.characterOffset(ofWord: 3, in: body)
        #expect(offset != nil)
        let out = CueInsertion.inserting(cue: "breath 1.5s", beforeWord: 3, in: body)
        #expect(out == "One [smile] two [pause 1s] three [breath 1.5s] four five",
                "a staged cue does not renumber anything")
    }

    @Test func theSameCueIsNotStagedTwice() {
        let body = "A long sentence that needs air here and keeps going"
        let once = CueInsertion.inserting(cue: "breath 1.5s", beforeWord: 5, in: body)
        let twice = CueInsertion.inserting(cue: "breath 1.5s", beforeWord: 5, in: once)
        #expect(once == twice)
    }

    @Test func twoNotesOnOneWordBecomeOneCue() {
        let cues: [(cue: String, word: Int)] = [("breath 1.5s", 4), ("breath 1.5s", 4)]
        let out = CueInsertion.inserting(cues: cues, in: "One two three four five six")
        #expect(out.components(separatedBy: "[breath 1.5s]").count - 1 == 1)
    }

    @Test func severalCuesAllLand() {
        let body = "Alpha beta gamma delta epsilon zeta eta theta"
        let out = CueInsertion.inserting(cues: [("pause 1s", 1), ("breath 1.5s", 4),
                                                 ("emphasis", 6)], in: body)
        #expect(ScriptParser.words(out) == ScriptParser.words(body), "words are unchanged")
        #expect(out.contains("[pause 1s] beta"))
        #expect(out.contains("[breath 1.5s] epsilon"))
        #expect(out.contains("[emphasis] eta"))
        // And the cues parse as cues, not as words.
        #expect(ScriptParser.parse(out).filter(\.isCue).count == 3)
    }

    @Test func aCueAtTheStartOfALineNeedsNoLeadingSpace() {
        let body = "First line here\nsecond line here"
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 3, in: body)
        #expect(out == "First line here\n[pause 1s] second line here")
    }

    @Test func aCueAfterPunctuationIsSpacedProperly() {
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 1, in: "Hello, world")
        #expect(out == "Hello, [pause 1s] world")
    }

    @Test func stagingPointsCoverEveryStagableNote() {
        let notes = ScriptAnalysis.analyse(words: ScriptParser.words("""
        However, the engine we inherited in 2019 could not settle an invoice in under two seconds.
        """))
        let points = CueInsertion.stagingPoints(for: notes)
        #expect(!points.isEmpty)
        #expect(points.allSatisfy { !$0.cue.isEmpty && $0.word >= 0 })
        // A stiff transition pauses *before* the sentence, so its note points
        // at the sentence's first word.
        if let stiff = notes.first(where: { $0.kind == .stiffTransition }) {
            #expect(points.contains { $0.word == stiff.wordIndex && $0.cue == "pause 1s" })
        }
    }

    @Test func offsetsMatchTheParserOnFuzzedScripts() {
        var random = SplitMix64(seed: 11)
        let pieces = ["word", "[smile]", "[pause 1s]", "unclosed[bracket", "3.5",
                      "## Heading", "", "punct.", "(paren)", "“quoted”"]
        for _ in 0..<200 {
            let count = Int(random.next() % 40) + 1
            let body = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: " ")
            let words = ScriptParser.words(body)
            for index in 0..<words.count {
                guard let at = CueInsertion.characterOffset(ofWord: index, in: body) else { continue }
                let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: index, in: body)
                // The staged cue must sit immediately before word `index`,
                // and must not have moved it.
                #expect(ScriptParser.words(out) == words,
                        "cue at \(index) changed the words in \(body.debugDescription)")
                if index < words.count {
                    // Immediately before the word it was about, modulo the
                    // newline it may have been placed after.
                    let marker = "[" + "pause 1s" + "]"
                    let adjacent = [" " + words[index], "\n" + words[index],
                                    "\n\n" + words[index], words[index]]
                    // Already staged by the script itself is also correct:
                    // inserting a second `[pause 1s]` here is the bug this
                    // guards against.
                    let found = adjacent.contains { out.contains(marker + $0) }
                        || alreadyStaged(at: index, in: body)
                    #expect(found, "cue landed wrong: \(index) / \(words[index].debugDescription)")
                }
                #expect(at >= 0 && at <= body.utf16.count)
            }
        }
    }
}
@Suite struct CueInsertionUnicodeTests {
    /// A cue index is an NSRange offset — UTF-16 — while `String.prefix`
    /// counts *characters*. Any astral character before the insertion point
    /// (an emoji, a mathematical symbol, a rare CJK ideograph) makes the two
    /// disagree, and the cue lands in the middle of a word.
    @Test func theOffsetIsCharactersNotUTF16() {
        // Pinned because the two conventions differ by exactly the astral
        // characters Cuebar's own scripts are full of (an emoji in a talk
        // title, a maths symbol in a name).
        let body = "a 🎉 b"
        let at = CueInsertion.characterOffset(ofWord: 2, in: body)
        #expect(at == 4, "characters: \(String(describing: at))")
        #expect(at != (body as NSString).range(of: "b").location,
                "UTF-16 would say 5 — the two conventions must not be mixed")
    }

    @Test func anEmojiBeforeTheCueDoesNotMoveIt() {
        let body = "Ship it 🎉 then tell the room"
        let words = ScriptParser.words(body)
        #expect(words == ["Ship", "it", "🎉", "then", "tell", "the", "room"])
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 3, in: body)
        #expect(out.contains("[pause 1s] then"), "got \(out.debugDescription)")
        #expect(ScriptParser.words(out) == words, "words changed: \(out.debugDescription)")
    }

    @Test func severalAstralCharactersDoNotDrift() {
        let body = "🚀 🎉 🔥 four five six"
        let out = CueInsertion.inserting(cue: "breath 1.5s", beforeWord: 3, in: body)
        #expect(out.hasSuffix("[breath 1.5s] four five six"), "got \(out.debugDescription)")
    }

    @Test func cueDetectionSurvivesAstralCharacters() {
        let body = "🚀 [smile] then talk"
        let offset = try? #require(CueInsertion.characterOffset(ofWord: 1, in: body))
        #expect(CueInsertion.alreadyCued(at: offset!, in: body),
                "the word after an emoji-indexed cue is already cued")
    }

    @Test func mixedScriptsRoundTrip() {
        // Hebrew and Latin share a line; the insertion point is after them.
        let body = "שלום world — and then we stopped"
        let words = ScriptParser.words(body)
        for index in 0..<words.count {
            let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: index, in: body)
            #expect(ScriptParser.words(out) == words, "words changed at \(index): \(out.debugDescription)")
            let marker = "[" + "pause 1s" + "] "
            #expect(out.contains(marker + words[index]),
                    "cue misplaced at \(index): \(out.debugDescription)")
        }
    }
}
