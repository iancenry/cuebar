import Foundation

/// What a run measured. The arithmetic for a rehearsal report, kept pure so
/// it can be tested against synthetic runs instead of being watched for.
///
/// Everything here is derived from two observations the app already has: how
/// far through the script the reader is, and whether they were speaking.
/// Nothing needs a camera or a transcript — a run that never asked for
/// either produces exactly the same report, which is why the metrics do not
/// live behind a permission prompt.
public enum RunReport {
    /// One observation. `time` is seconds since the run started; `word` is
    /// the word index the engine was on, `nil` before it starts; `speaking`
    /// is the voice track's opinion of whether words are being said.
    public struct Sample: Equatable, Sendable {
        public let time: TimeInterval
        public let word: Int?
        public let speaking: Bool

        public init(time: TimeInterval, word: Int?, speaking: Bool) {
            self.time = time
            self.word = word
            self.speaking = speaking
        }
    }

    public struct Pause: Equatable, Sendable {
        public let start: TimeInterval
        public let length: TimeInterval
    }

    /// One bar of the pace-over-time chart. Seconds, words, and the pace in
    /// that window — a presenter needs to see *where* they drifted, not just
    /// that they did.
    public struct Pace: Equatable, Sendable {
        public let start: TimeInterval
        public let wordsPerMinute: Double
    }

    public struct Result: Equatable, Sendable {
        public var duration: TimeInterval
        public var speakingSeconds: TimeInterval
        public var wordsReached: Int
        public var totalWords: Int
        /// How much of the script was reached, 0...1. Not a judgement about
        /// quality: a talk cut short by the chair is still 100% delivered up
        /// to where it stopped.
        public var adherence: Double
        /// Words per minute over the whole run, including pauses — the number
        /// a room actually experiences.
        public var averagePace: Double
        /// Words per minute while speaking. Compared with `averagePace`, the
        /// gap between them *is* the pausing.
        public var speakingPace: Double
        public var pauses: [Pause]
        public var sectionsCompleted: Int
        public var sectionTotal: Int
        public var pace: [Pace]
        public var longestWordGap: TimeInterval

        /// A single line for the presenter, honest about what it means.
        public var headline: String {
            let percent = Int((adherence * 100).rounded())
            let pace = Int(averagePace.rounded())
            return "\(percent)% of the script · \(pace) wpm · \(pauses.count) pause"
                + (pauses.count == 1 ? "" : "s")
        }

        public static func empty(totalWords: Int = 0, sectionTotal: Int = 0) -> Result {
            Result(duration: 0, speakingSeconds: 0, wordsReached: 0, totalWords: totalWords,
                   adherence: 0, averagePace: 0, speakingPace: 0, pauses: [],
                   sectionsCompleted: 0, sectionTotal: sectionTotal, pace: [],
                   longestWordGap: 0)
        }
    }

    /// A gap shorter than this is a breath, not a pause. Three-quarters of a
    /// second is the line the eye reads as "they stopped".
    ///
    /// A pause is measured from the last sample that *showed* words, so it can
    /// be up to one sample interval shorter than the truth and is never longer:
    /// words may have stopped at any point inside that interval, and the
    /// report claims the part it can see.
    public static let pauseThreshold: TimeInterval = 0.75

    /// One bar of the pace chart.
    public static let paceWindow: TimeInterval = 15

    /// A gap longer than this between samples is not a pause. It is a closed
    /// laptop, a system sleep, or somebody who walked away — and it is left
    /// out of the run's length entirely rather than counted as silence, or
    /// the average pace of a two-minute rehearsal reads as 6 wpm.
    public static let excludedGap: TimeInterval = 60

    /// Nobody says more than this many words a second. A forward jump larger
    /// than the elapsed time could physically allow is a *jump* — a Next Cue,
    /// a tap on the prompter — and its words were not read, so they are not
    /// credited and the interval is not billed as speech.
    public static let maxWordsPerSecond: Double = 6

