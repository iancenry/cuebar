import Foundation

/// One script. `body` is read-only so `wordCount` can't drift from it, and
/// `folderID` is the only record of where the script lives: `category` was
/// a flat string and is now a *path* through the folder tree, derived.
public struct ScriptDocument: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// Read-only: `wordCount` is derived from the body, so letting anyone
    /// assign the body directly would silently desync the count the sidebar
    /// shows. Go through `setBody`.
    public private(set) var body: String
    public var updatedAt: Date
    /// When the presenter last opened it, for "Recently used". Distinct
    /// from `updatedAt`: editing an old script shouldn't make it recent.
    public var lastOpenedAt: Date?
    /// The folder this script sits in. `nil` is Unfiled, not "the first
    /// folder" — an unfiled script has to stay reachable after a folder is
    /// deleted out from under it.
    public var folderID: UUID?
    public var tags: [String]
    public var isFavorite: Bool
    /// Archived scripts stay on disk and stay searchable, they just leave
    /// the library. Delete is still delete.
    public var isArchived: Bool
    /// The pre-folder `category` string, read once and then cleared by the
    /// store's migration. Never written back: `folderID` is the truth, and
    /// two sources of truth is how a script ends up in two places at once.
    public private(set) var legacyCategory: String?

    public var wordCount: Int = 0

    public init(id: UUID = UUID(), title: String, body: String,
                updatedAt: Date = Date(), folderID: UUID? = nil,
                tags: [String] = [], isFavorite: Bool = false,
                isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
        self.folderID = folderID
        self.tags = tags
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.wordCount = ScriptParser.wordCount(body)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, updatedAt, folderID, tags, isFavorite, isArchived
        case lastOpenedAt
        /// Only ever read, never written — see `legacyCategory`.
        case category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        let text = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        body = text
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        legacyCategory = try c.decodeIfPresent(String.self, forKey: .category)
        wordCount = ScriptParser.wordCount(text)
    }

    /// Hand-written because a custom `init(from:)` opts the type out of
    /// the synthesised `Encodable`, and because the encoding has to be a
    /// deliberate list: `category` and `legacyCategory` are migration-only
    /// and must not be written back, or a file would carry two answers to
    /// where a script lives and the older one would win on a downgrade.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(tags, forKey: .tags)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(isArchived, forKey: .isArchived)
    }

    /// Cleared by the store's migration once the folder exists. Public so
    /// the store — and the tests — can assert the migration is complete.
    public mutating func clearLegacyCategory() { legacyCategory = nil }

    public mutating func setBody(_ body: String) {
        self.body = body
        wordCount = ScriptParser.wordCount(body)
    }
}

/// A folder in the library tree. `parentID == nil` is a top-level folder.
/// Stored flat: a tree in a JSON array is a cycle waiting to happen, and
/// every read needs a parent lookup anyway.
public struct ScriptFolder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

/// Pure tree arithmetic over a flat folder list. Every rule about walking,
/// re-parenting and path building lives here so the store stays a container
/// and the sidebar stays a renderer.
public enum FolderTree {
    /// Depth-first children of `parent`, in stored order. A folder whose
    /// parent no longer exists is treated as top-level rather than
    /// vanishing — a dangling parent must not lose a folder's contents.
    public static func children(of parent: UUID?, in folders: [ScriptFolder]) -> [ScriptFolder] {
        let known = Set(folders.map(\.id))
        return folders.filter { folder in
            // A folder whose parent is missing reads as top-level rather
            // than vanishing — a dangling parent must not lose its contents.
            // Self-parenting is folded to top-level for the same reason,
            // and because a folder that is its own child makes every
            // recursive walk over the tree spin forever.
            if folder.parentID == folder.id { return parent == nil }
            guard let pid = folder.parentID, known.contains(pid) else { return parent == nil }
            return pid == parent
        }
    }

    public static func depth(of id: UUID, in folders: [ScriptFolder]) -> Int {
        var depth = 0
        var cursor = folders.first { $0.id == id }
        // Bounded: a corrupt file could contain a parent cycle, and an
        // unbounded walk here would hang the sidebar's body.
        while let folder = cursor, let parent = folder.parentID, depth < 32 {
            depth += 1
            cursor = folders.first { $0.id == parent }
        }
        return depth
    }

    /// `id` and everything under it, in depth-first order.
    public static func subtree(of id: UUID, in folders: [ScriptFolder]) -> [ScriptFolder] {
        var out: [ScriptFolder] = []
        var queue = [id]
        var seen: Set<UUID> = []
        while let next = queue.first {
            queue.removeFirst()
            guard seen.insert(next).inserted else { continue }
            guard let folder = folders.first(where: { $0.id == next }) else { continue }
            out.append(folder)
            queue.append(contentsOf: children(of: next, in: folders).map(\.id))
        }
        return out
    }

    /// "Presentations/Product Demo". `nil` is "Unfiled".
    public static func path(of id: UUID?, in folders: [ScriptFolder]) -> String {
        guard let id, let folder = folders.first(where: { $0.id == id }) else { return "Unfiled" }
        var parts = [folder.name]
        var cursor = folder.parentID
        var guard_ = 0
        while let parentID = cursor, guard_ < 32, let parent = folders.first(where: { $0.id == parentID }) {
            parts.insert(parent.name, at: 0)
            cursor = parent.parentID
            guard_ += 1
        }
        return parts.joined(separator: " / ")
    }

