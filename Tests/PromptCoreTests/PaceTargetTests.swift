import Testing
import Foundation
@testable import PromptCore

@Suite struct PaceTargetTests {
    // MARK: - Drift

    @Test func onPaceIsZero() {
        // Half the words read in half the target time.
        let d = PaceTarget.drift(elapsed: 300, word: 500, totalWords: 1000,
                                 targetSeconds: 600)
        #expect(d != nil)
        #expect(abs(d! - 0) < 0.001)
    }

    @Test func behindScheduleIsPositive() {
        // Two-thirds of the words read in the time the whole talk had.
        let d = PaceTarget.drift(elapsed: 600, word: 666, totalWords: 1000,
                                 targetSeconds: 600)
        #expect(d == 600 - 600 * 0.666)
    }

    @Test func aheadOfScheduleIsNegative() {
        let d = PaceTarget.drift(elapsed: 100, word: 500, totalWords: 1000,
                                 targetSeconds: 600)
        #expect(d == -200.0)
    }

    @Test func wordClampsToTheScript() {
        // A jump past the end cannot report an absurd deficit.
        let d = PaceTarget.drift(elapsed: 60, word: 5000, totalWords: 1000,
                                 targetSeconds: 600)
        #expect(d == -540.0)
    }

    @Test func negativeWordReadsAsTheStart() {
        let d = PaceTarget.drift(elapsed: 60, word: -3, totalWords: 1000,
                                 targetSeconds: 600)
        #expect(d == 60.0)
    }

    @Test func noWordsMeansNoAnswer() {
        #expect(PaceTarget.drift(elapsed: 0, word: 0, totalWords: 0,
                                 targetSeconds: 600) == nil)
    }

    @Test func noTargetMeansNoAnswer() {
        #expect(PaceTarget.drift(elapsed: 0, word: 0, totalWords: 1000,
                                 targetSeconds: 0) == nil)
        #expect(PaceTarget.drift(elapsed: 0, word: 0, totalWords: 1000,
                                 targetSeconds: -5) == nil)
    }

    @Test func deadEngineMeansNoAnswer() {
        // wordsPerSecond is clamped > 0 in the engine, but the arithmetic
        // must not divide by zero if a caller is less careful.
        #expect(PaceTarget.drift(word: 10, totalWords: 100, wordsPerSecond: 0,
                                 targetSeconds: 600) == nil)
    }

    @Test func liveRunShapeAgreesWithRawShape() {
        // The two entry points are one question: the same run through both
        // must land on the same number, or the pill and a raw computation
        // would disagree mid-talk.
        let word = 300, total = 900
        let wps = 2.5, target = 420.0
        let raw = PaceTarget.drift(elapsed: ScriptTime.elapsed(word: word, wordsPerSecond: wps),
                                   word: word, totalWords: total, targetSeconds: target)
        let live = PaceTarget.drift(word: word, totalWords: total,
                                    wordsPerSecond: wps, targetSeconds: target)
        #expect(raw == live)
    }

    // MARK: - Format

    @Test func formatSignsAndFields() {
        #expect(PaceTarget.format(0) == "+0:00")
        #expect(PaceTarget.format(65) == "+1:05")
        #expect(PaceTarget.format(-42) == "-0:42")
        #expect(PaceTarget.format(3600) == "+60:00")
        #expect(PaceTarget.format(-0.4) == "-0:00")
    }
}
