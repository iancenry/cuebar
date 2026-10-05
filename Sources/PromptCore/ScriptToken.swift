import Foundation

/// First-class script token. Cues like `[smile]` / `[pause]` are stage
/// directions: rendered distinctly, never tracked as spoken words.
public enum ScriptToken: Equatable, Sendable {
    /// `emphasised` is a fact about the *file*, not the speech: the text is
    /// already `spoken`, so this is the only surviving trace that the author
    /// wrote `**like this**`. It rides on the token rather than beside it in a
    /// parallel set, because a second container of per-word facts is a second
    /// thing that can disagree with the first.
    case word(String, emphasised: Bool = false)
    case cue(String)
    /// `## Problem` in the source. A section is not a word: it must not be
    /// counted in the duration, spoken by the recogniser, or highlighted —
    /// it is a place in the script, and the body keeps it as text so
    /// export and import round-trip without a second representation.
    case section(name: String, level: Int)
    case paragraphBreak

    public var isCue: Bool {
        if case .cue = self { return true }
        return false
    }

    public var isWord: Bool {
        if case .word = self { return true }
        return false
    }

    public var isParagraphBreak: Bool {
        if case .paragraphBreak = self { return true }
        return false
    }

    public var isSection: Bool {
        if case .section = self { return true }
        return false
    }
}

/// A section heading, and where it starts.
public struct ScriptSection: Equatable, Sendable, Identifiable {
    public var name: String
    /// 1 for `#`, 2 for `##`. Nesting is presentation only — sections are
    /// a flat timeline, the way a presenter thinks of them.
    public var level: Int
    /// First word under the heading. 0 when a script opens with one.
    public var wordIndex: Int
    public var id: String { name }

    public init(name: String, level: Int, wordIndex: Int) {
        self.name = name
        self.level = level
        self.wordIndex = wordIndex
    }
}


public enum ScriptParser: Sendable {
    /// A Markdown heading at `hash`, if this line is one.
    ///
    /// `afterFirst` is the index just past the leading `#`. A heading needs
    /// 1-3 hashes, a space, and something after it — so `#tag`, `#### deep`
    /// and a bare `#` are prose. Returning the line's end index lets the
    /// caller skip the line without inventing a second word-scanner for the
    /// "it wasn't a heading after all" case, which is how cues on a `#tag`
    /// line used to be read out loud as words.
    static func heading(_ text: String, afterFirst: String.Index)
    -> (level: Int, name: String, lineEnd: String.Index)? {
        var index = afterFirst
        var level = 1
        while index < text.endIndex, text[index] == "#" {
            level += 1
            index = text.index(after: index)
        }
        guard level <= 3, index < text.endIndex, text[index] == " " else { return nil }
        // The end of this line, found in scalars rather than by
        // `firstIndex(of: "\n")`: Swift treats "\r\n" as a *single* Character,
        // so that search returns nil for a CRLF script and the heading swallowed
        // every following line — a Windows talk parsed as one section and zero
        // words.
        var lineEnd = text.endIndex
        var scan = index
        while scan < text.endIndex, text[scan] != "\n" && !text[scan].isNewline {
            scan = text.index(after: scan)
        }
        lineEnd = scan
        let name = text[text.index(after: index)..<lineEnd]
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (level, name, lineEnd)
    }

    /// Splits on whitespace, keeping `[bracketed spans] (possibly with
    /// spaces inside) as a single cue token. Unclosed `[` is a plain word.
    /// Blank lines (two or more newlines with only whitespace between)
    /// emit a single `.paragraphBreak` so paragraph spacing can render.
    /// The index just past the next newline at or after `from`.
    static func endOfLine(_ text: String, from: String.Index) -> String.Index {
        var scan = from
        while scan < text.endIndex, !text[scan].isNewline {
            scan = text.index(after: scan)
        }
        return scan
    }

