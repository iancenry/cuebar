import Foundation
import Testing
@testable import PromptCore

/// One scanner, and the three callers that used to disagree about it.
///
/// Each of these failed at least once with three implementations in the file:
/// `parse` knew about headings and cues, the other two did not.
@Suite struct WordScannerTests {
    @Test func aHeadingIsNotWords() {
        let body = "## Problem\nWe shipped it."
        #expect(ScriptParser.words(body) == ["We", "shipped", "it."])
        #expect(ScriptParser.wordCount(body) == 3)
        #expect(ScriptParser.wordRanges(in: body).count == 3)
    }

    @Test func headingsDoNotShiftLaterCues() {
        let body = "## Problem\nWe shipped it.\n## Result\nIt worked."
        let words = ScriptParser.words(body)
        for (offset, word) in words.enumerated() {
            let at = try! #require(CueInsertion.characterOffset(ofWord: offset, in: body))
            let placed = CueInsertion.inserting(cue: "pause 1s", beforeWord: offset, in: body)
            let marker = "[pause 1s]"
            let atMarker = (placed as NSString).range(of: marker).location
            #expect((body as NSString).substring(to: at) == (placed as NSString).substring(to: atMarker),
                    "cue for \\(word) landed elsewhere")
        }
    }

    @Test func everyWordIndexResolvesToThatWord() throws {
        let body = """
        # Rebuilding billing

        [smile] One two three.

        ## Problem

        The engine we inherited **could not** settle an invoice.

        ### Detail

        However, it worked.
        """
        let words = ScriptParser.words(body)
        for (offset, word) in words.enumerated() {
            let at = try #require(CueInsertion.characterOffset(ofWord: offset, in: body),
                                  "no offset for word \(offset)")
            // The word must *begin* at the offset — the text before it ends
            // there. That is what "headings are not words" means here.
            let start = body.index(body.startIndex, offsetBy: at)
            let found = String(body[start...].prefix(word.count))
            #expect(found == word,
                    Comment(rawValue: "index \(offset): want \(word.debugDescription), got \(found.debugDescription)"))

        }
    }

    @Test func hashtagsAndDeepHashesAreStillWords() {
        #expect(ScriptParser.words("#hashtag one two") == ["#hashtag", "one", "two"])
        #expect(ScriptParser.words("#### four hashes") == ["####", "four", "hashes"])
        // A line of nothing but hashes is an empty heading placeholder: not a
        // heading, and not prose either. It used to be read as the word "#".
        #expect(ScriptParser.words("#\nOne") == ["One"])
        #expect(ScriptParser.words("###\nOne") == ["One"])
    }

    @Test func anUnclosedBracketIsWords() {
        let body = "One two [oops\n\nthree four five."
        #expect(ScriptParser.words(body).contains("[oops"))
        // And a cue can still be staged after it — the old walk entered the
        // cue state at the bracket and never left, so every later index
        // returned nil and *no* cue could be staged in that script at all.
        let staged = CueInsertion.inserting(cue: "pause 1s", beforeWord: 4, in: body)
            #expect(staged != body, "staging was silently disabled")
    }

    @Test func aClosedCueIsNotWords() {
        let body = "One [pause 2s] two"
        #expect(ScriptParser.words(body) == ["One", "two"])
        #expect(ScriptParser.wordCount(body) == 2)
    }

    @Test func theThreeCallersAgreeOnFuzzedScripts() {
        var random = SplitMix64(seed: 5)
        let pieces = ["# Head", "## Two words", "###", "#tag", "text", "[smile]",
                      "[unclosed", "]", "**bold**", "é", "🎉", "  ", "\n", "3.5"]
        for _ in 0..<500 {
            let count = Int(random.next() % 30) + 1
            let body = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: random.next() % 2 == 0 ? " " : "\n")
            let parsed = ScriptParser.words(body)
            #expect(ScriptParser.wordCount(body) == parsed.count,
                    "wordCount disagrees with parse")
            #expect(ScriptParser.wordRanges(in: body).count == parsed.count,
                    "ranges disagree: \(body.debugDescription)")
            // Every range must actually span the word parse found.
            for (offset, range) in ScriptParser.wordRanges(in: body).enumerated() {
                // The range covers the file's text, which for `**bold**`
                // includes the markers; `parsed` is what gets *said*. The
                // invariant is that they are the same word, not the same
                // characters.
                #expect(ScriptParser.spoken(String(body[range])) == parsed[offset],
                        "range is not the word parse found")

            }
        }
    }

    @Test func cueInsertionNeverChangesTheWords() {
        var random = SplitMix64(seed: 6)
        let pieces = ["# Head", "## Two words", "text", "[smile]", "**bold**", "🎉"]
        for _ in 0..<300 {
            let count = Int(random.next() % 20) + 1
            let body = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: "\n")
            let before = ScriptParser.words(body)
            let index = Int(random.next() % UInt64(max(1, before.count)))
            let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: index, in: body)
            #expect(ScriptParser.words(out) == before,
                    "words changed: \(body.debugDescription) -> \(out.debugDescription)")
        }
    }
}

