import Foundation

/// A `.docx`, written from a script.
///
/// A Word document is a ZIP of XML parts, so this produces the five parts
/// Word actually requires and nothing else: no styles beyond defaults, no
/// numbering, no theme. The alternative — driving `NSTextView`'s RTF
/// exporter — cannot write `.docx`, and RTF is not what anyone wants handed
/// to a Word user.
///
/// The script's own conventions survive the trip: `#`/`##`/`###` become
/// outline headings (which is also what puts the script in Word's
/// navigation pane), and `[pause 2s]` stays inline and italic, because a
/// printed script is where cues belong.
public enum DocxWriter {
    public enum Paragraph: Equatable, Sendable {
        case heading(level: Int, text: String)
        case cue(String)
        case text(String)
        case blank
    }

    /// Classify the script into paragraphs. Line-based on purpose: the
    /// body is the source of truth, and a Word paragraph is a line — so
    /// this never has to agree with the tokenizer about where a word
    /// starts.
    public static func paragraphs(from body: String) -> [Paragraph] {
        body.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .blank }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if hashes >= 1, hashes <= 3,
               trimmed.dropFirst(hashes).hasPrefix(" ") {
                let name = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return .heading(level: hashes, text: name) }
            }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
                return .cue(trimmed)
            }
            return .text(trimmed)
        }
    }

    /// The finished document.
    public static func document(body: String, title: String,
                                author: String = "Cuebar") -> Data {
        var bodyXML = ""
        for paragraph in paragraphs(from: body) {
            switch paragraph {
            case .blank:
                bodyXML += "<w:p/>"
            case .heading(let level, let text):
                // `outlineLvl` is what puts the script in Word's
                // navigation pane — for a document made of headings, the
                // navigation pane *is* the table of contents.
                bodyXML += """
                <w:p><w:pPr><w:outlineLvl w:val=\"\(level - 1)\"/> \
                <w:spacing w:before="320" w:after="120"/></w:pPr> \
                <w:r><w:rPr><w:b/><w:sz w:val="\(level == 1 ? 36 : (level == 2 ? 30 : 26))"/></w:rPr> \
                <w:t xml:space="preserve">\(escape(text))</w:t></w:r></w:p>
                """
            case .cue(let text):
                bodyXML += """
                <w:p><w:r><w:rPr><w:i/><w:color w:val="7A7A7A"/></w:rPr> \
                <w:t xml:space="preserve">\(escape(text))</w:t></w:r></w:p>
                """
            case .text(let text):
                bodyXML += """
                <w:p><w:r><w:t xml:space="preserve">\(escape(text))</w:t></w:r></w:p>
                """
            }
        }
        // US Letter, portrait, 1" margins. The section properties are what
        // make it a document rather than a stream of paragraphs. The spaces
        // at the line joins are load-bearing: a `\` continuation takes the
        // next line's leading whitespace with it, and two XML attributes
        // run together is not XML — Word rejects the file as malformed.
        bodyXML += """
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/> \
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
        w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
        """

        var entries: [ZipWriter.Entry] = []
        entries.append(ZipWriter.Entry(name: "[Content_Types].xml",
                                       data: xml(contentTypes)))
        entries.append(ZipWriter.Entry(name: "_rels/.rels", data: xml(packageRels)))
        entries.append(ZipWriter.Entry(name: "docProps/core.xml", data: xml(coreProps(title: title, author: author))))
        entries.append(ZipWriter.Entry(name: "word/_rels/document.xml.rels",
                                       data: xml(documentRels)))
        entries.append(ZipWriter.Entry(name: "word/styles.xml", data: xml(styles)))
        entries.append(ZipWriter.Entry(name: "word/document.xml",
                                       data: xml(document(body: bodyXML))))
        return ZipWriter.archive(entries)
    }

    // MARK: - Parts

    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static func xml(_ content: String) -> Data {
        Data((declaration + content).utf8)
    }

    private static let contentTypes = """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    </Types>
    """

    private static let packageRels = """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    private static let documentRels = """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    </Relationships>
    """

    private static let styles = """
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
    </w:docDefaults></w:styles>
    """

    private static func coreProps(title: String, author: String) -> String {
        // The document's own metadata, so the title the presenter gave the
        // script is the title Finder shows — exporting without it threw
        // away the one piece of a script that isn't its text.
        """
        <cp:coreProperties \
        xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escape(title))</dc:title><dc:creator>\(escape(author))</dc:creator>\
        <cp:lastModifiedBy>\(escape(author))</cp:lastModifiedBy></cp:coreProperties>
        """
    }

    private static func document(body: String) -> String {
        """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:body>\(body)</w:body></w:document>
        """
    }

    /// XML text escaping. `ScriptText.normalize` has already removed the
    /// control characters XML 1.0 forbids, which is the other way a
    /// generated document comes out unopenable.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(character)
            }
        }
        return out
    }
}