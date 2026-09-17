import Testing
import PromptCore

@Suite struct ReadingWindowTests {
    @Test func pageCountRoundsUp() {
        #expect(ReadingWindow.pageCount(wordCount: 0, pageSize: 300) == 0)
        #expect(ReadingWindow.pageCount(wordCount: 300, pageSize: 300) == 1)
        #expect(ReadingWindow.pageCount(wordCount: 301, pageSize: 300) == 2)
        #expect(ReadingWindow.pageCount(wordCount: 600, pageSize: 300) == 2)
    }

    @Test func pageIndexClamps() {
        #expect(ReadingWindow.pageIndex(forWord: nil, wordCount: 500, pageSize: 300) == 0)
        #expect(ReadingWindow.pageIndex(forWord: 0, wordCount: 500, pageSize: 300) == 0)
        #expect(ReadingWindow.pageIndex(forWord: 299, wordCount: 500, pageSize: 300) == 0)
        #expect(ReadingWindow.pageIndex(forWord: 300, wordCount: 500, pageSize: 300) == 1)
        #expect(ReadingWindow.pageIndex(forWord: 9999, wordCount: 500, pageSize: 300) == 1)
    }

    @Test func wordRangeCoversTail() {
        #expect(ReadingWindow.wordRange(page: 0, wordCount: 500, pageSize: 300) == 0..<300)
        #expect(ReadingWindow.wordRange(page: 1, wordCount: 500, pageSize: 300) == 300..<500)
        #expect(ReadingWindow.wordRange(page: 9, wordCount: 500, pageSize: 300) == 300..<500)
    }

    @Test func cuesRideWithNextWord() {
        let tokens = ScriptParser.parse("one two [pause] three four")
        let pages = ReadingWindow.tokenPages(tokens, pageSize: 2)
        // words: one(0) two(1) | three(2) four(3); cue joins page 1 with "three"
        #expect(pages == [0, 0, 1, 1, 1])
    }

    @Test func islandIsTopFlush() {
        let screen = ReadingWindow.Rect(x: 0, y: 0, width: 1512, height: 982)
        let o = ReadingWindow.notchIslandOrigin(screen: screen, panelWidth: 460, panelHeight: 300)
        #expect(o.x == 1512 / 2 - 230)
        #expect(o.y == 982 - 300)
    }

    @Test func menuBarHeightFromFrames() {
        #expect(ReadingWindow.menuBarHeight(screenHeight: 982, visibleHeight: 944) == 38)
        #expect(ReadingWindow.menuBarHeight(screenHeight: 900, visibleHeight: 900) == 28)
    }

    @Test func islandExpansionStaysCentered() {
        let screen = ReadingWindow.Rect(x: 0, y: 0, width: 1512, height: 982)
        let narrow = ReadingWindow.notchIslandOrigin(screen: screen, panelWidth: 400, panelHeight: 300)
        let wide = ReadingWindow.notchIslandOrigin(screen: screen, panelWidth: 560, panelHeight: 300)
        #expect(narrow.x + 400 / 2 == wide.x + 560 / 2)
        #expect(narrow.y == wide.y)
    }

    @Test func displayIndexClamps() {
        #expect(ReadingWindow.clampedDisplayIndex(5, screenCount: 2) == 1)
        #expect(ReadingWindow.clampedDisplayIndex(-1, screenCount: 2) == 0)
        #expect(ReadingWindow.clampedDisplayIndex(0, screenCount: 0) == 0)
    }

    @Test func durationStrings() {
        #expect(ReadingWindow.durationString(wordCount: 0, wordsPerSecond: 2.5) == "0 sec")
        #expect(ReadingWindow.durationString(wordCount: 31, wordsPerSecond: 2.5) == "12 sec")
        #expect(ReadingWindow.durationString(wordCount: 642, wordsPerSecond: 2.5) == "4:17")
        #expect(ReadingWindow.durationString(wordCount: 10, wordsPerSecond: 0) == "0 sec")
    }

    @Test func pauseCuesMarkTheNextWord() {
        let tokens = ScriptParser.parse("one [pause] two three")
        #expect(ReadingWindow.pauseCueWordIndices(tokens) == [1])
        let polite = ScriptParser.parse("one [smile] two")
        #expect(ReadingWindow.pauseCueWordIndices(polite).isEmpty)
        let trailing = ScriptParser.parse("one two [pause]")
        #expect(ReadingWindow.pauseCueWordIndices(trailing).isEmpty)
    }

    @Test func pauseCueRecognition() {
        #expect(ReadingWindow.isPauseCue("[pause]") == true)
        #expect(ReadingWindow.isPauseCue("[wait for laughter]") == true)
        #expect(ReadingWindow.isPauseCue("[hold]") == true)
        #expect(ReadingWindow.isPauseCue("[smile]") == false)
    }

    // MARK: - pageParagraphRows (single-pass render grouping)

    @Test func pageRowsSplitOnParagraphs() {
        let tokens = ScriptParser.parse("one two\n\nthree four")
        let rows = ReadingWindow.pageParagraphRows(tokens, page: 0, pageSize: 4, showCues: true)
        #expect(rows.count == 2)
        #expect(rows[0].map(\.token) == [.word("one"), .word("two")])
        #expect(rows[1].map(\.wordIndex) == [2, 3])
    }

    @Test func pageRowsSkipOtherPages() {
        let tokens = ScriptParser.parse("one two three four")
        let rows = ReadingWindow.pageParagraphRows(tokens, page: 1, pageSize: 2, showCues: true)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.wordIndex) == [2, 3])
    }

    @Test func pageRowsHideCuesWhenAsked() {
        let tokens = ScriptParser.parse("one [smile] two")
        let shown = ReadingWindow.pageParagraphRows(tokens, page: 0, pageSize: 2, showCues: true)
        #expect(shown[0].count == 3)
        let hidden = ReadingWindow.pageParagraphRows(tokens, page: 0, pageSize: 2, showCues: false)
        #expect(hidden[0].map(\.token) == [.word("one"), .word("two")])
    }

    @Test func pageRowsGlobalWordIndices() {
        // Word indexes keep counting across pages: page 2 starts at 4.
        let tokens = ScriptParser.parse("a b c d e f")
        let rows = ReadingWindow.pageParagraphRows(tokens, page: 1, pageSize: 4, showCues: true)
        #expect(rows[0].map(\.wordIndex) == [4, 5])
    }

    @Test func emptyPageStillRendersOneGroup() {
        let rows = ReadingWindow.pageParagraphRows([], page: 0, pageSize: 300, showCues: true)
        #expect(rows.count == 1)
        #expect(rows[0].isEmpty)
    }
}
