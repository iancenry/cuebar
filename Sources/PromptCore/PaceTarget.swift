import Foundation

/// Fit-to-time: how far the run is from landing on its target length.
///
/// Pure, because the one interesting question here — "am I ahead or behind"
/// — must be answered identically by the status pill on the Mac, the phone
/// remote, and any future reader, and three answers to one question is how
/// they drift apart.
///
/// The clock is *position-based*, on purpose. `ScriptTime` derives elapsed
/// time from the word index and the current rate, which is what the remote
/// already shows: a wall clock would keep counting through a pause and
/// report the presenter behind for thinking, which is the one thing a
/// teleprompter must never scold. The estimate moves when the pace or the
/// position moves, and says nothing about time the presenter spent silent.
public enum PaceTarget {
    /// Positive means behind schedule: more time has been spent reaching
    /// `word` than a level read at the target length would have spent.
    /// Nil when there is nothing to compare against — no target, no words,
    /// or an unreadable rate.
    public static func drift(elapsed: TimeInterval, word: Int, totalWords: Int,
                             targetSeconds: TimeInterval) -> TimeInterval? {
        guard targetSeconds > 0, totalWords > 0 else { return nil }
        let read = min(max(0, word), totalWords)
        let expected = targetSeconds * (Double(read) / Double(totalWords))
        return elapsed - expected
    }

    /// The same question from the live run's shape: where the highlight is,
    /// how many words there are, and how fast the engine is set to move.
    public static func drift(word: Int, totalWords: Int, wordsPerSecond: Double,
                             targetSeconds: TimeInterval) -> TimeInterval? {
        guard wordsPerSecond > 0 else { return nil }
        return drift(elapsed: ScriptTime.elapsed(word: word, wordsPerSecond: wordsPerSecond),
                     word: word, totalWords: totalWords, targetSeconds: targetSeconds)
    }

    /// "+1:05" behind, "-0:42" ahead — signed seconds, minutes:seconds.
    /// A pace readout is scanned, not read: the sign and the magnitude have
    /// to survive without any unit suffix.
    public static func format(_ drift: TimeInterval) -> String {
        let total = Int(abs(drift).rounded())
        return String(format: "%@%d:%02d", drift < 0 ? "-" : "+", total / 60, total % 60)
    }
}
