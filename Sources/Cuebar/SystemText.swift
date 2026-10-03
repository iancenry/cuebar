import Foundation
import AppKit
import PDFKit
import PromptCore

/// Text out of the formats only the system can read.
///
/// Everything here is `@MainActor` and hop-explicit, for the reason in
/// AGENTS.md: a `@Sendable` completion handed back by a framework runs on
/// that framework's queue no matter what the compiler inferred at the call
/// site. `ScriptImport`'s decoder is `@Sendable` because it may be called
/// from anywhere, so the hop lives *inside* the closures below rather than
/// being assumed by the caller.
@MainActor
enum SystemText {
    /// Word documents, RTF, `.doc`, HTML, `.webarchive`, Pages — anything
    /// AppKit's text system understands. `NSAttributedString` is the reader
    /// here because it is the same engine Pages, TextEdit and `textutil`
    /// use, so a Google Docs export and a Word file both come through as
    /// clean paragraphs instead of the XML soup a hand-rolled parser sees.
    ///
    /// The document type is chosen from the *extension*, and there is a
    /// sniff fallback underneath: insisting that HTML is RTF fails on every
    /// HTML file ever written, and a file that imports as nothing is a file
    /// the user believes they imported.
    static func attributed(from item: ScriptImport.Item) -> String? {
        let type: NSAttributedString.DocumentType?
        switch item.format {
        case .richText: type = .rtf
        case .docx: type = .officeOpenXML
        default: type = nil
        }
        if let type,
           let attributed = try? NSAttributedString(data: item.data,
                                                   options: [.documentType: type],
                                                   documentAttributes: nil) {
            return attributed.string
        }
        // Let AppKit work it out from the bytes: a `.doc` told to read as
        // RTF, or a Word file from a tool that saved something slightly
        // off-spec, is exactly the case where sniffing beats insisting.
        if let sniffed = try? NSAttributedString(data: item.data, options: [:],
                                                 documentAttributes: nil) {
            return sniffed.string
        }
        return nil
    }

    /// PDF text, page by page. PDFKit rather than a parser in PromptCore:
    /// a PDF's text lives behind font encodings and compressed streams, and
    /// the failure mode of getting that wrong is not a crash but a script
    /// full of mojibake presented to an audience.
    ///
    /// A scanned PDF has no text layer, so it comes back empty — which the
    /// import pipeline reports as "nothing to read" rather than importing a
    /// blank script.
    static func pdf(from data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string else { continue }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    /// The decoder `ScriptImport` calls for the formats it can't read.
    /// Reads from `Data`, so it works for a dropped file, a pasteboard
    /// attachment and an `open` event alike.
    /// The reader for one item, for the formats `ScriptFormat.Reader` says
    /// need a framework. HTML never arrives here: it is markup, and
    /// `HTMLText` strips it without a framework at all.
    static func decode(_ item: ScriptImport.Item) -> String? {
        switch ScriptFormat.reader(forFilename: item.name) {
        case .plainText, .markdown, .html:
            return nil
        case .attributed:
            return attributed(from: item)
        case .pdf:
            return pdf(from: item.data)
        }
    }

    /// Rich pasteboard flavours, in the order a person would want them.
    ///
    /// Plain text first, deliberately: the text a browser or Word puts on
    /// the pasteboard is already the readable version of what they copied,
    /// and re-deriving it from HTML is how you get a paragraph split at
    /// every tag. RTF is the fallback for a copy from an app that offers
    /// only that.
    static func clipboardText() -> (body: String, title: String?)? {
        let board = NSPasteboard.general
        if let text = board.string(forType: .string), !text.isEmpty {
            return (text, nil)
        }
        if let html = board.string(forType: .html) {
            return (HTMLText.plainBody(html), nil)
        }
        if let rtf = board.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return (attributed.string, nil)
        }
        return nil
    }

    /// Files on the pasteboard, read lazily: Finder puts a list of URLs
    /// there, and "paste a screenshot of a PDF" should import the PDF.
    static func clipboardFiles() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                  options: options) as? [URL]) ?? []
    }
}