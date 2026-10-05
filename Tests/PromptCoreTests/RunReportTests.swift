import Foundation
import Testing
@testable import PromptCore

@Suite struct RunReportTests {
    /// A clean 150 wpm run: 250 words over 100 seconds, all of it speaking.
    /// A run at a fixed pace: `words` reached by `seconds`, sampled `step`
    /// apart. The word index advances on the schedule rather than one per
    /// sample — otherwise "250 words in 100 seconds" is really 400 words and
    /// every pace assertion is measuring the sampler.
    private func steadyRun(words: Int = 250, seconds: TimeInterval = 100,
                           step: TimeInterval = 0.25) -> [RunReport.Sample] {
        let perSecond = Double(words) / seconds
        var samples: [RunReport.Sample] = []
        var t: TimeInterval = 0
        while t <= seconds {
            samples.append(RunReport.Sample(time: t,
                                            // An *index*: on the last
                                            // sample the reader is on the
                                            // final word, not one past it.
                                            word: min(max(0, words - 1),
                                                      Int(t * perSecond)),
                                            speaking: true))
            t += step
        }
        return samples
    }

    @Test func adherenceAndPaceOfACleanRun() {
        let result = RunReport.result(samples: steadyRun(words: 250, seconds: 100),
                                      totalWords: 250, sectionStarts: [0, 100, 200])
        #expect(result.adherence == 1.0)
        #expect(abs(result.averagePace - 150) < 2)
        #expect(result.sectionsCompleted == 3)
        #expect(result.sectionTotal == 3)
        #expect(result.pauses.isEmpty, "a run with no silence has no pauses")
    }

    @Test func aPartReadRunReportsThePartItGotThrough() {
        let result = RunReport.result(samples: steadyRun(words: 250, seconds: 100),
                                      totalWords: 500, sectionStarts: [0, 250, 400])
        #expect(abs(result.adherence - 0.5) < 0.01)
        #expect(result.sectionsCompleted == 1, "the second section starts at 250")
        #expect(result.sectionTotal == 3)
    }

    @Test func scrollingBackDoesNotLoseCredit() {
        var samples = steadyRun(words: 200, seconds: 80)
        // Somebody jumps back and re-reads a line, then carries on past the
        // point they had reached.
        samples.append(RunReport.Sample(time: 81, word: 120, speaking: true))
        samples.append(RunReport.Sample(time: 81.25, word: 121, speaking: true))
        samples.append(RunReport.Sample(time: 81.5, word: 190, speaking: true))
        samples.append(RunReport.Sample(time: 81.75, word: 205, speaking: true))
        let result = RunReport.result(samples: samples, totalWords: 200, sectionStarts: [])
        // The word the run started on counts once; the jump past the old
        // high-water mark counts as words reached; re-reading the same words
        // counts for nothing.
        #expect(result.wordsReached == 202, "the high-water mark is what counts")
        #expect(result.adherence > 0.99, "200 words of script, read past the end")
    }

    @Test func silenceBecomesAPause() {
        var samples = steadyRun(words: 100, seconds: 40)
        let here = samples[samples.count - 1].word ?? 0  // last word index
        // Three seconds of nothing, then the next word.
        samples.append(RunReport.Sample(time: 41, word: here, speaking: false))
        samples.append(RunReport.Sample(time: 42, word: here, speaking: false))
        samples.append(RunReport.Sample(time: 43, word: here, speaking: false))
        samples.append(RunReport.Sample(time: 43.25, word: here + 1, speaking: true))
        let result = RunReport.result(samples: samples, totalWords: 200, sectionStarts: [])
        #expect(result.pauses.count == 1)
        #expect(result.pauses[0].length >= 3.0, "silence from 40 to 43.25")
        #expect(result.longestWordGap >= 3.0)
        // Speaking pace stays at full speed; average pace drops. The gap
        // between the two numbers *is* the pausing, which is the point.
        #expect(result.speakingPace > result.averagePace)
    }

