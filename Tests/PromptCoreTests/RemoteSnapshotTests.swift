import Testing
import Foundation
@testable import PromptCore

@Suite struct RemoteSnapshotTests {
    @Test @MainActor func reportsTheRunAsThePhoneSeesIt() {
        let engine = PromptEngine()
        engine.loadScript("One two three four five six")
        engine.setSpeed(2.0)
        engine.confirmReadThroughWord(2)
        let index = ScriptIndex(tokens: ScriptParser.parse(
            "## A\nOne two\n## B\nthree four five six"))
        let snapshot = RemoteSnapshot(title: "Demo", engine: engine, index: index)
        #expect(snapshot.totalWords == 6)
        #expect(snapshot.currentWord == 2)
        #expect(snapshot.sections == ["A", "B"])
        // Word 2 is B's first word, so the pager is in B with A behind it
        // and nothing ahead — and the two booleans have to say exactly
        // that, or a greyed-out button and the press it refuses disagree.
        #expect(snapshot.currentSection == "B")
        #expect(snapshot.hasPreviousSection == true)
        #expect(snapshot.hasNextSection == false)
        #expect(snapshot.wordIndexForSection(offset: -1, in: index) == 0)
        #expect(snapshot.wordIndexForSection(offset: 1, in: index) == nil)
        #expect(snapshot.wordsPerMinute == 120)
        #expect(snapshot.elapsed == 1.0)
        #expect(snapshot.remaining == 2.0)
        #expect(abs(snapshot.progress - 1.0 / 3.0) < 0.0001)
    }

    @Test @MainActor func theSectionPagerDoesNotWrap() {
        // The keyboard's cue navigation wraps on purpose. A thumb must not:
        // "next" at the last section means there isn't one, and being thrown
        // to the top of the script mid-talk is the worse failure.
        let script = "## A\nOne two\n## B\nthree four"
        let index = ScriptIndex(tokens: ScriptParser.parse(script))
        let engine = PromptEngine()
        engine.loadScript(script)

        let atTop = RemoteSnapshot(title: "", engine: engine, index: index)
        #expect(atTop.currentSection == "A")
        #expect(atTop.wordIndexForSection(offset: -1, in: index) == nil)
        #expect(atTop.hasPreviousSection == false)
        #expect(atTop.hasNextSection == true)
        #expect(atTop.wordIndexForSection(offset: 1, in: index) == 2)

        // Word 3 is the last word of B: "back" must reach A, not B's own
        // first word, which is the bug this pins.
        engine.jumpTo(wordIndex: 3)
        let atEnd = RemoteSnapshot(title: "", engine: engine, index: index)
        #expect(atEnd.currentSection == "B")
        #expect(atEnd.hasNextSection == false)
        #expect(atEnd.wordIndexForSection(offset: 1, in: index) == nil)
        #expect(atEnd.wordIndexForSection(offset: -1, in: index) == 0)
    }

    @Test @MainActor func anEmptyOrUnloadedScriptDoesNotDivideByZero() {
        let engine = PromptEngine()
        let snapshot = RemoteSnapshot(title: "", engine: engine,
                                      index: ScriptIndex(tokens: []))
        #expect(snapshot.totalWords == 0)
        #expect(snapshot.progress == 0)
        #expect(snapshot.wordIndex(forProgress: 0.5) == 0)
        #expect(snapshot.elapsed == 0)
    }

    @Test func aScrubIsClampedAtBothEnds() {
        let snapshot = RemoteSnapshot(title: "", isPlaying: false, currentWord: 0,
                                      totalWords: 100, wordsPerMinute: 150,
                                      sections: [], elapsed: 0, remaining: 0)
        #expect(snapshot.wordIndex(forProgress: 0) == 0)
        #expect(snapshot.wordIndex(forProgress: 1) == 100)
        // A thumb on a 5-inch screen: out-of-range fractions are normal
        // events, and a remote that can jump past the end is worse.
        #expect(snapshot.wordIndex(forProgress: -0.4) == 0)
        #expect(snapshot.wordIndex(forProgress: 3.2) == 100)
        #expect(snapshot.wordIndex(forProgress: 0.5) == 50)
    }

    @Test func everyCommandTheRemoteCanSendAlreadyExists() {
        // The remote has no vocabulary of its own, so a rebind in Settings
        // changes the phone's buttons too. If this ever fails, a button on
        // the phone has drifted from a command the app no longer has.
        // Every button on the page, including the ones added for the
        // recovery cases. A name here that the app has lost would make a
        // button on the phone 400 for the rest of the talk.
        for name in ["playPause", "speedUp", "speedDown", "fineSpeedUp", "fineSpeedDown",
                     "nextCue", "previousCue", "restart", "toggleFollow",
                     "toggleMicrophone", "jumpForward", "jumpBack"] {
            #expect(ShortcutAction(rawValue: name) != nil, "\\(name) is not a command")
        }
    }
}
