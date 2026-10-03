import Foundation
import Testing
@testable import PromptCore

// MARK: - Text hygiene

@Suite struct ScriptTextTests {
    @Test func windowsAndClassicMacEndingsBecomeOneKind() {
        #expect(ScriptText.normalize("a\r\nb\rc") == "a\nb\nc")
    }

    @Test func invisibleCharactersBecomeSeparators() {
        // The real case: Word and PDF both leave these inside ordinary
        // words, and the tokenizer split on them.
        let body = ScriptText.normalize("Ke\u{200B}ep going with the so\u{00AD}ft hyphen")
        // A soft hyphen is a hyphenation artefact: it divides two words,
        // so it must not leave one glued word behind.
        #expect(ScriptParser.words(body) == ["Ke", "ep", "going", "with", "the", "so", "ft", "hyphen"])
    }

    @Test func exoticSpacesCollapseToOne() {
        let body = ScriptText.normalize("one\u{00A0}two\u{2009}three")
        #expect(body == "one two three")
    }

    @Test func graphemeClustersSurvive() {
        // Rebuilding character-by-character, or "cleaning" the zero-width
        // joiner, would break the family into three glyphs — and the body
        // is what gets copied out of Cuebar and pasted into somewhere
        // else, so the damage would outlive the import.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let body = ScriptText.normalize("family \(family) here")
        #expect(body.contains(family))
    }

    @Test func paragraphRunsAreCappedAtOneBlank() {
        #expect(ScriptText.normalize("a\n\n\n\n\nb") == "a\n\nb")
    }

    @Test func trailingSpaceAndBlankLinesGo() {
        // Trailing space is invisible and reads as a pause nobody asked
        // for; leading indentation is the author's, and is kept.
        #expect(ScriptText.normalize("\n\n  hello   \n\n\n") == "  hello")
    }

    @Test func composedTextIsNotRebuiltAsAccents() {
        #expect(ScriptText.normalize("cafe\u{0301}") == "caf\u{00E9}")
    }

    @Test func hasScriptTextRejectsBlank() {
        #expect(!ScriptText.hasScriptText("  \n\t "))
        #expect(ScriptText.hasScriptText("[smile]"))
    }

    @Test func decodesEveryEncodingWeMeet() {
        #expect(ScriptText.decode(Data("hello".utf8)) == "hello")
        #expect(ScriptText.decode(Data([0xEF, 0xBB, 0xBF] + Array("hello".utf8))) == "hello")
        let utf16 = Array("hello".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        #expect(ScriptText.decode(Data([0xFF, 0xFE] + utf16)) == "hello")
        // UTF-16 with no BOM: what a Windows editor saved as plain text.
        #expect(ScriptText.decode(Data(utf16)) == "hello")
        // Latin-1: a single byte above 127, still a valid script.
        #expect(ScriptText.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "caf\u{00E9}")
    }

    @Test func refusesBinary() {
        var data = Data()
        for i in 0..<512 { data.append(UInt8(i % 251)) }
        #expect(ScriptText.decode(data) == nil)
    }

    @Test func titleFromFilename() {
        #expect(ScriptText.title(fromFilename: "Keynote Talk 2026.md") == "Keynote Talk 2026")
        #expect(ScriptText.title(fromFilename: "My%20Talk.docx") == "My Talk")
        #expect(ScriptText.title(fromFilename: "draft_one.txt") == "draft one")
        #expect(ScriptText.title(fromFilename: ".hidden") == "hidden")
        // A leading dot is a hidden file, not an extension: NSString keeps
        // the whole name, and what is left is the honest title.
        #expect(ScriptText.title(fromFilename: ".txt") == "txt")
    }

    @Test func detectsAFileDroppedAsAPath() {
        let old = "Intro\n\nBody."
        let dropped = ScriptText.droppedFile(from: old,
                                             to: old + " /Users/me/Talk.docx")
        #expect(dropped == "/Users/me/Talk.docx")
        #expect(ScriptText.droppedFile(from: old, to: old + " \"Talk 2.md\"")
                == "Talk 2.md")
        #expect(ScriptText.droppedFile(from: old, to: old + " file:///Users/me/Talk.pdf")
                == "/Users/me/Talk.pdf")
    }

    @Test func leavesOrdinaryEditingAlone() {
        let old = "Intro"
        #expect(ScriptText.droppedFile(from: old, to: old + " and a thought") == nil)
        #expect(ScriptText.droppedFile(from: old, to: "") == nil)
        #expect(ScriptText.droppedFile(from: old, to: old) == nil)
        // A real edit rewrites both ends, which is not one inserted run.
        #expect(ScriptText.droppedFile(from: "one two", to: "one three four") == nil)
        // A path we could not read is not a script. Existence is not this
        // function's business — it is pure — so the caller checks.
        #expect(ScriptText.droppedFile(from: "", to: "/Users/me/Movie.mov") == nil)
        #expect(ScriptText.droppedFile(from: "", to: "just a sentence") == nil)
    }

    @Test func duplicateTitlesGetSuffixes() {
        #expect(ScriptText.uniqueTitle("Talk", against: ["Notes"]) == "Talk")
        #expect(ScriptText.uniqueTitle("Talk", against: ["Talk"]) == "Talk 2")
        #expect(ScriptText.uniqueTitle("Talk", against: ["talk", "Talk 2"]) == "Talk 3")
    }
}

