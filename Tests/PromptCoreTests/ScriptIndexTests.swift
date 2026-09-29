import Testing
import Foundation
@testable import PromptCore

/// The prompter renders one page at a time, and `ScriptIndex` exists so it
/// can build that page without walking the script. These tests hold that
/// fast path to the behaviour of a naive whole-script implementation.
@Suite struct ScriptIndexTests {
    /// Independent, deliberately naive reference: assign a page to every
    /// token by scanning the whole array, then collect one page's rows.
    private static func naiveRows(tokens: [ScriptToken], page: Int, pageSize: Int,
                                  showCues: Bool) -> [[ReadingWindow.TokenRow]] {
        var wordIndexAt = [Int](repeating: -1, count: tokens.count)
        var wordCount = 0
        for i in tokens.indices where tokens[i].isWord {
            wordIndexAt[i] = wordCount
            wordCount += 1
        }
        let lastPage = max(0, ReadingWindow.pageCount(wordCount: wordCount, pageSize: pageSize) - 1)
        var pages = [Int](repeating: 0, count: tokens.count)
        var nextWord = wordCount
        for i in tokens.indices.reversed() {
            if tokens[i].isWord {
                nextWord = wordIndexAt[i]
                pages[i] = min(wordIndexAt[i] / pageSize, lastPage)
            } else {
                let w = min(nextWord, max(0, wordCount - 1))
                pages[i] = wordCount == 0 ? 0 : min(w / pageSize, lastPage)
            }
        }
        var groups: [[ReadingWindow.TokenRow]] = [[]]
        var wordIndex = 0
        for (i, token) in tokens.enumerated() {
            guard pages[i] == page else {
                if token.isWord { wordIndex += 1 }
                continue
            }
            if token.isParagraphBreak {
                groups.append([])
            } else if token.isCue, !showCues {
                continue
            } else {
                groups[groups.count - 1].append(
                    ReadingWindow.TokenRow(token: token, wordIndex: token.isWord ? wordIndex : -1))
            }
            if token.isWord { wordIndex += 1 }
        }
        let nonEmpty = groups.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? [[]] : nonEmpty
    }

    private static let scripts = [
        "", "[smile]", "[pause 2s] leading cue only", "words then [break]",
        "one",
        "one two three four five six",
        "one two [pause] three four",
        "[smile] one two [pause 2s] three [drink] four",
        "one two\n\nthree four\n\nfive",
        "one [pause] two\n\nthree [breath 1.5] four\n\nfive [smile]",
        "a b [pause 2s] c [hold 1s] d\n\ne f g [break] h",
        "[pause 2s] leading cue then words",
        "trailing words then [pause 2s]",
        "trailing words then [smile]",
        "tight [a][b][c] together [pause 2s] words",
    ]

