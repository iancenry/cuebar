import Foundation

/// Markdown in, script body out.
///
/// The script format *is* a Markdown subset — headings and `[cues]` — so
/// the job here is to keep the parts Cuebar understands and drop the parts
/// it would otherwise read aloud. `**bold**` read as "star star bold star
/// star" is the failure this file exists to prevent, and so is
/// `[Documentation](https://…)` read as "Documentation link https".
///
/// Deliberately *not* stripped: headings. `#`/`##`/`###` become prompter
/// sections, which is exactly what a Markdown outline should become.
public enum MarkdownText {
    public static func plainBody(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        for rawLine in markdown.components(separatedBy: "\n") {
            let fence = rawLine.trimmingCharacters(in: .whitespaces)
            if fence.hasPrefix("```") || fence.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            // Inside a fence the text is verbatim — it is code, and code
            // the presenter chose to keep is still their words.
            if inFence { out.append(rawLine); continue }
            // nil is "this line was markup, not content" — a rule or a
            // table divider. Blank lines are kept: they are paragraphs,
            // and dropping a dropped line's empty string would take the
            // paragraph break around it as well.
            if let line = line(rawLine) { out.append(line) }
        }
        return ScriptText.normalize(out.joined(separator: "\n"))
    }

    /// One source line to one script line, or nil when the line was markup
    /// rather than words.
    static func line(_ raw: String) -> String? {
        if isRule(raw) { return nil }
        if isTableRule(raw) { return nil }
        if let heading = headingLine(raw) { return heading }
        if let table = tableLine(raw) { return table }
        var line = raw
        // Indentation is layout in a script; the prompter does its own.
        while line.hasPrefix("    ") || line.hasPrefix("\t") { line.removeFirst() }
        if let bullet = listPrefix(line) { line = String(line.dropFirst(bullet.count)) }
        while line.hasPrefix("> ") || line.hasPrefix(">") {
            line = String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1))
            if line.hasPrefix(" ") { line.removeFirst() }
        }
        return inline(line).trimmingCharacters(in: .whitespaces)
    }

    /// A `---`/`***` rule. Checked before the list-marker strip, or every
    /// thematic break would come back as an empty bullet.
    static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// `|---|---|` — the header rule of a table. Kept only to be dropped.
    static func isTableRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") || trimmed.contains("---") else { return false }
        let withoutPipes = trimmed.replacingOccurrences(of: "|", with: "")
        let allowed = Set("-: ")
        return !withoutPipes.isEmpty
            && withoutPipes.allSatisfy { allowed.contains($0) }
            && withoutPipes.contains("-")
    }

    /// A heading, clamped to the three levels the tokenizer reads. Deeper
    /// levels come back as plain words rather than four hashes, which the
    /// parser would read aloud.
    static func headingLine(_ raw: String) -> String? {
        let trimmed = raw.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // ATX requires a space after the hashes; `#hashtag` is a word and
        // must stay one (the tokenizer applies the same rule).
        guard rest.hasPrefix(" ") else { return nil }
        let name = inline(String(rest).trimmingCharacters(in: .whitespaces))
        let level = min(hashes, 3)
        return name.isEmpty ? "" : "\(String(repeating: "#", count: level)) \(name)"
    }

    static func listPrefix(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return marker
        }
        // `1. ` / `1) ` — the digits only, so "2026. was a year" survives.
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return String(digits) + (rest.hasPrefix(". ") ? ". " : ") ")
            }
        }
        return nil
    }

    /// A table row becomes its cells, comma separated. The pipes are
    /// layout; read aloud they are noise, and dropping the row entirely
    /// would silently lose the one table a script usually contains.
    static func tableLine(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.hasPrefix("|") || trimmed.hasSuffix("|") else {
            return nil
        }
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { inline(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        guard !cells.isEmpty else { return nil }
        return cells.joined(separator: ", ")
    }

    /// The inline span syntax: emphasis, code, links, images, footnotes,
    /// and any raw HTML tag someone left in the file.
    static func inline(_ text: String) -> String {
        var out = text
        // Order matters, longest delimiter first: `**` before `*`, and
        // links before emphasis so `[**bold**](x)` loses its link once.
        for rule in inlineRules {
            out = replacing(out, pattern: rule.pattern, template: rule.template)
        }
        return out
    }

    private static let inlineRules: [(pattern: String, template: String)] = [
        // Images carry no words a presenter wants; the alt text is a
        // filename more often than not.
        ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),
        ("!\\[[^\\]]*\\]\\[[^\\]]*\\]", ""),
        ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        ("\\[([^\\]]*)\\]\\[[^\\]]*\\]", "$1"),
        // Autolinks and bare angle-bracket brackets.
        ("<((?:https?|mailto):[^>\\s]+)>", "$1"),
        // Footnote and reference marks.
        ("\\s*\\[\\^[^\\]]*\\]", ""),
        // Code spans keep their text: a config value in a script is a
        // thing the presenter says out loud.
        ("`([^`]*)`", "$1"),
        ("\\*\\*([^*]+)\\*\\*", "$1"),
        ("__([^_]+)__", "$1"),
        ("~~([^~]+)~~", "$1"),
        // Emphasis, with CommonMark's flanking rule rather than a looser
        // one: an opening delimiter may not be followed by a space, and a
        // closing one may not be preceded by one. That is what keeps
        // `2 * 3 * 4` and `snake_case_helper` as they were written — a
        // script full of arithmetic is not italicised by a typo in a
        // converter.
        ("(?<![\\w*\\\\])\\*(?=\\S)([^*\\n]*?\\S)\\*(?![\\w*])", "$1"),
        ("(?<![\\w_\\\\])_(?=\\S)([^_\\n]*?\\S)_(?![\\w_])", "$1"),
        // A stray <br> or closing tag from pasted HTML.
        ("<\\s*br\\s*/?\\s*>", " "),
        ("</?[a-zA-Z][^>]*>", ""),
    ]

    static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard !text.isEmpty else { return text }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}