    /// Create the missing folders along `path` and return the leaf. Used to
    /// migrate the old flat `category` strings, which could already contain
    /// a slash from a hand-edited file.
    public static func ensurePath(_ path: String, in folders: inout [ScriptFolder]) -> UUID {
        var parent: UUID?
        for component in path.split(separator: "/").map(String.init) {
            let name = component.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let existing = folders.first(where: { $0.name == name && $0.parentID == parent }) {
                parent = existing.id
                continue
            }
            let folder = ScriptFolder(name: name, parentID: parent)
            folders.append(folder)
            parent = folder.id
        }
        return parent ?? UUID()
    }
}

@MainActor
@Observable
public final class ScriptStore {
    public private(set) var scripts: [ScriptDocument] = []
    public private(set) var folders: [ScriptFolder] = []
    public var selectedID: UUID?
    /// The script most recently brought in from outside the app — a file, a
    /// drop, the clipboard, a web page. Published rather than acted on
    /// here, because "put it on stage" is a view concern and `mode` lives
    /// in the view tree: the import command runs at app level, where the
    /// perform/edit switch cannot be reached. Views watch this and switch
    /// themselves, which is how a paste lands ready to present instead of
    /// ready to be edited.
    public private(set) var lastImportedID: UUID?

    /// Files in the library that could not be read. Reported, never removed:
    /// a script this build cannot parse is still the user's work, and the
    /// honest response is to say so rather than tidy it away.
    public private(set) var unreadableFiles: [String] = []

    /// Scripts whose last write failed. A folder the app cannot write to is
    /// a fact worth showing — the alternative is a presenter believing a talk
    /// is saved when it is not.
    public private(set) var unsavedScripts: Set<UUID> = []
    public var hasUnsavedScripts: Bool { !unsavedScripts.isEmpty }

    private let library: ScriptLibrary?
    private let legacyLibraryURL: URL?
    private let legacyFoldersURL: URL?
    private let legacyCategoriesURL: URL?
    /// Where each script's file is. The one map that makes a title change a
    /// file move rather than a second name to keep in step.
    private var paths: [UUID: URL] = [:]
    private var metadata: [UUID: ScriptFile.Metadata] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    /// Folder ids are derived from the directory's path, so they survive a
    /// relaunch without being written down anywhere.
    private var folderIDsByPath: [String: UUID] = [:]
    /// The exact text of the last successful write, per script. This is what
    /// makes "somebody else edited this" a fact rather than a guess: the file
    /// is compared against what we put there, so there is no window in which a
    /// real edit is invisible because it happened to arrive just after a save.
    private var lastWritten: [UUID: String] = [:]
    private var watcher: ScriptWatcher?

    /// Starter folders shown in a fresh library.
    public static let defaultFolderNames = ["Presentations", "Interviews", "Personal"]

    public var selected: ScriptDocument? {
        scripts.first(where: { $0.id == selectedID })
    }

    /// Everything the library shows, minus the archive.
    public var liveScripts: [ScriptDocument] { scripts.filter { !$0.isArchived } }

    // MARK: - Lifecycle

    /// Production init: the library is `~/Documents/Cuebar/Scripts`.
    public init() {
        // Before anything reads a path: an older Cuebar kept the library in
        // Application Support, and moving it is not something the user should
        // have to know about. Idempotent, and it never overwrites a file that
        // is already in the new place.
        CuebarFiles.migrateFromLegacy()
        self.library = ScriptLibrary(root: CuebarFiles.scriptsDirectory)
        self.legacyLibraryURL = CuebarFiles.legacyLibrary
        self.legacyFoldersURL = CuebarFiles.legacyFolders
        self.legacyCategoriesURL = CuebarFiles.legacyCategories
        load()
        // Only seed a first-run library when there was nothing to migrate: a
        // store that failed to read its own files must not invite "Welcome"
        // in beside them.
        if scripts.isEmpty, unreadableFiles.isEmpty, !migrateLegacyLibrary() {
            seedWelcome()
        }
        restoreSelection()
        startWatching()
    }

    /// Test seam: the same store, pointed at a file the test owns.
    ///
    /// There was no way to test persistence at all before this — the URL was
    /// `private let` and hardcoded to Application Support, so a test that
    /// wanted to check what was written had to write it over the user's
    /// library. Every persistence bug therefore shipped unobserved, including
    /// the one this pair of tests exists for: the open script was not stored
    /// at all.
    /// Test seam: the same store, pointed at a directory the test owns.
    ///
    /// There was no way to test persistence at all before this — the path was
    /// `private let` and hardcoded to Application Support, so a test that
    /// wanted to check what was written had to write it over the user's
    /// library. Every persistence bug therefore shipped unobserved, including
    /// the one these tests exist for: the open script was not stored at all.
    init(libraryRoot: URL, legacyLibrary: URL? = nil, legacyFolders: URL? = nil) {
        self.library = ScriptLibrary(root: libraryRoot)
        self.legacyLibraryURL = legacyLibrary
        self.legacyFoldersURL = legacyFolders
        self.legacyCategoriesURL = nil
        CuebarFiles.ensureDirectory(libraryRoot)
        load()
        if scripts.isEmpty, unreadableFiles.isEmpty, !migrateLegacyLibrary() {
            seedWelcome()
        }
        restoreSelection()
    }

