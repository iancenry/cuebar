import Foundation
import PromptCore

typealias CueTrigger = ReadingWindow.CueTrigger

/// What Cuebar does when the reading position crosses a cue that asks for
/// something beyond the prompter — a `[slide 4]` in the script.
///
/// Phase one is the plumbing: cues are parsed, the engine's plan says
/// exactly when a trigger fires (pure, tested arithmetic in `CuePlan`),
/// and the driver hands the batch here. Nothing in this file talks to
/// Keynote or PowerPoint, on purpose. Driving another app means an
/// Automation permission, a call that takes ~100ms, and a dictionary that
/// can change under us in a future release — the part that can't be tested
/// and can't be made reliable is the *reply*, not the request, and that is
/// exactly where the seam is.
///
/// So the prompter does not depend on any of it. A `[slide 4]` renders as
/// a badge and counts in the statistics whether or not a deck ever moves;
/// a presenter can rehearse against the badges with every driver switched
/// off, and a deck that fails to follow is visibly wrong rather than
/// silently so.
@MainActor
protocol SlideSyncing: AnyObject {
    /// `triggers` is in script order and may be a batch: a forward jump can
    /// cross several slide cues in one frame, and driving a deck to each in
    /// turn is both slow and wrong — only the furthest matters.
    func perform(_ triggers: [ReadingWindow.CueTrigger])
    /// Every slide cue crossed this run, in order. The deck-sync panel will
    /// read this to show how far through the slides the presenter actually
    /// got, and so to tell "I never reached slide 12" apart from "the deck
    /// never followed".
    var crossed: [CueTrigger] { get }
}

/// The shipped behaviour: record what was asked for, change nothing.
///
/// Not a stub for its own sake — `requested` is what the deck-sync UI will
/// report, and keeping the state here means adding a driver is adding one
/// type rather than touching the tick loop.
@MainActor
final class SlideSync: SlideSyncing {
    private(set) var crossed: [CueTrigger] = []

    /// Record what the script asked for. Nothing is sent anywhere yet —
    /// that is phase two, behind a permission the presenter grants and a
    /// dictionary we do not control.
    func perform(_ triggers: [CueTrigger]) {
        crossed.append(contentsOf: triggers)
    }
}
