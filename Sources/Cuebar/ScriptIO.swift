import AppKit
import PromptCore
import UniformTypeIdentifiers

/// Save/open panels for scripts. Scripts live in Application Support
/// automatically, but a prompter's text belongs to its author too —
/// export writes a plain-text (Markdown-friendly) file anywhere they
/// choose, import turns .txt/.md files back into scripts.
@MainActor
enum ScriptIO {
    /// Save panel for one script body. Returns true when written.
    @discardableResult
    static func export(_ doc: ScriptDocument) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText]
        panel.nameFieldStringValue = doc.title.isEmpty ? "Untitled" : doc.title
        panel.message = "Choose where to save this script."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try doc.body.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the script"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    /// Open panel for one or more text files. Returns parsed scripts
    /// (title from the filename), or nil when cancelled.
    static func importScripts() -> [(title: String, body: String)]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Import text files as scripts."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        var parsed: [(title: String, body: String)] = []
        for url in panel.urls {
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let title = url.deletingPathExtension().lastPathComponent
            parsed.append((title.isEmpty ? "Untitled" : title, body))
        }
        return parsed
    }
}