    /// Is the rest of this line only `#` and spaces?
    static func hashesOnly(_ text: String, from index: String.Index) -> Bool {
        var scan = index
        var sawHash = false
        while scan < text.endIndex, !text[scan].isNewline {
            if text[scan] == "#" { sawHash = true }
            else if !text[scan].isWhitespace { return false }
            scan = text.index(after: scan)
        }
        return sawHash
    }

    public static func parse(_ text: String) -> [ScriptToken] {
        var tokens: [ScriptToken] = []
        var current = ""
        var inCue = false
        var cueBuffer = ""
        var newlineCount = 0
        var atLineStart = true

        func flushWord() {
            guard !current.isEmpty else { return }
            // `**bold**` is file syntax, not speech. The token carries what is
            // said; the file keeps what the presenter typed.
            tokens.append(.word(spoken(current), emphasised: ScriptParser.isEmphasised(current)))
            current = ""
        }

        func flushParagraphBreakIfNeeded() {
            guard newlineCount >= 2, !tokens.isEmpty else { return }
            if tokens.last?.isParagraphBreak != true {
                tokens.append(.paragraphBreak)
            }
        }

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            index = text.index(after: index)
            if inCue {
                cueBuffer.append(ch)
                if ch == "]" {
                    flushParagraphBreakIfNeeded()
                    newlineCount = 0
                    tokens.append(.cue(cueBuffer))
                    cueBuffer = ""
                    inCue = false
                } else if ch == "\n" {
                    newlineCount += 1
                } else if !ch.isWhitespace {
                    newlineCount = 0
                }
                continue
            }
            if ch == "[", current.isEmpty {
                inCue = true
                cueBuffer = "["
                continue
            }
            if ch == "#", current.isEmpty, atLineStart {
                // Look ahead: a heading is consumed whole, and a line that is
                // merely prose starting with `#` simply carries on being
                // scanned — cues included, because there is no second scanner
                // here to forget about them.
                // From the `#` itself: `index` has already moved past it.
                if hashesOnly(text, from: text.index(before: index)) {
                    index = endOfLine(text, from: index)
                    if index == text.endIndex { break }
                    index = text.index(after: index)
                    atLineStart = true
                    continue
                }
                if let found = heading(text, afterFirst: index) {
                    flushWord()
                    flushParagraphBreakIfNeeded()
                    tokens.append(.section(name: found.name, level: found.level))
                    index = found.lineEnd
                    if index == text.endIndex { break }
                    // The newline itself is left for the whitespace branch, so
                    // the next line still knows it starts a line.
                    atLineStart = false
                    continue
                }
                flushParagraphBreakIfNeeded()
                newlineCount = 0
                atLineStart = false
                current.append(ch)
                continue
            }
            if ch.isWhitespace {
                flushWord()
                if ch == "\n" {
                    newlineCount += 1
                    atLineStart = true
                } else if ch != " " && ch != "\t" {
                    atLineStart = true
                }
                // Spaces/tabs don't reset the newline run; only a blank
                // line (2+ newlines) becomes a paragraph break.
                continue
            } else {
                flushParagraphBreakIfNeeded()
                newlineCount = 0
                atLineStart = false
                current.append(ch)
            }
        }
        if inCue {
            // Unclosed bracket: treat buffered text as plain words.
            // Any pending paragraph break comes first so "[oops\n\nword"
            // keeps its paragraph structure.
            flushParagraphBreakIfNeeded()
            for part in cueBuffer.split(whereSeparator: \.isWhitespace) {
                // Through `spoken` like every other word. Skipping it here made
                // `parse` and `words` disagree permanently for a script with an
                // unclosed bracket, and the cue-staging path compares those two
                // arrays to decide whether to reload the engine — so every ⌘K
                // on such a script called `cancelHold()` and killed the timed
                // pause it had just written.
                tokens.append(.word(spoken(String(part)),
                                    emphasised: ScriptParser.isEmphasised(String(part))))
            }
        } else {
            flushWord()
        }
        // Never lead or trail with a break — it would only add dead space.
        while tokens.first?.isParagraphBreak == true { tokens.removeFirst() }
        while tokens.last?.isParagraphBreak == true { tokens.removeLast() }
        // Coalesce accidental doubles (defensive; flush logic avoids them).
        var deduped: [ScriptToken] = []
        deduped.reserveCapacity(tokens.count)
        for t in tokens {
            if t.isParagraphBreak, deduped.last?.isParagraphBreak == true { continue }
            deduped.append(t)
        }
        return deduped
    }

    /// Where every word starts and ends, in reading order.
    ///
    /// This is the *only* definition of what counts as a word in Cuebar, and
    /// it exists because three scanners disagreed: `parse` (which knows about
    /// `#` headings and `[cue]` spans), `wordCount` (a character scan), and
    /// `CueInsertion.characterOffset` (another character scan). The latter two
    /// counted the words *inside* a heading, so a staged cue for "we shipped
    /// it" landed inside the heading above it — a pause in the wrong place,
    /// which reads as though the script said something it didn't.
    ///
    /// It follows `parse` exactly: a heading line contributes no words, a
    /// closed `[…]` contributes none, and an unclosed `[` is words.
    public static func wordRanges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var wordStart: String.Index?
        var inCue = false
        var cueStart: String.Index?
        var atLineStart = true

        /// The range of the whole word *in the file*, markers included.
        ///
        /// Not the spoken range: this is what a staged cue's character offset is
        /// measured from, and inserting `[pause 2s]` at the start of the
        /// *trimmed* word put it inside the `**` — which split the word into
        /// "`**`" and "bold**`" and changed the word count. The spoken form
        /// comes from `words(_:)`, which is what matching and counting read.
        func flushWord(upTo end: String.Index) {
            if let start = wordStart { out.append(start..<end) }
            wordStart = nil
        }

        /// A heading becomes a section and no words. Anything else — a
        /// hashtag, `#### four hashes`, `#` alone — is prose, split on
        /// whitespace, exactly as `parse` does.
        func flushHeadingLine(_ start: String.Index, _ end: String.Index) {
            let line = text[start..<end]
            let hashes = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(hashes)
            let name = rest.trimmingCharacters(in: .whitespaces)
            let isHeading = hashes >= 1 && hashes <= 3 && rest.first == " " && !name.isEmpty
            if isHeading { return }
            for part in line.split(whereSeparator: \.isWhitespace) {
                out.append(part.startIndex..<part.endIndex)
            }
        }

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)

            if inCue {
                if ch == "]" {
                    inCue = false
                    cueStart = nil
                }
                index = next
                continue
            }
            if ch == "[", wordStart == nil {
                inCue = true
                cueStart = index
                index = next
                continue
            }
            if ch == "#", wordStart == nil, atLineStart {
                // A line of nothing but hashes is an empty heading
                // placeholder: not a heading, and not prose either. Reading
                // "#" aloud is neither.
                if hashesOnly(text, from: index) {
                    index = endOfLine(text, from: index)
                    if index == text.endIndex { break }
                    index = text.index(after: index)
                    atLineStart = true
                    continue
                }
                // The same lookahead `parse` uses. A heading contributes no
                // words; anything else keeps going through the ordinary path,
                // so this scanner cannot drift from the tokeniser about what a
                // word is.
                if let found = heading(text, afterFirst: next) {
                    flushWord(upTo: index)
                    index = found.lineEnd == text.endIndex
                        ? text.endIndex : text.index(after: found.lineEnd)
                    atLineStart = true
                    continue
                }
            }
            if ch.isWhitespace {
                flushWord(upTo: index)
                // Only a newline (or some other separator) starts a line; a
                // space or tab mid-line must not make `#` a heading marker.
                if ch == "\n" || (ch != " " && ch != "\t") { atLineStart = true }
                index = next
                continue
            }
            if wordStart == nil { wordStart = index }
            atLineStart = false
            index = next
        }

        if inCue, let start = cueStart {
            // Unclosed bracket: `parse` treats the buffered text as words,
            // leading `[` attached to the first of them.
            for part in text[start..<text.endIndex].split(whereSeparator: \.isWhitespace) {
                out.append(part.startIndex..<part.endIndex)
            }
        }
        flushWord(upTo: text.endIndex)
        return out
    }

    /// Whether the author marked this word with `**` or `*`.
    ///
    /// Asked of `spokenRange` rather than of a rule of its own: "is this
    /// emphasised" and "what did we strip" have to have the same answer, and
    /// `2*3*4` and `****` are exactly the words where a hand-written second
    /// rule would disagree with the first.
    public static func isEmphasised(_ word: String) -> Bool {
        spokenRange(of: word) != nil
    }

    /// The part of a word that is actually spoken, with Markdown emphasis
    /// markers removed.
    ///
    /// Bold and italic are *file* syntax and not speech: without this the
    /// prompter says "asterisk word asterisk", and the presenter is the one who
    /// finds out. Only a balanced pair at both ends of one word counts, which is
    /// what keeps `2*3*4` and a lone `*` exactly as written — the arithmetic
    /// case is why a tidy rule is not enough on its own.
    ///
    /// The two scanners both ask this, so `parse` and `wordRanges` cannot
    /// disagree about where a word starts.
    public static func spokenRange(of word: String) -> Range<String.Index>? {
        let end = word.endIndex
        guard word.startIndex < end else { return nil }
        let marker = word[word.startIndex]
        guard marker == "*" || marker == "_" else { return nil }

        // A run of markers at each end, the same length at both, so `**bold**`,
        // `*it*`, `***both***` come out as the word inside.
        var opening = 0
        var contentStart = word.startIndex
        while contentStart < end, word[contentStart] == marker {
            opening += 1
            contentStart = word.index(after: contentStart)
        }
        guard opening > 0, opening <= 3, contentStart < end else { return nil }

        // The closing run, which may be followed by punctuation: `*quiet*.` and
        // `**important**,` are how emphasis appears in prose, and requiring the
        // marker to be the last character left the asterisks on stage for most of
        // a sentence. Trailing punctuation goes with the markers — it is
        // punctuation, and the prompter has a setting for whether to show it.
        var cursor = contentStart
        while cursor < end {
            if word[cursor] == marker,
               let runEnd = markerRun(word, from: cursor, marker: marker),
               word.index(cursor, offsetBy: opening) == runEnd {
                return contentStart..<cursor
            }
            cursor = word.index(after: cursor)
        }
        return nil
    }

    /// Where a closing marker run ends, if the rest of the word is only that
    /// run and punctuation.
    private static func markerRun(_ word: String, from start: String.Index,
                                  marker: Character) -> String.Index? {
        var scan = start
        while scan < word.endIndex, word[scan] == marker { scan = word.index(after: scan) }
        var rest = scan
        while rest < word.endIndex, word[rest].isPunctuation || word[rest].isSymbol {
            rest = word.index(after: rest)
        }
        return rest == word.endIndex ? scan : nil
    }

    /// Emphasis stripped from a whole line, for the exporters.
    ///
    /// `spoken(_:)` is for one *token*; a line of prose has spaces in it, and
    /// stripping that as one token finds no balanced pair and returns it
    /// unchanged — which is how literal asterisks reached the PDF and `.docx`.
    public static func deemphasised(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { spoken(String($0)) }
            .joined(separator: " ")
    }

    /// The spoken text of a word.
    public static func spoken(_ word: String) -> String {
        guard let range = spokenRange(of: word) else { return word }
        return String(word[range])
    }


    /// The spoken part of a word, given its range in the whole script. The one
    /// place both scanners get their answer from.
    static func spoken(of range: Range<String.Index>, in text: String) -> Range<String.Index> {
        let piece = String(text[range])
        guard let trimmed = spokenRange(of: piece) else { return range }
        // Both ends, or the closing markers are left behind and `**bold**`
        // becomes the word "**" — which is what the first version did.
        let lower = piece.distance(from: piece.startIndex, to: trimmed.lowerBound)
        let upper = piece.distance(from: piece.startIndex, to: trimmed.upperBound)
        let start = text.index(range.lowerBound, offsetBy: lower)
        let end = text.index(range.lowerBound, offsetBy: upper)
        return start..<end
    }

    /// The words as they are *spoken*: the ranges cover the file's text
    /// (markers and all) and this strips the emphasis, so the matcher and the
    /// prompter both see "bold" for `**bold**`.
    public static func words(_ text: String) -> [String] {
        wordRanges(in: text).map { spoken(String(text[$0])) }
    }

    /// How many words there are.
    ///
    /// Was a hand-written character scan that skipped the token array, for the
    /// sidebar's benefit. It was also wrong in the same way the other two
    /// scanners were — it counted the words inside a `#` heading — and being
    /// fast and wrong is how a heading's words ended up in two different
    /// places at once. `ScriptDocument.wordCount` is cached by the store, so
    /// this is called on load and on edit, not per row per render.
    public static func wordCount(_ text: String) -> Int {
        wordRanges(in: text).count
    }


}

