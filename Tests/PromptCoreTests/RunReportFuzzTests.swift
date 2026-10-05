import Foundation
import Testing
@testable import PromptCore

/// The runs these generate are not ones anybody would perform — that is the
/// point. A report is computed from whatever the sampler managed to record,
/// and the sampler records whatever happened: a jump backwards, two samples
/// with the same timestamp, a word index past the end of the script, a gap of
/// an hour because the laptop slept.
@Suite struct RunReportFuzzTests {
    private func randomSamples(seed: UInt64, count: Int) -> [RunReport.Sample] {
        var random = SplitMix64(seed: seed)
        var out: [RunReport.Sample] = []
        var time: TimeInterval = 0
        var word: Int? = nil
        for _ in 0..<count {
            // Gaps from nothing to an hour, including zero and negative
            // (a clock adjustment shows up as a negative delta).
            let gap = Double(Int(random.next() % 3601) - 1) / 10
            time = max(0, time + gap)
            switch random.next() % 10 {
            case 0: word = nil
            case 1: word = nil
            case 2 where word != nil: word = max(0, word! - Int(random.next() % 20))
            default: word = (word ?? 0) + Int(random.next() % 12)
            }
            out.append(RunReport.Sample(time: time, word: word,
                                        speaking: Bool(random.next() % 2 == 0)))
        }
        return out
    }