    @Test func fastPageSlicingMatchesTheWholeScriptWalk() {
        for text in Self.scripts {
            let tokens = ScriptParser.parse(text)
            let index = ScriptIndex(tokens: tokens)
            for pageSize in [1, 2, 3, 4, 300] {
                let pages = max(1, index.pageCount(pageSize: pageSize))
                for page in 0..<pages {
                    for showCues in [true, false] {
                        let fast = index.pageParagraphRows(page: page, pageSize: pageSize,
                                                           showCues: showCues)
                        let naive = Self.naiveRows(tokens: tokens, page: page, pageSize: pageSize,
                                                   showCues: showCues)
                        #expect(fast.map { $0.map(\.token) } == naive.map { $0.map(\.token) },
                                "tokens differ: \\(text.debugDescription) p\\(page)/\\(pageSize)")
                        #expect(fast.map { $0.map(\.wordIndex) } == naive.map { $0.map(\.wordIndex) },
                                "indices differ: \\(text.debugDescription) p\\(page)/\\(pageSize)")
                    }
                }
            }
        }
    }

    @Test func pagesTogetherCoverEveryTokenExactlyOnce() {
        for text in Self.scripts {
            let tokens = ScriptParser.parse(text)
            let index = ScriptIndex(tokens: tokens)
            for pageSize in [1, 3, 300] {
                var seen = [Int]()
                for page in 0..<max(1, index.pageCount(pageSize: pageSize)) {
                    seen.append(contentsOf: index.pageTokenRange(page: page, pageSize: pageSize))
                }
                #expect(seen == Array(tokens.indices), "coverage: \\(text.debugDescription) \\(pageSize)")
            }
        }
    }

    @Test func wordCountAndPageArithmeticMatchThePureHelpers() {
        for text in Self.scripts {
            let tokens = ScriptParser.parse(text)
            let index = ScriptIndex(tokens: tokens)
            #expect(index.wordCount == ScriptParser.words(text).count)
            for pageSize in [1, 2, 5, 300] {
                #expect(index.pageCount(pageSize: pageSize)
                        == ReadingWindow.pageCount(wordCount: index.wordCount, pageSize: pageSize))
                for word in 0..<max(1, index.wordCount) {
                    #expect(index.page(forWord: word, pageSize: pageSize)
                            == ReadingWindow.pageIndex(forWord: word, wordCount: index.wordCount,
                                                      pageSize: pageSize))
                }
                #expect(index.page(forWord: nil, pageSize: pageSize) == 0)
            }
        }
    }

    /// One implementation of the cue rules, so the three public readers must
    /// agree with the index they delegate to.
    @Test func theCueReadersAgreeWithTheIndex() {
        for text in Self.scripts {
            let tokens = ScriptParser.parse(text)
            let plan = ScriptIndex(tokens: tokens).cuePlan
            #expect(ReadingWindow.timedHoldCues(tokens) == plan.holds)
            #expect(ReadingWindow.pauseCueWordIndices(tokens) == plan.pauses)
            #expect(ReadingWindow.cueWordIndices(tokens) == plan.indices)
        }
    }

    @Test func rowsCarryTheInterpretedCue() {
        let index = ScriptIndex(tokens: ScriptParser.parse("one [pause 2s] two [smile] three"))
        let rows = index.pageParagraphRows(page: 0, pageSize: 10, showCues: true).flatMap { $0 }
        let cues = rows.compactMap(\.cue)
        #expect(cues.count == 2)
        #expect(cues[0].kind == .pause)
        #expect(cues[0].seconds == 2)
        #expect(cues[1].kind == .smile)
        #expect(rows.filter { !$0.token.isCue }.allSatisfy { $0.cue == nil })
    }

    @Test func pageSizeDoesNotInvalidateTheIndex() {
        // The "Words per page" slider must not force a re-parse.
        let index = ScriptIndex(tokens: ScriptParser.parse("a b c d e f g"))
        #expect(index.pageCount(pageSize: 2) == 4)
        #expect(index.pageCount(pageSize: 7) == 1)
        #expect(index.page(forWord: 6, pageSize: 2) == 3)
    }
}

/// `ScriptParser.wordCount` has its own character scanner so the sidebar can
/// count words without building a token array. It must agree with the parser
/// on every input, including the awkward ones.
@Suite struct WordCountTests {
    private static let inputs = [
        "", " ", "\n\n", "one", "one two", "  one   two  ", "one\n\ntwo",
        "one\ntwo", "[pause]", "a [pause] b", "[pause] [smile] words",
        "[pause 2s]", "a[smile]b", "[unclosed", "[unclosed two words",
        "[oops\n\nword", "trailing [", "trailing [pause", "[a b] c",
        "one two\n\n[smile] three\n\n[break] four", "  \n [pause 2s] \n ",
        "[nested [pause] brackets] word", "word with — dashes and ’quotes’",
    ]

    @Test func scannerAgreesWithTheParser() {
        for text in Self.inputs {
            #expect(ScriptParser.wordCount(text) == ScriptParser.words(text).count,
                    "word count for \\(text.debugDescription)")
        }
    }

    @Test func scannerMatchesOnRandomInput() {
        // Deterministic pseudo-random text: a short alphabet makes the
        // bracket/whitespace/paragraph interactions actually collide.
        let alphabet = Array("ab \n[]")
        var seed: UInt64 = 0x5eed_1234
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 33) % UInt64(alphabet.count))
        }
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<24 { text.append(alphabet[next()]) }
            #expect(ScriptParser.wordCount(text) == ScriptParser.words(text).count,
                    "word count for \\(text.debugDescription)")
        }
    }
}