    /// Build the report.
    ///
    /// One pass over the samples produces every number, from one series of
    /// "words newly credited during this interval". The first version grew a
    /// separate rule for each statistic and they disagreed: the pace chart
    /// counted words cumulatively while the report counted them once, the
    /// chart's trailing bar was the whole run divided by the tail, and a run
    /// that started part-way through a script counted every word before it as
    /// words reached. Deriving all of it from one series is the only way they
    /// stay consistent.
    ///
    /// `sectionStarts` is the word index of each section heading, ascending —
    /// `ScriptIndex.sections` already is. A section counts as reached once the
    /// reader got there.
    public static func result(samples: [Sample], totalWords: Int,
                              sectionStarts: [Int]) -> Result {
        guard let first = samples.first else {
            return .empty(totalWords: totalWords, sectionTotal: sectionStarts.count)
        }
        var wordsReached = 0
        /// The furthest word index seen. Position, not credit: a jump moves it
        /// without being read.
        var highWater: Int?
        /// Length of the run, with excluded gaps left out.
        var runSeconds: TimeInterval = 0
        var speakingSeconds: TimeInterval = 0
        var pauses: [Pause] = []
        /// When the current silence began.
        var openPauseStart: TimeInterval?
        /// When words were last credited — the anchor a pause is measured from.
        var lastProduction = first.time
        var lastAccepted = first.time
        var buckets: [Pace] = []
        var bucketStart = first.time
        var bucketWords = 0
        var bucketSeconds: TimeInterval = 0

        func closePause(at time: TimeInterval) {
            guard let start = openPauseStart else { return }
            let length = time - start
            if length >= Self.pauseThreshold {
                pauses.append(Pause(start: start - first.time, length: length))
            }
            openPauseStart = nil
        }

        /// One pace window. Emitted only if it has words in it: silence is the
        /// pauses list's job, and a stalled run would otherwise fill the chart
        /// with rows of zero.
        func closeBucket() {
            guard bucketWords > 0, bucketSeconds > 0 else {
                bucketStart += Self.paceWindow
                bucketWords = 0
                bucketSeconds = 0
                return
            }
            let minutes = bucketSeconds / 60
            buckets.append(Pace(start: bucketStart - first.time,
                                wordsPerMinute: minutes > 0
                                    ? Double(bucketWords) / minutes : 0))
            bucketStart += Self.paceWindow
            bucketWords = 0
            bucketSeconds = 0
        }

        for sample in samples {
            // A clock that steps backwards (NTP, a laptop lid) must not make
            // the run longer than it was, or the pace negative.
            guard sample.time >= lastAccepted else { continue }
            let gap = sample.time - lastAccepted
            lastAccepted = sample.time

            var credited = 0
            if let word = sample.word {
                if let reached = highWater {
                    if word > reached {
                        // Credit only what the interval could have held. A
                        // jump of 300 words across one sample is a cue, not a
                        // 3 600 wpm delivery.
                        let ceiling = max(1, Int((gap * Self.maxWordsPerSecond).rounded(.up)))
                        credited = min(word - reached, ceiling)
                        highWater = word
                    }
                } else {
                    // The first word seen is where the run started. It counts
                    // as one word read — the reader has it on screen — and it
                    // is the *anchor*: everything before it is somebody else's
                    // credit, so a section rehearsal cannot report 300 words of
                    // silence as progress. The last word of a clean run is
                    // therefore reachable, and a full read is 100%.
                    highWater = word
                    wordsReached = 1
                }
            }
            wordsReached += credited

            if gap > Self.excludedGap {
                // Not a pause and not part of the run: restart the silence
                // clock from here, and drop any silence that was open before
                // the break rather than reporting the break as one.
                openPauseStart = nil
                lastProduction = sample.time
                // The run's clock stops for a break, so the chart's does too:
                // advancing the bucket by the break would date a bar later
                // than the run it belongs to.
                bucketWords = 0
                bucketSeconds = 0
                continue
            }

            runSeconds += gap
            bucketSeconds += gap
            bucketWords += credited
            while bucketSeconds >= Self.paceWindow { closeBucket() }

            let produced = credited > 0 || sample.speaking
            if produced {
                if let start = openPauseStart {
                    // The silence runs from its anchor to the *start* of the
                    // interval in which words came back — the words may have
                    // resumed at any point inside it, so charging the whole
                    // interval to speech is how `speaking + pauses` came to
                    // exceed the run, and closing the pause at the anchor
                    // rather than at the resume is how a five-second pause
                    // measured zero.
                    // The silence can span several intervals, so it can be
                    // longer than the one that closes it; crediting that
                    // interval by `gap - silence` went *negative*. The pause
                    // carries the whole silence, and speech is credited only
                    // where speech is possible to have happened.
                    let resumedAt = sample.time - gap
                    let silencePortion = max(0, resumedAt - start)
                    speakingSeconds += max(0, gap - silencePortion)
                    closePause(at: resumedAt)
                } else {
                    speakingSeconds += gap
                }
                lastProduction = sample.time
            } else if openPauseStart == nil,
                      sample.time - lastProduction >= Self.pauseThreshold {
                openPauseStart = lastProduction
            }
        }

        closePause(at: lastAccepted)
        closeBucket()

        let adherence = totalWords > 0 ? min(1, Double(wordsReached) / Double(totalWords)) : 0
        let averagePace = runSeconds > 0 ? Double(wordsReached) / runSeconds * 60 : 0
        let speakingPace = speakingSeconds > 0 ? Double(wordsReached) / speakingSeconds * 60 : 0
        let completed = sectionStarts.filter { $0 <= (highWater ?? -1) }.count

        return Result(duration: runSeconds,
                      speakingSeconds: speakingSeconds,
                      wordsReached: wordsReached,
                      totalWords: totalWords,
                      adherence: adherence,
                      averagePace: averagePace,
                      speakingPace: speakingPace,
                      pauses: pauses.sorted { $0.length > $1.length },
                      sectionsCompleted: completed,
                      sectionTotal: sectionStarts.count,
                      pace: buckets,
                      longestWordGap: pauses.first?.length ?? 0)
    }

}
