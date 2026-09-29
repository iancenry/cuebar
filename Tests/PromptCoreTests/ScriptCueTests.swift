import Testing
import PromptCore

@Suite struct ScriptCueTests {
    @Test func kindAndDurationParsing() {
        #expect(ScriptCue.interpret("[pause 2s]").kind == .pause)
        #expect(ScriptCue.interpret("[pause 2s]").seconds == 2)
        #expect(ScriptCue.interpret("[PAUSE 2S]").seconds == 2) // case-insensitive
        #expect(ScriptCue.interpret("[hold 500ms]").kind == .hold)
        #expect(ScriptCue.interpret("[hold 500ms]").seconds == 0.5)
        #expect(ScriptCue.interpret("[breath 1.5]").kind == .breath)
        #expect(ScriptCue.interpret("[breath 1.5]").seconds == 1.5)
        #expect(ScriptCue.interpret("[wait 3 sec]").seconds == 3)
    }

    @Test func bareTimingCuesHaveNoDuration() {
        #expect(ScriptCue.interpret("[pause]").seconds == nil)
        #expect(ScriptCue.interpret("[pause]").kind == .pause)
        #expect(ScriptCue.interpret("[hold]").kind == .hold)
    }

    @Test func directionKinds() {
        #expect(ScriptCue.interpret("[smile]").kind == .smile)
        #expect(ScriptCue.interpret("[look left]").kind == .look)
        #expect(ScriptCue.interpret("[EMPHASIS]").kind == .emphasis)
        #expect(ScriptCue.interpret("[demo]").kind == .demo)
        #expect(ScriptCue.interpret("[drink]").kind == .drink)
        #expect(ScriptCue.interpret("[slide 4]").kind == .slide)
        #expect(ScriptCue.interpret("[slide 4]").seconds == nil) // non-timing: no duration parse
        #expect(ScriptCue.interpret("[nervous laughter]").kind == .other)
    }

    @Test func labelStripsBrackets() {
        #expect(ScriptCue.interpret("[pause 2s]").label == "pause 2s")
        #expect(ScriptCue.interpret("[smile]").label == "smile")
    }

    /// A case whose rawValue didn't match its name would silently degrade to
    /// `.other` — the cue would render as an unrecognized tag and, worse, stop
    /// being executable.
    @Test func everyKindRoundTripsFromItsRawValue() {
        for kind in ScriptCue.Kind.allCases {
            #expect(ScriptCue.interpret("[\(kind.rawValue)]").kind == kind)
        }
    }

    @Test func garbageDurationsAreIgnored() {
        #expect(ScriptCue.interpret("[pause banana]").seconds == nil)
        #expect(ScriptCue.interpret("[pause 0]").seconds == nil)
        #expect(ScriptCue.interpret("[pause -2]").seconds == nil)
    }
}

@Suite struct ScriptCueLimitTests {
    /// The doc comment promises an hour. Every suffix has to honour it —
    /// only the bare-number branch used to.
    @Test func durationIsCappedAtAnHour() {
        #expect(ScriptCue.interpret("[pause 5000s]").seconds == nil)
        #expect(ScriptCue.interpret("[pause 4000]").seconds == nil)
        #expect(ScriptCue.interpret("[hold 9000ms]").seconds == 9)   // under the cap
        #expect(ScriptCue.interpret("[hold 4000000ms]").seconds == nil)
        #expect(ScriptCue.interpret("[pause 3600]").seconds == 3600)
    }

    @Test func everyKindHasAGlyph() {
        for kind in ScriptCue.Kind.allCases {
            #expect(!ScriptCue.iconName(for: "[\(kind.rawValue)]").isEmpty)
        }
        #expect(ScriptCue.iconName(for: "[pause 2s]") == "pause.fill")
        #expect(ScriptCue.iconName(for: "[whatever]") == "tag")
    }
}