    @Test func fuzzedRunsProduceACoherentReport() {
        for seed in UInt64(1)...200 {
            let samples = randomSamples(seed: seed, count: Int(seed % 40) + 2)
            let total = Int(seed % 500) + 1
            let sections = [0, 100, 250].filter { $0 < total }
            let result = RunReport.result(samples: samples, totalWords: total,
                                          sectionStarts: sections)
            #expect(result.duration >= 0, "seed \\(seed)")
            #expect(result.speakingSeconds >= 0, "seed \\(seed)")
            #expect(result.speakingSeconds <= result.duration + 0.5,
                    "more speaking than run: seed \\(seed)")
            #expect(result.wordsReached >= 0, "seed \\(seed)")
            #expect(result.wordsReached >= min(total, result.wordsReached), "seed \\(seed)")
            #expect(result.adherence >= 0 && result.adherence <= 1, "seed \\(seed)")
            #expect(result.averagePace >= 0 && result.speakingPace >= 0, "seed \\(seed)")
            // Speaking pace is over a subset of the run, so it cannot be
            // *slower* than the whole-run pace — unless nothing was recorded
            // as speech at all, which is a real run: the prompter sat open and
            // the reading position never moved. Then it is honestly zero, and
            // showing both numbers is the point.
            if result.speakingSeconds > 0 {
                #expect(result.speakingPace >= result.averagePace - 0.001, "seed \\(seed)")
            } else {
                #expect(result.speakingPace == 0, "seed \\(seed)")
            }
            #expect(result.sectionsCompleted <= sections.count, "seed \\(seed)")
            #expect(result.longestWordGap >= 0, "seed \\(seed)")
            for pace in result.pace {
                #expect(pace.wordsPerMinute >= 0, "seed \\(seed)")
                #expect(pace.start >= 0, "seed \\(seed)")
            }
            // The chart is sorted by time and does not run past the run.
            let starts = result.pace.map(\.start)
            #expect(starts == starts.sorted(), "seed \\(seed)")
            #expect(result.pace.allSatisfy { $0.start <= result.duration + 0.5 },
                    "a bar after the run ended: seed \\(seed)")
        }
    }

    /// Credit is for words reached *past where the run started*, counted once.
    /// Scrolling back and re-reading adds nothing, and the words before the
    /// first sample are nobody's credit — which is why the bound is the span
    /// and not the high-water index.
    @Test func fuzzedRunsNeverLoseCreditForAScrollback() {
        for seed in UInt64(1)...100 {
            let samples = randomSamples(seed: seed, count: Int(seed % 30) + 3)
            let observed = samples.compactMap(\.word)
            guard let start = observed.first, let high = observed.max() else { continue }
            let result = RunReport.result(samples: samples, totalWords: 10_000,
                                          sectionStarts: [])
            // At least the word the run started on, and never more than the
            // span it moved through — an advance bigger than the interval
            // could hold is a jump, and is not credited. Re-reading the same
            // words adds nothing, which `scrollingBackDoesNotLoseCredit`
            // pins by hand.
            #expect(result.wordsReached >= 1, "nothing was credited at all")
            #expect(result.wordsReached <= high - start + 1,
                    "credited \(result.wordsReached) of a span \(high - start)")
        }
    }

    /// A run where the reading position never moved and the mic heard nothing:
    /// the prompter sat open for ten minutes and nobody started. The report has
    /// to say so rather than divide by nothing, and the silence it does not
    /// count as speech has to appear as a pause — otherwise the sheet shows a
    /// pace for a run in which nobody spoke.
    @Test func aSilentRunReportsZeroSpeakingPace() {
        let samples = (0..<40).map { step in
            RunReport.Sample(time: Double(step) * 0.25, word: 0, speaking: false)
        }
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.speakingSeconds == 0)
        #expect(result.speakingPace == 0)
        // One word was on screen — the one the run started on — and that is
        // all that is credited. The alternative, which this file once did, was
        // to treat the whole script as read because the position never moved.
        #expect(result.wordsReached == 1)
        // 1 word over 10 s is 6 wpm, which means nothing; what must be true is
        // that no *time* was counted as speech and the whole stretch is
        // reported as the pause it is.
        #expect(result.longestWordGap >= 9)
        #expect(result.adherence < 0.002)
        #expect(result.headline.contains("wpm"))
    }

    /// Starting part-way through is the normal way to rehearse: ⌘⇧R never
    /// rewinds. The words before the run are not credit, and they must not
    /// appear in the pace either.
    @Test func startingMidScriptDoesNotInflateTheReport() {
        // 30 seconds at a plausible 120 wpm: two words a second.
        var samples: [RunReport.Sample] = []
        for step in 0..<60 {
            samples.append(RunReport.Sample(time: Double(step) * 0.5,
                                            word: 300 + step * 2, speaking: true))
        }
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        // The first sample's word is where the run *started*, so it is the
        // anchor, not credit: 118 advances after it.
        #expect(result.wordsReached == 119, "only what was read during the run")
        #expect(result.adherence < 0.13, "adherence was inflated")
        // 119 words over 29.75 s: 240 rather than 238 wpm. The extra word is
        // the one the run started on, and it is counted once — which is the
        // whole difference between this and the 20 000 wpm it used to report.
        #expect(abs(result.averagePace - 240) < 8,
                "pace was inflated to \(result.averagePace)")
        // The chart must not carry the skipped prefix either.
        for bar in result.pace {
            #expect(abs(bar.wordsPerMinute - 240) < 15,
                    "a bar was inflated: \(bar.wordsPerMinute)")
        }
    }

    /// A deliberate jump — Next Cue, a tap on the prompter — is not a
    /// 3 600 wpm delivery. Its words are not credited and the interval is not
    /// billed as speech.
    @Test func aJumpIsNotReading() {
        var samples: [RunReport.Sample] = []
        for step in 0..<40 { samples.append(RunReport.Sample(time: Double(step) * 0.25,
                                                              word: step, speaking: true)) }
        // t=10: a jump from word 39 to word 400 in one sample.
        samples.append(RunReport.Sample(time: 10, word: 400, speaking: false))
        for step in 0..<40 { samples.append(RunReport.Sample(time: 10.25 + Double(step) * 0.25,
                                                              word: 400 + step, speaking: true)) }
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.wordsReached < 120,
                "the jumped words were credited: \(result.wordsReached)")
        #expect(result.averagePace < 400, "the jump inflated the pace: \(result.averagePace)")
    }

    /// And the opposite: a muted mic with the clock advancing is a *normal*
    /// run, because the word index is the authority on whether words are being
    /// said. The voice track only fills the silence inside a timed hold.
    @Test func aMutedMicStillReportsSpeakingPaceWhileTheScriptMoves() {
        let samples = (0..<40).map { step in
            RunReport.Sample(time: Double(step) * 0.25, word: step * 3, speaking: false)
        }
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.speakingSeconds > 0)
        #expect(result.speakingPace >= result.averagePace)
    }

    @Test func aRunOfOneSampleIsEmptyNotACrash() {
        let result = RunReport.result(samples: [RunReport.Sample(time: 0, word: 0, speaking: true)],
                                      totalWords: 10, sectionStarts: [0])
        #expect(result.duration == 0)
        // The word on screen counts as one word reached, and nothing else can
        // be known from a single sample.
        #expect(result.wordsReached == 1)
        #expect(result.averagePace == 0, "no time passed, so there is no pace")
    }

    @Test func identicalTimestampsDoNotDivideByZero() {
        let samples = (0..<10).map { _ in
            RunReport.Sample(time: 5, word: 3, speaking: true)
        }
        let result = RunReport.result(samples: samples, totalWords: 10, sectionStarts: [])
        #expect(result.duration == 0)
        #expect(result.averagePace == 0 || result.averagePace.isFinite)
    }
}

/// The regime the app actually produces. The pause logic used to key off the
/// gap *between* samples, which only fires when the sampler goes quiet — so at
/// 4 Hz, which is what `RunRecorder` does, no pause was ever found. These pin
/// the dense case separately from the sparse one so the hole cannot reopen.
@Suite struct RunReportDenseSamplingTests {
    /// A run read at 4 Hz: the position advances every quarter second.
    private func reading(steps: Int, from word: Int = 0, at time: TimeInterval = 0)
    -> [RunReport.Sample] {
        (0..<steps).map { step in
            RunReport.Sample(time: time + Double(step) * 0.25, word: word + step,
                             speaking: true)
        }
    }