/// Markdown emphasis is *file* syntax, not speech. Bold in the editor is only
/// safe because the parser drops the markers before anything is said, read,
/// counted or matched — and both scanners have to agree, or the prompter
/// renders a different script from the one the driver follows.
@Suite struct EmphasisIsNotSpokenTests {
    private func spoken(_ text: String) -> [String] { ScriptParser.words(text) }

    @Test func bothMarkersComeOff() {
        #expect(spoken("We **shipped** it.") == ["We", "shipped", "it."])
        #expect(spoken("We *shipped* it.") == ["We", "shipped", "it."])
        #expect(spoken("We _shipped_ it.") == ["We", "shipped", "it."])
    }

    /// The case the tidy rule exists for: `2*3*4` is a spoken expression, not
    /// emphasis, and a character-level stripper turns it into `234`.
    @Test func arithmeticIsNotEmphasis() {
        #expect(spoken("We shipped 2*3*4 yesterday.") == ["We", "shipped", "2*3*4", "yesterday."])
        #expect(spoken("A * B") == ["A", "*", "B"])
        #expect(spoken("5*6") == ["5*6"])
    }

    @Test func unbalancedMarkersAreLeftExactlyAsWritten() {
        #expect(spoken("*unclosed") == ["*unclosed"])
        #expect(spoken("**") == ["**"])
        #expect(spoken("*") == ["*"])
        #expect(spoken("a*b*c") == ["a*b*c"])
    }

    /// The invariant: the tokeniser and the range scanner agree, including on
    /// where each word starts — which is what a staged cue's offset depends on.
    @Test func theTwoScannersAgree() {
        for text in ["We **shipped** it.", "2*3*4 rules", "**a** *b* _c_ d",
                     "***bold italic*** here", "nothing marked at all"] {
            let tokenised = ScriptParser.parse(text).compactMap { token -> String? in
                if case .word(let w) = token { return w }
                return nil
            }
            #expect(tokenised == spoken(text), Comment(rawValue: "\(text)"))
            #expect(ScriptParser.wordCount(text) == tokenised.count)
        }
    }

    /// A cue inside emphasis, and a heading, are unaffected.
    @Test func cuesAndHeadingsAreUntouched() {
        #expect(ScriptParser.words("**Bold** [smile] here") == ["Bold", "here"])
        #expect(ScriptParser.parse("## **Bold** heading").compactMap { token -> String? in
            if case .section(let name, _) = token { return name }
            return nil
        } == ["**Bold** heading"])
    }
}

/// The editor's Bold and Italic buttons. Presentational only — the markers stay
/// in the file and the parser drops them — and they toggle rather than nest,
/// because pressing Bold twice must undo it rather than produce `****`.
@Suite struct EmphasisInsertTests {
    @Test func wrappingASelectionKeepsItSelected() {
        let plan = EmphasisInsert.plan(for: "We shipped it.",
                                       selection: NSRange(location: 3, length: 7),
                                       marker: "**")
        #expect(plan.text == "We **shipped** it.")
        #expect(plan.selected == NSRange(location: 5, length: 7))
        #expect(plan.caret == "We **shipped**".count)
    }

