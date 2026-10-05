import Foundation

/// Cuebar's library as files on disk.
///
/// One Markdown file per script, in real folders, so the library is something
/// a person owns rather than something an app hides: it can be opened in
/// another editor, searched with `grep`, put in iCloud, backed up per script,
/// and — the reason this exists at all — read without this app.
///
/// Two decisions that shape everything else:
///
/// - **The title is the filename.** One source of truth. A rename in Finder
///   retitles the script, because anything else means two names that can
///   disagree, and a teleprompter that shows "Draft 3" over a file called
///   "Keynote.md" is worse than one that shows "Keynote.md".
/// - **Front matter is written only when there is metadata to keep.** A script
///   nobody has tagged or opened is a plain `.md` file with the talk in it.
///   The moment something needs remembering — an id, tags, a favourite, an
///   archive flag — a small `---` block appears above the script, in the
///   convention every Markdown tool understands.
public enum ScriptFile {
    public static let extensionName = "md"

    // MARK: - Front matter

    /// Everything Cuebar remembers that the script text cannot say.
    public struct Metadata: Equatable, Sendable {
        public var id: UUID
        public var created: Date
        public var lastOpened: Date?
        public var tags: [String]
        public var isFavorite: Bool
        public var isArchived: Bool
        /// Whether this id came off a disk rather than being minted for a new
        /// script. Once a file has an id, dropping it on the next save would
        /// give the script a new identity — and a new identity is a script
        /// that vanished from every list that referred to the old one.
        public var isEstablished: Bool

        public init(id: UUID = UUID(), created: Date = Date(), lastOpened: Date? = nil,
                    tags: [String] = [], isFavorite: Bool = false, isArchived: Bool = false,
                    isEstablished: Bool = false) {
            self.isEstablished = isEstablished
            self.id = id
            self.created = created
            self.lastOpened = lastOpened
            self.tags = tags
            self.isFavorite = isFavorite
            self.isArchived = isArchived
        }

        /// Is there anything here a plain script file should not carry?
        ///
        /// An id always is, once written, so "needs front matter" is about
        /// *this* script's history rather than about the format. A brand-new
        /// untitled script therefore starts as pure text and grows the block
        /// the first time the app has something to record.
        public var isEmptyForAFile: Bool {
            !isEstablished && tags.isEmpty && !isFavorite && !isArchived && lastOpened == nil
        }
    }

    /// The keys a file may carry. Anything else in the block is somebody's
    /// own front matter — Jekyll's `layout:`, a note, a date format — and is
    /// left alone rather than dropped.
    static let keys: Set<String> = ["id", "created", "opened", "tags",
                                    "favorite", "archived"]

    public static func render(_ body: String, metadata: Metadata?) -> String {
        guard let metadata, !metadata.isEmptyForAFile else { return body }
        var lines: [String] = ["---", "id: \(metadata.id.uuidString)"]
        let formatter = ISO8601DateFormatter()
        // Fractional seconds, because whole seconds are not enough: two
        // scripts opened in the same second used to tie, and which one Cuebar
        // reopened then came down to sort order.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lines.append("created: \(formatter.string(from: metadata.created))")
        if let opened = metadata.lastOpened {
            lines.append("opened: \(formatter.string(from: opened))")
        }
        if !metadata.tags.isEmpty {
            lines.append("tags: [\(metadata.tags.joined(separator: ", "))]")
        }
        if metadata.isFavorite { lines.append("favorite: true") }
        if metadata.isArchived { lines.append("archived: true") }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    public struct Parsed: Equatable, Sendable {
        public var body: String
        public var metadata: Metadata?
        /// Whether the block carried an id. A block without one is still front
        /// matter — a half-written file must not silently become a new script.
        public var hadIdentity: Bool
    }

    public static func parse(_ text: String) -> Parsed {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---", lines.count > 1 else {
            return Parsed(body: text, metadata: nil, hadIdentity: false)
        }
        guard let closing = lines.indices.dropFirst().first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return Parsed(body: text, metadata: nil, hadIdentity: false)
        }

