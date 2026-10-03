import Foundation

/// Line breaking and page breaking for the PDF export.
///
/// Pure, and taking the *measurement* as a parameter, because measuring is
/// the one part that needs a font engine. The app layer hands in a closure
/// built on CoreText; here the arithmetic is a greedy wrap and a height
/// budget, both of which can be fuzzed without a graphics context — and a
/// collapsed page is the failure a PDF cannot show you before you are ten
/// pages into it.
public enum PdfLayout {
    public struct PageSpec: Equatable, Sendable {
        /// US Letter at 72dpi. Letter rather than A4 because this is a
        /// print-and-carry script on a machine whose paper is whatever
        /// paper is.
        public var width: Double = 612
        public var height: Double = 792
        public var marginTop: Double = 72
        public var marginBottom: Double = 66
        public var marginLeft: Double = 72
        public var marginRight: Double = 72

        public init() {}

        public var columnWidth: Double { width - marginLeft - marginRight }
        /// Bottom of the last line that may be drawn, above the footer.
        public var textBottom: Double { height - marginBottom }
    }

    public struct Style: Equatable, Sendable {
        public var titleSize: Double = 26
        public var headingSizes: [Double] = [19, 15.5, 13.5]
        public var bodySize: Double = 12.5
        public var lineHeightMultiple: Double = 1.5
        public var paragraphGap: Double = 11
        public var headingGapBefore: Double = 20
        public var titleGapAfter: Double = 22
        /// Room reserved for the running footer. Without it the last line
        /// of every page sits under the page number.
        public var footerReserve: Double = 24
        public var showsFooter: Bool = true

        public init() {}

        public func headingSize(level: Int) -> Double {
            let index = max(1, min(level, headingSizes.count)) - 1
            return headingSizes[index]
        }
    }

    public enum Block: Equatable, Sendable {
        case title(String)
        case heading(level: Int, text: String)
        case paragraph(String)
    }

    public struct Line: Equatable, Sendable {
        public var text: String
        public var size: Double
        public var bold: Bool
        /// Distance from the top of the page, so the renderer draws without
        /// tracking its own baseline — the layout and the drawing can't
        /// disagree about where a line is.
        public var y: Double
        public var isHeading: Bool
        public var isFooter: Bool
    }

    public struct Page: Equatable, Sendable {
        public var number: Int
        public var lines: [Line]
    }

