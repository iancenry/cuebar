import Foundation

/// The formats Cuebar reads and writes.
///
/// The type identifier is a plain string rather than a `UTType` so this
/// stays AppKit-free: the panels in the app layer wrap these in
/// `UTType(identifier)`, and the same identifiers are what the bundle's
/// `CFBundleDocumentTypes` declares, so "Open With Cuebar" and the open
/// panel agree by construction instead of by two hand-kept lists.
public enum ScriptFormat: String, CaseIterable, Sendable {
    case plainText
    case markdown
    /// RTF, RTFD, `.doc`, HTML, `.webarchive`, Pages — anything AppKit's
    /// text system can read into one attributed string. Import only: there
    /// is no "export as .doc" worth having when `.docx` exists.
    case richText
    case docx
    case pdf

    /// Everything the open panel and the drop target accept.
    public static let importable: [ScriptFormat] = [
        .plainText, .markdown, .richText, .docx, .pdf,
    ]

    /// What the save panel offers. No `richText`: `.docx` is the Word
    /// format people actually mean, and a second Word format in the same
    /// popup is a question nobody needs to be asked twice.
    public static let exportable: [ScriptFormat] = [
        .plainText, .markdown, .docx, .pdf,
    ]

    public var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown: return "md"
        case .richText: return "rtf"
        case .docx: return "docx"
        case .pdf: return "pdf"
        }
    }

    public var utTypeIdentifier: String {
        switch self {
        case .plainText: return "public.plain-text"
        case .markdown: return "net.daringfireball.markdown"
        case .richText: return "public.rtf"
        case .docx: return "org.openxmlformats.wordprocessingml.document"
        case .pdf: return "com.adobe.pdf"
        }
    }

    /// What the panel's format popup reads. The extension is in it because
    /// the popup *is* the extension picker, and a row reading "Word
    /// document (.docx)" answers the question the user is actually asking.
    public var displayName: String {
        switch self {
        case .plainText: return "Plain Text (.txt)"
        case .markdown: return "Markdown (.md)"
        case .richText: return "Rich Text (.rtf, .doc, .html)"
        case .docx: return "Word Document (.docx)"
        case .pdf: return "PDF Document (.pdf)"
        }
    }

    /// Formats whose payload is text we can read here. Everything else
    /// needs the system readers in the app layer.
    public var isPlainText: Bool { self == .plainText || self == .markdown }

    /// Which reader a file needs. The *decision* is pure and lives here;
    /// only the readers themselves need AppKit.
    ///
    /// The distinction that matters is HTML: it is markup we can strip
    /// ourselves, and AppKit's attributed-string importer would rather
    /// import the stylesheet than the article. Everything else in
    /// `.richText` is a binary format only the text system understands.
    public enum Reader: Equatable, Sendable {
        /// UTF-8 (or a guessed encoding) — decoded in PromptCore.
        case plainText
        /// Markdown in, script syntax out — handled in PromptCore.
        case markdown
        /// HTML in, script body out, by our own converter.
        case html
        /// `NSAttributedString` with an explicit document type.
        case attributed
        /// `PDFDocument`.
        case pdf

    /// Whether reading this needs a framework. One answer, used both to
    /// pre-read files the app layer is responsible for and to route them in
    /// the pure pipeline — two switches would be two answers, and they
    /// would disagree the first time one gained a case.
    public var needsFramework: Bool {
        switch self {
        case .plainText, .markdown, .html: return false
        case .attributed, .pdf: return true
        }
    }

    }

    /// The reader for a filename. Decided on the extension, not the coarse
    /// format: `.rtf` and `.html` are both `.richText` and want completely
    /// different readers, and a `.docx` told to read itself as RTF fails on
    /// every Word file ever saved.
    public static func reader(forFilename name: String) -> Reader {
        switch detect(filename: name) {
        case .plainText: return .plainText
        case .markdown: return .markdown
        case .pdf: return .pdf
        case .docx: return .attributed
        case .richText:
            switch (name as NSString).pathExtension.lowercased() {
            case "html", "htm", "xhtml", "webarchive": return .html
            default: return .attributed
            }
        case nil:
            return .plainText // sniffed as text; refused downstream if not
        }
    }

    /// Extensions that mean this format. Includes the spellings people
    /// actually have on disk (`.text`, `.markdown`, `.mdown`, `.htm`,
    /// `.webarchive`, `.pages`) — a refused open panel is a silent loss.
    public var pathExtensions: Set<String> {
        switch self {
        case .plainText: return ["txt", "text", "log", "textfile"]
        case .markdown: return ["md", "markdown", "mdown", "mkd", "mdtext"]
        case .richText: return ["rtf", "rtfd", "doc", "docm", "html", "htm",
                               "webarchive", "pages", "odt", "wpml"]
        case .docx: return ["docx", "dotx", "docm"]
        case .pdf: return ["pdf"]
        }
    }

    /// Format for a path extension, case-insensitively. `nil` for nothing
    /// we can read, and for no extension at all — an extensionless file is
    /// sniffed as text rather than assumed, because guessing wrong on a
    /// binary produces a script of mojibake instead of an honest refusal.
    public static func detect(pathExtension: String) -> ScriptFormat? {
        let ext = pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return ScriptFormat.allCases.first { $0.pathExtensions.contains(ext) }
    }

    public static func detect(filename: String) -> ScriptFormat? {
        detect(pathExtension: (filename as NSString).pathExtension)
    }

    /// Type identifiers the open panel and the drop target accept, ready
    /// for `UTType(identifier:)`.
    public static var importableTypeIdentifiers: [String] {
        importable.map(\.utTypeIdentifier)
    }

    public static var exportableTypeIdentifiers: [String] {
        exportable.map(\.utTypeIdentifier)
    }

    /// Every extension worth offering in a panel, for `allowedContentTypes`
    /// via `UTType(filenameExtension:)`: the concrete ones plus the
    /// markdown/RTF spellings the system has no type of its own for.
    public static var importableExtensions: [String] {
        importable.flatMap { Array($0.pathExtensions) }
    }
}