// MARK: - Markdown

@Suite struct MarkdownTextTests {
    @Test func emphasisAndCodeAreStrippedButWordsStay() {
        let body = MarkdownText.plainBody("This is **bold**, *soft*, _quiet_, `mono` and ~~gone~~.")
        #expect(body == "This is bold, soft, quiet, mono and gone.")
    }

    @Test func underscoresInsideWordsSurvive() {
        let body = MarkdownText.plainBody("Call snake_case_helper with 2 * 3 * 4.")
        #expect(body == "Call snake_case_helper with 2 * 3 * 4.")
    }

    @Test func linksBecomeTheirLabelAndImagesVanish() {
        let body = MarkdownText.plainBody("See [the docs](https://example.com) and ![a cat](cat.png).")
        #expect(body == "See the docs and .")
    }

    @Test func cuesAreNotMistakenForLinks() {
        let body = MarkdownText.plainBody("Hello [smile] there [pause 2s]")
        #expect(body == "Hello [smile] there [pause 2s]")
        #expect(ScriptParser.parse(body).filter { $0.isCue }.count == 2)
    }

    @Test func headingsSurviveAndDeepOnesClamp() {
        let body = MarkdownText.plainBody("# One\n\ntext\n\n##### Five\n\nmore")
        #expect(body == "# One\n\ntext\n\n### Five\n\nmore")
        #expect(ScriptIndex(tokens: ScriptParser.parse(body)).sections.map(\.name) == ["One", "Five"])
    }

    @Test func hashtagsAreWordsNotHeadings() {
        #expect(MarkdownText.plainBody("#hashtag time") == "#hashtag time")
    }

    @Test func listMarkersGoButTheWordsStay() {
        let body = MarkdownText.plainBody("- first\n* second\n1. third\n2) fourth")
        #expect(body == "first\nsecond\nthird\nfourth")
    }

    @Test func blockquotesAndRulesGo() {
        let body = MarkdownText.plainBody("> quoted line\n\n---\n\n***\n\nafter")
        #expect(body == "quoted line\n\nafter")
    }

    @Test func tableRowsBecomeTheirCells() {
        let body = MarkdownText.plainBody("| Cue | When |\n| --- | --- |\n| pause | a beat |")
        #expect(body == "Cue, When\npause, a beat")
    }

    @Test func fencedCodeKeepsItsContent() {
        let body = MarkdownText.plainBody("```\nlet x = 2 * 3\n```")
        #expect(body == "let x = 2 * 3")
    }

    @Test func strayTagsAreRemoved() {
        #expect(MarkdownText.plainBody("a<br>b <span class=\"x\">c</span>") == "a b c")
    }
}

// MARK: - HTML

@Suite struct HTMLTextTests {
    @Test func scriptsStylesAndCommentsVanish() {
        let body = HTMLText.plainBody("""
        <html><head><title>T</title><style>p { color: red }</style></head>
        <body><!-- <p>hidden</p> --><script>var x = "<p>no</p>";</script>
        <p>Hello <b>there</b></p></body></html>
        """)
        #expect(body == "Hello there")
    }

