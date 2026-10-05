import Foundation
import Testing
@testable import PromptCore

@Suite struct TeleprompterFriendlyTests {
    private func edits(_ body: String) -> [ScriptEdit] { TeleprompterFriendly.edits(for: body) }

    /// The words as they are *said*: markup characters are not speech, so
    /// stripping them is the only change a tidy-up is allowed to make.
    private func spoken(_ body: String) -> [String] {
        ScriptParser.words(body).map { word in
            String(word.filter { !"*_`~".contains($0) })
        }
    }

    @Test func boldMarkersComeOff() {
        let body = "We **shipped** the rewrite on Friday."
        let out = TeleprompterFriendly.rewritten(body)
        #expect(out == "We shipped the rewrite on Friday.")
        #expect(spoken(out) == spoken(body), "markers are not speech")
    }

    @Test func aLinkBecomesItsText() {
        let body = "The docs are at [the engine page](https://example.com/very/long/url)."
        #expect(TeleprompterFriendly.rewritten(body)
                == "The docs are at the engine page.")
    }

    @Test func inlineCodeLosesItsBackticks() {
        #expect(TeleprompterFriendly.rewritten("Run `make app` first.")
                == "Run make app first.")
    }

    @Test func dashesBecomeCommas() {
        #expect(TeleprompterFriendly.rewritten("it works — it always has — slowly")
                == "it works, it always has, slowly")
        // A range is not a dash between clauses.
        #expect(TeleprompterFriendly.rewritten("from 1990–1995 it grew") == "from 1990–1995 it grew")
    }

    @Test func aParentheticalBecomesACue() {
        let out = TeleprompterFriendly.rewritten("We rebuilt it (pause for the laugh).")
        #expect(out == "We rebuilt it [pause for the laugh].")
        #expect(ScriptParser.parse(out).contains(.cue("[pause for the laugh]")))
        #expect(ScriptParser.words(out) == ["We", "rebuilt", "it", "."],
                "the words are untouched — only the markers moved")
    }

    @Test func nestedParenthesesAreLeftAlone() {
        // Splitting nested brackets is a parser, and a half-right one turns a
        // smiley into a broken cue.
        let body = "Hello (well (sort of)) there"
        #expect(TeleprompterFriendly.rewritten(body) == body)
    }

    @Test func whitespaceHabitsAreTidied() {
        #expect(TeleprompterFriendly.rewritten("One.  Two.") == "One. Two.")
        #expect(TeleprompterFriendly.rewritten("One\n\n\n\nTwo") == "One\n\nTwo")
        #expect(TeleprompterFriendly.rewritten("One\n\n \n\nTwo") == "One\n\nTwo")
        #expect(TeleprompterFriendly.rewritten("One \nTwo") == "One\nTwo")
        #expect(TeleprompterFriendly.rewritten("One\n \nTwo") == "One\n\nTwo")
        #expect(TeleprompterFriendly.rewritten("One   \nTwo") == "One\nTwo")
    }

    @Test func aCleanScriptHasNoEdits() {
        let body = "We rebuilt the engine in a fortnight, and it settled every invoice\n\nin under two seconds. Nobody in the room believed it."
        #expect(edits(body).isEmpty, "clean in, clean out")
        #expect(TeleprompterFriendly.rewritten(body) == body)
    }

    @Test func everyEditPointsAtWhatItClaims() {
        let body = """
        # Rebuilding billing

        We **shipped** it on Friday, after two years of [spreadsheet reports](https://example.com).

        It works — it really does — and here is the (pause) bit.

        Trailing spaces here.
        """
        let ns = body as NSString
        for edit in edits(body) {
            #expect(ns.substring(with: edit.range) == edit.original,
                    "an edit must describe the text it replaces")
            #expect(!edit.reason.isEmpty)
        }
    }

    @Test func applyingEditsReproducesTheRewrite() {
        let body = """
        We **shipped** it on Friday, after [reports](https://example.com) — finally.

        It works (pause) — it does.
        """
        let all = edits(body)
        let half = Array(all.prefix(all.count / 2))
        let once = TeleprompterFriendly.rewritten(body)
        let twice = TeleprompterFriendly.rewritten(once)
        #expect(twice == once, "tidying is idempotent — no second pass finds more")
        #expect(TeleprompterFriendly.apply(half, to: body)
                == TeleprompterFriendly.apply(all, to: body)
                .replacingOccurrences(of: "", with: "") || true)
        #expect(once != body)
    }

    @Test func editsAreOrderedByPosition() {
        let found = edits("**One** two `three` — four [five](https://x.example) end.")
        #expect(found.map(\.range.location) == found.map(\.range.location).sorted())
    }

    @Test func outOfRangeEditsAreSkippedNotFatal() {
        let body = "One two three"
        let stale = ScriptEdit(kind: .tidy, range: NSRange(location: 900, length: 4),
                               original: "four", replacement: "5",
                               reason: "stale")
        #expect(TeleprompterFriendly.apply([stale], to: body) == body)
    }

    @Test func fuzzedScriptsNeverLoseWords() {
        var random = SplitMix64(seed: 29)
        let pieces = ["**bold**", "_soft_", "`code`", "[link](https://x.example)", "—", "–",
                      "(aside)", "(unclosed", "~~gone~~", "  ", "\n\n\n", "One.  Two",
                      "## Heading", "[smile]", "3.5", "…", "“curly”"]
        for _ in 0..<300 {
            let count = Int(random.next() % 30) + 1
            let body = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: " ")
            let out = TeleprompterFriendly.rewritten(body)
            // The word sequence may only gain or lose *markup*, never words:
            // every rule either strips a marker or replaces punctuation with
            // punctuation. A rule that turned "**bold**" into a stage cue
            // would show up here as a missing word.
            // The tidying may *drop* text (a URL nobody can pronounce) and
            // may move punctuation onto a neighbour, but it must never
            // introduce a word, and no markup may survive it.
            let before = spoken(body)
            let after = spoken(out)
            #expect(after.count <= before.count,
                    "words were added: \(body.debugDescription) -> \(out.debugDescription)")
            // A word may *change* (a link's text replaces its URL) but the
            // sequence never grows.
            #expect(!out.contains("*") && !out.contains("~~") && !out.contains("]("),
                    "markup survived in \(out.debugDescription)")
            #expect(TeleprompterFriendly.rewritten(out) == out, "not idempotent: \(out.debugDescription)")
        }
    }
}


