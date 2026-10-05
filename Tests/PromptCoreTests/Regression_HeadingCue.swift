import Foundation
import Testing
@testable import PromptCore

/// The regression this whole change exists for, stated as the user sees it:
/// ⌥A on a script with a heading staged every cue one line too high.
@Suite struct RegressionHeadingCuePlacement {
    @Test func aStagedCueLandsBeforeItsSentenceNotInsideTheHeading() {
        let body = """
        # Rebuilding billing

        However, the engine could not settle an invoice in two seconds.

        ## Result

        It settled in four hundred milliseconds.
        """
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 0, in: body)
        #expect(out.contains("[pause 1s] However,"),
                Comment(rawValue: "cue is not before its sentence: \(out.debugDescription)"))
        #expect(!out.contains("billing [pause"), Comment(rawValue: "cue landed in the heading"))
        #expect(!out.contains("[pause 1s] #"), Comment(rawValue: "cue landed before the heading"))
    }

    @Test func aLaterCueIsAlsoPlacedCorrectly() throws {
        let body = "# One\n\nFirst line here.\n\n## Two\n\nSecond line here."
        let words = ScriptParser.words(body)
        // "Second" is the fourth word: both headings contribute none.
        let index = try! #require(words.firstIndex(of: "Second"))
        let out = CueInsertion.inserting(cue: "breath 1.5s", beforeWord: index, in: body)
        #expect(out.contains("[breath 1.5s] Second"),
                Comment(rawValue: "got \(out.debugDescription.debugDescription)"))
    }
}