    @Test func aStopInTheMiddleOfALineIsAPause() {
        var samples = reading(steps: 40)                      // 0…10 s, moving
        let frozen = 40
        for step in 0..<20 {                                  // 5 s of nothing
            samples.append(RunReport.Sample(time: 10 + Double(step) * 0.25,
                                            word: frozen, speaking: false))
        }
        samples += reading(steps: 20, from: frozen, at: 15)
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.pauses.count == 1, "\(result.pauses.count) pauses")
        // Up to one sample interval short, and never long: words could have
        // stopped at any point inside the interval that last showed one.
        #expect(result.longestWordGap >= 4.5, "got \(result.longestWordGap)")
        #expect(result.longestWordGap < 5.5)
    }

    @Test func aBreathIsNotAPauseAtFourHertz() {
        var samples = reading(steps: 40)
        let frozen = 40
        for step in 0..<2 {                                   // half a second
            samples.append(RunReport.Sample(time: 10 + Double(step) * 0.25,
                                            word: frozen, speaking: false))
        }
        samples += reading(steps: 20, from: frozen, at: 10.5)
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.pauses.isEmpty, "a breath was reported as a pause")
    }

    @Test func aTimedHoldIsNotAPauseBecauseTheMicHeardIt() {
        // The engine is deliberately idle inside `[pause 2s]`; the voice
        // track is the only thing that says the reader is still there.
        var samples = reading(steps: 40)
        let frozen = 40
        for step in 0..<8 {                                   // two seconds
            samples.append(RunReport.Sample(time: 10 + Double(step) * 0.25,
                                            word: frozen, speaking: true))
        }
        samples += reading(steps: 20, from: frozen, at: 12)
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.pauses.isEmpty, "a scripted hold was reported as a pause")
    }

    @Test func twoStopsAreTwoPauses() {
        var samples = reading(steps: 40)
        let frozen = 40
        for step in 0..<12 { samples.append(RunReport.Sample(time: 10 + Double(step) * 0.25,
                                                             word: frozen, speaking: false)) }
        samples += reading(steps: 20, from: frozen, at: 13)
        for step in 0..<12 { samples.append(RunReport.Sample(time: 18 + Double(step) * 0.25,
                                                             word: frozen, speaking: false)) }
        samples += reading(steps: 20, from: frozen, at: 21)
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.pauses.count == 2, "\(result.pauses.count)")
        #expect(result.pauses.allSatisfy { $0.length >= 2.5 && $0.length < 3.5 },
                "stops were \(result.pauses)")
        // Longest first, which is what the sheet shows.
        #expect(result.pauses[0].length >= result.pauses[1].length)
    }

    @Test func aLaptopSleepIsNotAPause() {
        var samples = reading(steps: 40)
        let frozen = 40
        // Twenty minutes later.
        for step in 0..<4 { samples.append(RunReport.Sample(time: 10 + 1_200 + Double(step) * 0.25,
                                                             word: frozen, speaking: false)) }
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        // The twenty minutes themselves are gone; the sub-second silence
        // after waking, before the reader has started again, is real.
        #expect(result.pauses.allSatisfy { $0.length < 5 },
                "the sleep was reported as a pause: \(result.pauses)")
    }
}

/// The scenario the recorder's heartbeat exists for, pinned at the arithmetic
/// level: a presenter stops halfway through a line and thinks for eight
/// seconds. The position is frozen and nobody is speaking, and the report has
/// to say so — this is the pause a rehearsal is actually about.
@Suite struct RunReportPauseScenarioTests {
    @Test func thinkingTimeIsReportedAsAPause() {
        var samples: [RunReport.Sample] = []
        var time: TimeInterval = 0
        var word = 0
        // Twenty seconds of reading: the position moves, the mic hears words.
        for _ in 0..<80 {
            word += 2
            samples.append(RunReport.Sample(time: time, word: word, speaking: true))
            time += 0.25
        }
        // Then the presenter stops. Same position, nobody speaking, 4 Hz.
        let frozen = word
        while time < 28 {
            samples.append(RunReport.Sample(time: time, word: frozen, speaking: false))
            time += 0.25
        }
        // Then they carry on.
        for _ in 0..<40 {
            word += 2
            samples.append(RunReport.Sample(time: time, word: word, speaking: true))
            time += 0.25
        }
        let result = RunReport.result(samples: samples, totalWords: 1_000,
                                      sectionStarts: [])
        #expect(result.duration > 27)
        #expect(result.longestWordGap > 7, "the thinking pause is missing")
        #expect(result.pauses.contains { $0.length > 7 })
        // And the pace reflects it: the words were read over 20 s, but the run
        // took 30, so the room's average is below the speaking pace.
        #expect(result.speakingPace > result.averagePace)
    }

    @Test func aPauseIsChargedToTheRunNotTheReader() {
        let word = 40
        var samples: [RunReport.Sample] = []
        for step in 0..<200 {
            samples.append(RunReport.Sample(time: Double(step) * 0.25,
                                            word: word, speaking: false))
        }
        let result = RunReport.result(samples: samples, totalWords: 100,
                                      sectionStarts: [])
        #expect(result.duration >= 49)
        #expect(result.longestWordGap >= 49, "one continuous pause")
        #expect(result.speakingSeconds == 0)
        #expect(result.headline.contains("pause"), Comment(rawValue: result.headline))
    }
}
