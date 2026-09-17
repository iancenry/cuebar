import Foundation

public struct ScriptDocument: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var updatedAt: Date
    public var category: String

    public init(id: UUID = UUID(), title: String, body: String,
                updatedAt: Date = Date(), category: String = "Scripts") {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
        self.category = category
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, updatedAt, category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? "Scripts"
    }

    public var wordCount: Int { ScriptParser.words(body).count }
}

@MainActor
@Observable
public final class ScriptStore {
    public private(set) var scripts: [ScriptDocument] = []
    public var selectedID: UUID?
    public private(set) var knownCategories: [String] = []

    private let fileURL: URL?
    private let categoriesURL: URL?
    private var saveTask: Task<Void, Never>?

    /// Starter categories shown in the sidebar box.
    public static let defaultCategories = ["Presentations", "Interviews", "Personal"]

    public var selected: ScriptDocument? {
        scripts.first(where: { $0.id == selectedID })
    }

    /// Production init: persists to Application Support/Cuebar/scripts.json.
    public init() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cuebar", isDirectory: true) else {
            self.fileURL = nil
            self.categoriesURL = nil
            scripts = [ScriptDocument(title: "Welcome", body: SampleTexts.welcome)]
            selectedID = scripts.first?.id
            knownCategories = Self.defaultCategories
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("scripts.json")
        self.categoriesURL = dir.appendingPathComponent("categories.json")
        load()
        loadCategories()
        if scripts.isEmpty {
            scripts = [ScriptDocument(title: "Welcome", body: SampleTexts.welcome)]
            selectedID = scripts.first?.id
            save()
        } else if selectedID == nil {
            selectedID = scripts.first?.id
        }
    }

    /// Test/preview init: in-memory only.
    public init(inMemory scripts: [ScriptDocument]) {
        self.fileURL = nil
        self.categoriesURL = nil
        self.scripts = scripts
        self.selectedID = scripts.first?.id
        var seen: [String] = []
        for doc in scripts where !seen.contains(doc.category) {
            seen.append(doc.category)
        }
        self.knownCategories = seen
    }

    public func select(_ id: UUID) {
        guard scripts.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    @discardableResult
    public func add(title: String = "Untitled") -> ScriptDocument {
        let doc = ScriptDocument(title: title, body: "")
        scripts.insert(doc, at: 0)
        selectedID = doc.id
        save()
        return doc
    }

    /// Insert an imported script without changing the selection.
    @discardableResult
    public func importScript(title: String, body: String) -> ScriptDocument {
        let doc = ScriptDocument(title: title, body: body)
        scripts.insert(doc, at: 0)
        save()
        return doc
    }

    public func delete(_ id: UUID) {
        scripts.removeAll(where: { $0.id == id })
        if selectedID == id { selectedID = scripts.first?.id }
        save()
    }

    public func updateBody(_ id: UUID, body: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].body = body
        scripts[i].updatedAt = Date()
        save()
    }

    public func rename(_ id: UUID, title: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].title = title.isEmpty ? "Untitled" : title
        scripts[i].updatedAt = Date()
        save()
    }

    public func setCategory(_ name: String, for id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.isEmpty ? "Scripts" : name
        scripts[i].category = clean
        scripts[i].updatedAt = Date()
        if !knownCategories.contains(clean) {
            knownCategories.append(clean)
            saveCategories()
        }
        save()
    }

    private func load() {
        guard let url = fileURL else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([ScriptDocument].self, from: data) {
            scripts = decoded.sorted(by: { $0.updatedAt > $1.updatedAt })
        } else if !data.isEmpty {
            // Quarantine corrupt files instead of letting the seeder
            // overwrite them on the next save.
            let dead = url.deletingLastPathComponent()
                .appendingPathComponent("scripts.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: dead)
        }
    }

    /// Coalesced persistence: the title field commits on every keystroke
    /// and bodies can be large, so full-file JSON writes collapse to the
    /// latest state shortly after the last change (EditView already
    /// debounces its own commits; this catches the rest).
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

    private func loadCategories() {
        if let url = categoriesURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            knownCategories = decoded
        } else {
            knownCategories = Self.defaultCategories
            saveCategories()
        }
        for doc in scripts where !knownCategories.contains(doc.category) {
            knownCategories.append(doc.category)
        }
    }

    private func saveCategories() {
        guard let url = categoriesURL else { return }
        try? JSONEncoder().encode(knownCategories).write(to: url, options: .atomic)
    }
}

public enum SampleTexts {
    public static let welcome = """
    Welcome to Cuebar. [smile]

    Press Option-Space to play. Click any word to jump straight there.

    Take a breath here. [pause] The highlight follows you while cues stay pink and never count as words.
    """
}