    /// Test/preview init: in-memory only.
    public init(inMemory scripts: [ScriptDocument], folders: [ScriptFolder] = []) {
        self.library = nil
        self.legacyLibraryURL = nil
        self.legacyFoldersURL = nil
        self.legacyCategoriesURL = nil
        self.scripts = scripts
        self.folders = folders
        self.selectedID = scripts.first?.id
    }

    /// A brand-new library: the starter folders exist on disk from the first
    /// launch, so what the sidebar shows is what Finder shows.
    private func seedWelcome() {
        var personal: ScriptFolder?
        for name in Self.defaultFolderNames {
            let url = library?.folder(for: name, under: library!.scriptsDirectory) ?? URL(fileURLWithPath: "/")
            guard let library else { return }
            CuebarFiles.ensureDirectory(url)
            let folder = ScriptFolder(name: name)
            folders.append(folder)
            if let key = Self.relativeKey(url, under: library.scriptsDirectory) {
                folderIDsByPath[key] = folder.id
            }
            if name == "Personal" { personal = folder }
        }
        var doc = ScriptDocument(title: "Welcome", body: SampleTexts.welcome,
                                 folderID: personal?.id)
        doc.lastOpenedAt = Date()
        scripts = [doc]
        selectedID = doc.id
        writeNow(doc.id)
    }

    /// Open the script that was open last, rather than whichever one was
    /// edited last — and falling back to the same order the sidebar shows.
    private func restoreSelection() {
        if let recent = recentScripts.first {
            selectedID = recent.id
        } else {
            selectedID = liveScripts.first?.id
        }
    }

    /// A folder's key: its path relative to the library root.
    ///
    /// Both sides are resolved first, and that is not fussiness — on macOS
    /// `/var` is a symlink to `/private/var`, and a directory enumerator
    /// hands back resolved paths while the configured root usually is not. The
    /// two spellings of the same folder then failed to match, so every
    /// folder looked new on every reload: a new id each time, and the sidebar's
    /// folder selection with it.
    static func relativeKey(_ url: URL, under root: URL) -> String? {
        // Both sides are resolved, and that is not fussiness — on macOS `/var`
        // is a symlink to `/private/var` and a directory enumerator hands back
        // resolved paths while the configured root usually is not. The two
        // spellings of the same folder then failed to match, so every folder
        // looked new on every reload.
        //
        // Returns nil for anything that is not *under* the root. Returning the
        // absolute path instead — which is what this used to do — meant a
        // symlink pointing out of the library produced a key like
        // `/var/folders/…/Somewhere`, and filing a script into that folder
        // built a phantom directory chain inside the library that the next read
        // turned into a junk tree in the sidebar.
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedURL.hasPrefix(base), resolvedURL != resolvedRoot else { return nil }
        return String(resolvedURL.dropFirst(base.count))
    }

    // MARK: - Folders

    public func childFolders(of parent: UUID?) -> [ScriptFolder] {
        FolderTree.children(of: parent, in: folders)
    }