@Suite struct DocumentWordCountTests {
    /// The count is cached on the document, so a body change has to be the
    /// only thing that can invalidate it — the sidebar reads it every render.
    @Test func cachedCountFollowsTheBody() {
        var doc = ScriptDocument(title: "t", body: "one two three")
        #expect(doc.wordCount == 3)
        doc.setBody("one two [pause] three four")
        #expect(doc.wordCount == 4)
        doc.setBody("")
        #expect(doc.wordCount == 0)
    }

    @Test func cachedCountSurvivesPersistence() throws {
        let doc = ScriptDocument(title: "t", body: "one two three four five")
        let data = try JSONEncoder().encode([doc])
        let decoded = try JSONDecoder().decode([ScriptDocument].self, from: data)
        #expect(decoded[0].wordCount == 5)
    }
}

@Suite struct ScriptIndexCueStorageTests {
    /// `cues` is the render path's only source of cue data — if it were
    /// dropped, the rows would silently re-parse on every frame.
    @Test func cuesAreIndexAlignedWithTokens() {
        for text in ["one [pause 2s] two [smile] three",
                     "[break]\n\none two", "[drink]",
                     "no cues at all", "[a][b] words"] {
            let index = ScriptIndex(tokens: ScriptParser.parse(text))
            #expect(index.cues.count == index.tokens.count, "text: \\(text.debugDescription)")
            for (i, token) in index.tokens.enumerated() {
                if token.isCue {
                    #expect(index.cues[i] != nil, "cue at \(i) missing")
                    // Same interpretation the row builder hands the badge.
                    if case .cue(let raw) = token {
                        #expect(index.cues[i]?.label == ScriptCue.interpret(raw).label,
                                "label at \(i)")
                    }
                } else {
                    #expect(index.cues[i] == nil, "non-cue at \\(i) carried a cue")
                }
            }
        }
    }

    @Test func rowCueComesFromTheIndex() {
        let index = ScriptIndex(tokens: ScriptParser.parse("a [pause 2s] b [drink] c"))
        let rows = index.pageParagraphRows(page: 0, pageSize: 10, showCues: true).flatMap { $0 }
        #expect(rows.compactMap(\.cue) == index.cues.filter { $0 != nil })
    }
}

@Suite struct ScriptSectionTests {
    @Test func headingsBecomeSectionsNotWords() {
        let index = ScriptIndex(tokens: ScriptParser.parse("""
        # Introduction

        Welcome to the show. [smile]

        ## Problem

        Nobody knows what to do.
        """))
        #expect(index.sections.map(\.name) == ["Introduction", "Problem"])
        #expect(index.sections.map(\.level) == [1, 2])
        // A heading is not spoken, counted, or highlighted: word 0 is still
        // "Welcome", the two headings and the cue are none of the words, and
        // the duration covers the four words of the opening plus the five of
        // the problem — nine.
        #expect(index.wordCount == 9)
        // Each heading points at the first word *under* it.
        #expect(index.sections.map(\.wordIndex) == [0, 4])
    }

    @Test func aHashtagIsStillAWord() {
        // `#hashtag` has no space after the hashes, and `####` is deeper
        // than three levels — neither is a heading, and both have to
        // survive a round trip as the text the presenter typed.
        let index = ScriptIndex(tokens: ScriptParser.parse("#hashtag stays\n#### four hashes stays"))
        #expect(index.sections.isEmpty)
        #expect(index.wordCount == 6)
    }

    @Test func sectionLookupIsByWord() {
        let index = ScriptIndex(tokens: ScriptParser.parse("""
        ## One
        a b c
        ## Two
        d e
        """))
        #expect(index.section(containingWord: 0)?.name == "One")
        #expect(index.section(containingWord: 2)?.name == "One")
        #expect(index.section(containingWord: 3)?.name == "Two")
        #expect(index.section(containingWord: 99)?.name == "Two")
    }

    @Test func anUnsectionedScriptHasNoSections() {
        let index = ScriptIndex(tokens: ScriptParser.parse("Just some words."))
        #expect(index.sectionCount == 0)
        #expect(index.section(containingWord: 0) == nil)
    }