/// Inserting a section heading at a caret.
///
/// A heading has to own a whole line — `##` is only a heading at the start
/// of one — so this is line surgery rather than a string insert, and it
/// lives here where it can be tested. Offsets are UTF-16, which is what
/// `NSTextView` and `TextEditor` speak.
///
/// Nothing is ever rewritten or dropped: the caret's sentence is pushed
/// down intact, because losing a paragraph to a convenience button is
/// unforgivable in an editor.
public enum SectionInsert {
    public struct Plan: Equatable, Sendable {
        public var text: String
        /// Where the caret lands: inside the new heading, ready to type.
        public var caret: Int
    }

    public static func plan(for text: String, caret: Int, level: Int = 2) -> Plan {
        let ns = text as NSString
        let clamped = max(0, min(caret, ns.length))
        let line = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let lineText = ns.substring(with: line)
        // Keep the block's indentation: a heading inside an indented run
        // stays inside it rather than jumping back to column zero.
        let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
        let marker = String(repeating: "#", count: min(max(level, 1), 3)) + " "
        let head = ns.substring(to: line.location)
        let tail = ns.substring(from: NSMaxRange(line))

        // On an empty line, claim that line rather than pushing a heading
        // above a blank one and leaving the blank behind.
        if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
            let insertion = indent + marker
            return Plan(text: head + insertion + tail,
                        caret: (head + insertion).utf16.count)
        }