@Suite struct SlideCueTests {
    @Test func aSlideNumberIsParsedOnlyFromARealOne() {
        #expect(ScriptCue.interpret("[slide 4]").slideNumber == 4)
        #expect(ScriptCue.interpret("[SLIDE 12]").slideNumber == 12)
        // A bare direction, and a zero, are both "no slide" — a deck must
        // never be sent to slide 0 because someone typed it.
        #expect(ScriptCue.interpret("[slide]").slideNumber == nil)
        #expect(ScriptCue.interpret("[slide next]").slideNumber == nil)
        #expect(ScriptCue.interpret("[slide 0]").slideNumber == nil)
        #expect(ScriptCue.interpret("[smile]").slideNumber == nil)
        #expect(ScriptCue.interpret("[pause 2s]").slideNumber == nil)
    }

    @Test func aBareSlideCueAdvancesRatherThanDoingNothing() {
        // The whole point: `[slide]` is what people type, and a bare slide
        // cue that quietly rendered like any other direction was a trap —
        // it looked like it worked and did nothing.
        let index = ScriptIndex(tokens: ScriptParser.parse("Welcome. [slide] Next. [slide 4]"))
        #expect(index.cuePlan.slideCueCount == 2)
        #expect(index.cuePlan.triggers[1] == .advance)
        #expect(index.cuePlan.slideNumbers == [4])
    }

    @Test func slideCuesBecomeTriggersAtTheWordTheyIntroduce() {
        let index = ScriptIndex(tokens: ScriptParser.parse("""
        Welcome to the show. [slide 2]

        Now the problem. [slide 3]
        """))
        let plan = index.cuePlan
        #expect(plan.slideNumbers == [2, 3])
        // "Welcome to the show." is words 0-3, so `[slide 2]` belongs to
        // word 4 — the first word of the next paragraph. The change is
        // keyed to the words *under* it, which is what makes it fire as the
        // reader arrives rather than as they leave.
        #expect(plan.triggers[4] == .goto(2))
        #expect(plan.triggers[0] == nil)
        // The last cue has no word under it, and is keyed to the end —
        // the same place a trailing hold would go.
        #expect(plan.triggers[index.wordCount] == .goto(3))
    }

    @Test func triggersAreReportedForTheStrokesThatCrossedThem() {
        let index = ScriptIndex(tokens: ScriptParser.parse("a b [slide 2] c d e [slide 5] f"))
        let plan = index.cuePlan
        // Crossed exactly.
        #expect(plan.triggers(from: -1, to: 2) == [.goto(2)])
        #expect(plan.triggers(from: 0, to: 5) == [.goto(2), .goto(5)])
        // A backwards jump re-arms nothing, and a jump that doesn't move
        // reports nothing.
        #expect(plan.triggers(from: 5, to: 2) == [])
        #expect(plan.triggers(from: 3, to: 3) == [])
        // A forward jump past two cues reports both, in script order, so
        // the deck can be corrected to where the reader actually is.
        #expect(plan.triggers(from: 1, to: 6) == [.goto(2), .goto(5)])
    }
}

@Suite struct SlideCueCountTests {
    @Test func everySlideCueIsCountedEvenWhenTheyShareAWord() {
        // The bug this pins: `triggers` is keyed by word position, so two
        // slide cues in a script with no words collide at word 0. Counting
        // the dictionary reported "1 slide" for two cues.
        let index = ScriptIndex(tokens: ScriptParser.parse("[slide]\n[slide]\n[slide 4]"))
        #expect(index.cuePlan.slideCueCount == 3)
        #expect(index.cuePlan.triggers.count == 1)
    }

    @Test func slideCuesUnderWordsAreCountedOnceEach() {
        let index = ScriptIndex(tokens: ScriptParser.parse("a b [slide] c d [slide 2] e"))
        #expect(index.cuePlan.slideCueCount == 2)
        #expect(index.cuePlan.triggers[2] == .advance)
        #expect(index.cuePlan.triggers[4] == .goto(2))
    }
}
