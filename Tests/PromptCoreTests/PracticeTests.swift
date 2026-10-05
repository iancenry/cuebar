import Foundation
import Testing
@testable import PromptCore

@Suite struct PracticePlanTests {
    /// A real-feeling script: headings, cues, clauses of several lengths.
    private var script: [String] {
        ScriptParser.words("""
        # Why we rebuilt the billing engine

        Our organisation is committed to delivering innovative solutions that facilitate growth \
        for our customers, and the billing engine was the last thing standing in the way.

        The first problem was latency, which affected every single invoice we generated.

        The second problem was correctness.

        So we rebuilt it, and now it settles in under two hundred milliseconds.
        """)
    }

    @Test func levelZeroHidesNothing() {
        let plan = PracticePlan.plan(words: script, level: 0, seed: 1)
        #expect(plan.isEmpty)
        #expect(plan.hiddenFraction == 0)
    }

    @Test func theSameSeedGivesTheSamePlan() {
        // A rehearsal that reshuffles its gaps between passes rehearses the
        // wrong thing twice.
        let a = PracticePlan.plan(words: script, level: 0.45, seed: 99)
        let b = PracticePlan.plan(words: script, level: 0.45, seed: 99)
        #expect(a == b)
    }

    @Test func differentSeedsPickDifferentGaps() {
        // If every seed gave the same plan, the level would be the only thing
        // being rehearsed — and the presenter would learn one script's gaps.
        let plans = (0..<6).map { PracticePlan.plan(words: script, level: 0.45, seed: UInt64($0)) }
        #expect(Set(plans).count > 1, "six seeds produced one plan")
        for plan in plans {
            #expect(plan.hiddenWords > 0)
        }
    }

    @Test func moreLevelHidesAtLeastAsMuch() {
        var previous = 0
        for pass in 0..<PracticePlan.passCount {
            let plan = PracticePlan.planForPass(words: script, pass: pass, seed: 7)
            #expect(plan.hiddenWords >= previous, "pass \(pass) hid less than the pass before")
            previous = plan.hiddenWords
        }
    }

    @Test func aLongSentenceIsFragmentedRatherThanSkipped() {
        // The bug this replaced: one 30-word clause no gap could hold, so the
        // level stopped mattering for the whole opening line.
        let long = (0..<30).map { "word\($0)" }
        let phrases = PracticePlan.clauses(of: long, minWords: 3, maxWords: 8)
        #expect(phrases.count >= 3)
        #expect(phrases.allSatisfy { $0.count <= 8 })
        let fragments = PracticePlan.clauses(of: long, minWords: 2, maxWords: 4)
        #expect(fragments.count > phrases.count)
        #expect(fragments.allSatisfy { $0.count <= 4 })
    }

    @Test func passesHideDifferentSpans() {
        let first = PracticePlan.planForPass(words: script, pass: 1, seed: 7)
        let second = PracticePlan.planForPass(words: script, pass: 2, seed: 7)
        #expect(first.blanks.map { $0.range } != second.blanks.map { $0.range })
    }

    @Test func noGapIsLongEnoughToBeUnsayable() {
        for pass in 0..<PracticePlan.passCount {
            let level = PracticePlan.level(forPass: pass)
            let plan = PracticePlan.planForPass(words: script, pass: pass, seed: 3)
            let cap = PracticePlan.granularity(forLevel: level).maxWords
            for blank in plan.blanks {
                #expect(blank.wordCount <= cap, "gap of \(blank.wordCount) words at level \(level)")
                #expect(blank.wordCount >= 2)
            }
        }
    }

