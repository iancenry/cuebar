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
        // words: one(0) two(1) | three(2) four(3); the cue joins page 1
        // with "three", so page 1's token slice starts before the word.
        let index = ScriptIndex(tokens: ScriptParser.parse("one two [pause] three four"))
        #expect(index.pageTokenRange(page: 0, pageSize: 2) == 0..<2)
        #expect(index.pageTokenRange(page: 1, pageSize: 2) == 2..<5)
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
        // A trailing cue waits at the last word rather than being dropped.
        let trailing = ScriptParser.parse("one two [pause]")
        #expect(ReadingWindow.pauseCueWordIndices(trailing) == [1])
    }

    @Test func timedCuesHoldTheNextWord() {
        let tokens = ScriptParser.parse("a [smile] [pause 2s] b [breath 1.5] c")
        let holds = ReadingWindow.timedHoldCues(tokens)
        // words: a(0) b(1) c(2); the pause arms b, the breath arms c
        #expect(holds == [1: 2.0, 2: 1.5])
        // Timed cues are NOT bare-pause indices (no double handling).
        #expect(ReadingWindow.pauseCueWordIndices(tokens).isEmpty)
    }

    @Test func barePauseCuesExcludeTimedOnes() {
        let tokens = ScriptParser.parse("one [pause] two [pause 2s] three [break] four")
        #expect(ReadingWindow.pauseCueWordIndices(tokens) == [1, 3]) // bare + [break]
        #expect(ReadingWindow.timedHoldCues(tokens) == [2: 2.0])
    }

    @Test func pauseCueRecognition() {
        func isPause(_ raw: String) -> Bool {
            ReadingWindow.isPauseCue(ScriptCue.interpret(raw))
        }
        #expect(isPause("[pause]"))
        #expect(isPause("[wait for laughter]"))   // "break" is a pause too
        #expect(isPause("[hold]"))
        #expect(isPause("[stop]"))
        #expect(!isPause("[smile]"))
    }

    // MARK: - Cue plan (one pass, one answer for holds / pauses / jumps)

    @Test func directionCueDoesNotCancelAPendingWait() {
        // [pause 2s][smile] word — the smile is a stage direction, not a
        // reason to drop the two-second hold the presenter asked for.
        let plan = ScriptIndex(tokens: ScriptParser.parse("a [pause 2s][smile] b")).cuePlan
        #expect(plan.holds == [1: 2.0])
        #expect(plan.indices == [1])
    }

    @Test func trailingCueWaitsAtTheEnd() {
        let plan = ScriptIndex(tokens: ScriptParser.parse("a b [pause 2s]")).cuePlan
        #expect(plan.holds == [1: 2.0])   // the last word
        #expect(plan.indices == [1])      // and it is still a legal jump target
        let bare = ScriptIndex(tokens: ScriptParser.parse("a b [pause]")).cuePlan
        #expect(bare.pauses == [1])
        #expect(ScriptIndex(tokens: ScriptParser.parse("[smile]")).cuePlan.indices.isEmpty)
    }

    @Test func adjacentCuesShareOneTarget() {
        let plan = ScriptIndex(tokens: ScriptParser.parse("a [smile][emphasis][pause 2s] b")).cuePlan
        #expect(plan.indices == [1])
        #expect(plan.holds == [1: 2.0])
    }

    @Test func everyCueTargetIsARealWordIndex() {
        // The trailing cue is the case that bites: an out-of-range target
        // would make Jump-to-cue stop playback at the end of the script.
        let text = "one [smile] two\n\n[breath 1.5] three [pause] four [drink] five [pause 2s]"
        let plan = ScriptIndex(tokens: ScriptParser.parse(text)).cuePlan
        let words = ScriptParser.words(text).count
        #expect(plan.indices.allSatisfy { $0 < words })
        // Everything executable is also jumpable. (The reverse isn't true:
        // a [drink] is a badge, not a behaviour.)
        #expect(Set(plan.holds.keys).union(plan.pauses).isSubset(of: Set(plan.indices)))
    }

    @Test func scriptWithoutCuesHasAnEmptyPlan() {
        let plan = ScriptIndex(tokens: ScriptParser.parse("just words here")).cuePlan
        #expect(plan.isEmpty)
        #expect(plan.holds.isEmpty)
        #expect(plan.pauses.isEmpty)
    }

    @Test func cueBeforeAParagraphBreakRidesToTheNextWord() {
        let plan = ScriptIndex(tokens: ScriptParser.parse("one two [pause 2s]\n\nthree four")).cuePlan
        #expect(plan.holds == [2: 2.0])
    }

    @Test func jumpWordsConvertsSecondsAtTheCurrentSpeed() {
        #expect(ReadingWindow.jumpWords(forSeconds: 10, wordsPerSecond: 2.5) == 25)
        #expect(ReadingWindow.jumpWords(forSeconds: -10, wordsPerSecond: 2.5) == -25)
        #expect(ReadingWindow.jumpWords(forSeconds: 10, wordsPerSecond: 0.5) == 5)
        #expect(ReadingWindow.jumpWords(forSeconds: .nan, wordsPerSecond: 2.5) == 0)
    }

    // MARK: - Cue jumps (Next / Previous Cue)


    private let tokens = ScriptParser.parse("one two [smile] three four [pause 2s] five")

    @Test func cueIndicesPointAtTheFollowingWord() {
        #expect(ReadingWindow.cueWordIndices(tokens) == [2, 4])
    }

    @Test func scriptWithoutCuesHasNowhereToJump() {
        #expect(ReadingWindow.cueWordIndices(ScriptParser.parse("just words here")) == [])
        #expect(ReadingWindow.nextCueWordIndex(after: 0, in: []) == nil)
        #expect(ReadingWindow.previousCueWordIndex(before: 0, in: []) == nil)
    }

    @Test func nextCueMovesForwardThenWraps() {
        let indices = ReadingWindow.cueWordIndices(tokens)
        #expect(ReadingWindow.nextCueWordIndex(after: 0, in: indices) == 2)
        #expect(ReadingWindow.nextCueWordIndex(after: 2, in: indices) == 4)
        #expect(ReadingWindow.nextCueWordIndex(after: 4, in: indices) == 2) // wraps
    }

    @Test func previousCueMovesBackThenWraps() {
        let indices = ReadingWindow.cueWordIndices(tokens)
        #expect(ReadingWindow.previousCueWordIndex(before: 5, in: indices) == 4)
        #expect(ReadingWindow.previousCueWordIndex(before: 4, in: indices) == 2)
        #expect(ReadingWindow.previousCueWordIndex(before: 0, in: indices) == 4) // wraps
    }

    @Test func fromAnUnknownPositionJumpToTheNearestEdge() {
        let indices = ReadingWindow.cueWordIndices(tokens)
        #expect(ReadingWindow.nextCueWordIndex(after: nil, in: indices) == 2)
        #expect(ReadingWindow.previousCueWordIndex(before: nil, in: indices) == 4)
    }

    // MARK: - pageParagraphRows (single-pass render grouping)

    @Test func pageRowsSplitOnParagraphs() {
        let tokens = ScriptParser.parse("one two\n\nthree four")
        let rows = ScriptIndex(tokens: tokens).pageParagraphRows(page: 0, pageSize: 4, showCues: true)
        #expect(rows.count == 2)
        #expect(rows[0].map(\.token) == [.word("one"), .word("two")])
        #expect(rows[1].map(\.wordIndex) == [2, 3])
    }

    @Test func pageRowsSkipOtherPages() {
        let tokens = ScriptParser.parse("one two three four")
        let rows = ScriptIndex(tokens: tokens).pageParagraphRows(page: 1, pageSize: 2, showCues: true)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.wordIndex) == [2, 3])
    }

    @Test func pageRowsHideCuesWhenAsked() {
        let tokens = ScriptParser.parse("one [smile] two")
        let shown = ScriptIndex(tokens: tokens).pageParagraphRows(page: 0, pageSize: 2, showCues: true)
        #expect(shown[0].count == 3)
        let hidden = ScriptIndex(tokens: tokens).pageParagraphRows(page: 0, pageSize: 2, showCues: false)
        #expect(hidden[0].map(\.token) == [.word("one"), .word("two")])
    }

    @Test func pageRowsGlobalWordIndices() {
        // Word indexes keep counting across pages: page 2 starts at 4.
        let tokens = ScriptParser.parse("a b c d e f")
        let rows = ScriptIndex(tokens: tokens).pageParagraphRows(page: 1, pageSize: 4, showCues: true)
        #expect(rows[0].map(\.wordIndex) == [4, 5])
    }

    @Test func emptyPageStillRendersOneGroup() {
        let rows = ScriptIndex(tokens: []).pageParagraphRows(page: 0, pageSize: 300, showCues: true)
        #expect(rows.count == 1)
        #expect(rows[0].isEmpty)
    }
}

