import Foundation

/// What a remote needs to know about the run, and the arithmetic a scrub
/// needs to turn a finger position back into a word.
///
/// Pure and in PromptCore for the same reason the rest of the engine is:
/// the remote is a second input device, and its one interesting piece of
/// logic — where does this fraction of the script put the highlight — is
/// exactly the kind of thing that must be tested rather than reasoned
/// about. The transport that ships it is the app's problem, not this
/// type's.
public struct RemoteSnapshot: Equatable, Sendable, Codable {
    public var title: String
    public var isPlaying: Bool
    public var currentWord: Int
    public var totalWords: Int
    public var wordsPerMinute: Double
    /// Every section name, in order. Names only: the phone needs to count
    /// them and to name the one being read, and shipping word indices to a
    /// page would be a second description of the script for it to disagree
    /// with.
    public var sections: [String]
    /// Name of the section the highlight is inside, nil before the first
    /// heading — a script can open with words.
    public var currentSection: String?
    /// So the pager can grey out a button that has nowhere to go, instead
    /// of accepting the press and doing nothing.
    public var hasPreviousSection: Bool
    public var hasNextSection: Bool
    /// Follow mode and mic mute, so the phone can show which of the two
    /// recovery controls is currently in force. A presenter whose voice
    /// tracking has stopped is standing at a lectern that will not scroll;
    /// these are the two buttons that fix it without walking to the laptop,
    /// and a toggle that doesn't show its state is a coin toss.
    public var isFollowing: Bool
    public var isMicMuted: Bool
    /// The slide the deck is on, or nil when the script carries no slide
    /// cues. Nil rather than 1: "slide 1" on a script that never mentioned
    /// slides is a claim about a deck Cuebar has never seen.
    public var slide: Int?
    /// Seconds elapsed and remaining at the current reading speed.
    public var elapsed: TimeInterval
    public var remaining: TimeInterval

    public init(title: String, isPlaying: Bool, currentWord: Int, totalWords: Int,
                wordsPerMinute: Double, sections: [String],
                elapsed: TimeInterval, remaining: TimeInterval) {
        self.init(title: title, isPlaying: isPlaying, currentWord: currentWord,
                  totalWords: totalWords, wordsPerMinute: wordsPerMinute,
                  sections: sections, currentSection: nil,
                  hasPreviousSection: false, hasNextSection: false,
                  isFollowing: false, isMicMuted: false, slide: nil,
                  elapsed: elapsed, remaining: remaining)
    }

    public init(title: String, isPlaying: Bool, currentWord: Int, totalWords: Int,
                wordsPerMinute: Double, sections: [String], currentSection: String?,
                hasPreviousSection: Bool, hasNextSection: Bool,
                isFollowing: Bool, isMicMuted: Bool, slide: Int? = nil,
                elapsed: TimeInterval, remaining: TimeInterval) {
        self.title = title
        self.isPlaying = isPlaying
        self.currentWord = currentWord
        self.totalWords = totalWords
        self.wordsPerMinute = wordsPerMinute
        self.sections = sections
        self.currentSection = currentSection
        self.hasPreviousSection = hasPreviousSection
        self.hasNextSection = hasNextSection
        self.isFollowing = isFollowing
        self.isMicMuted = isMicMuted
        self.slide = slide
        self.elapsed = elapsed
        self.remaining = remaining
    }

    /// Built from the live run. `currentWord` is nil before the script is
    /// loaded, and a remote that has never seen a word should show zero
    /// rather than an error — the phone is not where the bug is.
    @MainActor
    public init(title: String, engine: PromptEngine, index: ScriptIndex,
                isFollowing: Bool = false, isMicMuted: Bool = false,
                slide: Int? = nil) {
        let here = engine.currentWordIndex ?? 0
        self.init(title: title,
                  isPlaying: engine.isPlaying,
                  currentWord: here,
                  totalWords: engine.words.count,
                  wordsPerMinute: engine.wordsPerSecond * 60,
                  sections: index.sections.map(\.name),
                  currentSection: index.sections.last { $0.wordIndex <= here }?.name,
                  hasPreviousSection: Self.sectionWordIndex(offset: -1, from: here,
                                                            in: index.sections) != nil,
                  hasNextSection: Self.sectionWordIndex(offset: 1, from: here,
                                                        in: index.sections) != nil,
                  isFollowing: isFollowing,
                  isMicMuted: isMicMuted,
                  slide: slide,
                  elapsed: ScriptTime.elapsed(word: here,
                                             wordsPerSecond: engine.wordsPerSecond),
                  remaining: ScriptTime.elapsed(
                      word: max(0, engine.words.count - here),
                      wordsPerSecond: engine.wordsPerSecond))
    }