    @Test func gapsCoverWholeClauses() {
        // The point of the whole design: a gap lands where a phrase was, so
        // every gap is one of the clauses found at that level's granularity.
        for pass in 0..<PracticePlan.passCount {
            let level = PracticePlan.level(forPass: pass)
            let granularity = PracticePlan.granularity(forLevel: level)
            let clauses = PracticePlan.clauses(of: script,
                                               minWords: granularity.minWords,
                                               maxWords: granularity.maxWords)
            let plan = PracticePlan.planForPass(words: script, pass: pass, seed: 11)
            for blank in plan.blanks {
                #expect(clauses.contains(blank.range),
                        "pass \(pass): gap \(blank.range) is not one of \(clauses.count) clauses")
            }
        }
    }

    @Test func gapsAreOrderedAndDisjoint() {
        let plan = PracticePlan.planForPass(words: script, pass: 5, seed: 21)
        var previousEnd = 0
        for blank in plan.blanks {
            #expect(blank.range.lowerBound >= previousEnd, "gaps overlap or are out of order")
            previousEnd = blank.range.upperBound
        }
    }

    @Test func theLevelLadderRisesAndStopsAtOne() {
        #expect(PracticePlan.level(forPass: 0) == 0)
        var previous = -1.0
        for pass in 0..<PracticePlan.passCount {
            let level = PracticePlan.level(forPass: pass)
            #expect(level >= previous)
            #expect(level >= 0 && level <= 1)
            previous = level
        }
        // Out of range passes clamp rather than crash or run away.
        #expect(PracticePlan.level(forPass: -5) == 0)
        #expect(PracticePlan.level(forPass: 999) <= 1)
    }

    @Test func theCurrentWordIsNeverHidden() {
        let plan = PracticePlan.planForPass(words: script, pass: 6, seed: 5)
        guard let blank = plan.blanks.first else { return }
        let current = blank.range.lowerBound
        let hidden = plan.hiddenWords(excluding: current)
        #expect(!hidden.contains(current))
        #expect(hidden.count == plan.hiddenWords - 1)
    }

    @Test func anEmptyOrTinyScriptIsSurvivable() {
        #expect(PracticePlan.plan(words: [], level: 0.5, seed: 1).isEmpty)
        #expect(PracticePlan.plan(words: ["Hello"], level: 0.9, seed: 1).isEmpty)
        #expect(PracticePlan.plan(words: ["Hello", "there", "friend"], level: 0.9, seed: 1).blanks
                .allSatisfy { $0.wordCount <= 5 })
    }

    @Test func clausesBreakAtCommasAndConnectives() {
        // "and" mid-span does not start a gap that is one word long.
        let clauses = PracticePlan.clauses(of: ["One", "two", "three,", "four", "and", "five", "six"])
        #expect(clauses == [0..<3, 3..<7])
    }

    @Test func fuzzedPlansStaySane() {
        var random = SplitMix64(seed: 42)
        for _ in 0..<400 {
            let count = Int(random.next() % 300) + 1
            var words = (0..<count).map { _ in
                let length = Int(random.next() % 9) + 1
                return String(repeating: "x", count: length)
            }
            // Sprinkle some clause breaks.
            for i in words.indices where i < words.count - 1 && random.next() % 7 == 0 {
                words[i] += ","
            }
            let level = Double(random.next() % 101) / 100
            let plan = PracticePlan.plan(words: words, level: level,
                                         seed: random.next())
            #expect(plan.hiddenWords <= words.count)
            #expect(plan.hiddenFraction >= 0 && plan.hiddenFraction <= 1)
            var seen = Set<Int>()
            for blank in plan.blanks {
                #expect(blank.range.lowerBound >= 0)
                #expect(blank.range.upperBound <= words.count)
                for word in blank.range {
                    #expect(seen.insert(word).inserted, "word \(word) hidden twice")
                }
            }
        }
    }
}
/// A rehearsal plan for a two-line script has to be usable. The plan used to
/// go from hiding nothing to hiding *everything* between two passes — a
/// four-word script cannot be split into phrases, so its single candidate
/// span overshot the target at the first level and was taken whole at the
/// next, leaving the presenter one word and three gaps.
@Suite struct PracticeShortScriptTests {
    @Test func somethingIsAlwaysLeftToRead() {
        for count in 2...6 {
            let words = (0..<count).map { "w\($0)" }
            for level in stride(from: 0.1, through: 1.0, by: 0.1) {
                let plan = PracticePlan.plan(words: words, level: level, seed: 7)
                let hidden = plan.blanks.reduce(0) { $0 + $1.range.count }
                #expect(hidden < words.count,
                        "level \\(level) of a \\(count)-word script hides all of it")
            }
        }
    }

    @Test func theFirstPassStillHidesNothing() {
        let words = ["one", "two", "three", "four"]
        let plan = PracticePlan.plan(words: words, level: 0.25, seed: 7)
        #expect(plan.blanks.isEmpty)
    }
}