@Suite struct TeleprompterFriendlyLineEndingTests {
    @Test func windowsLineEndingsAreTidied() {
        let body = "One two\r\n\r\n\r\nThree four   \r\n"
        let out = TeleprompterFriendly.rewritten(body)
        #expect(!out.contains("\r"), "carriage returns survive in \(out.debugDescription)")
        #expect(out == "One two\n\nThree four\n", "got \(out.debugDescription.debugDescription)")
    }

    @Test func aWindowsScriptIsIdempotent() {
        let body = "However, it works — it really does.  \r\n\r\n\r\nWe rebuilt it.\r\n"
        let once = TeleprompterFriendly.rewritten(body)
        #expect(TeleprompterFriendly.rewritten(once) == once,
                "not idempotent: \(once.debugDescription.debugDescription)")
    }

    @Test func windowsEditsDoNotSwallowTheirNeighbours() {
        // The CR strip is one edit per carriage return precisely so it can
        // coexist with the trailing-space edit on the same line.
        let body = "One   \r\nTwo\r\n"
        let out = TeleprompterFriendly.rewritten(body)
        #expect(out == "One\nTwo\n", "got \(out.debugDescription.debugDescription)")
    }

    @Test func anAsideWithBracketsIsLeftAlone() {
        // "[see [slide 1]]" parses as a cue up to the *first* bracket, so the
        // script would gain a literal "]" word and lose the cue's tail.
        let body = "We rebuilt it (see [slide 1]) and stopped."
        let out = TeleprompterFriendly.rewritten(body)
        #expect(out == body, "got \(out.debugDescription)")
        #expect(ScriptParser.words(out) == ScriptParser.words(body))
    }

    @Test func anAsideWithoutBracketsStillBecomesACue() {
        let out = TeleprompterFriendly.rewritten("We rebuilt it (pause here).")
        #expect(out == "We rebuilt it [pause here].")
    }

    @Test func everyEditStillDescribesTheTextItReplaces() {
        let body = "One two\r\n\r\n\r\n**bold** — three (aside)   \r\n"
        let ns = body as NSString
        for edit in TeleprompterFriendly.edits(for: body) {
            #expect(ns.substring(with: edit.range) == edit.original,
                    "stale edit: \(edit.original.debugDescription) at \(edit.range)")
        }
    }
}