    @Test func blockEndsBecomeParagraphsAndListsLoseTheirMarkers() {
        let body = HTMLText.plainBody("<ul><li>one</li><li>two</li></ul><p>end</p>")
        #expect(body == "one\ntwo\n\nend")
    }

    @Test func entitiesAreDecoded() {
        #expect(HTMLText.plainBody("<p>5 &lt; 6 &amp;&amp; caf&eacute; &#8212; 30&hellip;</p>")
                == "5 < 6 && caf\u{00E9} \u{2014} 30\u{2026}")
    }

    @Test func unknownEntitiesAreLeftAlone() {
        #expect(HTMLText.plainBody("<p>&amp;x=1 &notanentity;</p>") == "&x=1 &notanentity;")
    }

    @Test func titleComesFromTheDocument() {
        let html = "<html><head><title>My &amp;mdash; Talk</title></head><body>x</body></html>"
        let url = URL(string: "https://example.com/2026/talk.html")!
        #expect(ScriptText.title(fromHTML: html, url: url) == "My &mdash; Talk")
        #expect(ScriptText.title(fromHTML: "<html><body>no title</body></html>",
                                  url: URL(string: "https://www.example.com/")!)
                == "example.com")
    }
}

// MARK: - DOCX / ZIP

@Suite struct DocxWriterTests {
    @Test func crcMatchesTheKnownVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func archiveIsReadableBack() {
        // A test-only reader, so the writer is checked against the format
        // rather than against itself: the central directory is the only
        // place a reader must agree with a writer.
        let data = ZipWriter.archive([
            ZipWriter.Entry(name: "[Content_Types].xml", data: Data("<Types/>".utf8)),
            ZipWriter.Entry(name: "word/document.xml", data: Data("<w:document/>".utf8)),
        ])
        #expect(Array(data.prefix(2)) == [0x50, 0x4B])

        let entries = zipEntries(data)
        #expect(entries["[Content_Types].xml"].map { String(decoding: $0, as: UTF8.self) }
                == "<Types/>")
        #expect(entries["word/document.xml"].map { String(decoding: $0, as: UTF8.self) }
                == "<w:document/>")
    }

    @Test func paragraphClassification() {
        let body = "# Title\n\nplain line\n[pause 2s]\n## Sub"
        #expect(DocxWriter.paragraphs(from: body) == [
            .heading(level: 1, text: "Title"),
            .blank,
            .text("plain line"),
            .cue("[pause 2s]"),
            .heading(level: 2, text: "Sub"),
        ])
    }

    @Test func documentCarriesEveryRequiredPart() {
        let data = DocxWriter.document(body: "# Talk\n\nHello & <goodbye>\n[smile]",
                                       title: "Talk")
        let names = Array(zipEntries(data).keys)
        #expect(names.contains("[Content_Types].xml"))
        #expect(names.contains("_rels/.rels"))
        #expect(names.contains("word/document.xml"))
        #expect(names.contains("word/_rels/document.xml.rels"))
        #expect(names.contains("word/styles.xml"))
        #expect(names.contains("docProps/core.xml"))

        let document = String(decoding: zipEntries(data)["word/document.xml"]!, as: UTF8.self)
        #expect(document.contains("Hello &amp; &lt;goodbye&gt;"))
        #expect(document.contains("<w:outlineLvl w:val=\"0\"/>"))
        #expect(document.hasSuffix("</w:document>"))

        // The title lives in the document's own properties, which is where
        // Finder and Word read the name from.
        let core = String(decoding: zipEntries(data)["docProps/core.xml"]!, as: UTF8.self)
        #expect(core.contains("<dc:title>Talk</dc:title>"))
    }

    @Test func ampersandsInCorePropertiesAreEscaped() {
        let data = DocxWriter.document(body: "x", title: "Ben & Jerry's")
        let core = String(decoding: zipEntries(data)["docProps/core.xml"]!, as: UTF8.self)
        #expect(core.contains("<dc:title>Ben &amp; Jerry&apos;s</dc:title>")
                || core.contains("<dc:title>Ben &amp; Jerry's</dc:title>"))
    }

    // MARK: Helpers

    /// Enough of the ZIP format to prove the writer emits one: walk the
    /// central directory and pull each entry's payload back.
    private func zipEntries(_ data: Data) -> [String: Data] {
        var out: [String: Data] = [:]
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { return out }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8
                | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        var eocd = bytes.count - 22
        while eocd >= 0, u32(eocd) != 0x0605_4B50 { eocd -= 1 }
        guard eocd >= 0 else { return out }
        var offset = u32(eocd + 16)
        for _ in 0..<u16(eocd + 10) {
            guard u32(offset) == 0x0201_4B50 else { break }
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            let localName = u16(local + 26) + u16(local + 28)
            let start = local + 30 + localName
            out[name] = Data(bytes[start..<(start + size)])
            offset += 46 + nameLength + extraLength + commentLength
        }
        return out
    }
}