        // The heading needs a line of its own: a newline *before* it if
        // the caret's line already has content above it, and one *after* the
        // marker always. Getting that second one wrong put the marker and
        // the sentence on the same line, which the parser then read as one
        // very long heading.
        let lead = (head.isEmpty || head.hasSuffix("\n")) ? "" : "\n"
        let prefix = lead + indent + marker
        return Plan(text: head + prefix + "\n" + lineText + tail,
                    caret: (head + prefix).utf16.count)
    }

}

public enum EmphasisInsert {
    /// Wrap the selection — or the word the caret is in — in `**` or `*`.
    ///
    /// Presentational only, and deliberately so: the markers stay in the file
    /// (so the script is still readable Markdown, and the tidy can remove them),
    /// while the parser drops them before anything is said. That is what makes
    /// a Bold button safe in a teleprompter rather than a way to say
    /// "asterisk".
    /// What a press of ⌘B or ⌘I did.
    ///
    /// A struct rather than a tuple because it is now the return of a
    /// *dispatched command* rather than of a button: the chord reaches the app
    /// through the single key monitor, and a named result is what lets the
    /// same plan be tested without a text view.
    public struct Plan: Equatable, Sendable {
        public var text: String
        public var caret: Int
        public var selected: NSRange?
    }

    public static func plan(for text: String, selection: NSRange,
                            marker: String) -> Plan {
        let ns = text as NSString
        // A selection can arrive out of date — a document that shrank under an
        // open sheet — and `substring(with:)` traps on one. Clamped here rather
        // than trusted: a crashed editor is a crashed editor.
        var clamped = selection
        clamped.location = min(max(0, selection.location), ns.length)
        clamped.length = min(max(0, selection.length), ns.length - clamped.location)
        // No selection, or a selection that is only whitespace: wrap the word
        // under the caret, which is what pressing Bold with nothing highlighted
        // should mean.
        if clamped.length == 0 || ns.substring(with: clamped)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let range = wordRange(in: ns, around: clamped.location)
            if range.length == 0 {
                // Nothing to wrap (an empty script, or a caret between two
                // spaces): insert the markers so the presenter can type
                // between them.
                let markerText = marker + marker
                let out = ns.replacingCharacters(in: range, with: markerText)
                let middle = range.location + marker.utf16.count
                return Plan(text: out, caret: middle,
                            selected: NSRange(location: middle, length: 0))
            }
            let inner = ns.substring(with: range)
            // Already emphasised? Toggle it off rather than nesting.
            if isEmphasised(inner, marker: marker) {
                let stripped = String(inner.dropFirst(marker.count)
                    .dropLast(marker.count))
                let start = range.location
                let out = ns.replacingCharacters(in: range, with: stripped)
                return Plan(text: out, caret: start + stripped.utf16.count,
                        selected: nil)
            }
            let wrapped = marker + inner + marker
            let out = ns.replacingCharacters(in: range, with: wrapped)
            return Plan(text: out, caret: range.location + wrapped.utf16.count,
                        selected: nil)
        }
        let inner = ns.substring(with: clamped)
        // Emphasis is stripped per *word*, so a marker pair around several
        // words would leave half of them on stage: `**hello world**` parses as
        // "`**hello`" and "`world**`". Each selected word is wrapped instead,
        // which is honest Markdown and renders correctly.
        if inner.contains(where: { $0.isWhitespace }) {
            let wrapped = inner.split(whereSeparator: { $0.isWhitespace })
                .map { marker + $0 + marker }
                .joined(separator: " ")
            let out = ns.replacingCharacters(in: clamped, with: wrapped)
            return Plan(text: out, caret: clamped.location + wrapped.utf16.count,
                        selected: NSRange(location: clamped.location + marker.utf16.count,
                                          length: inner.utf16.count))
        }
        if isEmphasised(inner, marker: marker) {
            let stripped = String(inner.dropFirst(marker.count).dropLast(marker.count))
            let out = ns.replacingCharacters(in: clamped, with: stripped)
            return Plan(text: out, caret: clamped.location + stripped.utf16.count,
                        selected: nil)
        }
        let wrapped = marker + inner + marker
        let out = ns.replacingCharacters(in: clamped, with: wrapped)
        let caret = clamped.location + wrapped.utf16.count
        return Plan(text: out, caret: caret,
                    selected: NSRange(location: clamped.location + marker.utf16.count,
                                      length: inner.utf16.count),)
    }

    static func isEmphasised(_ word: String, marker: String) -> Bool {
        guard word.count > marker.count * 2 else { return false }
        return word.hasPrefix(marker) && word.hasSuffix(marker)
    }

    /// The whitespace-delimited word containing `location`, as UTF-16 offsets.
    static func wordRange(in ns: NSString, around location: Int) -> NSRange {
        let length = ns.length
        var start = min(max(0, location), length)
        var end = start
        let space = CharacterSet.whitespacesAndNewlines
        func isBoundary(_ index: Int) -> Bool {
            guard index >= 0, index < length else { return true }
            let piece = ns.substring(with: NSRange(location: index, length: 1))
            guard let scalar = piece.unicodeScalars.first else { return true }
            return space.contains(scalar)
        }
        while start > 0, !isBoundary(start - 1) { start -= 1 }
        while end < length, !isBoundary(end) { end += 1 }
        // Bounded by the string. An empty script has no word to wrap, and
        // `max(1, …)` used to produce a range one character long in a
        // zero-length string — which `substring(with:)` aborts on.
        guard length > 0, end > start else {
            return NSRange(location: min(start, length), length: 0)
        }
        return NSRange(location: start, length: end - start)
    }
}
