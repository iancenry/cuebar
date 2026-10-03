import Foundation

/// HTML in, script body out.
///
/// Used for two things that arrive as markup and must arrive as words: a
/// fetched web page, and the rich flavour of the pasteboard when someone
/// copies out of a browser. The alternative — AppKit's attributed-string
/// HTML importer — is better at typography, and worse here for two reasons:
/// it needs the main thread (the fetch completes on a queue, and per
/// AGENTS.md a `@Sendable` callback's isolation is not a guarantee), and it
/// imports CSS-derived whitespace. A script wants the words and the
/// paragraph breaks.
public enum HTMLText {
    public static func plainBody(_ html: String) -> String {
        var text = html
        // Elements whose *contents* are not prose. Dropped whole, tags
        // included: stripping tags alone would leave a stylesheet's rules
        // and a script's source in the middle of the script.
        for element in ["script", "style", "noscript", "template", "svg",
                        "canvas", "iframe", "head", "form", "button", "select"] {
            text = dropping(element, from: text)
        }
        // Comments can hide whole stylesheets.
        text = replacing(text, pattern: "<!--.*?-->", template: "", options: .dotMatchesLineSeparators)
        // Whitespace-only markup between block tags collapses to nothing,
        // so `<p>a</p>\n  <p>b</p>` doesn't become a paragraph break per
        // indent level.
        text = replacing(text, pattern: "[ \t\r\n]+", template: " ", options: [])

        var out = ""
        var last = text.startIndex
        guard let regex = try? NSRegularExpression(pattern: "</?[a-zA-Z][^>]*>|<[^>]+>") else {
            return ScriptText.normalize(decodeEntities(text))
        }
        while last < text.endIndex {
            let range = NSRange(last..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let tagRange = Range(match.range, in: text) else { break }
            out += String(text[last..<tagRange.lowerBound])
            out += separation(for: String(text[tagRange]))
            last = tagRange.upperBound
        }
        out += String(text[last...])
        out = decodeEntities(out)
        out = replacing(out, pattern: "[ \t]+\n", template: "\n", options: [])
        out = replacing(out, pattern: "\n{3,}", template: "\n\n", options: [])
        // Indentation in a page is the layout of the original site; in a
        // script read aloud it is nothing at all.
        out = replacing(out, pattern: "^[ \\t]+", template: "", options: [.anchorsMatchLines])
        return ScriptText.normalize(out)
    }

    /// What a tag means as a break. Block-level ends are paragraphs, not
    /// line breaks — the prompter draws the gap itself, and a line break per
    /// `<div>` would fragment every wrapped paragraph.
    static func separation(for tag: String) -> String {
        let isClosing = tag.hasPrefix("</")
        let name = tag.dropFirst().drop(while: { $0 == "/" }).lowercased()
            .prefix(while: { $0.isLetter })
        switch name {
        case "br":
            return "\n"
        case "p", "div", "section", "article", "aside", "header", "footer",
             "main", "nav", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "table",
             "ul", "ol", "dl", "blockquote", "pre", "figure", "address":
            return "\n\n"
        case "li", "dd", "dt":
            // A bullet is layout. Keep the words, drop the marker — and
            // break *between* items, not between the words and the tag,
            // which would make every other item its own paragraph.
            return isClosing ? "" : "\n"
        default:
            return ""
        }
    }

    /// Element contents removed, tags included.
    static func dropping(_ element: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: element)
        return replacing(text, pattern: "<\(escaped)\\b[^>]*>.*?</\(escaped)\\s*>",
                         template: "", options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    // MARK: - Entities

    /// The named entities that actually turn up in prose. The full HTML5
    /// table is 2 000 entries; these are the ones a page or a Word
    /// document produces, and an unknown `&thing;` is left alone rather
    /// than eaten (`&amp;x=1` must keep its semicolon).
    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "bull": "•", "middot": "·", "dagger": "†", "Dagger": "‡",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§",
        "para": "¶", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
        "minus": "−", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤",
        "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞", "micro": "µ",
        "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç",
        "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
        "ntilde": "ñ", "aacute": "á", "iacute": "í", "oacute": "ó",
        "uacute": "ú", "aring": "å", "oslash": "ø",
        "shy": "", "zwj": "", "zwnj": "", "lrm": "", "rlm": "",
    ]

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            // Longest entity bodies are short; 12 is past `#x1D7FF`… no:
            // numeric references run to `&#128512;`.
            let limit = text.index(index, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            let searchEnd = min(limit, text.endIndex)
            guard let semicolon = text[index..<searchEnd].firstIndex(of: ";"),
                  semicolon != index else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let body = String(text[text.index(after: index)..<semicolon])
            if let replacement = entity(body) {
                out.append(replacement)
                index = text.index(after: semicolon)
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    static func entity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = String(body.dropFirst())
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return namedEntities[body]
    }

    // MARK: - Helpers

    /// Contents of the first `<tag>…</tag>` capture group.
    static func firstCapture(of pattern: String, in text: String,
                             options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let inner = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[inner])
    }

    static func replacing(_ text: String, pattern: String, template: String,
                          options: NSRegularExpression.Options) -> String {
        guard !text.isEmpty else { return text }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}