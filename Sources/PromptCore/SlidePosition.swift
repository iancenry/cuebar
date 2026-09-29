import Foundation

/// Which slide of the deck the presenter is on.
///
/// A bare `[slide]` means "the next one", which is meaningless on its own —
/// it is only the next one *relative to somewhere*. That somewhere is
/// running state, not script state: the same script re-read from the top
/// has to start over, and a jump backwards has to rewind. So it is a value
/// the app threads through rather than a counter buried in a view, and it
/// is pure so "what does the third bare cue in a row mean" has an answer
/// that can be tested instead of reasoned about.
public struct SlidePosition: Equatable, Sendable {
    /// The slide currently showing. Always ≥ 1; decks are 1-based and a
    /// presenter who has not started is on the title slide, not on zero.
    public private(set) var current: Int

    /// Where manual slide buttons stop.
    ///
    /// The furthest slide the *script* names — or nil when it names none,
    /// because a script of bare `[slide]` cues says nothing about how long
    /// the deck is. It is a *lower* bound on the deck, not an upper one, so
    /// it stops a thumb and nothing else: a cue that goes past it raises it
    /// rather than being clamped (see `apply`).
    public private(set) var ceiling: Int?

    public init(current: Int = 1, ceiling: Int? = nil) {
        self.ceiling = ceiling.flatMap { $0 >= 1 ? $0 : nil }
        self.current = min(max(1, current), max(1, self.ceiling ?? current))
    }

    /// Built from a cue plan: the ceiling is the highest absolute target
    /// the script contains, if it contains any.
    public init(plan: ReadingWindow.CuePlan) {
        self.init(ceiling: plan.slideNumbers.last)
    }

    /// Apply a cue as the reading position crosses it. Returns the slide to
    /// show, or nil when the cue asks for a move that cannot be made.
    ///
    /// **Cues are never clamped to the ceiling.** A script that says
    /// `[slide 12]` and then a bare `[slide]` is asking for 13; clamping
    /// would re-show 12 and look like the deck had simply stopped
    /// responding, which is the failure that gets mistaken for a broken
    /// app. The ceiling rises to match instead, because the script naming
    /// slide 12 was only ever a lower bound on the deck.
    @discardableResult
    public mutating func apply(_ trigger: ReadingWindow.CueTrigger) -> Int? {
        switch trigger {
        case .advance:
            current = max(1, current + 1)
        case .goto(let number):
            current = max(1, number)
        }
        ceiling = max(ceiling ?? 1, current)
        return current
    }

    /// Move by hand — the remote's slide buttons. Clamped, and reports nil
    /// when the move was refused: a presenter who taps "back" on slide 1
    /// wants to stay put, not to be sent to a deck's end screen, and a nil
    /// here means "do nothing" rather than "go to the slide you are
    /// already on".
    @discardableResult
    public mutating func step(_ delta: Int) -> Int? {
        let next = current + delta
        let clamped = min(max(1, next), max(1, ceiling ?? next))
        guard clamped == next else { return nil }
        current = next
        return current
    }
}