    /// Word index of the next (`1`) or previous (`-1`) section, or nil at
    /// either end.
    ///
    /// **No wrap**, unlike the keyboard's cue navigation: a presenter who
    /// taps "next section" at the last one means "there is no next", and
    /// being thrown to the top of the script mid-talk is worse than a
    /// button that does nothing. The keyboard wraps because holding a
    /// modifier and pressing it twice is deliberate; a thumb is not.
    ///
    /// This is the only implementation — the snapshot's own
    /// `hasNextSection`/`hasPreviousSection` come from the same question, so
    /// a greyed-out button and the press it refuses can't disagree.
    public func wordIndexForSection(offset step: Int, in index: ScriptIndex) -> Int? {
        Self.sectionWordIndex(offset: step, from: currentWord, in: index.sections)
    }

    /// The section either side of the one the highlight is *inside*.
    ///
    /// Measured from the current section's own start, not from the word
    /// index: comparing word indices directly made "back section" from
    /// three words into section B return B's own first word, so the button
    /// was enabled and did nothing useful. Before the first heading there is
    /// no current section, and "back" genuinely has nowhere to go while
    /// "next" is the first one.
    static func sectionWordIndex(offset step: Int, from word: Int,
                                 in sections: [ScriptSection]) -> Int? {
        guard !sections.isEmpty else { return nil }
        let mine = sections.lastIndex { $0.wordIndex <= word }
        if step > 0 {
            let next = mine.map { sections.index(after: $0) } ?? sections.startIndex
            return next < sections.endIndex ? sections[next].wordIndex : nil
        }
        guard let mine, mine > sections.startIndex else { return nil }
        return sections[sections.index(before: mine)].wordIndex
    }

    public var progress: Double {
        guard totalWords > 0 else { return 0 }
        return min(1, Double(currentWord) / Double(totalWords))
    }

    /// A thumb on a slider, turned into a word.
    ///
    /// Clamped at both ends, because a remote is a 5-inch screen held in
    /// one hand: a fraction slightly outside 0…1 is a normal event, not a
    /// bug, and a remote that can jump past the end of the script is worse
    /// than one that ignores the nudge.
    public func wordIndex(forProgress fraction: Double) -> Int {
        guard totalWords > 0 else { return 0 }
        let clamped = min(1, max(0, fraction))
        return min(totalWords, Int((Double(totalWords) * clamped).rounded()))
    }
}

/// Seconds for `word` words at a given pace. Split out because both the
/// snapshot and the sidebar's own estimate need it, and two answers to
/// "how long is this" is how they drift apart.
public enum ScriptTime {
    public static func elapsed(word: Int, wordsPerSecond: Double) -> TimeInterval {
        guard word > 0, wordsPerSecond.isFinite, wordsPerSecond > 0 else { return 0 }
        return Double(word) / wordsPerSecond
    }
}

/// What a remote can ask for. `ShortcutAction` already names every
/// command the app has, so the remote has no vocabulary of its own to keep
/// in step — a new binding in Settings changes the phone's buttons too.
public enum RemoteCommand: Equatable, Sendable {
    case action(ShortcutAction)
    /// Jump to a fraction of the script.
    case scrub(Double)
    /// Next (`1`) or previous (`-1`) section.
    ///
    /// Not a `ShortcutAction`, on purpose: it needs no chord of its own,
    /// because it is a thing you press with a thumb rather than a key you
    /// memorise, and a remote-only command that claimed a binding would
    /// take one away from the keyboard for every user to serve the phone.
    /// It resolves against the section list, so it is a one-liner once the
    /// index is to hand.
    case sectionOffset(Int)
}
