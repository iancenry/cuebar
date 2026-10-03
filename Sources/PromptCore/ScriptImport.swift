import Foundation

/// Turning files, a pasteboard, or a web page into scripts.
///
/// The whole pipeline lives here rather than in the panel: what to do with
/// a 90 MB file, with a file whose text is empty, with two files both
/// called "Talk", and with a `.md` that is really a page of `**bold**` are
/// rules, and rules are what PromptCore exists to hold. The app layer
/// supplies one thing the pure side can't do — read the formats only the
/// system can read.
public enum ScriptImport {
    /// One file handed in, already read into memory. Reading is the caller's
    /// job because it needs the file system; everything after it is ours.
    public struct Item: Sendable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }

        public var format: ScriptFormat? { ScriptFormat.detect(filename: name) }
        public var proposedTitle: String { ScriptText.title(fromFilename: name) }
    }

    public enum Failure: Equatable, Sendable {
        /// Nothing we can read: an unknown extension, or a binary.
        case unsupportedFormat
        /// Too big to be a talk. Decoding it would stall the import.
        case tooLarge(bytes: Int)
        /// The format is ours but the contents wouldn't decode — a corrupt
        /// file, or a PDF that is a scan.
        case unreadable
        /// Decoded fine, holds no words. A blank script is not an import.
        case empty
    }

    public struct Rejected: Equatable, Sendable {
        public var name: String
        public var reason: Failure

        public init(name: String, reason: Failure) {
            self.name = name
            self.reason = reason
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var scripts: [ImportedScript]
        public var rejected: [Rejected]

        public init(scripts: [ImportedScript], rejected: [Rejected]) {
            self.scripts = scripts
            self.rejected = rejected
        }

        public var isEmpty: Bool { scripts.isEmpty }
        public var titles: [String] { scripts.map(\.title) }
    }

    /// `decode` reads the formats the pure side cannot: Word documents and
    /// PDFs, both of which need a framework. It is `@Sendable` because it
    /// may be called off the main actor — and per the constraint in
    /// AGENTS.md that annotation promises nothing about isolation, so the
    /// app layer does its reading *before* calling this and hands the
    /// results in. (Do not reach for `MainActor.assumeIsolated` in there:
    /// this runs synchronously from a run-loop callback — a modal panel
    /// handler — with no Task to suspend on, which is the SIGBUS trap.)
    ///
    /// It is handed the item's index as well as the item, because a closure
    /// that has to identify an item again to find its answer is a closure
    /// that can find the wrong one.
    ///
    /// Returning nil means "couldn't read it", and the file is reported as
    /// rejected rather than dropped in silence.
    public static func plan(items: [Item], existingTitles: [String] = [],
                            decode: @Sendable (Int, Item) -> String?) -> Outcome {
        var scripts: [ImportedScript] = []
        var rejected: [Rejected] = []
        var taken = existingTitles
        for (index, item) in items.enumerated() {
            guard item.data.count <= ScriptText.maxImportBytes else {
                rejected.append(Rejected(name: item.name, reason: .tooLarge(bytes: item.data.count)))
                continue
            }
            guard let body = text(for: item, decode: { decode(index, $0) }) else {
                rejected.append(Rejected(name: item.name, reason: unreadableReason(for: item)))
                continue
            }
            let normalized = ScriptText.normalize(body)
            guard ScriptText.hasScriptText(normalized) else {
                rejected.append(Rejected(name: item.name, reason: .empty))
                continue
            }
            let title = ScriptText.uniqueTitle(item.proposedTitle, against: taken)
            taken.append(title)
            scripts.append(ImportedScript(title: title, body: normalized))
        }
        return Outcome(scripts: scripts, rejected: rejected)
    }

    /// Text for one item. Routed by `ScriptFormat.reader`, the same
    /// decision the app layer uses to decide what it must pre-read: HTML is
    /// ours to strip, and only Word documents and PDFs need a framework.
    static func text(for item: Item, decode: (Item) -> String?) -> String? {
        switch ScriptFormat.reader(forFilename: item.name) {
        case .plainText:
            return ScriptText.decode(item.data)
        case .markdown:
            // Markdown is stripped into script syntax: headings stay
            // (they become sections), inline markup goes, so nothing says
            // "star star" from the stage.
            return ScriptText.decode(item.data).map(MarkdownText.plainBody)
        case .html:
            return ScriptText.decode(item.data).map(HTMLText.plainBody)
        case .attributed, .pdf:
            return decode(item)
        }
    }

    /// Distinguish "we have no reader for this" from "this file is broken",
    /// because the two need different advice.
    static func unreadableReason(for item: Item) -> Failure {
        // An unknown extension can still arrive here — an extensionless text
        // file that turned out to be binary — and that is a reader problem.
        item.format == nil ? .unsupportedFormat : .unreadable
    }

    /// A script built from a body, with the title rules applied. Used by
    /// the clipboard and web paths, which have no file to take a name from.
    public static func fromBody(_ body: String, title: String,
                                existingTitles: [String] = []) -> ImportedScript? {
        let normalized = ScriptText.normalize(ScriptText.trimLineIndents(body))
        guard ScriptText.hasScriptText(normalized) else { return nil }
        return ImportedScript(
            title: ScriptText.uniqueTitle(ScriptText.collapseSpaces(title).isEmpty
                                          ? "Untitled"
                                          : ScriptText.collapseSpaces(title),
                                          against: existingTitles),
            body: normalized)
    }
}

/// A script ready to be stored. `ImportedScript` and `ScriptDocument` are
/// deliberately different types: this one has no id, no folder and no
/// timestamps, so the import pipeline cannot half-populate a document.
public struct ImportedScript: Equatable, Sendable {
    public var title: String
    public var body: String
    /// Where the caller decided it should be filed. `nil` is Unfiled, the
    /// same as any other script — the import pipeline doesn't invent a
    /// destination.
    public var folderID: UUID?

    public init(title: String, body: String, folderID: UUID? = nil) {
        self.title = title
        self.body = body
        self.folderID = folderID
    }
}