// MARK: - PDF layout

@Suite struct PdfLayoutTests {
    /// Monospace-ish: predictable, and every assertion can be exact.
    private let measure: (String, Double, Bool) -> Double = { text, size, bold in
        Double(text.count) * size * (bold ? 0.55 : 0.5)
    }

    @Test func wrapBreaksAtTheColumn() {
        // 10pt per character at size 20, column 130.
        let lines = PdfLayout.wrap("one two three four five", width: 130, size: 20, measure: measure)
        #expect(lines == ["one two three", "four five"])
    }

    @Test func aWordLongerThanTheColumnStartsItsOwnLine() {
        let lines = PdfLayout.wrap("a supercalifragilistic b", width: 40, size: 10, measure: measure)
        #expect(lines == ["a", "supercalifragilistic", "b"])
    }

    @Test func hardBreakSplitsAnUnbreakableToken() {
        let pieces = PdfLayout.hardBreak("abcdefgh", width: 35, size: 10, measure: measure)
        #expect(pieces == ["abcdefg", "h"])
        #expect(pieces.joined() == "abcdefgh")
    }

    @Test func shortScriptIsOnePage() {
        let pages = PdfLayout.paginate(blocks: PdfLayout.blocks(from: "Hello world", title: "Talk"),
                                       measure: measure)
        #expect(pages.count == 1)
        let text = pages[0].lines.filter { !$0.isFooter }.map(\.text)
        #expect(text == ["Talk", "Hello world"])
    }

    @Test func emptyScriptHasNoPages() {
        #expect(PdfLayout.paginate(blocks: PdfLayout.blocks(from: "", title: ""), measure: measure).isEmpty)
        #expect(PdfLayout.paginate(blocks: PdfLayout.blocks(from: "   \n\n", title: ""),
                                   measure: measure).isEmpty)
    }

    @Test func longScriptPaginatesWithoutAnEmptyTail() {
        let paragraph = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let pages = PdfLayout.paginate(blocks: PdfLayout.blocks(from: paragraph, title: "Long"),
                                       measure: measure)
        #expect(pages.count > 1)
        for (index, page) in pages.enumerated() {
            #expect(page.number == index + 1)
            #expect(page.lines.contains { $0.isFooter })
            let body = page.lines.filter { !$0.isFooter }
            #expect(!body.isEmpty)
        }
    }

    @Test func linesStayInsideTheTextBoxAndNeverOverlap() {
        var style = PdfLayout.Style()
        style.showsFooter = true
        let page = PdfLayout.PageSpec()
        let bottom = page.textBottom - style.footerReserve
        let pages = PdfLayout.paginate(
            blocks: PdfLayout.blocks(from: "# One\n\nbody\n\n## Two\n\nmore body", title: "T"),
            page: page, style: style, measure: measure)
        for page in pages {
            var previous = -Double.infinity
            for line in page.lines where !line.isFooter {
                #expect(line.y > previous)
                #expect(line.y <= bottom + style.bodySize)
                previous = line.y
            }
        }
    }

    @Test func headingsAreClampedAndIndentByLevel() {
        let blocks = PdfLayout.blocks(from: "###### Deep\n\ntext", title: "")
        #expect(blocks == [.heading(level: 3, text: "Deep"), .paragraph("text")])
    }

    @Test func fuzzedWrappingNeverLosesOrDuplicatesWords() {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        for _ in 0..<300 {
            let count = Int(next() % 40) + 1
            let words = (0..<count).map { _ -> String in
                let length = Int(next() % 12) + 1
                return String(repeating: "x", count: length)
            }
            let column = Double(next() % 300) + 20
            let size = Double(next() % 30) + 6
            let wrapped = PdfLayout.wrap(words.joined(separator: " "), width: column,
                                         size: size, measure: measure)
            #expect(wrapped.flatMap { $0.split(separator: " ").map(String.init) } == words)
            for line in wrapped {
                if line.contains("x"), !words.contains(where: { $0 == line }) {
                    // A single word wider than the column is expected to
                    // stand alone; anything else must have been split.
                    #expect(Double(line.count) <= column / (size * 0.5) + 1)
                }
            }
        }
    }
}