    @Test func aHeadingOpensItsOwnGroup() {
        // The wall of text sections exist to prevent: a heading must not
        // run on from the last line of the previous section.
        let index = ScriptIndex(tokens: ScriptParser.parse("intro words\n## Next\nmore words"))
        let groups = index.pageParagraphRows(page: 0, pageSize: 50, showCues: true)
        #expect(groups.count == 3)
        #expect(groups[1].count == 1)
        #expect(groups[1][0].section?.name == "Next")
    }
}

@Suite struct SectionInsertTests {
    @Test func pushesTheSentenceDownAndLandsTheCaretInTheHeading() {
        let plan = SectionInsert.plan(for: "Hello there", caret: 5)
        #expect(plan.text == "## \nHello there")
        #expect(plan.caret == 3)
        #expect(plan.text.isEmpty == false)
    }

    @Test func reusesAnEmptyLineInsteadOfLeavingABlank() {
        // The blank line the presenter just made *becomes* the heading,
        // and its terminator is kept — so there is somewhere to write the
        // section's body. Nothing is consumed: the caret ends on the marker
        // with the blank line still there underneath.
        let plan = SectionInsert.plan(for: "Intro line\n\n", caret: 11)
        #expect(plan.text == "Intro line\n## \n\n")
        #expect(plan.caret == 14)
    }

    @Test func keepsBlockIndentation() {
        let plan = SectionInsert.plan(for: "  - nested", caret: 3, level: 3)
        #expect(plan.text == "  ### \n  - nested")
    }

    @Test func midSentenceCaretStillKeepsTheWholeSentence() {
        // The half-typed word must survive; a convenience button that eats
        // what you were writing is worse than no button.
        let plan = SectionInsert.plan(for: "The quick brown fox", caret: 10)
        #expect(plan.text == "## \nThe quick brown fox")
    }

    @Test func clampsACaretOutsideTheText() {
        #expect(SectionInsert.plan(for: "abc", caret: 99).caret == 3)
        #expect(SectionInsert.plan(for: "abc", caret: -4).caret == 3)
    }

    @Test func theInsertedHeadingParsesOnceItHasAName() {
        // Straight after the button, the line is "## " with nothing after
        // it — not a heading yet, and it parses as the plain word "##",
        // which is the right way to fail: the presenter's sentence is
        // untouched and the line starts resolving the moment they type.
        let fresh = SectionInsert.plan(for: "Some words here", caret: 0)
        #expect(ScriptIndex(tokens: ScriptParser.parse(fresh.text)).sectionCount == 0)
        #expect(ScriptIndex(tokens: ScriptParser.parse(fresh.text)).wordCount == 4)

        // Type the name and it is a section, and the words are untouched.
        let named = fresh.text.replacingOccurrences(of: "## ", with: "## Problem\n", options: [], range: fresh.text.startIndex..<fresh.text.index(fresh.text.startIndex, offsetBy: 3))
        let index = ScriptIndex(tokens: ScriptParser.parse(named))
        #expect(index.sections.map(\.name) == ["Problem"])
        #expect(index.sections.map(\.wordIndex) == [0])
        #expect(index.wordCount == 3)
    }
}

@Suite struct ConsecutiveHeadingTests {
    @Test func everyHeadingInARunIsRecognised() {
        // The case that was broken: three heading lines in a row, no blank
        // between them — the most ordinary way to type an outline.
        let index = ScriptIndex(tokens: ScriptParser.parse("""
        ## test
        ## hello
        ### deeper
        """))
        #expect(index.sections.map(\.name) == ["test", "hello", "deeper"])
        #expect(index.sections.map(\.level) == [2, 2, 3])
        // A heading-only script has no words at all, and must not claim
        // any: nothing to speak, nothing to highlight.
        #expect(index.wordCount == 0)
    }

    @Test func aHeadingFollowedByTextOnTheNextLineStillParses() {
        let index = ScriptIndex(tokens: ScriptParser.parse("## Problem\nThe text follows."))
        #expect(index.sections.map(\.name) == ["Problem"])
        #expect(index.wordCount == 3)
        #expect(index.sections.map(\.wordIndex) == [0])
    }
}
