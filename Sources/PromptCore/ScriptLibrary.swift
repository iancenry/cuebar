import Foundation

/// The library on disk: read it, write it, notice when someone else does.
///
/// Everything here is filesystem work with no UI, so it can be tested against
/// a temporary directory and so the store can stay a plain in-memory model
/// with a persistence edge. The rules that matter for a shipped app:
///
/// - **Writes are per file and atomic.** Write to a sibling temp file, then
///   rename over the target. A crash mid-save leaves the previous script
///   intact, and a save can never take the rest of the library with it.
/// - **Nothing is deleted that we did not write.** A file we cannot parse is
///   reported and skipped, left exactly where it is. Somebody's talk is never
///   the app's to throw away.
/// - **Outside edits are first-class.** A file changed in Finder, in another
///   editor, or by `git pull` comes back through the watcher. That is the
///   whole reason for using files instead of a database.
public final class ScriptLibrary {
    /// Where the `.md` files live. Real folders, one per level.
    public let root: URL

    /// Files that could not be read, so the UI can say so rather than
    /// pretending the library is complete.
    public private(set) var unreadable: [URL] = []

    public init(root: URL) {
        self.root = root
    }

    public var scriptsDirectory: URL { root }

    // MARK: - Reading

    /// One script, read from disk. `nil` when the file is not ours.
    public func script(at url: URL) -> (body: String, metadata: ScriptFile.Metadata?, title: String)? {
        guard url.pathExtension.lowercased() == ScriptFile.extensionName else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = ScriptFile.parse(normalised(text))
        let title = url.deletingPathExtension().lastPathComponent
        return (parsed.body, parsed.metadata, title)
    }

    /// One script as it exists on disk.
    public struct Entry: Sendable {
        public var url: URL
        /// The directory it sits in, or nil for the library root.
        public var folder: URL?
        public var body: String
        public var metadata: ScriptFile.Metadata?
        /// The filename without its extension: the script's title.
        public var title: String
        public var modifiedAt: Date?
    }

    /// Every script under the root, paired with the folder it sits in.
    ///
    /// A file the app cannot read is *skipped and recorded*, never truncated
    /// or moved: a script with an encoding we did not expect is still the
    /// user's, and the fix is to tell them, not to tidy it away.
    public func loadAll() -> [Entry] {
        var out: [Entry] = []
        unreadable = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker where !isOurs(url) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            guard url.pathExtension.lowercased() == ScriptFile.extensionName else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                unreadable.append(url)
                continue
            }
            let parsed = ScriptFile.parse(normalised(text))
            let parent = url.deletingLastPathComponent()
            out.append(Entry(url: url,
                             folder: parent == scriptsDirectory ? nil : parent,
                             body: parsed.body,
                             metadata: parsed.metadata,
                             title: url.deletingPathExtension().lastPathComponent,
                             modifiedAt: (try? FileManager.default
                                .attributesOfItem(atPath: url.path)[.modificationDate]
                                as? Date) ?? nil))
        }
        return out
    }

    /// The folder tree, as directory URLs.
    public func directories() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where !isOurs(url) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, url != root else { continue }
            // A symlink *inside* the library is not a folder. Following one
            // gave two directories the same key (so one of them became
            // unaddressable and appeared twice in the sidebar), and one that
            // pointed outside built a phantom directory chain inside the
            // library when a script was filed into it.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true { continue }
            out.append(url)
        }
        return out
    }

    func isOurs(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") || name.hasSuffix(".cuebar-tmp")
            || name.hasSuffix(".tmp")
    }

    /// CRLF in, LF out. A script pasted from Windows otherwise picks up a
    /// carriage return at the end of every line, which the tidy then has to
    /// clean and the presenter sees in a word count.
    func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Writing

    public enum WriteFailure: LocalizedError, Equatable {
        case cannotCreate(String)
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let path): return "Couldn't create \(path)."
            case .cannotWrite(let path):
                return "Couldn't write \(path) — the script is still open, but "
                    + "not saved. Check the folder's permissions."
            }
        }
    }

    /// Write one script atomically.
    public func write(_ body: String, metadata: ScriptFile.Metadata?, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        guard CuebarFiles.ensureDirectory(folder) else {
            throw WriteFailure.cannotCreate(folder.lastPathComponent)
        }
        // A directory where the script's file should be: `replaceItemAt` will
        // happily do something undefined with it, and the edit is lost without
        // a word. Reported instead.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw WriteFailure.cannotWrite(url.lastPathComponent)
        }
        let text = ScriptFile.render(normalised(body), metadata: metadata)
        // Same directory, so the rename is atomic rather than a copy across
        // volumes — and a dot-prefixed name, so the watcher and Finder both
        // ignore it while it exists.
        let temporary = folder.appendingPathComponent(
            "." + url.lastPathComponent + ".cuebar-tmp")
        do {
            try Data(text.utf8).write(to: temporary)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw WriteFailure.cannotWrite(url.lastPathComponent)
        }
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Move a script, keeping its name unless a clash forces a new one.
    @discardableResult
    public func move(_ url: URL, toFolder folder: URL?, keepingName name: String? = nil)
    throws -> URL {
        let target = folder ?? scriptsDirectory
        guard CuebarFiles.ensureDirectory(target) else {
            throw WriteFailure.cannotCreate(target.lastPathComponent)
        }
        let stem = name ?? url.deletingPathExtension().lastPathComponent
        let unique = ScriptFile.uniqueFilename(stem, in: target,
                                              ignoring: [url.lastPathComponent])
        let destination = target.appendingPathComponent(unique + "." + ScriptFile.extensionName)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// A folder path for `name`, made unique against what is already there.
    public func folder(for name: String, under parent: URL) -> URL {
        var candidate = parent.appendingPathComponent(ScriptFile.filename(for: name),
                                                     isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent(
                "\(ScriptFile.filename(for: name)) \(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }
}
