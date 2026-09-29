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

    // MARK: - Timed holds ([pause 2s])

    @Test @MainActor func holdFreezesThenResumes() {
        let e = PromptEngine()
        e.loadScript("alpha beta gamma delta")
        e.play()
        e.jumpTo(wordIndex: 1)
        let frozen = e.readCharCount
        e.hold(for: 2)
        #expect(e.isHolding)
        #expect(e.holdRemaining == 2)
        e.tick(0.25)
        #expect(e.readCharCount == frozen) // frozen mid-hold
        e.tick(0.25)
        #expect(e.holdRemaining == 1.5)
        for _ in 0..<7 { e.tick(0.25) } // 2 s of ticks total: expired
        #expect(!e.isHolding)
        let afterHold = e.readCharCount
        e.tick(2) // past ramp-up: must advance again
        #expect(e.readCharCount > afterHold)
    }

    @Test @MainActor func manualControlsCancelHold() {
        let e = PromptEngine()
        e.loadScript("alpha beta gamma delta")
        e.play()
        e.jumpTo(wordIndex: 1)
        e.hold(for: 2)
        e.pause() // manual pause wins
        #expect(!e.isHolding)
        e.play()
        e.hold(for: 2)
        e.jumpTo(wordIndex: 3) // manual jump wins
        #expect(!e.isHolding)
        #expect(e.currentWordIndex == 3)
    }

    @Test @MainActor func holdRequiresPlayback() {
        let e = PromptEngine()
        e.loadScript("alpha beta")
        e.hold(for: 2) // paused: no-op
        #expect(!e.isHolding)
    }
}

@Suite struct RestartAndPauseReasonTests {
    @Test @MainActor func restartReturnsToTheTopAndPlays() {
        let e = PromptEngine()
        e.loadScript("one two three four five six seven eight")
        e.confirmRead(upTo: 40, allowBacktrack: true)
        #expect((e.currentWordIndex ?? 0) > 0)
        e.restart()
        #expect(e.currentWordIndex == 0)
        #expect(e.isPlaying)
        #expect(e.progress == 0)     // must not trigger auto-next
    }

    @Test @MainActor func restartDuringASoftStopCancelsIt() {
        let e = PromptEngine()
        e.loadScript("one two three four five")
        e.play()
        e.pause()
        #expect(e.isStopping)
        e.restart()
        #expect(!e.isStopping)
        #expect(e.isPlaying)
    }

    @Test @MainActor func restartCancelsATimedHold() {
        let e = PromptEngine()
        e.loadScript("one two three")
        e.play()
        e.hold(for: 5)
        e.restart()
        #expect(!e.isHolding)
        #expect(e.holdRemaining == nil)
    }

    @Test @MainActor func restartOnAnEmptyScriptIsSafe() {
        let e = PromptEngine()
        e.loadScript("")
        e.restart()
        #expect(!e.isPlaying)
    }

    @Test @MainActor func pauseReasonIsPublishedThenCleared() {
        let e = PromptEngine()
        e.loadScript("one two three")
        e.play()
        e.pause(reason: .smartPause)
        #expect(e.pauseReason == .smartPause)
        #expect(e.pauseReason?.label == "waiting for you")
        e.pause(reason: .cue)
        #expect(e.pauseReason?.label == "at cue")
        e.play()
        #expect(e.pauseReason == nil)
    }

    @Test @MainActor func aManualPauseHasNoReasonLabel() {
        // "Paused" alone is right for a pause the presenter pressed; the
        // label exists to explain the ones they didn't.
        #expect(PromptEngine.PauseReason.manual.label == nil)
    }

    @Test @MainActor func pausingAStoppedEngineKeepsItsReason() {
        let e = PromptEngine()
        e.loadScript("one two")
        e.pause(reason: .smartPause)   // never started
        #expect(e.pauseReason == nil)
    }
}

@Suite struct PromptEngineGlideTests {
    static let script = (1...40).map { "word\($0)" }.joined(separator: " ")

    @Test @MainActor func aConfirmationWalksRatherThanTeleports() {
        let e = PromptEngine()
        e.loadScript(Self.script)
        e.setSpeed(3.0)                       // 3 w/s reading → 4.2 w/s glide
        e.confirmReadThroughWord(10, glide: true)
        // Nothing has moved yet — the walk is driven per frame.
        #expect(e.currentWordIndex == 0)
        for _ in 0..<60 { e.glideStep(1.0 / 60.0) }
        #expect(e.currentWordIndex == 4)       // ~2.4 words, mid-glide
        for _ in 0..<90 { e.glideStep(1.0 / 60.0) }
        #expect(e.currentWordIndex == 10)
    }

    @Test @MainActor func theGlideIsPacedByTheReadingSpeed() {
        // A flat rate ignores the reader: pause for two seconds and the
        // marker races through the backlog. The walk has to run at roughly
        // the speed they are reading.
        let slow = PromptEngine()
        slow.loadScript(Self.script)
        slow.setSpeed(1.0)                     // 1 w/s → 1.4 w/s glide
        slow.confirmReadThroughWord(10, glide: true)
        for _ in 0..<60 { slow.glideStep(1.0 / 60.0) }
        #expect(slow.currentWordIndex == 1)

        let quick = PromptEngine()
        quick.loadScript(Self.script)
        quick.setSpeed(6.0)                    // clamped to a 6 w/s glide
        quick.confirmReadThroughWord(10, glide: true)
        for _ in 0..<60 { quick.glideStep(1.0 / 60.0) }
        #expect(quick.currentWordIndex! > slow.currentWordIndex!)
    }

    @Test @MainActor func aOneWordConfirmationIsImmediate() {
        let e = PromptEngine()
        e.loadScript(Self.script)
        e.confirmReadThroughWord(1, glide: true)
        #expect(e.currentWordIndex == 1)
    }

    @Test @MainActor func aJumpAbandonsAPendingGlide() {
        let e = PromptEngine()
        e.loadScript(Self.script)
        e.confirmReadThroughWord(20, glide: true)
        e.jumpTo(wordIndex: 2)
        for _ in 0..<200 { e.glideStep(1.0 / 60.0) }
        // A queued confirmation must never drag the highlight back.
        #expect(e.currentWordIndex == 2)
    }

    @Test @MainActor func glidingNeverRunsBackwards() {
        let e = PromptEngine()
        e.loadScript(Self.script)
        e.confirmReadThroughWord(10, glide: true)
        e.confirmReadThroughWord(4, glide: true)   // a worse alignment lands
        for _ in 0..<200 { e.glideStep(1.0 / 60.0) }
        #expect(e.currentWordIndex == 10)
    }
}
