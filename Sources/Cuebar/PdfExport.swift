import Foundation
import AppKit
import CoreGraphics
import CoreText
import PromptCore

/// Draws the pages `PdfLayout` planned.
///
/// The split is deliberate: the *arithmetic* — what wraps, where a page
/// ends, what the footer says — is in PromptCore and tested; this file only
/// measures text and draws it. A PDF export that silently lost a page
/// because of a rounding error in the renderer would be very hard to see,
/// and impossible to unit test.
///
/// CoreText rather than `NSAttributedString.draw(at:)` inside a "flipped"
/// `NSGraphicsContext`: that trick is for bitmap contexts, and applied to a
/// PDF consumer it produced a page rendered upside down and mirrored — a
/// PDF that opened, looked like a document, and was unreadable. A CTLine
/// drawn at an explicit baseline in Quartz's own coordinate space has no
/// such ambiguity.
enum PdfExport {
    /// Text width in points, via CoreText. NSAttributedString would do it
    /// too, and would also drag in font fallback rules that make the
    /// measurement disagree with what is drawn.
    private static func width(of text: String, font: NSFont) -> Double {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func font(size: Double, bold: Bool) -> NSFont {
        // Helvetica is a PDF base-14 font, so the file needs no font
        // embedding and renders identically on a machine that has never
        // heard of Cuebar.
        let name = bold ? "Helvetica-Bold" : "Helvetica"
        return NSFont(name: name, size: size)
            ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    }

    /// Render one script. Returns nil when the plan is empty — an empty
    /// script has no pages, and writing a zero-page PDF produces a file that
    /// Preview opens as an error.
    static func data(for doc: ScriptDocument) -> Data? {
        let style = PdfLayout.Style()
        let spec = PdfLayout.PageSpec()
        let body = ScriptText.posix(doc.body)

        // One measurement pass per (size, bold, text), reused for the wrap
        // and for the width check that decides a line fits: measuring twice
        // with two different faces is how a bold heading ends up a hair
        // wider than the column it was measured against.
        var cache: [String: Double] = [:]
        func measureWidth(_ text: String, _ size: Double, _ bold: Bool) -> Double {
            let key = "\(size)|\(bold)|\(text)"
            if let hit = cache[key] { return hit }
            let value = width(of: text, font: font(size: size, bold: bold))
            cache[key] = value
            return value
        }

        let pages = PdfLayout.paginate(blocks: PdfLayout.blocks(from: body, title: doc.title),
                                       page: spec, style: style, measure: measureWidth)
        guard !pages.isEmpty else { return nil }

        let media = CGRect(x: 0, y: 0, width: spec.width, height: spec.height)
        var box = media
        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        for page in pages {
            context.beginPDFPage(nil)
            for line in page.lines {
                if line.isFooter {
                    // Near-black for text, grey for furniture: a page of
                    // solid black is heavier on paper than the same page
                    // on screen.
                    draw(context: context, spec: spec, page: page, total: pages.count,
                         title: doc.title, atY: line.y)
                    continue
                }
                draw(context: context, spec: spec, text: line.text,
                     size: line.size, bold: line.bold, y: line.y, grey: false)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return buffer as Data
    }

    /// The running footer: the title on the left, the page on the right.
    private static func draw(context: CGContext, spec: PdfLayout.PageSpec,
                             page: PdfLayout.Page, total: Int, title: String, atY y: Double) {
        if !title.isEmpty {
            draw(context: context, spec: spec, text: title, size: 9, bold: false,
                 y: y, grey: true)
        }
        let stamp = total > 1 ? "\(page.number) of \(total)" : "\(page.number)"
        let size = 9.0
        let stampWidth = width(of: stamp, font: font(size: size, bold: false))
        draw(context: context, spec: spec, text: stamp, size: size, bold: false,
             y: y, grey: true, xOverride: spec.width - spec.marginRight - stampWidth)
    }

    /// One line, at its baseline. `y` is the layout's top-of-line-box,
    /// measured down the page; Quartz counts up from the bottom, so the
    /// conversion happens here and nowhere else.
    private static func draw(context: CGContext, spec: PdfLayout.PageSpec, text: String,
                             size: Double, bold: Bool, y: Double, grey: Bool,
                             xOverride: Double? = nil) {
        guard !text.isEmpty else { return }
        let nsFont = font(size: size, bold: bold)
        let attributed = NSAttributedString(string: text, attributes: [.font: nsFont])
        let line = CTLineCreateWithAttributedString(attributed)
        let baseline = spec.height - y - size
        context.saveGState()
        context.setFillColor(grey ? CGColor(gray: 0.45, alpha: 1) : CGColor(gray: 0.08, alpha: 1))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: xOverride ?? spec.marginLeft, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}