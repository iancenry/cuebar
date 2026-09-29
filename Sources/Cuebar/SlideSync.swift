import Foundation
import PromptCore

typealias CueTrigger = ReadingWindow.CueTrigger

/// What Cuebar does when the reading position crosses a cue that asks for
/// something beyond the prompter — a `[slide 4]` in the script.
///
/// A cue is a fact about the deck, so it drives the deck; everything else
/// here is bookkeeping. The arithmetic that decides what a bare `[slide]`
/// means lives in `SlidePosition` (PromptCore, tested), because it is
/// running state that has to survive a rewind, a jump, and a script edit —
/// and none of that belongs in a counter inside the tick loop.
///
/// **Owned by the app, not by the tick loop.** The driver fires cues, but
/// the phone's slide buttons and ⌥⇧→ move the same position, and two
/// objects each counting slides is how the prompter and the deck drift
/// apart. There is one instance and both write to it.
@MainActor
protocol SlideSyncing: AnyObject {
    /// Record what the script asked for and, if a deck is connected, move
    /// it. `triggers` is in script order and may be a batch: a forward jump
    /// can cross several slide cues in one frame, and driving a deck to each
    /// in turn is both slow and wrong — only the furthest matters.
    func perform(_ triggers: [ReadingWindow.CueTrigger])

    /// A button press, as opposed to a cue. Reports the slide moved to, or
    /// nil when the move was refused (already at the first slide).
    @discardableResult
    func step(_ delta: Int) -> Int?

    /// The slide the presenter is on, or nil when the script carries no
    /// slide cues at all — in which case the phone hides its stepper rather
    /// than showing "slide 1" for a script that never mentioned slides.
    var slide: Int? { get }

    /// Hand over a new script's cue plan. A new script is a new deck
    /// position: keeping the old one would leave the phone on "slide 7" for
    /// a talk that opens on its title slide.
    func load(_ plan: ReadingWindow.CuePlan)

    /// Attach (or detach) the deck to drive. Driven by the setting rather
    /// than per-tick, so the AppleScript object never sits on the hot path.
    func connect(_ driver: DeckDriving?)

    /// Every slide cue crossed this run, in order, so a panel can tell
    /// "I never reached slide 12" apart from "the deck never followed".
    var crossed: [CueTrigger] { get }
}

/// The shipped behaviour: hold the position, record what was asked for, and
/// hand it to a deck driver if one is connected.
@MainActor
final class SlideSync: SlideSyncing {
    private(set) var crossed: [CueTrigger] = []
    private var position = SlidePosition()
    private var driver: DeckDriving?

    /// True once a script with slide cues has been loaded. Until then the
    /// phone shows no stepper at all.
    private(set) var hasSlideCues = false

    var slide: Int? { hasSlideCues ? position.current : nil }

    /// Called when the script changes. A new script is a new deck
    /// position: keeping the old one would put the phone on "slide 7" for a
    /// talk that opens on its title slide.
    func load(_ plan: ReadingWindow.CuePlan) {
        position = SlidePosition(plan: plan)
        hasSlideCues = !plan.triggers.isEmpty
        crossed.removeAll()
    }

    func connect(_ driver: DeckDriving?) {
        self.driver = driver
    }

    /// Record what the script asked for, and move the deck to match.
    func perform(_ triggers: [ReadingWindow.CueTrigger]) {
        guard !triggers.isEmpty else { return }
        crossed.append(contentsOf: triggers)
        // Fold the whole batch through the position and move the deck once,
        // to where it ended up. Picking "the last absolute cue" instead
        // looks equivalent and isn't: a batch of `[goto 3]` then a bare
        // `[slide]` means slide 4, and searching for the last absolute would
        // leave the deck on 3 with no way to tell.
        for trigger in triggers { position.apply(trigger) }
        guard hasSlideCues else { return }
        driver?.go(to: position.current)
    }

    @discardableResult
    func step(_ delta: Int) -> Int? {
        guard hasSlideCues else { return nil }
        guard let moved = position.step(delta) else { return nil }
        driver?.go(to: moved)
        return moved
    }
}
