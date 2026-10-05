import Testing
import Foundation
@testable import PromptCore

/// The Bold button used to do nothing a presenter could see.
///
/// `**` was stripped before the token reached a view and nothing said so
/// afterwards, so the file carried the mark and neither the editor nor the
/// prompter showed it. The flag is the fix, and these pin where it comes from:
/// the *same* function that decides what to strip.
@Suite struct EmphasisTokenTests {
    private func words(_ body: String) -> [(String, Bool)] {
        ScriptParser.parse(body).compactMap {
            if case .word(let text, let emphasised) = $0 { return (text, emphasised) }
            return nil
        }
    }

    @Test func markedWordsSaySoAndOthersDoNot() {
        let parsed = words("Say **this** loudly and that softly")
        #expect(parsed.map(\.0) == ["Say", "this", "loudly", "and", "that", "softly"])
        #expect(parsed.map(\.1) == [false, true, false, false, false, false])
    }

    /// Both markers count, and a word can only be one thing at a time.
    @Test func italicsAndUnderscoresCountToo() {
        #expect(words("a *word* here").map(\.1) == [false, true, false])
        #expect(words("***both*** ways").map(\.1) == [true, false])
        #expect(words("_under_score_ here").map(\.1) == [true, false])
    }

    /// The whole point of asking `spokenRange` rather than writing a rule: the
    /// cases that broke the tidy pass are the cases where a second rule
    /// disagrees with the stripper.
    @Test func arithmeticAndEmptyPairsAreNotEmphasis() {
        #expect(words("2*3*4 stays").map(\.1) == [false, false])
        // `****` is left exactly as written, so it stays a literal word rather
        // than becoming an empty one counted in the duration.
        #expect(words("**** alone").map(\.0) == ["****", "alone"])
        #expect(words("**** alone").map(\.1) == [false, false])
        #expect(words("un*closed").map(\.1) == [false])
    }

    /// Punctuation may follow the closing marker, or the marker is left on
    /// stage and the mark reads as a word.
    @Test func punctuationAfterTheMarkerStillCounts() {
        #expect(words("**quiet**.").map(\.0) == ["quiet"])
        #expect(words("**quiet**.").map(\.1) == [true])
    }

    /// The flag must not change a single spoken word, or the matcher and the
    /// duration would both be reading something else.
    @Test func theSpokenTextIsIdenticalEitherWay() {
        #expect(ScriptParser.words("Say **this** loudly") == ["Say", "this", "loudly"])
    }
}
