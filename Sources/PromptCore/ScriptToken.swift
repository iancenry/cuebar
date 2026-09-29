import Foundation

/// First-class script token. Cues like `[smile]` / `[pause]` are stage
/// directions: rendered distinctly, never tracked as spoken words.
public enum ScriptToken: Equatable, Sendable {
    case word(String)
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
    /// Splits on whitespace, keeping `[bracketed spans]` (possibly with
    /// spaces inside) as a single cue token. Unclosed `[` is a plain word.
    /// Blank lines (two or more newlines with only whitespace between)
    /// emit a single `.paragraphBreak` so paragraph spacing can render.
    public static func parse(_ text: String) -> [ScriptToken] {
        var tokens: [ScriptToken] = []
        var current = ""
        var inCue = false
        var cueBuffer = ""
        var newlineCount = 0
        var atLineStart = true
        /// Non-nil while a line that began with `#` is being read. The
        /// whole line is buffered because whether it is a heading depends
        /// on what follows the hashes — `#hashtag` is a word, `## Problem`
        /// is not — and a character loop can't look ahead.
        var headingLine: String?

        func flushWord() {
            guard !current.isEmpty else { return }
            tokens.append(.word(current))
            current = ""
        }

        func flushParagraphBreakIfNeeded() {
            guard newlineCount >= 2, !tokens.isEmpty else { return }
            if tokens.last?.isParagraphBreak != true {
                tokens.append(.paragraphBreak)
            }
        }

        /// Emit a buffered candidate line as a heading, or as plain words
        /// if it isn't one. A heading needs 1-3 hashes, a space, and
        /// something after it; anything else stays text so hashtags and
        /// ASCII survive a round trip.
        func flushHeadingLine() {
            guard let line = headingLine else { return }
            headingLine = nil
            let hashes = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(hashes)
            let name = rest.trimmingCharacters(in: .whitespaces)
            if hashes >= 1, hashes <= 3, rest.first == " ", !name.isEmpty {
                flushParagraphBreakIfNeeded()
                tokens.append(.section(name: name, level: hashes))
                return
            }
            for part in line.split(whereSeparator: \.isWhitespace) {
                tokens.append(.word(String(part)))
            }
        }

        for ch in text {
            if headingLine != nil {
                if ch == "\n" {
                    flushHeadingLine()
                    newlineCount += 1
                    // The next line starts fresh. Missing this meant only
                    // the *first* heading of a run of them was recognised:
                    // "## test" then "## hello" parsed as one section and
                    // then two stray words, because the second line's `#`
                    // was no longer at a line start.
                    atLineStart = true
                } else {
                    headingLine?.append(ch)
                }
                continue
            }
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
                flushWord()
                headingLine = "#"
                atLineStart = false
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
        flushHeadingLine()
        if inCue {
            // Unclosed bracket: treat buffered text as plain words.
            // Any pending paragraph break comes first so "[oops\n\nword"
            // keeps its paragraph structure.
            flushParagraphBreakIfNeeded()
            for part in cueBuffer.split(whereSeparator: \.isWhitespace) {
                tokens.append(.word(String(part)))
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

    /// Words only, in order — what the tracking engine consumes.
    public static func words(_ text: String) -> [String] {
        parse(text).compactMap {
            if case .word(let w) = $0 { return w }
            return nil
        }
    }

    /// Word count by scanning the characters, with no token array and no
    /// `[String]` at all. The sidebar asks for this once per row per render
    /// and the editor twice per keystroke, so building a full parse to
    /// throw it away was pure cost. Mirrors `parse`'s rules exactly:
    /// a `[` at a word boundary opens a cue (not a word), a closed cue
    /// discards its buffer, and an unclosed one becomes words.
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        var inCue = false
        var cuePart = false        // non-whitespace seen in the open buffer
        var cueParts = 0           // finished parts of the open buffer
        for ch in text {
            if inCue {
                if ch == "]" {
                    // The cue is one token of its own: its contents are
                    // text, not words.
                    inCue = false
                    cuePart = false
                    cueParts = 0
                } else if ch.isWhitespace {
                    if cuePart { cueParts += 1; cuePart = false }
                } else {
                    cuePart = true
                }
                continue
            }
            if ch == "[", !inWord {
                // The bracket itself is part of the buffer: an unclosed cue
                // flushes "[…" as plain words, so it counts as content.
                inCue = true
                cuePart = true
                cueParts = 0
                continue
            }
            if ch.isWhitespace {
                if inWord { inWord = false; count += 1 }
            } else {
                inWord = true
            }
        }
        if inWord { count += 1 }
        if inCue { count += cueParts + (cuePart ? 1 : 0) }
        return count
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
