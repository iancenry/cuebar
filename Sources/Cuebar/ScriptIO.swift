import AppKit
import UniformTypeIdentifiers
import PromptCore

/// Everything that moves a script between Cuebar and the outside world:
/// files, the pasteboard, a web page, and the drag ghost.
///
/// The *rules* live in PromptCore (`ScriptImport`, `ScriptFormat`,
/// `MarkdownText`, `DocxWriter`, `PdfLayout`) and are tested there. What is
/// left here is the part that needs a window on the world — panels,
/// pasteboards, the file system — plus the two conversions that need a
/// framework (`SystemText`) and one that needs CoreGraphics (`PdfExport`).
@MainActor
enum ScriptIO {
    /// Any window with a content view, largest first. What the save panel
    /// and alerts attach to: `NSApp.keyWindow` is nil in a `WindowGroup` app
    /// like this one (measured), and a panel with nowhere to attach is a
    /// panel nobody ever sees.
    static func anyPanelHost() -> NSWindow? {
        NSApp.windows
            .filter { $0.contentView != nil && $0.frame.width > 200 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    // MARK: - Export

    /// Save one script wherever the user wants, in any format we write.
    /// Returns whether it was written.
    @discardableResult
    static func export(_ doc: ScriptDocument) -> Bool {
        guard let window = anyPanelHost() else {
            report("Can't save without a window", "Open Cuebar's window and try again.")
            return false
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = exportTypes()
        // The popup *is* the extension picker, so the name field carries the
        // extension too: a user who typed "Keynote" and picked Markdown
        // should not have to remember that Markdown means `.md`.
        panel.nameFieldStringValue = defaultName(for: doc)
        panel.message = "Choose where to save this script."
        panel.isExtensionHidden = false
        var written = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            written = Self.write(doc, to: url)
        }
        return written
    }

    /// The save panel's format list: one `UTType` per format we can write.
    static func exportTypes() -> [UTType] {
        ScriptFormat.exportable.compactMap {
            UTType(exportedAs: $0.utTypeIdentifier) ?? UTType(filenameExtension: $0.fileExtension)
        }
    }

    /// Write one script to a known URL. Shared by the save panel, by
    /// dropping a file onto Finder, and by the drag ghost.
    @discardableResult
    static func write(_ doc: ScriptDocument, to url: URL) -> Bool {
        do {
            switch ScriptFormat.detect(filename: url.lastPathComponent) {
            case .markdown:
                try ScriptText.posix(doc.body).write(to: url, atomically: true, encoding: .utf8)
            case .plainText, nil:
                try ScriptText.posix(doc.body).write(to: url, atomically: true, encoding: .utf8)
            case .docx:
                let data = DocxWriter.document(body: doc.body, title: doc.title)
                try data.write(to: url, options: .atomic)
            case .pdf:
                guard let data = PdfExport.data(for: doc) else {
                    report("Couldn't export \"\(doc.title)\"", "This script has no words in it, so there are no pages to write.")
                    return false
                }
                try data.write(to: url, options: .atomic)
            case .richText:
                // Not offered in the panel; if someone types `.rtf` into the
                // name anyway, plain text is still a valid RTF-free answer
                // and beats a failure.
                try ScriptText.posix(doc.body).write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            report("Couldn't save the script", error.localizedDescription)
            return false
        }
    }

    /// `Keynote Talk.md`, with anything a file system would object to taken
    /// out of the title.
    static func defaultName(for doc: ScriptDocument, format: ScriptFormat = .markdown) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:")
        var name = doc.title.components(separatedBy: illegal).joined(separator: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled" }
        if ScriptFormat.detect(filename: name) != nil { return name }
        return "\(name).\(format.fileExtension)"
    }

    /// A temporary plain-text copy for the drag ghost, so a script can be
    /// dropped into Finder, Mail or anywhere else that takes files.
    ///
    /// Plain text because every one of those accepts plain text, and
    /// because a drag that offers three formats asks the receiving app to
    /// pick — which some do badly.
    ///
    /// One directory per script, and nothing is ever deleted here: a drag
    /// reads its file when the session starts, so clearing a shared
    /// directory on the way in can pull the file out from under a drag that
    /// is already running. The temp directory is the system's to clean.
    static func temporaryFile(for doc: ScriptDocument) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cuebar Drag", isDirectory: true)
            .appendingPathComponent(doc.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let url = directory.appendingPathComponent(defaultName(for: doc, format: .plainText))
        do {
            try ScriptText.posix(doc.body).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Import

    /// The open panel's type list: our identifiers plus a `UTType` for every
    /// extension we can read, because the panel filters on *types*, and a
    /// `.webarchive` or `.pages` has no identifier of its own.
    static func importTypes() -> [UTType] {
        var types: [UTType] = ScriptFormat.importable.compactMap {
            UTType(exportedAs: $0.utTypeIdentifier)
        }
        for ext in ScriptFormat.importableExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    /// Read files into scripts. Directories are walked, so dropping a talk
    /// folder imports the talk.
    @discardableResult
    static func importFiles(_ urls: [URL], existingTitles: [String]) -> ScriptImport.Outcome {
        let (items, oversized) = items(from: urls)
        // Read the framework formats *here*, on the main actor, and hand the
        // results to the pipeline. Not inside its decoder: that closure is
        // `@Sendable` with no isolation guarantee, and reaching for
        // `MainActor.assumeIsolated` there is the SIGBUS trap in AGENTS.md —
        // this runs synchronously from a run-loop callback (a modal panel
        // handler), with no Task to suspend on.
        var decoded: [Int: String] = [:]
        for (index, item) in items.enumerated() where needsSystemReader(item) {
            decoded[index] = SystemText.decode(item)
        }
        // `let`, so the lookup table is an immutable `Sendable` value rather
        // than a var the closure may not capture.
        let answers = decoded
        let outcome = ScriptImport.plan(items: items, existingTitles: existingTitles) { index, _ in
            answers[index]
        }
        var rejected = oversized.map {
            ScriptImport.Rejected(name: $0.name, reason: .tooLarge(bytes: $0.bytes))
        }
        rejected.append(contentsOf: outcome.rejected)
        return ScriptImport.Outcome(scripts: outcome.scripts, rejected: rejected)
    }

    /// True for the formats only AppKit or PDFKit can read. Plain text,
    /// Markdown and HTML are all handled by PromptCore and never come
    /// through here — `ScriptFormat.Reader` is the single answer both sides
    /// ask for.
    static func needsSystemReader(_ item: ScriptImport.Item) -> Bool {
        ScriptFormat.reader(forFilename: item.name).needsFramework
    }

    /// Flatten the dropped or chosen URLs into the files worth reading.
    ///
    /// A dropped folder is a walk, bounded twice: depth, because a symlink
    /// loop would otherwise run forever, and count, because dropping a
    /// home directory should import a talk rather than forty thousand
    /// unrelated documents. The cap is reported, not silent.
    static func items(from urls: [URL]) -> (items: [ScriptImport.Item],
                                            oversized: [(name: String, bytes: Int)]) {
        let limit = 400
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var items: [ScriptImport.Item] = []
        var oversized: [(name: String, bytes: Int)] = []
        var seen = Set<String>()
        var queue: [(url: URL, depth: Int)] = urls.map { ($0, 0) }

        while let next = queue.first {
            queue.removeFirst()
            let url = next.url
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                guard next.depth < 3 else { continue }
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys)) ?? []
                // Sorted so importing a folder twice imports it the same
                // way, and so the first script in it is the first one the
                // user sees selected.
                queue.append(contentsOf: children
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .map { ($0, next.depth + 1) })
                continue
            }
            guard items.count + oversized.count < limit else { continue }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            // Size first: reading a 400 MB "script" into memory to find out
            // it is too big is the failure, not the report.
            if let size = values?.fileSize, size > ScriptText.maxImportBytes {
                oversized.append((url.lastPathComponent, size))
                continue
            }
            // A file with no extension is only worth reading if it decodes
            // as text; `ScriptImport` decides that, so hand it everything
            // and let it refuse.
            guard let data = read(url) else { continue }
            items.append(ScriptImport.Item(name: url.lastPathComponent, data: data))
        }
        return (items, oversized)
    }

    /// Read with the security scope the user granted by dropping or
    /// choosing the file. The sandbox hands one out per URL, and a dropped
    /// file is granted the same way an open-panel one is — this just makes
    /// sure it is *taken*, because a scope that is never started is a read
    /// that fails for a reason no error message mentions.
    private static func read(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }

    // MARK: - Clipboard and web

    /// ⌘⇧V: whatever is on the pasteboard becomes a script.
    ///
    /// Three cases, in the order a person means them: a file (paste a PDF
    /// from Finder), a URL (paste a link, get the article), and text. This
    /// is the "paste and go" path — it must never stop to ask a question
    /// the pasteboard already answered.
    static func fromClipboard(existingTitles: [String]) async -> ScriptImport.Outcome? {
        let files = SystemText.clipboardFiles()
        if !files.isEmpty {
            let outcome = importFiles(files, existingTitles: existingTitles)
            if outcome.scripts.isEmpty { reportRejected(outcome) }
            return outcome
        }
        let clipboard = SystemText.clipboardText()
        if let url = ScriptWeb.url(fromClipboardText: clipboard?.body) {
            do {
                let script = try await ScriptWeb.script(for: url, existingTitles: existingTitles)
                return ScriptImport.Outcome(scripts: [script], rejected: [])
            } catch {
                report("Couldn't import that page", error.localizedDescription)
                return nil
            }
        }
        guard let (body, _) = clipboard else { return nil }
        guard let script = ScriptImport.fromBody(body, title: pastedTitle(for: body),
                                                existingTitles: existingTitles) else {
            let empty = ScriptImport.Outcome(scripts: [],
                                             rejected: [.init(name: "Clipboard", reason: .empty)])
            reportRejected(empty)
            return empty
        }
        return ScriptImport.Outcome(scripts: [script], rejected: [])
    }

    /// The title a pasted script arrives under: its first heading, else its
    /// first line, so the sidebar doesn't fill up with "Untitled".
    static func pastedTitle(for body: String) -> String {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if hashes >= 1, hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                let name = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        let firstLine = body.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return "Untitled" }
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }

    // MARK: - Reporting

    /// Say what could not be imported. A silent `continue` here is how a
    /// user drops five files and gets three scripts with no idea which two
    /// went missing, or why.
    static func reportRejected(_ outcome: ScriptImport.Outcome) {
        guard !outcome.rejected.isEmpty else { return }
        let lines = outcome.rejected.prefix(8).map { entry -> String in
            let reason: String
            switch entry.reason {
            case .unsupportedFormat: reason = "no format Cuebar can read"
            case .tooLarge(let bytes): reason = "too large (\(bytes / 1_048_576) MB)"
            case .unreadable: reason = "couldn't be read"
            case .empty: reason = "contains no words"
            }
            return "\(entry.name) — \(reason)"
        }
        var informative = lines.joined(separator: "\n")
        if outcome.rejected.count > lines.count {
            informative += "\n…and \(outcome.rejected.count - lines.count) more."
        }
        if outcome.scripts.isEmpty {
            report("Nothing was imported", informative)
        } else {
            report("Imported \(outcome.scripts.count) script\(outcome.scripts.count == 1 ? "" : "s")",
                   "Skipped:\n\(informative)")
        }
    }

    /// Sheet on the window rather than `NSAlert.runModal()`, for the same
    /// reason the file panels are: a modal with nowhere to attach spins a
    /// nested run loop and is never seen — so an import that hit an error
    /// would fail *silently*, which is the worst possible failure for the
    /// message that exists to explain one.
    static func report(_ message: String, _ informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        guard let window = anyPanelHost() else {
            NSLog("Cuebar: \(message) — \(informative)")
            return
        }
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}