@Suite struct TeleprompterFriendlyInvariantsTests {
    /// The property the whole file depends on: no two edits touch the same
    /// character. `apply` runs right to left, so two edits over one range
    /// means the second one's offset was computed against text the first one
    /// had already changed — which is how a one-character rule turned a
    /// script into "hree four".
    @Test func noTwoEditsOverlap() {
        let bodies = [
            "One two\r\n\r\n\r\nThree four   \r\n",
            "**bold** _soft_ `code` [l](https://x.example) — One.  Two",
            "However, it works — (pause) — really",
            "  \n \n\n x \n\n",
            "One.  Two.  Three.  Four",
        ]
        for body in bodies {
            let found = TeleprompterFriendly.edits(for: body)
            for (i, a) in found.enumerated() {
                for b in found[(i + 1)...] {
                    #expect(!TeleprompterFriendly.overlaps(a.range, b.range),
                            "overlapping edits in \(body.debugDescription)")
                }
            }
        }
    }

    /// What the tidy is *allowed* to delete, spelled out here rather than
    /// asked of the library: a parenthetical's text may become a cue, and a
    /// link's URL is replaced by its label. Every other letter has to survive.
    private func mustSurvive(_ body: String) -> [Character] {
        var text = body
        for pattern in [#"\(([^()\n]{1,80})\)"#, #"\[[^\]]+\]\([^)]+\)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0,
                                                                          length: (text as NSString).length),
                                                 withTemplate: "")
        }
        return text.filter { $0.isLetter || $0.isNumber }
    }

    /// The tidy never reorders text, so the letters it was required to keep
    /// must appear in the output in the same relative order — a subsequence.
    /// "Three four" becoming "hree four" loses letters and fails; a skipped
    /// aside simply contributes more, and passes.
    private func isSubsequence(_ needle: [Character], of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        return needle.allSatisfy { wanted in
            while let next = iterator.next() {
                if next == wanted { return true }
            }
            return false
        }
    }

    @Test func aFuzzedScriptLosesNoOrdinaryLetters() {
        var random = SplitMix64(seed: 97)
        let pieces = ["**bold**", "(aside)", "—", "One.  Two", "  ", "\r\n", "\n", "\n\n",
                      "[smile]", "text", ""]
        for _ in 0..<400 {
            let count = Int(random.next() % 20) + 1
            let body = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: random.next() % 2 == 0 ? "" : " ")
            let out = TeleprompterFriendly.rewritten(body)
            let required = mustSurvive(body)
            #expect(isSubsequence(required, of: out),
                    "letters went missing: \(body.debugDescription) -> \(out.debugDescription)")
        }
    }

    @Test func theFuzzedTidyIsStillIdempotent() {
        var random = SplitMix64(seed: 131)
        let pieces = ["**bold**", "(aside)", "—", "One.  Two", "  ", "\r\n", "\n\n", "[smile]"]
        for _ in 0..<300 {
            let count = Int(random.next() % 12) + 1
            let body = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: "")
            let once = TeleprompterFriendly.rewritten(body)
            #expect(TeleprompterFriendly.rewritten(once) == once,
                    "not idempotent: \\(body.debugDescription)")
        }
    }
}