    /// The script as blocks. Blank lines become paragraph ends, so a blank
    /// line in the editor is a blank line in the PDF.
    public static func blocks(from body: String, title: String) -> [Block] {
        var blocks: [Block] = []
        if !title.isEmpty { blocks.append(.title(title)) }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // One blank paragraph between two text blocks, not three:
                // the gap is already in the style.
                if case .paragraph = blocks.last { blocks.append(.paragraph("")) }
                continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if hashes >= 1, hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                let name = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    blocks.append(.heading(level: min(hashes, 3), text: name))
                    continue
                }
            }
            blocks.append(.paragraph(trimmed))
        }
        return blocks
    }

    /// Break the blocks into pages of lines. `measure(text, size, bold)`
    /// returns the drawn width in points for that face — bold Helvetica is
    /// wider than regular, so measuring a heading with the regular face is
    /// how a section title ends up past the right margin.
    public static func paginate(blocks: [Block], page: PageSpec = .init(),
                                style: Style = .init(),
                                measure: (String, Double, Bool) -> Double) -> [Page] {
        let column = page.columnWidth
        let bottom = page.textBottom - (style.showsFooter ? style.footerReserve : 0)
        var lines: [Line] = []
        var pages: [Page] = []
        /// Top of the next line box, measured down the page.
        var y = page.marginTop

        // The footer's text is left empty: the renderer knows the title and
        // the total page count, and a string baked in here would be a
        // second place the page numbering is decided.
        func footerLine() -> Line {
            Line(text: "", size: 9, bold: false, y: page.height - 34,
                 isHeading: false, isFooter: true)
        }

        /// Close the page in progress and start the next one. Called only on
        /// a break: page 1 is opened by the first line, so there is never a
        /// blank sheet in front of the script and the numbering starts at 1.
        func newPage() {
            if style.showsFooter { lines.append(footerLine()) }
            pages.append(Page(number: pages.count + 1, lines: lines))
            lines = []
            y = page.marginTop
        }

        /// A line's `y` is where its text starts, so the renderer draws
        /// exactly where the arithmetic said and cannot drift by a leading.
        func place(_ text: String, size: Double, bold: Bool, leading: Double,
                   isHeading: Bool) {
            if y + leading > bottom { newPage() }
            lines.append(Line(text: text, size: size, bold: bold, y: y,
                              isHeading: isHeading, isFooter: false))
            y += leading
        }

        func gap(_ height: Double) {
            y += height
            if y > bottom { newPage() }
        }

        for (index, block) in blocks.enumerated() {
            let size: Double
            let bold: Bool
            let isHeading: Bool
            let gapBefore: Double
            let gapAfter: Double
            let indent: Double
            switch block {
            case .title:
                size = style.titleSize; bold = true; isHeading = true
                gapBefore = index == 0 ? 0 : style.titleGapAfter
                gapAfter = 0
                indent = 0
            case .heading(let level, _):
                size = style.headingSize(level: level); bold = true; isHeading = true
                gapBefore = style.headingGapBefore
                gapAfter = style.paragraphGap * 0.5
                indent = Double(max(0, level - 1)) * 12
            case .paragraph(let text):
                size = style.bodySize; bold = false; isHeading = false
                gapBefore = 0
                gapAfter = style.paragraphGap
                indent = 0
                if text.isEmpty { gap(style.bodySize); continue }
            }
            if gapBefore > 0 { gap(gapBefore) }
            let leading = size * style.lineHeightMultiple
            let available = column - indent
            for wrapped in wrap(blockText(block), width: available,
                                size: size, measure: measure) {
                if measure(wrapped, size, bold) > available {
                    // A word longer than the column (a URL, an
                    // unbreakable token): break it by character rather than
                    // draw off the edge of the paper.
                    for piece in hardBreak(wrapped, width: available, size: size,
                                           measure: measure) {
                        place(piece, size: size, bold: bold, leading: leading,
                              isHeading: isHeading)
                    }
                    continue
                }
                place(wrapped, size: size, bold: bold, leading: leading,
                      isHeading: isHeading)
            }
            if gapAfter > 0 { gap(gapAfter) }
        }
        // The last page is still pending: `newPage` runs on a *break*, so
        // nothing has closed the final page yet.
        if !lines.isEmpty {
            if style.showsFooter { lines.append(footerLine()) }
            pages.append(Page(number: pages.count + 1, lines: lines))
        }
        // Never hand back a page with nothing on it. A break caused by the
        // gap after a heading leaves an empty trailing page, and a script
        // with no words in it has no pages at all — both are "0 pages",
        // which the caller can act on and a stray sheet of paper can't.
        return pages.filter { $0.lines.contains { !$0.isFooter } }
    }

    private static func blockText(_ block: Block) -> String {
        switch block {
        case .title(let text), .heading(_, let text), .paragraph(let text): return text
        }
    }

    /// Greedy word wrap. A word longer than the line starts the line
    /// anyway rather than looping forever on it.
    public static func wrap(_ text: String, width: Double, size: Double,
                            measure: (String, Double, Bool) -> Double) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
                continue
            }
            let candidate = current + " " + word
            if measure(candidate, size, false) <= width {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        lines.append(current)
        return lines
    }

    /// Character-level fallback for a word that cannot fit a line at all.
    public static func hardBreak(_ text: String, width: Double, size: Double,
                                 measure: (String, Double, Bool) -> Double) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            if !current.isEmpty, measure(current + String(character), size, false) > width {
                pieces.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