// MARK: - Import pipeline

@Suite struct ScriptImportTests {
    /// Stands in for the app layer's readers: anything Word- or PDF-shaped
    /// decodes, except the one file whose payload says it is broken.
    private let decodeStub: @Sendable (Int, ScriptImport.Item) -> String? = { _, item in
        guard let format = item.format, format == .docx || format == .pdf else { return nil }
        guard String(decoding: item.data, as: UTF8.self) != "nope" else { return nil }
        return "text from \(format.rawValue)"
    }

    private func plan(_ items: [ScriptImport.Item], existing: [String] = []) -> ScriptImport.Outcome {
        ScriptImport.plan(items: items, existingTitles: existing, decode: decodeStub)
    }

    @Test func textFileImportsWithItsFilenameAsTheTitle() {
        let outcome = plan([.init(name: "Keynote Talk.txt", data: Data("Hello world".utf8))])
        #expect(outcome.scripts == [.init(title: "Keynote Talk", body: "Hello world")])
        #expect(outcome.rejected.isEmpty)
    }

    @Test func markdownLosesItsMarkupAndKeepsItsHeadings() {
        let source = "# Intro\n\n**bold** and [link](https://x.com) [smile]"
        let outcome = plan([.init(name: "Talk.md", data: Data(source.utf8))])
        #expect(outcome.scripts.first?.body == "# Intro\n\nbold and link [smile]")
    }

    @Test func htmlNeedsNoFrameworkReader() {
        // The pipeline strips HTML itself, so a caller whose decoder can
        // only read Word files still imports a web page.
        let outcome = ScriptImport.plan(
            items: [.init(name: "page.html",
                          data: Data("<p>Hello <b>there</b></p>".utf8))]) { _, _ in
            // Must never be reached: if it were, the page would import as
            // these words instead of the page's own.
            return "the decoder should not have been asked"
        }
        #expect(outcome.scripts.first?.body == "Hello there")
        #expect(ScriptFormat.reader(forFilename: "page.html").needsFramework == false)
        #expect(ScriptFormat.reader(forFilename: "page.docx").needsFramework)
        #expect(ScriptFormat.reader(forFilename: "page.pdf").needsFramework)
        #expect(!ScriptFormat.reader(forFilename: "page.md").needsFramework)
    }

    @Test func binaryFormatsGoThroughTheCallersReader() {
        let outcome = plan([
            .init(name: "Paper.pdf", data: Data("pdf bytes".utf8)),
            .init(name: "Brief.docx", data: Data("docx bytes".utf8)),
            .init(name: "Broken.docx", data: Data("nope".utf8)),
        ])
        #expect(outcome.titles == ["Paper", "Brief"])
        #expect(outcome.rejected.count == 1)
        #expect(outcome.rejected[0].reason == ScriptImport.Failure.unreadable)
    }

    @Test func unknownExtensionsAreRefusedRatherThanGuessed() {
        let outcome = plan([
            .init(name: "movie.mov",
                  data: Data([UInt8](repeating: 0x00, count: 900))),
            .init(name: "screenshot.png", data: Data(repeating: 0x7F, count: 400)),
        ])
        #expect(outcome.scripts.isEmpty)
        #expect(outcome.rejected.allSatisfy { $0.reason == ScriptImport.Failure.unsupportedFormat })
    }

    @Test func extensionlessTextStillImports() {
        let outcome = plan([.init(name: "notes", data: Data("just words".utf8))])
        #expect(outcome.scripts.first?.title == "notes")
    }