@Suite struct CuePlanIndexTests {
    /// Every jump target must be a real, ascending, unique word index. A
    /// target past the end would make Jump-to-cue *stop* playback.
    @Test func targetsAreInRangeAscendingAndUnique() {
        for text in ["a b [pause 2s]", "[smile]", "[pause 2s] a", "a [smile][pause 2s] b",
                     "a [pause 2s]\n\nb", "", "[smile] a [smile]",
                     "a b [pause] c [pause 2s]", "x [drink] y [smile] z [demo] w"] {
            let plan = ScriptIndex(tokens: ScriptParser.parse(text)).cuePlan
            let words = ScriptParser.words(text).count
            #expect(plan.indices.allSatisfy { $0 >= 0 && $0 < words }, "out of range: \\(text)")
            #expect(plan.indices == plan.indices.sorted(), "not ascending: \\(text)")
            #expect(Set(plan.indices).count == plan.indices.count, "duplicate: \\(text)")
        }
    }

    @Test func aScriptEndingInACueStillJumpsToItsLastWord() {
        let plan = ScriptIndex(tokens: ScriptParser.parse("a b [pause 2s]")).cuePlan
        let next = ReadingWindow.nextCueWordIndex(after: 0, in: plan.indices)
        #expect(next == 1)
        #expect(ReadingWindow.previousCueWordIndex(before: 0, in: plan.indices) == 1)
    }
}