    /// Depth-first list for rendering, each folder paired with its depth.
    public func folderRows() -> [(folder: ScriptFolder, depth: Int)] {
        var out: [(ScriptFolder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in childFolders(of: parent) {
                out.append((folder, depth))
                walk(folder.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    public func folderPath(_ id: UUID?) -> String { FolderTree.path(of: id, in: folders) }

    public func folderName(_ id: UUID?) -> String { FolderTree.path(of: id, in: folders) }

    /// This folder and everything beneath it — the set a delete or a
    /// recursive count has to cover.
    public func subtreeFolderIDs(of id: UUID) -> Set<UUID> {
        Set(FolderTree.subtree(of: id, in: folders).map(\.id))
    }

    public func scriptCount(in folder: UUID, includeNested: Bool = true) -> Int {
        let ids: Set<UUID> = includeNested ? subtreeFolderIDs(of: folder) : [folder]
        return liveScripts.count { $0.folderID.map(ids.contains) ?? false }
    }

    public func scripts(inFolder folder: UUID?, includeNested: Bool = false) -> [ScriptDocument] {
        guard let folder else { return liveScripts.filter { $0.folderID == nil } }
        let ids = includeNested ? subtreeFolderIDs(of: folder) : [folder]
        return liveScripts.filter { $0.folderID.map(ids.contains) ?? false }
    }

    @discardableResult
    public func createFolder(name: String, parent: UUID? = nil) -> ScriptFolder {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ScriptFolder(name: clean.isEmpty ? "Untitled folder" : clean, parentID: parent)
        folders.append(folder)
        if let library {
            let parentURL = directoryURL(of: parent) ?? library.scriptsDirectory
            let url = library.folder(for: folder.name, under: parentURL)
            if CuebarFiles.ensureDirectory(url),
               let key = Self.relativeKey(url, under: library.scriptsDirectory) {
                folderIDsByPath[key] = folder.id
            }
        }
        return folder
    }

    /// A folder's directory, from the ids derived when the tree was read.
    public func directoryURL(of id: UUID?) -> URL? {
        guard let library, let id else { return nil }
        guard let key = folderIDsByPath.first(where: { $0.value == id })?.key else { return nil }
        return library.scriptsDirectory.appendingPathComponent(key, isDirectory: true)
    }

    /// Rename a folder by renaming its directory.
    ///
    /// Folder ids are derived from a folder's path, so a rename has to
    /// re-derive every folder beneath it. The *ids* stay put — only the map
    /// from path to id changes — which is why no script's filing needs
    /// rewriting and why the sidebar does not have to reload.
    public func renameFolder(_ id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != folders[i].name else { return }
        guard let library, let from = directoryURL(of: id),
              FileManager.default.fileExists(atPath: from.path) else {
            folders[i].name = clean
            return
        }

        guard let ownKey = Self.relativeKey(from, under: library.scriptsDirectory) else { return }
        // Every path in the subtree, captured *before* the move: afterwards
        // they no longer exist to be looked up.
        let before = Dictionary(uniqueKeysWithValues:
            folders.filter { subtreeFolderIDs(of: id).contains($0.id) }
                .compactMap { folder -> (UUID, String)? in
                    guard let url = directoryURL(of: folder.id),
                          let key = Self.relativeKey(url, under: library.scriptsDirectory)
                    else { return nil }
                    return (folder.id, key)
                })
        let newLeaf = ScriptFile.filename(for: clean)
        let destination = from.deletingLastPathComponent()
            .appendingPathComponent(newLeaf, isDirectory: true)
        guard (try? FileManager.default.moveItem(at: from, to: destination)) != nil else { return }
        let parentRelative = Self.relativeKey(from.deletingLastPathComponent(),
                                              under: library.scriptsDirectory) ?? ""
        let prefix = parentRelative.isEmpty ? newLeaf : parentRelative + "/" + newLeaf
        for (_, oldKey) in before { folderIDsByPath.removeValue(forKey: oldKey) }
        for (folderID, oldKey) in before {
            guard oldKey == ownKey || oldKey.hasPrefix(ownKey + "/") else { continue }
            folderIDsByPath[prefix + String(oldKey.dropFirst(ownKey.count))] = folderID
        }
        folders[i].name = clean
    }

    /// Delete a folder and pull its contents up to its parent. Scripts go
    /// to the parent folder, not to Unfiled and not into the bin: deleting
    /// a folder should reorganise, not lose work.
    public func deleteFolder(_ id: UUID) {
        let parent = folders.first { $0.id == id }?.parentID
        let doomed = subtreeFolderIDs(of: id)
        for i in scripts.indices where scripts[i].folderID.map(doomed.contains) ?? false {
            moveScript(scripts[i].id, to: parent, updatingFolder: false)
        }
        for folderID in doomed {
            if let url = directoryURL(of: folderID) {
                try? FileManager.default.removeItem(at: url)
                if let key = Self.relativeKey(url, under: library?.scriptsDirectory ?? url) {
                    folderIDsByPath.removeValue(forKey: key)
                }
            }
        }
        folders.removeAll { doomed.contains($0.id) }
    }

    public func moveScript(_ id: UUID, to folder: UUID?) {
        moveScript(id, to: folder, updatingFolder: true)
    }

    /// Filing a script is a file move.
    ///
    /// The destination name is chosen by the filesystem's own rules, so
    /// dropping "Talk" into a folder that already has one lands as
    /// "Talk 2" — the same thing Finder would do — instead of quietly
    /// replacing somebody's talk with another.
    private func moveScript(_ id: UUID, to folder: UUID?, updatingFolder: Bool) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        guard let library else {
            scripts[i].folderID = folder
            return
        }
        let destination = directoryURL(of: folder) ?? library.scriptsDirectory
        guard let from = paths[id] else {
            scripts[i].folderID = folder
            writeNow(id)
            return
        }
        let alreadyThere = (from.deletingLastPathComponent().standardizedFileURL.path
            == destination.standardizedFileURL.path)
        if !alreadyThere, let moved = try? library.move(from, toFolder: destination) {
            paths[id] = moved
            let stem = moved.deletingPathExtension().lastPathComponent
            if stem != scripts[i].title {
                // A clash changed the name, and the title *is* the name.
                scripts[i].title = stem
                writeNow(id)
            }
        }
        if updatingFolder {
            scripts[i].folderID = folder
            scripts[i].updatedAt = Date()
            save(id)
        } else {
            scripts[i].folderID = folder
            scripts[i].updatedAt = Date()
        }
    }

    // MARK: - Tags

    /// Every tag in use, sorted, case-insensitively deduped.
    public var allTags: [String] {
        var seen: [String] = []
        for tag in liveScripts.flatMap(\.tags) where !seen.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            seen.append(tag)
        }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Titles in use, for the import's duplicate check. Case-insensitive
    /// inside that check, so this is just the list.
    public var titles: [String] { scripts.map(\.title) }

    public func scripts(tagged tag: String) -> [ScriptDocument] {
        liveScripts.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    public func addTag(_ raw: String, to id: UUID) {
        let tag = Self.normaliseTag(raw)
        guard !tag.isEmpty, let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        guard !scripts[i].tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        scripts[i].tags.append(tag)
        scripts[i].updatedAt = Date()
        save(id)
    }

    public func removeTag(_ tag: String, from id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        save(id)
    }

    /// Tags are free text typed by a presenter mid-rehearsal, so they get
    /// tidied: trimmed, collapsed whitespace, capped, and no leading `#`
    /// (which is a convention from the issue tracker, not from here).
    static func normaliseTag(_ raw: String) -> String {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Tags are written as a comma-separated list, so a comma inside one
        // would come back as two tags after a relaunch. Replaced rather than
        // rejected: the tag is a label, and losing the word is worse than
        // losing the punctuation.
        tag = tag.replacingOccurrences(of: ",", with: " ")
        return String(tag.prefix(32))
    }

    // MARK: - Favourites, archive, recents

    public var favorites: [ScriptDocument] { liveScripts.filter(\.isFavorite) }
    public var archivedScripts: [ScriptDocument] { scripts.filter(\.isArchived) }

    public var recentScripts: [ScriptDocument] {
        liveScripts
            .filter { $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    public func toggleFavorite(_ id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].isFavorite.toggle()
        save(id)
    }

    public func setArchived(_ archived: Bool, for id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].isArchived = archived
        if archived, selectedID == id { selectedID = liveScripts.first?.id }
        save(id)
    }

    /// When a script was last open lives in that script's file, so "reopen
    /// the talk I was reading" survives a launch without an index to keep.
    public func markOpened(_ id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].lastOpenedAt = Date()
        save(id)
    }

    /// Copy, including the folder and tags — a duplicate that lost its
    /// filing would be filed wherever it happened to be pasted.
    @discardableResult
    public func duplicate(_ id: UUID) -> ScriptDocument? {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return nil }
        let source = scripts[i]
        let copy = ScriptDocument(title: Self.uniqueTitle("\(source.title) copy", in: scripts),
                                  body: source.body, folderID: source.folderID,
                                  tags: source.tags, isFavorite: false)
        scripts[i].lastOpenedAt = Date()
        scripts.insert(copy, at: i + 1)
        // Through `select`, which records when a script was opened: assigning
        // `selectedID` left the copy out of "Recently used", and out of the
        // script that gets restored on the next launch.
        select(copy.id)
        writeNow(copy.id)
        return copy
    }

    private static func uniqueTitle(_ base: String, in docs: [ScriptDocument]) -> String {
        let titles = Set(docs.map(\.title))
        guard titles.contains(base) else { return base }
        var n = 2
        while titles.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Selection and content

    public func select(_ id: UUID) {
        guard scripts.contains(where: { $0.id == id }) else { return }
        selectedID = id
        markOpened(id)
    }

    @discardableResult
    public func add(title: String = "Untitled", body: String = "",
                    folder: UUID? = nil) -> ScriptDocument {
        let target = folder ?? selected?.folderID
        var doc = ScriptDocument(title: title, body: body, folderID: target)
        doc.lastOpenedAt = Date()
        scripts.insert(doc, at: 0)
        selectedID = doc.id
        // Written immediately, not on the debounce: a script the user has
        // not typed into yet should still be a file they can find.
        writeNow(doc.id)
        // The file may have had to take a numbered name, in which case the
        // title follows it — so hand back what the store actually holds
        // rather than the name that was asked for.
        return scripts.first(where: { $0.id == doc.id }) ?? doc
    }

    /// Bring an outside script into the library.
    ///
    /// Filed next to whatever is selected, the same as New Script: an import
    /// that landed in Unfiled every time was invisible to anyone browsing
    /// their Presentations folder. The selection is *not* moved here —
    /// importing five files at once should leave the presenter on the one
    /// they were reading, and the caller decides what to open.
    @discardableResult
    public func importScript(_ imported: ImportedScript, folder: UUID? = nil) -> ScriptDocument {
        let target = folder ?? selected?.folderID
        var doc = ScriptDocument(title: imported.title, body: imported.body, folderID: target)
        doc.lastOpenedAt = Date()
        scripts.insert(doc, at: 0)
        lastImportedID = doc.id
        writeNow(doc.id)
        return scripts.first(where: { $0.id == doc.id }) ?? doc
    }

    /// Forget the last import, so re-selecting the same script later doesn't
    /// drag the editor back to the prompter.
    public func clearImported() {
        lastImportedID = nil
    }

    /// Deleting a script deletes its file — and only its file. Cuebar does
    /// not keep a bin: the talk is in the user's Documents, where it can be
    /// put back from the Trash like anything else they own.
    public func delete(_ id: UUID) {
        if let url = paths[id] {
            saveTasks[id]?.cancel()
            saveTasks[id] = nil
            library?.remove(url)
        }
        paths.removeValue(forKey: id)
        metadata.removeValue(forKey: id)
        scripts.removeAll(where: { $0.id == id })
        unsavedScripts.remove(id)
        if selectedID == id { selectedID = liveScripts.first?.id }
    }

    public func updateBody(_ id: UUID, body: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].setBody(body)
        scripts[i].updatedAt = Date()
        save(id)
    }

    /// Renaming a script renames its file. The title *is* the filename, so
    /// renaming it anywhere — here, in the sidebar, or in Finder — retitles
    /// the script, and there is never a second name to fall out of step.
    public func rename(_ id: UUID, title: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = clean.isEmpty ? "Untitled" : clean
        guard wanted != scripts[i].title else { return }
        scripts[i].title = wanted
        scripts[i].updatedAt = Date()
        guard let from = paths[id] else {
            save(id)
            return
        }
        let folder = from.deletingLastPathComponent()
        let stem = ScriptFile.filename(for: wanted)
        let unique = ScriptFile.uniqueFilename(stem, in: folder,
                                              ignoring: [from.lastPathComponent])
        let destination = folder.appendingPathComponent(unique + "." + ScriptFile.extensionName)
        if unique != from.deletingPathExtension().lastPathComponent {
            // Somebody already has a script by that name here, so the file
            // becomes "Talk 2" — and so does the title, or the app and Finder
            // would disagree about what this script is called.
            scripts[i].title = unique
        }
        guard (try? FileManager.default.moveItem(at: from, to: destination)) != nil else {
            save(id)
            return
        }
        paths[id] = destination
        save(id)
    }

    // MARK: - Persistence

    /// Coalesced per script, not for the whole library.
    ///
    /// The title field commits on every keystroke and bodies can be large, so
    /// writes collapse to the latest state shortly after the last change —
    /// and because only one script is being edited at a time, only that
    /// script's file is touched. Renaming a folder rewrites nothing at all.
    private func save(_ id: UUID) {
        guard library != nil else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.writeNow(id)
        }
    }

    /// Write one script's file, now, and say so if we could not.
    private func writeNow(_ id: UUID) {
        saveTasks[id] = nil
        guard let library, let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        let doc = scripts[i]
        var meta = metadata[id] ?? ScriptFile.Metadata(id: doc.id)
        meta.lastOpened = doc.lastOpenedAt
        meta.tags = doc.tags
        meta.isFavorite = doc.isFavorite
        meta.isArchived = doc.isArchived
        let destination = paths[id] ?? newPath(for: doc)
        if paths[id] == nil {
            // The filesystem may have had to number the name because another
            // script already had it. The title *is* the filename, so the title
            // follows rather than quietly disagreeing with the file.
            let stem = destination.deletingPathExtension().lastPathComponent
            if stem != doc.title, let i = scripts.firstIndex(where: { $0.id == id }) {
                scripts[i].title = stem
            }
        }
        do {
            try library.write(scripts[i].body, metadata: meta, to: destination)
            paths[id] = destination
            metadata[id] = meta
            lastWritten[id] = scripts[i].body
            unsavedScripts.remove(id)
        } catch {
            unsavedScripts.insert(id)
        }
    }

    /// Where a script's file belongs, with a name nothing else in that
    /// folder is using.
    private func newPath(for doc: ScriptDocument) -> URL {
        let directory = directoryURL(of: doc.folderID)
            ?? library?.scriptsDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stem = ScriptFile.filename(for: doc.title)
        return directory.appendingPathComponent(
            ScriptFile.uniqueFilename(stem, in: directory) + "." + ScriptFile.extensionName)
    }

    /// Read the library off disk. One file per script, folders are
    /// directories, and a file we cannot read is reported rather than
    /// dropped — the difference between "Cuebar lost my talk" and "Cuebar
    /// could not open this one file".
    /// `preRead` is what `reloadFromDisk` already read from disk. Walking the
    /// library twice per reload cost a measured 113 ms on a 200-script library,
    /// on the main actor, for every save and every outside edit.
    private func load(entries preRead: [ScriptLibrary.Entry]? = nil,
                      keepingBodiesFor keep: Set<UUID> = []) {
        guard let library else { return }
        let read = preRead ?? library.loadAll()
        var built: [ScriptDocument] = []
        var builtFolders: [ScriptFolder] = []
        var folderIDs: [String: UUID] = [:]
        var builtPaths: [UUID: URL] = [:]
        var builtMetadata: [UUID: ScriptFile.Metadata] = [:]

        let directories = library.directories()
            .sorted { $0.path.count < $1.path.count }   // parents before children
        for url in directories {
            guard let key = Self.relativeKey(url, under: library.scriptsDirectory) else {
                continue
            }
            let parentKey = (key as NSString).deletingLastPathComponent
            // Reuse the id this folder already had. Minting a fresh UUID here
            // changed every folder's identity on every reload, and the sidebar
            // keys its collapsed set and its folder selection on exactly these
            // ids: one watcher event popped every folder open and turned a
            // folder-filtered sidebar into an empty "Unfiled".
            let id = folderIDsByPath[key] ?? UUID()
            let folder = ScriptFolder(id: id, name: url.lastPathComponent,
                                      parentID: folderIDs[parentKey])
            builtFolders.append(folder)
            folderIDs[key] = id
        }

        for entry in read {
            let folderKey = entry.folder.flatMap {
                Self.relativeKey($0, under: library.scriptsDirectory)
            }
            let meta = entry.metadata ?? ScriptFile.Metadata()
            // A file with no front matter of its own takes its creation date
            // from the filesystem, not from the moment Cuebar happened to look.
            let created = entry.metadata == nil
                ? (entry.modifiedAt ?? Date())
                : meta.created
            var doc = ScriptDocument(id: meta.id, title: entry.title,
                                     body: keep.contains(meta.id)
                                        ? (scripts.first { $0.id == meta.id }?.body ?? entry.body)
                                        : entry.body,
                                     updatedAt: entry.modifiedAt ?? created,
                                     folderID: folderKey.flatMap { folderIDs[$0] },
                                     tags: meta.tags, isFavorite: meta.isFavorite,
                                     isArchived: meta.isArchived)
            doc.lastOpenedAt = meta.lastOpened
            if keep.contains(meta.id), let i = scripts.firstIndex(where: { $0.id == meta.id }) {
                doc.setBody(scripts[i].body)
            }
            // Two files carrying the same id are two scripts — which is exactly
            // what duplicating a talk in Finder produces. Last-writer-wins here
            // made the copy invisible, and every later edit landed in whichever
            // file the enumerator happened to visit last, while the sidebar
            // showed the other one.
            if builtPaths[doc.id] != nil, builtPaths[doc.id] != entry.url {
                let copy = ScriptDocument(id: UUID(), title: entry.title, body: doc.body,
                                          updatedAt: doc.updatedAt, folderID: doc.folderID,
                                          tags: doc.tags, isFavorite: doc.isFavorite,
                                          isArchived: doc.isArchived)
                built.append(copy)
                builtPaths[copy.id] = entry.url
                builtMetadata[copy.id] = ScriptFile.Metadata()
                continue
            }
            built.append(doc)
            builtPaths[doc.id] = entry.url
            builtMetadata[doc.id] = meta
        }

        scripts = built.sorted { $0.updatedAt > $1.updatedAt }
        folders = builtFolders
        folderIDsByPath = folderIDs
        paths = builtPaths
        metadata = builtMetadata
        unreadableFiles = library.unreadable.map(\.lastPathComponent)
    }

    /// The old single-file library, read once into files, then set aside.
    ///
    /// Returns whether there was anything to migrate. The JSON is *renamed*,
    /// not deleted: if a future version finds a bug in this conversion, the
    /// original is still on disk, and a user who quits halfway through a
    /// conversion gets a backup rather than a partial library.
    @discardableResult
    private func migrateLegacyLibrary() -> Bool {
        guard let library, let url = legacyLibraryURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LegacyLibrary.self, from: data) else {
            return false
        }
        let legacyFolders = (legacyFoldersURL.flatMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode([ScriptFolder].self, from: $0) }
        }) ?? []
        var folderPath: [UUID: String] = [:]
        for folder in legacyFolders {
            let names = FolderTree.path(of: folder.id, in: legacyFolders)
                .components(separatedBy: " / ")
                .filter { !$0.isEmpty }
            let key = names.map(ScriptFile.filename(for:)).joined(separator: "/")
            folderPath[folder.id] = key
            var url = library.scriptsDirectory
            for component in key.split(separator: "/") {
                url = url.appendingPathComponent(String(component), isDirectory: true)
                CuebarFiles.ensureDirectory(url)
            }
            folderIDsByPath[key] = folder.id
        }
        // A library of nothing but one talk must not come back with three
        // empty starter folders in it.
        var imported = 0
        for doc in decoded.scripts {
            let key = doc.folderID.flatMap { folderPath[$0] }
            var url = library.scriptsDirectory
            for component in (key ?? "").components(separatedBy: "/") where !component.isEmpty {
                url = url.appendingPathComponent(component, isDirectory: true)
            }
            let stem = ScriptFile.filename(for: doc.title)
            let destination = url.appendingPathComponent(
                ScriptFile.uniqueFilename(stem, in: url) + "." + ScriptFile.extensionName)
            let meta = ScriptFile.Metadata(id: doc.id,
                                          created: doc.updatedAt,
                                          lastOpened: doc.lastOpenedAt,
                                          tags: doc.tags,
                                          isFavorite: doc.isFavorite,
                                          isArchived: doc.isArchived)
            do {
                try library.write(doc.body, metadata: meta, to: destination)
                paths[doc.id] = destination
                imported += 1
            } catch {
                unsavedScripts.insert(doc.id)
            }
        }
        setAside(url)
        load()
        selectedID = decoded.selectedID.flatMap { id in paths.keys.contains(id) ? id : nil }
        return imported > 0
    }

    private func setAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let parked = url.deletingLastPathComponent()
            .appendingPathComponent("scripts.json.migrated-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: parked)
    }

    // MARK: - Outside edits

    private func startWatching() {
        guard let library else { return }
        watcher = ScriptWatcher(root: library.scriptsDirectory) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
    }


    /// Pick up a script edited, added, moved or deleted outside Cuebar.
    ///
    /// Files win over memory, with one deliberate exception: **the script the
    /// editor has open.** Its text belongs to the caret and to the 400 ms
    /// commit that is still pending behind the last keystroke; reading the file
    /// back over it either loses those keystrokes or silently discards an edit
    /// the user made in their own editor. So instead of adopting it, the store
    /// records it in `externalChanges` and the editor asks.
    ///
    /// Two other things are held rather than read back: anything with a save
    /// in flight (the write is newer than the file) and anything whose last
    /// write failed (that text exists nowhere else at all).
    func reloadFromDisk() {
        guard let library else { return }
        let inFlight = Set(saveTasks.compactMap { id, task in
            task.isCancelled ? nil : id
        })
        var keep = inFlight.union(unsavedScripts)
        if let id = selectedID { keep.insert(id) }

        // What the file said before this read, so an outside change can be
        // told apart from a save we made ourselves.
        let entries = library.loadAll()
        var onDisk: [UUID: ScriptLibrary.Entry] = [:]
        for entry in entries {
            if let id = entry.metadata?.id, onDisk[id] == nil { onDisk[id] = entry }
        }

        var external: Set<UUID> = []
        if let id = selectedID, let entry = onDisk[id], !inFlight.contains(id),
           !unsavedScripts.contains(id),
           let ours = lastWritten[id] ?? scripts.first(where: { $0.id == id })?.body,
           entry.body != ours {
            external.insert(id)
        }

        // Keep anything we held whose file has gone: a failed write must not
        // be erased by a reload, and a script deleted in Finder must be
        // dropped (unless it is one of those).
        // A document whose file has gone: dropped, so deleting a script in
        // Finder actually deletes it — *except* when its last write failed, in
        // which case the file is the only reason the text still exists nowhere
        // else, and when it is the open script and the reload found it gone on
        // purpose.
        // Every document with no readable file is re-added from memory, which
        // is what keeps a *failed write* alive: its text is nowhere else, and
        // the earlier version excluded exactly those — so the next reload
        // deleted the document and every later keystroke was swallowed by a
        // `firstIndex` guard on something that no longer existed.
        //
        // The open script is the exception: if its file is gone it was deleted
        // on purpose, and Finder's delete has to stick.
        let vanished = keep.filter { id in
            guard onDisk[id] == nil else { return false }
            // The open script is normally dropped — its file being gone means
            // it was deleted on purpose, and Finder's delete has to stick. But
            // a *failed write* also leaves it without a file, and that text
            // exists nowhere else.
            return id != selectedID || unsavedScripts.contains(id)
        }
        heldBeforeLoad = Dictionary(uniqueKeysWithValues:
            scripts.filter { vanished.contains($0.id) }.map { ($0.id, $0) })

        // A conflict on a script that is *not* open any more is not a conflict:
        // the user has moved on, and adopting it silently is the whole point of
        // using files. Left flagged, the banner would come back claiming two
        // texts differ when they are identical.
        if externalChanges.contains(where: { $0 != selectedID }) {
            let stillOpen = Set(keep)
            externalChanges.subtract(Set(scripts.map(\.id)).subtracting(stillOpen)
                .intersection(externalChanges))
            keep.subtract(externalChanges.filter { $0 != selectedID })
        }

        load(entries: entries, keepingBodiesFor: keep)
        for id in vanished {
            if let doc = heldBeforeLoad[id] {
                scripts.append(doc)
                if paths[id] == nil { paths[id] = newPath(for: doc) }
            }
        }
        externalChanges.formUnion(external)
        // A failure that no longer describes anything must not keep the editor
        // claiming a script is unsaved forever.
        unsavedScripts.formIntersection(Set(scripts.map(\.id)))
        externalChanges.subtract(unsavedScripts)

        // If the open script's file is gone, open something rather than
        // nothing: an overlay with no script in it is the app looking broken.
        if selectedID.map({ id in scripts.contains { $0.id == id } }) != true {
            selectedID = recentScripts.first?.id ?? liveScripts.first?.id
        }
        scripts.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Scripts whose file changed on disk since Cuebar last wrote them, and
    /// which the editor has open. Surfaced rather than resolved: only the
    /// person editing can say which version is the one they want.
    public private(set) var externalChanges: Set<UUID> = []

    /// Take the file's version of an open script, discarding the editor's.
    public func acceptExternalChange(_ id: UUID) {
        guard externalChanges.contains(id) else { return }
        // Take the file's text first, and only then clear the flag: clearing it
        // up front made the button a lie — with the file deleted in between, it
        // dismissed the banner without applying anything, and the edit was gone.
        guard let entry = library?.loadAll().first(where: { $0.metadata?.id == id }),
              let i = scripts.firstIndex(where: { $0.id == id }) else {
            externalChanges.remove(id)
            return
        }
        scripts[i].setBody(entry.body)
        scripts[i].updatedAt = entry.modifiedAt ?? Date()
        // Recorded as *ours*, or the next reload sees a body it did not write
        // and puts the banner straight back — a button that clears a warning
        // which returns on the next event.
        lastWritten[id] = entry.body
        externalChanges.remove(id)
    }

    /// Keep the editor's version and overwrite the file.
    public func keepLocalVersion(_ id: UUID) {
        guard externalChanges.contains(id) else { return }
        externalChanges.remove(id)
        writeNow(id)
    }

    /// What the editor is holding for the open script, for the views to show
    /// the difference if they want to.
    public func localBody(_ id: UUID) -> String? {
        scripts.first { $0.id == id }?.body
    }

    private var heldBeforeLoad: [UUID: ScriptDocument] = [:]

    private struct LegacyLibrary: Codable {
        var selectedID: UUID?
        var scripts: [ScriptDocument]
    }
}

public enum SampleTexts {
    public static let welcome = """
    Welcome to Cuebar. [smile]

    Press Option-Space to play. Click any word to jump straight there.

    Take a breath here. [pause] The highlight follows you while cues stay pink and never count as words.
    """
}