    @Test func aFileWithNoWordsIsRejected() {
        let outcome = plan([
            .init(name: "blank.txt", data: Data("   \n\t\n".utf8)),
            .init(name: "scan.pdf", data: Data("pages".utf8)),
        ])
        // The PDF's reader returned "pages", so it survives: the stub stands
        // in for a decoder, and only a genuinely empty body is rejected.
        #expect(outcome.titles == ["scan"])
        #expect(outcome.rejected.first?.reason == ScriptImport.Failure.empty)
    }

    @Test func oversizedFilesAreRefusedBeforeDecoding() {
        var big = Data()
        big.append(contentsOf: [UInt8](repeating: 0x41, count: ScriptText.maxImportBytes + 1))
        let outcome = plan([.init(name: "huge.txt", data: big)])
        #expect(outcome.scripts.isEmpty)
        #expect(outcome.rejected.first?.reason
                == ScriptImport.Failure.tooLarge(bytes: ScriptText.maxImportBytes + 1))
    }

    @Test func duplicateFilenamesBothSurvive() {
        let item = ScriptImport.Item(name: "Talk.txt", data: Data("one".utf8))
        let outcome = plan([item, item], existing: ["Talk"])
        #expect(outcome.titles == ["Talk 2", "Talk 3"])
    }

    @Test func bodyImportsTitleTheClipboardDidntHave() {
        // Pasted text is indented for a reason that has nothing to do with
        // reading: a mail client, a code block, a page's source. Files keep
        // their layout instead, so an exported script round-trips.
        let script = ScriptImport.fromBody("  Hello  \n\n\n    world ",
                                           title: "", existingTitles: [])
        #expect(script == .init(title: "Untitled", body: "Hello\n\nworld"))
        #expect(ScriptImport.fromBody("   ", title: "x") == nil)
    }
}

// MARK: - Formats

@Suite struct ScriptFormatTests {
    @Test func everyExportFormatIsImportable() {
        for format in ScriptFormat.exportable {
            #expect(ScriptFormat.importable.contains(format))
        }
        #expect(!ScriptFormat.exportable.contains(.richText))
    }

    @Test func detectionIsCaseInsensitiveAndCoversRealSpellings() {
        #expect(ScriptFormat.detect(pathExtension: "MD") == .markdown)
        #expect(ScriptFormat.detect(pathExtension: "docx") == .docx)
        #expect(ScriptFormat.detect(pathExtension: "webarchive") == .richText)
        #expect(ScriptFormat.detect(filename: "Talk.PDF") == .pdf)
        #expect(ScriptFormat.detect(pathExtension: "") == nil)
        #expect(ScriptFormat.detect(pathExtension: "mov") == nil)
    }

    @Test func identifiersAreDistinctAndNonEmpty() {
        let ids = ScriptFormat.allCases.map(\.utTypeIdentifier)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(""))
        #expect(ids.allSatisfy { !$0.contains(" ") && !$0.isEmpty })
    }

    @Test func readerIsChosenFromTheExtensionNotTheFormat() {
        // `.rtf` and `.html` are the same coarse format and want opposite
        // readers; insisting one document type on both is how an HTML file
        // imports as nothing.
        #expect(ScriptFormat.reader(forFilename: "a.txt") == .plainText)
        #expect(ScriptFormat.reader(forFilename: "a.md") == .markdown)
        #expect(ScriptFormat.reader(forFilename: "a.html") == .html)
        #expect(ScriptFormat.reader(forFilename: "a.HTM") == .html)
        #expect(ScriptFormat.reader(forFilename: "a.webarchive") == .html)
        #expect(ScriptFormat.reader(forFilename: "a.rtf") == .attributed)
        #expect(ScriptFormat.reader(forFilename: "a.doc") == .attributed)
        #expect(ScriptFormat.reader(forFilename: "a.docx") == .attributed)
        #expect(ScriptFormat.reader(forFilename: "a.pdf") == .pdf)
        // No extension: read as text and let the importer refuse it.
        #expect(ScriptFormat.reader(forFilename: "notes") == .plainText)
        #expect(ScriptFormat.reader(forFilename: "a.mov") == .plainText)
    }

    @Test func extensionAndTypeAreBothDeclared() {
        for format in ScriptFormat.allCases {
            #expect(!format.fileExtension.isEmpty)
            #expect(format.pathExtensions.contains(format.fileExtension))
        }
    }
}