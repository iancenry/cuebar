import Testing
import Foundation
@testable import PromptCore

/// The bare `[slide]` cue is the form people actually write, and what it
/// means depends entirely on a running total that lives nowhere in the
/// script. That is why this is a type with tests rather than a counter.
///
/// These go through `ScriptIndex` rather than a hand-built `CuePlan`,
/// because that is the only way the plan is ever built — a plan assembled in
/// a test would pass while the script that produces it did not.
@Suite struct SlidePositionTests {
    private func plan(_ script: String) -> ReadingWindow.CuePlan {
        ScriptIndex(tokens: ScriptParser.parse(script)).cuePlan
    }

    private func position(_ script: String) -> SlidePosition {
        SlidePosition(plan: plan(script))
    }

    @Test func startsOnTheFirstSlide() {
        // Zero is not a slide, and "not started yet" is the title slide.
        #expect(SlidePosition().current == 1)
        #expect(SlidePosition(current: 0).current == 1)
        #expect(SlidePosition(current: -4).current == 1)
    }

    @Test func aBareCueAdvances() {
        var position = position("[slide]\nOne two")
        #expect(position.ceiling == nil)
        #expect(position.apply(.advance) == 2)
        #expect(position.current == 2)
    }

    @Test func consecutiveBareCuesCountUp() {
        let script = "[slide]\nOne\n[slide]\ntwo\n[slide]\nthree"
        var position = position(script)
        #expect(position.apply(.advance) == 2)
        #expect(position.apply(.advance) == 3)
        #expect(position.apply(.advance) == 4)
        // …and the plan really does carry three triggers, so the test isn't
        // passing because the script failed to parse.
        #expect(plan(script).slideCueCount == 3)
    }

    @Test func anAbsoluteCueWinsOverTheRunningTotal() {
        var position = position("[slide]\nOne\n[slide 12]\ntwo")
        #expect(position.ceiling == 12)
        #expect(position.apply(.advance) == 2)
        // A late jump to a specific slide — rehearsing a change, or coming
        // back to a section.
        #expect(position.apply(.goto(12)) == 12)
        // …and the next bare cue continues from *there* — 13, not clamped
        // back to 12, which would re-show the same slide and look like a
        // dead deck.
        #expect(position.apply(.advance) == 13)
        #expect(position.ceiling == 13, "the ceiling rises with the script")
    }

    @Test func theCeilingIsTheHighestSlideTheScriptNames() {
        #expect(position("[slide 3]\nOne\n[slide 8]\nTwo").ceiling == 8)
    }

    @Test func steppingIsClampedByTheCeilingWhenTheScriptNamesOne() {
        var position = position("[slide 3]\nOne two three")
        // A thumb pressing "next" repeatedly must not run off the end of a
        // deck the script has said is three slides long.
        #expect(position.step(1) == 2)
        #expect(position.step(1) == 3)
        #expect(position.step(1) == nil, "already at the ceiling: stay put")
        #expect(position.current == 3)
    }

    @Test func steppingBackStopsAtTheFirstSlide() {
        var position = position("[slide 5]\nOne two three")
        // Already on slide 1, so "back" is refused — nil, meaning "do
        // nothing" — rather than "go to the slide you are already on".
        #expect(position.step(-1) == nil)
        #expect(position.current == 1)
        position.apply(.goto(5))
        // One slide at a time, all the way down, and then it stops.
        #expect(position.step(-1) == 4)
        #expect(position.step(-1) == 3)
        #expect(position.step(-1) == 2)
        #expect(position.step(-1) == 1)
        #expect(position.step(-1) == nil)
        #expect(position.current == 1)
    }

    @Test func aScriptThatNamesNoSlidesHasNoCeiling() {
        // Bare cues in a script that never says "slide 7" tell us nothing
        // about the deck's length, so the tenth tap is allowed.
        var position = position("[slide]\nOne\n[slide]\nTwo")
        #expect(position.ceiling == nil)
        for _ in 0..<9 { position.step(1) }
        #expect(position.current == 10)
    }

    @Test func aNonsenseCeilingIsIgnoredRatherThanTrusted() {
        #expect(SlidePosition(ceiling: 0).ceiling == nil)
        #expect(SlidePosition(ceiling: -2).ceiling == nil)
    }

    @Test func aBatchOfCuesLandsOnTheLastOne() {
        // A forward jump can cross several slide cues at once, and driving
        // a deck to each in turn is both slow and wrong: the furthest wins.
        let script = "[slide]\nOne\n[slide]\ntwo\n[slide 7]\nthree"
        var position = position(script)
        for trigger in [ReadingWindow.CueTrigger.advance, .advance, .goto(7)] {
            position.apply(trigger)
        }
        #expect(position.current == 7)
    }
}
