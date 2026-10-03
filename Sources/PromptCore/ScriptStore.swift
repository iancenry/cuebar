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

    private let fileURL: URL?
    private let foldersURL: URL?
    private let legacyCategoriesURL: URL?
    private var saveTask: Task<Void, Never>?

    /// Starter folders shown in a fresh library.
    public static let defaultFolderNames = ["Presentations", "Interviews", "Personal"]

    public var selected: ScriptDocument? {
        scripts.first(where: { $0.id == selectedID })
    }

    /// Everything the library shows, minus the archive.
    public var liveScripts: [ScriptDocument] { scripts.filter { !$0.isArchived } }

    // MARK: - Lifecycle

    /// Production init: persists to Application Support/Cuebar.
    public init() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cuebar", isDirectory: true) else {
            self.fileURL = nil
            self.foldersURL = nil
            self.legacyCategoriesURL = nil
            seedWelcome()
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("scripts.json")
        self.foldersURL = dir.appendingPathComponent("folders.json")
        self.legacyCategoriesURL = dir.appendingPathComponent("categories.json")
        loadFolders()
        load()
        migrateLegacyCategories()
        if scripts.isEmpty {
            seedWelcome()
        } else if selectedID == nil {
            selectedID = scripts.first?.id
        }
    }

    /// Test/preview init: in-memory only.
    public init(inMemory scripts: [ScriptDocument], folders: [ScriptFolder] = []) {
        self.fileURL = nil
        self.foldersURL = nil
        self.legacyCategoriesURL = nil
        self.scripts = scripts
        self.folders = folders
        self.selectedID = scripts.first?.id
    }

    private func seedWelcome() {
        let folder = folders.first { $0.name == "Personal" && $0.parentID == nil }
        scripts = [ScriptDocument(title: "Welcome", body: SampleTexts.welcome, folderID: folder?.id)]
        selectedID = scripts.first?.id
        save()
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
        saveFolders()
        return folder
    }

    public func renameFolder(_ id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[i].name = clean.isEmpty ? folders[i].name : clean
        saveFolders()
    }

    /// Delete a folder and pull its contents up to its parent. Scripts go
    /// to the parent folder, not to Unfiled and not into the bin: deleting
    /// a folder should reorganise, not lose work.
    public func deleteFolder(_ id: UUID) {
        let parent = folders.first { $0.id == id }?.parentID
        let doomed = subtreeFolderIDs(of: id)
        folders.removeAll { doomed.contains($0.id) }
        for i in scripts.indices where scripts[i].folderID.map(doomed.contains) ?? false {
            scripts[i].folderID = parent
        }
        saveFolders()
        save()
    }

    public func moveScript(_ id: UUID, to folder: UUID?) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].folderID = folder
        scripts[i].updatedAt = Date()
        save()
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
        save()
    }

    public func removeTag(_ tag: String, from id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        save()
    }

    /// Tags are free text typed by a presenter mid-rehearsal, so they get
    /// tidied: trimmed, collapsed whitespace, capped, and no leading `#`
    /// (which is a convention from the issue tracker, not from here).
    static func normaliseTag(_ raw: String) -> String {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
        save()
    }

    public func setArchived(_ archived: Bool, for id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].isArchived = archived
        if archived, selectedID == id { selectedID = liveScripts.first?.id }
        save()
    }

    public func markOpened(_ id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].lastOpenedAt = Date()
        save()
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
        scripts.insert(copy, at: i + 1)
        selectedID = copy.id
        save()
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
        let doc = ScriptDocument(title: title, body: body, folderID: target)
        scripts.insert(doc, at: 0)
        selectedID = doc.id
        if let i = scripts.firstIndex(where: { $0.id == doc.id }) { scripts[i].lastOpenedAt = Date() }
        save()
        return doc
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
        let doc = ScriptDocument(title: imported.title, body: imported.body, folderID: target)
        scripts.insert(doc, at: 0)
        lastImportedID = doc.id
        save()
        return doc
    }

    /// Forget the last import, so re-selecting the same script later doesn't
    /// drag the editor back to the prompter.
    public func clearImported() {
        lastImportedID = nil
    }

    public func delete(_ id: UUID) {
        scripts.removeAll(where: { $0.id == id })
        if selectedID == id { selectedID = liveScripts.first?.id }
        save()
    }

    public func updateBody(_ id: UUID, body: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].setBody(body)
        scripts[i].updatedAt = Date()
        save()
    }

    public func rename(_ id: UUID, title: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].title = title.isEmpty ? "Untitled" : title
        scripts[i].updatedAt = Date()
        save()
    }

    // MARK: - Persistence

    /// Coalesced: the title field commits on every keystroke and bodies can
    /// be large, so full-file JSON writes collapse to the latest state
    /// shortly after the last change.
    private func save() {
        saveTask?.cancel()
        let snapshot = scripts
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushSave(snapshot)
        }
    }

    private func flushSave(_ snapshot: [ScriptDocument]) {
        saveTask = nil
        guard let url = fileURL else { return }
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = fileURL else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([ScriptDocument].self, from: data) {
            scripts = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } else if !data.isEmpty {
            // Quarantine corrupt files instead of letting the seeder
            // overwrite them on the next save.
            let dead = url.deletingLastPathComponent()
                .appendingPathComponent("scripts.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: dead)
        }
    }

    private func loadFolders() {
        if let url = foldersURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ScriptFolder].self, from: data) {
            folders = decoded
        } else {
            folders = Self.defaultFolderNames.map { ScriptFolder(name: $0) }
        }
    }

    private func saveFolders() {
        guard let url = foldersURL else { return }
        try? JSONEncoder().encode(folders).write(to: url, options: .atomic)
    }

    /// Give every pre-folder script a real folder.
    ///
    /// The old model stored a flat `category` string and a separate list of
    /// known names. Those names become top-level folders, and each script
    /// is filed under the one it named. The legacy string is cleared
    /// afterwards so nothing can later disagree about where a script is.
    private func migrateLegacyCategories() {
        guard scripts.contains(where: { $0.legacyCategory != nil }) else { return }
        if let legacyURL = legacyCategoriesURL,
           let data = try? Data(contentsOf: legacyURL),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            for name in names where !folders.contains(where: { $0.name == name && $0.parentID == nil }) {
                folders.append(ScriptFolder(name: name))
            }
        }
        for i in scripts.indices {
            guard let legacy = scripts[i].legacyCategory, !legacy.isEmpty else { continue }
            scripts[i].folderID = FolderTree.ensurePath(legacy, in: &folders)
            scripts[i].clearLegacyCategory()
        }
        saveFolders()
        save()
    }
}

public enum SampleTexts {
    public static let welcome = """
    Welcome to Cuebar. [smile]

    Press Option-Space to play. Click any word to jump straight there.

    Take a breath here. [pause] The highlight follows you while cues stay pink and never count as words.
    """
}
