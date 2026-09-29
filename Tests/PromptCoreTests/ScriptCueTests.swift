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