    @Test func aBreathIsNotAPause() {
        var samples = steadyRun(words: 100, seconds: 40)
        let here = samples[samples.count - 1].word ?? 0  // last word index
        samples.append(RunReport.Sample(time: 40.5, word: here, speaking: false))
        samples.append(RunReport.Sample(time: 41, word: here + 1, speaking: true))
        let result = RunReport.result(samples: samples, totalWords: 200, sectionStarts: [])
        #expect(result.pauses.isEmpty, "half a second is a breath")
    }

    @Test func aCoffeeBreakIsNotAPause() {
        var samples = steadyRun(words: 100, seconds: 40)
        let here = samples[samples.count - 1].word ?? 0  // last word index
        samples.append(RunReport.Sample(time: 41, word: here, speaking: false))
        samples.append(RunReport.Sample(time: 120, word: here, speaking: false))
        samples.append(RunReport.Sample(time: 121, word: here + 1, speaking: true))
        let result = RunReport.result(samples: samples, totalWords: 200, sectionStarts: [])
        #expect(result.pauses.isEmpty, "a minute off is not a pause")
    }

    @Test func anEmptyRunIsNotADivisionByZero() {
        for samples in [[], [RunReport.Sample(time: 0, word: nil, speaking: false)],
                         [RunReport.Sample(time: 3, word: nil, speaking: false)]] {
            let result = RunReport.result(samples: samples, totalWords: 10,
                                          sectionStarts: [0])
            #expect(result.adherence == 0)
            #expect(result.averagePace.isFinite)
            #expect(result.duration == 0)
        }
    }

    @Test func sectionsCountedFromTheirWordStarts() {
        let result = RunReport.result(samples: steadyRun(words: 120, seconds: 48),
                                      totalWords: 600, sectionStarts: [0, 40, 200, 400])
        #expect(result.sectionsCompleted == 2)
        #expect(result.sectionTotal == 4)
    }

    @Test func paceBucketsAppearAndGrow() {
        // 300 words over 75 seconds, in 15s windows: four bars.
        let result = RunReport.result(samples: steadyRun(words: 300, seconds: 75),
                                      totalWords: 300, sectionStarts: [])
        #expect(result.pace.count >= 3)
        for bar in result.pace {
            #expect(bar.wordsPerMinute.isFinite)
            #expect(bar.start >= 0)
        }
        #expect(result.pace.first?.wordsPerMinute ?? 0 > 0)
    }

    @Test func theHeadlineReadsLikeAResultCard() {
        let result = RunReport.result(samples: steadyRun(words: 250, seconds: 100),
                                      totalWords: 250, sectionStarts: [])
        #expect(result.headline.contains("100%"))
        #expect(result.headline.contains("wpm"))
    }

    @Test func fuzzedRunsNeverGoNegativeOrInfinite() {
        var random = SplitMix64(seed: 11)
        for _ in 0..<300 {
            let count = Int(random.next() % 60) + 1
            var samples: [RunReport.Sample] = []
            var t: TimeInterval = 0
            var word = 0
            for _ in 0..<count {
                // Wild steps: a sample 40 seconds later, no progress, noise.
                t += Double(random.next() % 3000) / 100
                if random.next() % 3 == 0 { word += Int(random.next() % 5) }
                if random.next() % 4 == 0 { word = max(0, word - Int(random.next() % 3)) }
                samples.append(RunReport.Sample(
                    time: t, word: random.next() % 5 == 0 ? nil : word,
                    speaking: random.next() % 2 == 0))
            }
            let total = Int(random.next() % 500)
            let sections = (0..<Int(random.next() % 6)).map { Int($0 * 40) }
            let result = RunReport.result(samples: samples, totalWords: total,
                                          sectionStarts: sections)
            #expect(result.duration >= 0)
            #expect(result.speakingSeconds >= 0 && result.speakingSeconds <= result.duration + 1)
            #expect(result.adherence >= 0 && result.adherence <= 1)
            #expect(result.averagePace.isFinite && result.speakingPace.isFinite)
            #expect(result.wordsReached >= 0 && result.wordsReached <= max(total, result.wordsReached))
            #expect(result.sectionsCompleted <= result.sectionTotal)
            #expect(result.pauses.count <= samples.count)
            for bar in result.pace { #expect(bar.wordsPerMinute.isFinite && bar.wordsPerMinute >= 0) }
        }
    }
}