    @Test func withNoSelectionItWrapsTheWordAtTheCaret() {
        let plan = EmphasisInsert.plan(for: "We shipped it.",
                                       selection: NSRange(location: 5, length: 0),
                                       marker: "**")
        #expect(plan.text == "We **shipped** it.")
    }

    @Test func pressingItAgainRemovesIt() {
        let plan = EmphasisInsert.plan(for: "We **shipped** it.",
                                       selection: NSRange(location: 3, length: 11),
                                       marker: "**")
        #expect(plan.text == "We shipped it.")
    }

    /// A selection that is only the space between two words must not be
    /// wrapped into "** **" — it wraps the word at the caret instead.
    @Test func itDoesNotWrapAWhitespaceSelection() {
        let plan = EmphasisInsert.plan(for: "We shipped it.",
                                       selection: NSRange(location: 2, length: 1),
                                       marker: "**")
        #expect(plan.text != "We ** **shipped it.")
        #expect(ScriptParser.words(plan.text).count == 3,
                Comment(rawValue: plan.text))
    }

    /// A stale selection — a document that shrank under an open sheet — must not
    /// trap. `NSString.substring(with:)` aborts on an out-of-range range.
    @Test func anOutOfDateSelectionIsClampedRatherThanTrapping() {
        let plan = EmphasisInsert.plan(for: "Short", selection: NSRange(location: 40, length: 90),
                                       marker: "**")
        #expect(!plan.text.isEmpty)
        #expect(plan.caret <= plan.text.utf16.count)
    }

    /// The promise that makes the button safe: what is written is not what is
    /// said, in either order.
    @Test func whatIsWrittenIsNotWhatIsSaid() {
        let plan = EmphasisInsert.plan(for: "We shipped it.",
                                       selection: NSRange(location: 3, length: 7),
                                       marker: "**")
        #expect(ScriptParser.words(plan.text) == ["We", "shipped", "it."])
    }

    @Test func italicsToggleToo() {
        let plan = EmphasisInsert.plan(for: "We shipped it.",
                                       selection: NSRange(location: 3, length: 7),
                                       marker: "*")
        #expect(plan.text == "We *shipped* it.")
        let back = EmphasisInsert.plan(for: plan.text, selection: NSRange(location: 3, length: 9),
                                      marker: "*")
        #expect(back.text == "We shipped it.")
    }

    /// An empty script has no word to wrap, so the markers go in for the
    /// presenter to type between. The first version produced a range one
    /// character long in a zero-length string, and `substring(with:)` aborts.
    @Test func anEmptyScriptGetsMarkersRatherThanATrap() {
        let plan = EmphasisInsert.plan(for: "", selection: NSRange(location: 0, length: 0),
                                       marker: "**")
        #expect(plan.text == "****")
        #expect(plan.caret == 2, "the caret belongs between the markers")
    }
}

/// Emphasis followed by punctuation is how it actually appears in prose, and
/// requiring the marker to be the token's last character left the asterisks on
/// stage for most of a sentence.
@Suite struct EmphasisWithPunctuationTests {
    private func spoken(_ text: String) -> String { ScriptParser.spoken(text) }

    @Test func aClosingMarkerMayBeFollowedByPunctuation() {
        #expect(spoken("*quiet*.") == "quiet")
        #expect(spoken("**important**,") == "important")
        #expect(spoken("*really*!") == "really")
    }

    /// The arithmetic must survive all of it.
    @Test func arithmeticStillSurvivesPunctuation() {
        #expect(spoken("2*3*4,") == "2*3*4,")
        #expect(spoken("a*b*c.") == "a*b*c.")
    }

    /// An unbalanced pair is still prose, not emphasis.
    @Test func unbalancedIsStillProse() {
        #expect(spoken("**unclosed") == "**unclosed")
        #expect(spoken("*a") == "*a")
        #expect(spoken("a*") == "a*")
    }

    @Test func aLineIsStrippedForTheExporters() {
        #expect(ScriptParser.deemphasised("This is **important** and *quiet*.")
                == "This is important and quiet")
    }
}
