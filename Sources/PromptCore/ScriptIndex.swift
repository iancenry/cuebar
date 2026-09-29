import Foundation

/// One pass over a script, done once per edit, that answers every question
/// the reading surface asks: how many words, which page a word is on, which
/// tokens belong to a page, and what the cues do.
///
/// The alternative was recomputing all of it from `[ScriptToken]` on every
/// body evaluation — and the prompter re-runs its body on *every word
/// change* (12 Hz at 150 wpm, ~100 Hz boosted), so that was a full script
/// walk per word. Page-size independent on purpose: the "Words per page"
/// slider can then change without rebuilding anything.
public struct ScriptIndex: Sendable, Equatable {
    public let tokens: [ScriptToken]
    /// Token index of every word, ascending. The spine: pages, row slices and
    /// jump targets are all arithmetic on top of this.
    public let wordTokenIndices: [Int]
    /// What the cues do — holds, auto-pauses and jump targets.
    public let cuePlan: ReadingWindow.CuePlan

    /// The interpreted cue at each token index (nil for words and breaks).
    /// A badge used to parse its own string — twice — on every render, and
    /// the prompter re-renders on every word change.
    public let cues: [ScriptCue?]

    public init(tokens: [ScriptToken]) {
        self.tokens = tokens

        var words: [Int] = []
        words.reserveCapacity(tokens.count)
        var interpreted: [ScriptCue?] = []
        interpreted.reserveCapacity(tokens.count)
        var plan = ReadingWindow.CuePlan()
        var wordCount = 0
        var lastWord: Int?
        var pendingHold: TimeInterval?
        var pendingPause = false
        var pendingIndex: Int?

        for i in tokens.indices {
            let token = tokens[i]
            if token.isWord {
                if let seconds = pendingHold {
                    plan.holds[wordCount] = seconds
                    pendingHold = nil
                }
                if pendingPause {
                    plan.pauses.insert(wordCount)
                    pendingPause = false
                }
                if let index = pendingIndex {
                    plan.indices.append(index)
                    pendingIndex = nil
                }
                words.append(i)
                interpreted.append(nil)
                lastWord = wordCount
                wordCount += 1
            } else if case .cue(let raw) = token {
                // Adjacent cues share one jump target, but each still
                // contributes its own behaviour.
                if pendingIndex == nil { pendingIndex = wordCount }
                let cue = ScriptCue.interpret(raw)
                interpreted.append(cue)
                if cue.kind.isTiming, let seconds = cue.seconds {
                    pendingHold = seconds
                } else if ReadingWindow.isPauseCue(cue), cue.seconds == nil {
                    pendingPause = true
                }
            } else {
                interpreted.append(nil)
            }
        }
        // A cue with no word after it waits at the end of the script rather
        // than being dropped on the floor.
        if let lastWord {
            if let seconds = pendingHold { plan.holds[lastWord] = seconds }
            if pendingPause { plan.pauses.insert(lastWord) }
            if let index = pendingIndex {
                let target = min(index, lastWord)
                if plan.indices.last != target { plan.indices.append(target) }
            }
        }
        wordTokenIndices = words
        cues = interpreted
        cuePlan = plan
    }

    public var isEmpty: Bool { tokens.isEmpty }
    public var wordCount: Int { wordTokenIndices.count }

    public func pageCount(pageSize: Int) -> Int {
        ReadingWindow.pageCount(wordCount: wordCount, pageSize: pageSize)
    }

    public func page(forWord wordIndex: Int?, pageSize: Int) -> Int {
        ReadingWindow.pageIndex(forWord: wordIndex, wordCount: wordCount, pageSize: pageSize)
    }

    public func wordRange(page: Int, pageSize: Int) -> Range<Int> {
        ReadingWindow.wordRange(page: page, wordCount: wordCount, pageSize: pageSize)
    }

    /// Token indices of one page. Page assignment is monotonic in token
    /// order, so a page is a contiguous slice — found here in O(1).
    ///
    /// Leading cues belong to the page of the word they introduce, so the
    /// slice starts after the *previous* page's last word; trailing cues
    /// belong to the last page.
    public func pageTokenRange(page: Int, pageSize: Int) -> Range<Int> {
        // A script that is only cues still has something to show, and it has
        // no word range to slice it by.
        guard pageSize > 0, wordCount > 0 else { return 0..<tokens.count }
        let words = wordRange(page: page, pageSize: pageSize)
        guard !words.isEmpty else { return 0..<0 }
        let start = words.lowerBound == 0 ? 0 : wordTokenIndices[words.lowerBound - 1] + 1
        // The slice also stops before the cues that introduce the *next*
        // page's first word — those belong to that page.
        let end = words.upperBound < wordCount
            ? wordTokenIndices[words.upperBound - 1] + 1
            : tokens.count
        return start..<max(start, end)
    }

    /// Paragraph groups of rows for one page, walking only that page's
    /// tokens. Cues hide when `showCues` is false; paragraph breaks always
    /// split groups so a page renders real gaps.
    public func pageParagraphRows(page: Int, pageSize: Int, showCues: Bool) -> [[ReadingWindow.TokenRow]] {
        let slice = pageTokenRange(page: page, pageSize: pageSize)
        guard !slice.isEmpty else { return [[]] }
        // Global word index of the page's first word, from its position.
        let firstWord = ReadingWindow.wordRange(page: page, wordCount: wordCount,
                                                pageSize: pageSize).lowerBound
        var groups: [[ReadingWindow.TokenRow]] = [[]]
        var wordIndex = firstWord
        for i in slice {
            let token = tokens[i]
            if token.isParagraphBreak {
                groups.append([])
            } else if token.isCue, !showCues {
                continue
            } else if case .cue(let raw) = token {
                groups[groups.count - 1].append(ReadingWindow.TokenRow(token: token, wordIndex: -1,
                                                          cue: ScriptCue.interpret(raw)))
            } else {
                groups[groups.count - 1].append(ReadingWindow.TokenRow(token: token, wordIndex: wordIndex,
                                                          cue: nil))
                wordIndex += 1
            }
        }
        // A page boundary can strand a leading break; drop empty groups but
        // keep at least one so empty pages still render.
        let nonEmpty = groups.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? [[]] : nonEmpty
    }
}
