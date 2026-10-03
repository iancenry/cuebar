import Foundation

/// Everything that turns *bytes or somebody else's markup* into a script
/// body. Pure and in PromptCore so the rules are tested rather than
/// discovered — a stray zero-width space read as a word, or a Windows
/// line ending collapsing a paragraph, is invisible on screen and audible
/// from the stage.
public enum ScriptText {
    /// Longest single file we will pull into a script. A 300 MB PDF is not
    /// a talk; it is a scanning accident, and decoding it would stall the
    /// import (and the run loop it runs on) for no script at the end.
    public static let maxImportBytes = 24 * 1024 * 1024

    // MARK: - Normalizing

    /// Canonical form for a script body: LF endings, one trailing newline,
    /// no invisible characters, precomposed text.
    ///
    /// The invisible characters are the point. Word and PDF both sprinkle
    /// zero-width spaces and soft hyphens through ordinary words, and the
    /// tokenizer splits on character class — so `Keep` became two
    /// words, the word count was wrong, and voice matching never lined up.
    /// Non-breaking spaces get the same treatment: the tokenizer treats a
    /// NBSP as a separator, which is right for *layout* and wrong for text
    /// that someone typed a space into.
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        // Scalar view, not `[Character]`: rebuilding character by character
        // would split every grapheme cluster — a family emoji or a flag
        // arrives as three Characters and then three words. Appending
        // scalars lets Swift re-cluster them.
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0000...0x0008, 0x000C, 0x000E...0x001F, 0x007F:
                // C0 controls, minus tab (kept) and the separators handled
                // below. Any of these inside a word is a corrupt import.
                view.append(" ")
            case 0x000B, 0x2028, 0x2029:
                // Vertical tab, line/paragraph separators: PDF text
                // extraction is full of them.
                view.append("\n")
            case 0x200B, 0x2060, 0xFEFF, 0x00AD:
                // Zero-width space, word joiner, BOM, soft hyphen:
                // invisible, and a split point. U+200C/U+200D are *not*
                // in this list — they join emoji into one glyph
                // sequence, and damaging a grapheme cluster is worse
                // than the tokenizer splitting one.
                view.append(" ")
            case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                // Every flavour of space the tokenizer would treat as a
                // separator anyway — make it the one it splits on.
                view.append(" ")
            default:
                view.append(scalar)
            }
        }
        var out = String(view)
        out = out.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        var lines = out.components(separatedBy: "\n")
            .map { line -> String in
                // Trailing whitespace is invisible and reads as a pause the
                // presenter didn't ask for.
                var trimmed = line
                while let last = trimmed.last, last == " " || last == "\t" {
                    trimmed.removeLast()
                }
                return trimmed
            }
        while lines.count > 1, lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        // Three newlines is two paragraphs with a gap the prompter already
        // draws; more than that is a formatting accident from Word.
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").precomposedStringWithCanonicalMapping
    }

    /// Strip indentation from every line. For *pasted* text only: a mail
    /// client or a page's source indents for reasons that have nothing to
    /// do with reading aloud. A file keeps its own layout, so an exported
    /// script that comes back in is byte-identical.
    public static func trimLineIndents(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                var out = Substring(line)
                while let first = out.first, first == " " || first == "\t" {
                    out = out.dropFirst()
                }
                return String(out)
            }
            .joined(separator: "\n")
    }

    /// Body as it goes into a *file*. One trailing newline, always: a text
    /// file without one is not POSIX-clean, `cat` glues the next file onto
    /// this one's last line, and every diff of an exported script shows a
    /// phantom change on the last line. Kept apart from `normalize` so an
    /// imported script's body is byte-identical to what the editor shows.
    public static func posix(_ body: String) -> String {
        var text = body
        while text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? "" : text + "\n"
    }

    /// A body worth showing. A file that decodes but holds nothing usable
    /// (a scanned PDF, an empty `.docx`, a page of navigation) has to be
    /// refused rather than imported as a blank script.
    public static func hasScriptText(_ body: String) -> Bool {
        body.contains { !$0.isWhitespace }
    }

    // MARK: - Decoding

    /// Read text out of bytes, guessing the encoding.
    ///
    /// UTF-8 only, like the first version of this, silently refused every
    /// `.txt` a Windows machine wrote — and UTF-8 with a BOM decoded to a
    /// body starting with an invisible character, which the tokenizer then
    /// treated as the first word. Both are cheap to get right, so: BOM
    /// first, then strict UTF-8, then the UTF-16 that a BOM-less Windows
    /// file is, then Latin-1 as a last resort *only if the result still
    /// looks like text*. That last test is what keeps a dropped binary
    /// from importing as a page of mojibake.
    public static func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        let bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        // NUL bytes first. UTF-16 text with no BOM *is* valid UTF-8 — it
        // is `h\0e\0l\0l\0o\0` — so trying UTF-8 first and checking
        // afterwards hands back a body with invisible NULs in it, and
        // those split every word.
        if bytes.contains(0) {
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                if let text = String(data: data, encoding: encoding), looksLikeText(text) {
                    return text
                }
            }
        }
        if let text = String(data: data, encoding: .utf8), looksLikeText(text) {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1), looksLikeText(text) {
            return text
        }
        return nil
    }

    /// Whether a decoded string is prose rather than bytes that happened to
    /// decode. Control characters are the tell: Latin-1 decodes anything,
    /// so without this a dropped `.dmg` imports as a script of garbage.
    static func looksLikeText(_ text: String) -> Bool {
        var suspicious = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: continue
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F:
                suspicious += 1
            default: continue
            }
            if suspicious > 8 { return false }
        }
        return true
    }

    // MARK: - Titles

    /// A presentable title from a filename: extension dropped, separators
    /// tidied, and never blank. `Talk (final) v2.md` reads as "Talk (final)
    /// v2" — the presenter recognised the file by that name, so rewriting
    /// it into something tidier would be worse than keeping it.
    public static func title(fromFilename filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        // A drop can hand over a URL-escaped path; "My%20Talk.docx" as a
        // title is a bug report, not a title.
        name = name.removingPercentEncoding ?? name
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: "%20", with: " ")
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasPrefix(".") { title.removeFirst() }
        while title.hasSuffix(".") { title.removeLast() }
        title = collapseSpaces(title)
        return title.isEmpty ? "Untitled" : title
    }

    /// Title for a fetched page: the document's own `<title>`, falling back
    /// to the site so a page without one still arrives named.
    public static func title(fromHTML html: String, url: URL) -> String {
        if let raw = HTMLText.firstCapture(of: "<title[^>]*>(.*?)</title>", in: html,
                                       options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let decoded = HTMLText.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { return collapseSpaces(decoded) }
        }
        if let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return title(fromFilename: url.lastPathComponent)
    }

    /// The file a drop *tried* to insert, given the text before and after.
    ///
    /// `NSTextView` answers a file drop by inserting the file's path as
    /// text, and it does so before any drop target is consulted — a dropped
    /// `.docx` lands in the script as its own filename. The property is
    /// read-only, so the path cannot be taken off the text view's list of
    /// acceptable types; this finds the insertion instead, so the caller can
    /// undo it and import the document.
    ///
    /// Returns nil unless the *only* difference is an inserted path to a
    /// file that exists and is one we can read. Anything else is the
    /// presenter typing, and must be left alone.
    public static func droppedFile(from old: String, to new: String) -> String? {
        guard new != old, let added = insertedText(from: old, to: new) else { return nil }
        var candidate = added.trimmingCharacters(in: .whitespacesAndNewlines)
        // AppKit quotes a path with spaces in it, and may hand back a URL.
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !candidate.isEmpty else { return nil }
        if candidate.hasPrefix("file:") {
            guard let url = URL(string: candidate) else { return nil }
            candidate = url.path
        }
        candidate = candidate.removingPercentEncoding ?? candidate
        guard ScriptFormat.detect(filename: candidate) != nil else { return nil }
        return candidate
    }

    /// The single run of text that was added between two revisions, or nil
    /// if that isn't what happened. A prefix/suffix comparison rather than a
    /// diff: the insertion is one token, and a real edit changes more than
    /// one end at once.
    static func insertedText(from old: String, to new: String) -> String? {
        guard new.hasPrefix(old) || old.hasPrefix(new) else { return nil }
        let difference = new.count > old.count
            ? String(new.dropFirst(old.count))
            : String(old.dropFirst(new.count))
        let added = difference.trimmingCharacters(in: .whitespacesAndNewlines)
        return added.isEmpty ? nil : added
    }

    /// Make a title unique against titles already in the library. Two
    /// scripts called "Talk" must both survive an import, and the second
    /// one is the one the user is looking at afterwards.
    public static func uniqueTitle(_ base: String, against existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    static func collapseSpaces(_ text: String) -> String {
        var out = ""
        var space = false
        for character in text {
            if character == " " || character == "\t" {
                space = true
                continue
            }
            if space, !out.isEmpty { out.append(" ") }
            space = false
            out.append(character)
        }
        return out
    }
}