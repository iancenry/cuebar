import Testing
import PromptCore

@Suite struct PromptEngineTests {
    @Test @MainActor func loadsAndAdvancesManually() {
        let e = PromptEngine()
        e.loadScript("hello world foo")
        #expect(e.words.count == 3)
        #expect(e.readCharCount == 0)
        e.play()
        e.tick(1.0)
        #expect(e.readCharCount > 0)
    }

    @Test @MainActor func frameRateAccumulates() {
        let a = PromptEngine()
        a.loadScript("hello world foo bar baz qux hello world foo bar baz qux")
        a.play()
        for _ in 0..<60 { a.tick(1.0 / 60) }
        let b = PromptEngine()
        b.loadScript("hello world foo bar baz qux hello world foo bar baz qux")
        b.play()
        for _ in 0..<8 { b.tick(0.125) }
        #expect(abs(a.readCharCount - b.readCharCount) <= 1)
        #expect(a.readCharCount > 0)
    }

    @Test @MainActor func jumpAndSpeedClamp() {
        let e = PromptEngine()
        e.loadScript("one two three four five")
        let idx = e.jumpTo(wordIndex: 3)
        #expect(idx == 3)
        #expect(e.currentWordIndex == 3)
        e.adjustSpeed(100)
        #expect(e.wordsPerSecond == 8)
        e.adjustSpeed(-100)
        #expect(e.wordsPerSecond == 0.5)
        e.setSpeed(.nan)
        #expect(e.wordsPerSecond == 0.5)
    }

    @Test @MainActor func emptyScriptIsSafe() {
        let e = PromptEngine()
        e.loadScript("")
        #expect(e.words.isEmpty)
        #expect(e.currentWordIndex == nil)
        #expect(e.progress == 0)
        e.play()
        #expect(e.isPlaying == false)
        e.tick(1.0)
        e.jumpTo(wordIndex: 5)
    }

    @Test @MainActor func voiceNeverMovesBackwardsByDefault() {
        let e = PromptEngine()
        e.loadScript("one two three")
        e.confirmRead(upTo: 5)
        e.confirmRead(upTo: 2)
        #expect(e.readCharCount == 5)
        e.confirmRead(upTo: 2, allowBacktrack: true)
        #expect(e.readCharCount == 2)
    }

    @Test @MainActor func finishesAndStops() {
        let e = PromptEngine()
        e.loadScript("one two")
        e.play()
        e.confirmRead(upTo: 1000)
        #expect(e.readCharCount == e.totalCharCount)
        #expect(e.isPlaying == false)
    }

    @Test @MainActor func badDeltaIsIgnored() {
        let e = PromptEngine()
        e.loadScript("one two three")
        e.play()
        e.tick(-1)
        e.tick(.nan)
        e.tick(.infinity)
        #expect(e.readCharCount == 0)
        e.tick(5.0)
        #expect(e.readCharCount <= e.totalCharCount)
    }

    @Test @MainActor func velocityRampsUpGently() {
        let e = PromptEngine()
        e.loadScript("hello world foo bar baz qux hello world foo bar")
        e.play()
        #expect(e.effectiveWordsPerSecond == 0)
        e.tick(1.0 / 60)
        #expect(e.effectiveWordsPerSecond > 0)
        #expect(e.effectiveWordsPerSecond < e.wordsPerSecond)
        for _ in 0..<240 { e.tick(1.0 / 60) }
        #expect(abs(e.effectiveWordsPerSecond - e.wordsPerSecond) < 0.05)
    }

    @Test @MainActor func pauseEasesOutInsteadOfHalting() {
        let e = PromptEngine()
        e.loadScript("hello world foo bar baz qux hello world foo bar")
        e.play()
        for _ in 0..<240 { e.tick(1.0 / 60) }
        e.pause()
        // Soft stop: still settling, not dead yet.
        #expect(e.isPlaying == true)
        for _ in 0..<120 { e.tick(1.0 / 60) }
        #expect(e.isPlaying == false)
        #expect(e.effectiveWordsPerSecond == 0)
    }

    @Test @MainActor func boostSpeedsUpWithoutTouchingSavedSpeed() {
        let a = PromptEngine()
        a.loadScript("hello world foo bar baz qux hello world foo bar")
        let b = PromptEngine()
        b.loadScript("hello world foo bar baz qux hello world foo bar")
        a.play()
        b.play()
        b.setBoost(2.0)
        for _ in 0..<60 { a.tick(1.0 / 60); b.tick(1.0 / 60) }
        #expect(b.readCharCount > a.readCharCount)
        #expect(b.wordsPerSecond == a.wordsPerSecond)
        b.setBoost(99)
        #expect(b.boostMultiplier == 2.5)
        b.setBoost(0)
        #expect(b.boostMultiplier == 1.0)
    }

    @Test func pacingDwellsOnLongWordsAndSentenceEnds() {
        #expect(PromptEngine.pacingFactor(for: "a") > PromptEngine.pacingFactor(for: "extraordinary"))
        #expect(PromptEngine.pacingFactor(for: "done.") < PromptEngine.pacingFactor(for: "done"))
        #expect(PromptEngine.pacingFactor(for: "wait,") < PromptEngine.pacingFactor(for: "wait"))
        #expect(PromptEngine.pacingFactor(for: "hello", paragraphStart: true)
            < PromptEngine.pacingFactor(for: "hello"))
    }

    @Test func paragraphStartsFollowBlankLines() {
        let starts = PromptEngine.paragraphStartIndices(in: "one two\n\nthree four", wordCount: 4)
        #expect(starts == [0, 2])
    }
}
