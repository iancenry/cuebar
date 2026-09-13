import Foundation

/// First-class script token. Cues like `[smile]` / `[pause]` are stage
/// directions: rendered distinctly, never tracked as spoken words.
public enum ScriptToken: Equatable, Sendable {
    case word(String)
    case cue(String)

    public var isCue: Bool {
        if case .cue = self { return true }
        return false
    }

    public var text: String {
        switch self {
        case .word(let w): return w
        case .cue(let c): return c
        }
    }
}

public enum ScriptParser: Sendable {
    /// Splits on whitespace, keeping `[bracketed spans]` (possibly with
    /// spaces inside) as a single cue token. Unclosed `[` is a plain word.
    public static func parse(_ text: String) -> [ScriptToken] {
        var tokens: [ScriptToken] = []
        var current = ""
        var inCue = false
        var cueBuffer = ""

        func flushWord() {
            guard !current.isEmpty else { return }
            tokens.append(.word(current))
            current = ""
        }

        for ch in text {
            if inCue {
                cueBuffer.append(ch)
                if ch == "]" {
                    tokens.append(.cue(cueBuffer))
                    cueBuffer = ""
                    inCue = false
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
            } else {
                current.append(ch)
            }
        }
        if inCue {
            // Unclosed bracket: treat buffered text as plain words.
            for part in cueBuffer.split(whereSeparator: \.isWhitespace) {
                tokens.append(.word(String(part)))
            }
        } else {
            flushWord()
        }
        return tokens
    }

    /// Words only, in order — what the tracking engine consumes.
    public static func words(_ text: String) -> [String] {
        parse(text).compactMap {
            if case .word(let w) = $0 { return w }
            return nil
        }
    }
}
