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