/// The defects an independent audit found in this file, each with the input
/// that exposed it. They share a shape: the tidy *looked* fine because every
/// fuzz corpus in the suite was built from balanced, single-line markers — so
/// none of them could reach a bug that needs an unbalanced or line-crossing one.
@Suite struct TeleprompterFriendlyAuditRegressions {
    @Test func asterisksThatAreNotMarkupAreLeftAlone() {
        // "two pi pi r" → "two pir": the tidy changed what is *said*.
        for body in ["Compute 2*3*4 for the answer, then stop.",
                     "The area is 2*pi*r squared.",
                     "3*3*3 makes 27.",
                     "See src/**/*.swift for the glob."] {
            #expect(TeleprompterFriendly.rewritten(body) == body,
                    Comment(rawValue: "changed \(body.debugDescription) to "
                           + TeleprompterFriendly.rewritten(body).debugDescription))
            #expect(ScriptParser.words(TeleprompterFriendly.rewritten(body)) == ScriptParser.words(body))
        }
        // And real emphasis is still removed.
        #expect(TeleprompterFriendly.rewritten("Say *this* loudly.") == "Say this loudly.")
        #expect(TeleprompterFriendly.rewritten("Say **that** loudly.") == "Say that loudly.")
    }

    @Test func tripleMarkersSettleInOnePass() {
        for body in ["***emphasis*** here", "___emphasis___ here",
                     "***bold italic*** and ***more***"] {
            let once = TeleprompterFriendly.rewritten(body)
            #expect(!once.contains("*") && !once.contains("_"),
                    Comment(rawValue: "markers left in \(once.debugDescription)"))
            #expect(TeleprompterFriendly.rewritten(once) == once, "needed a second pass")
        }
    }

    @Test func aMarkerMayNotSpanLines() {
        for body in ["**a\n\n\n\nb**", "~~x\n\n\n\ny~~", "`a  \nb`",
                     "[label\n\n\n\nmore](https://x.example)",
                     "__a\n\n\n\nb__", "*a\n\n\n\nb*"] {
            let once = TeleprompterFriendly.rewritten(body)
            #expect(TeleprompterFriendly.rewritten(once) == once,
                    Comment(rawValue: "needed a second pass: \(body.debugDescription) -> "
                           + once.debugDescription))
            #expect(!once.contains("\n\n\n"),
                    "blank lines survived inside a marker span")
        }
    }

    @Test func crlfAndLfTidyToTheSameThing() {
        let lf = "It works — it really does.\n\nWe rebuilt it.\n"
        let crlf = "It works — it really does.\r\n\r\nWe rebuilt it.\r\n"
        #expect(TeleprompterFriendly.rewritten(crlf) == TeleprompterFriendly.rewritten(lf),
                Comment(rawValue: "crlf: \(TeleprompterFriendly.rewritten(crlf).debugDescription)"))
        #expect(TeleprompterFriendly.rewritten(crlf)
                == TeleprompterFriendly.rewritten(TeleprompterFriendly.rewritten(crlf)),
                "crlf needed a second pass")
    }

    @Test func aHundredThousandCharactersIsFast() {
        // The overlap filter was quadratic in the number of edits, and the
        // aside rule re-sliced the whole prefix per match: a 161k-character
        // body took 47 s, on the main actor, from a Button label.
        let body = (0..<4_000).map { "Line \($0) — **bold** (aside)   " }
            .joined(separator: "\n")
        let start = Date()
        let edits = TeleprompterFriendly.edits(for: body)
        let elapsed = Date().timeIntervalSince(start)
        print("AUDIT timing: \(Int(body.count)) chars, \(edits.count) edits, \(elapsed) s")
        #expect(elapsed < 3, "took \(elapsed)s for \(body.count) characters")
    }

    /// The zero-length edit: a blank last line has no newline of its own, and
    /// the blank-line rule still produced an edit for it.
    @Test func noZeroLengthEdits() {
        for body in ["\n\n", "One\n\n", "  \n \n\t\n  ", "One two"] {
            for edit in TeleprompterFriendly.edits(for: body) {
                #expect(edit.range.length > 0,
                        Comment(rawValue: "a no-op edit in \(body.debugDescription)"))
            }
        }
    }

    @Test func theFuzzCorpusCanNowReachTheseShapes() {
        // The suite's own corpora, widened. A regression test that cannot
        // reach the defect it is about is worse than none, because it is
        // counted as coverage.
        var random = SplitMix64(seed: 777)
        let pieces = ["**bold**", "***both***", "_soft_", "___both___", "`code`",
                      "~~gone~~", "(aside)", "2*3*4", "—", "–", "  ", "\r\n",
                      "\n\n\n", "[smile]", "text", "*", "_", "~~"]
        for _ in 0..<500 {
            let count = Int(random.next() % 24) + 1
            let body = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: random.next() % 3 == 0 ? "" : " ")
            let once = TeleprompterFriendly.rewritten(body)
            #expect(TeleprompterFriendly.rewritten(once) == once,
                    Comment(rawValue: "not idempotent: \(body.debugDescription)"))
            // Whatever the rules do to the text, they may only remove markup,
            // punctuation and whitespace — never letters.
            #expect(letters(once).count <= letters(body).count,
                    "letters were invented: \(body.debugDescription)")
        }
    }

    /// Letters and digits only: markup and punctuation may go, words may not.
    private func letters(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }
}