        // A script whose text begins with `---` is not metadata: it is a talk
        // that opens with a horizontal rule. Only a block carrying an `id` or a
        // `created` line counts as front matter — Cuebar writes one of those
        // whenever it writes a block at all, so requiring them costs nothing
        // and protects a talk that opens with a rule *and* happens to have a
        // line like `archived: true` in it (a talk about Cuebar, for instance).
        let raw = lines[1..<closing].reduce(into: [String: String]()) { fields, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else { return }
            let key = trimmed[trimmed.startIndex..<separator].lowercased()
            guard ScriptFile.keys.contains(key) else { return }
            fields[key] = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard raw["id"] != nil || raw["created"] != nil else {
            return Parsed(body: text, metadata: nil, hadIdentity: false)
        }

        var metadata = Metadata()
        var sawField = false
        for line in lines[1..<closing] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator]).lowercased()
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "id":
                if let id = uuid(from: value) { metadata.id = id; sawField = true }
            case "created":
                if let date = parseDate(value) { metadata.created = date; sawField = true }
            case "opened":
                if let date = parseDate(value) {
                    metadata.lastOpened = date
                    sawField = true
                }
            case "tags":
                // A comma separates tags, so one cannot contain a comma. They
                // are written as a flat list rather than quoted, and a tag with
                // a comma in it came back as two tags on every relaunch.
                let inner = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                metadata.tags = inner.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                sawField = true
            case "favorite":
                metadata.isFavorite = (value as NSString).boolValue
                sawField = true
            case "archived":
                metadata.isArchived = (value as NSString).boolValue
                sawField = true
            default:
                break
            }
        }

        var body = lines[(closing + 1)...].joined(separator: "\n")
        // Exactly one blank line separates the block from the talk, so that a
        // script may open with a rule of its own. Take that one line back off
        // — no more, no less: a script that legitimately begins with a blank
        // line keeps it, and one saved a hundred times does not grow a
        // hundred blank lines.
        if body.hasPrefix("\n") { body.removeFirst() }
        metadata.isEstablished = sawField
        return Parsed(body: body, metadata: sawField ? metadata : nil,
                      hadIdentity: sawField)
    }

    /// A UUID in any of the shapes people and other tools write.
    ///
    /// `UUID(uuidString:)` refuses the braced form YAML emitters produce
    /// (`{550E8400-…}`) and the unhyphenated one, and the silent failure was
    /// expensive: the script was read with a *fresh* id and the next save wrote
    /// that new id into the file, so the identity the user's other tools knew
    /// was gone for good.
    static func uuid(from text: String) -> UUID? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        if trimmed.lowercased().hasPrefix("urn:uuid:") {
            trimmed = String(trimmed.dropFirst(9))
        }
        if let id = UUID(uuidString: trimmed) { return id }
        let hex = trimmed.filter { $0.isHexDigit }
        return hex.count == 32 ? UUID(uuidString: String(hex.prefix(8)) + "-"
            + String(hex.dropFirst(8).prefix(4)) + "-"
            + String(hex.dropFirst(12).prefix(4)) + "-"
            + String(hex.dropFirst(16).prefix(4)) + "-"
            + String(hex.dropFirst(20))) : nil
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: text) { return date }
        // A hand-edited file may carry a bare date.
        whole.formatOptions = [.withFullDate]
        return whole.date(from: text)
    }

    /// Where the `[cue]` spans are, in UTF-16 offsets (NSRange's unit).
    ///
    /// Shared by the things that must not touch a cue: the offline tidy, which
    /// rewrites brackets and dashes, and anything else that edits prose. An
    /// unclosed `[` is not a span — it is words, and the parser says so.
    public static func cueRanges(of text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var start: Int?
        for index in 0..<ns.length {
            let character = ns.substring(with: NSRange(location: index, length: 1))
            if character == "[" {
                // A cue starts a token. `array[0]` is an index, not a cue.
                // The tokenizer's rule, exactly: a `[` starts a cue when it
                // starts a *token*, and a token starts after any whitespace —
                // including a non-breaking space, which is what a Word or a web
                // page puts in front of a bracket. Testing three ASCII
                // characters here meant the tidy rewrote a cue the prompter
                // still treated as one.
                if start == nil, index == 0
                    || CharacterSet.whitespacesAndNewlines.contains(
                        Unicode.Scalar(ns.substring(
                            with: NSRange(location: index - 1, length: 1)).unicodeScalars.first!)
                    ) {
                    start = index
                }
            } else if character == "]" {
                if let begin = start {
                    // No exception for `[label](url)`: the parser reads that as
                    // a cue followed by words, so on stage the label *is* a
                    // cue, and protecting only the words around it is not
                    // protection.
                    out.append(NSRange(location: begin, length: index - begin + 1))
                    start = nil
                }
            }
        }
        return out
    }

    /// The script with its cues removed — what a rule that must not touch a cue
    /// is allowed to reason about.
    public static func withoutCues(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for range in cueRanges(of: text).sorted(by: { $0.location < $1.location }) {
            guard range.location >= cursor else { continue }
            out += ns.substring(with: NSRange(location: cursor,
                                              length: range.location - cursor))
            cursor = range.location + range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Filenames

    /// A title as a filename that macOS will accept and a person can read.
    ///
    /// The illegal set is `/ : \ ? % * | " < >` plus a leading dot, control
    /// characters, and — the one people hit without noticing — a trailing
    /// space or a name that is `.` or `..`.
    public static func filename(for title: String) -> String {
        var out = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        out = out.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) }
            .reduce(into: "") { $0.append($1) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") { out.removeLast() }
        // A leading dot hides the file from Finder and from this app's own
        // scanner, so a script titled ".hidden" would simply disappear.
        if out.hasPrefix(".") { out = "-" + out.dropFirst() }
        if out.isEmpty { out = "Untitled" }
        // 255 bytes is the filesystem limit; leave room for the extension and
        // for a " 2" suffix when a name collides.
        if out.utf8.count > 200 { out = String(out.prefix(100)) }
        return out
    }

    /// A filename no other script in `directory` is already using, comparing
    /// the way the filesystem does: case-insensitively, because APFS is.
    public static func uniqueFilename(_ name: String, in directory: URL,
                                      ignoring ignored: Set<String> = []) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
        let existing = names.filter { $0.lowercased().hasSuffix("." + extensionName) }
        let taken = Set(existing.map { $0.lowercased() })
            .subtracting(ignored.map { $0.lowercased() })
        guard taken.contains((name + "." + extensionName).lowercased()) else { return name }
        var counter = 2
        while taken.contains("\(name) \(counter).\(extensionName)".lowercased()) { counter += 1 }
        return "\(name) \(counter)"
    }
}
