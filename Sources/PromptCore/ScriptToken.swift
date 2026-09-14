import Foundation

/// First-class script token. Cues like `[smile]` / `[pause]` are stage
/// directions: rendered distinctly, never tracked as spoken words.
public enum ScriptToken: Equatable, Sendable {
    case word(String)
    case cue(String)
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

    public var text: String {
        switch self {
        case .word(let w): return w
        case .cue(let c): return c
        case .paragraphBreak: return ""
        }
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

        for ch in text {
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
            if ch.isWhitespace {
                flushWord()
                if ch == "\n" {
                    newlineCount += 1
                }
                // Spaces/tabs don't reset the newline run; only a blank
                // line (2+ newlines) becomes a paragraph break.
                continue
            } else {
                flushParagraphBreakIfNeeded()
                newlineCount = 0
                current.append(ch)
            }
        }
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
}
