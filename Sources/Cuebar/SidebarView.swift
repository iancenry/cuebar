import SwiftUI
import PromptCore

/// Script manager sidebar: browse, then open.
///
/// One region at a time. At the root the rail *is* the library — smart
/// groups, the folder tree, tags — and choosing one opens it, replacing
/// the rail with that library's scripts and a back row. This was tried
/// the other way (a navigator pinned above a permanent list) and it read
/// as one long list of mixed things: folders and scripts drawn with the
/// same row treatment, in the same column, with only a tonal step
/// between them. Drilling in and back is unambiguous, and it is what the
/// rail is for.
struct SidebarView: View {
    @Bindable var scripts: ScriptStore
    var wordsPerSecond: Double
    var onPick: (UUID) -> Void
    var onNew: () -> Void
    var onExport: (ScriptDocument) -> Void = { _ in }
    @State private var search = ""
    @State private var selection: LibrarySelection = .all
    @State private var collapsed: Set<UUID> = []
    @State private var hoveringNew = false
    /// One text field, three flows: new folder, new subfolder, rename. A
    /// tag has its own prompt because it acts on the open script rather
    /// than creating a container.
    @State private var showingFolderPrompt = false
    @State private var showingTagPrompt = false
    @State private var folderNameDraft = ""
    @State private var folderParent: UUID?
    @State private var renameTarget: UUID?

    /// What the list below is showing. The smart groups are *views* of the
    /// library, not places things live: filing a script into "Favorites"
    /// would be a category error, so they sit beside the folders and never
    /// appear as a move target.
    enum LibrarySelection: Hashable {
        /// Browsing: the rail shows the library itself.
        case root
        case all
        case unfiled
        case folder(UUID)
        case favorites
        case recent
        case archived
        case tag(String)
    }

    // MARK: - Derived lists

    private var searched: [ScriptDocument] {
        let base = scripts.scripts
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.body.localizedCaseInsensitiveContains(search)
        }
    }

    private func inFolder(_ id: UUID?, nested: Bool) -> [ScriptDocument] {
        guard let id else { return searched.filter { $0.folderID == nil } }
        let ids = nested ? scripts.subtreeFolderIDs(of: id) : [id]
        return searched.filter { $0.folderID.map(ids.contains) ?? false }
    }

    private var visible: [ScriptDocument] {
        switch selection {
        case .root: return []
        case .all: return searched.filter { !$0.isArchived }
        case .unfiled: return inFolder(nil, nested: false)
        case .folder(let id): return inFolder(id, nested: true)
        case .favorites: return searched.filter { $0.isFavorite && !$0.isArchived }
        case .recent: return searched.filter { !$0.isArchived && $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        case .archived: return searched.filter(\.isArchived)
        case .tag(let tag): return searched.filter {
            $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        }

    }

    private func count(_ selection: LibrarySelection) -> Int {
        switch selection {
        case .root: return 0
        case .all: return searched.count(where: { !$0.isArchived })
        case .unfiled: return inFolder(nil, nested: false).count
        case .folder(let id): return inFolder(id, nested: true).count
        case .favorites: return searched.count(where: { $0.isFavorite && !$0.isArchived })
        case .recent: return searched.count(where: { !$0.isArchived && $0.lastOpenedAt != nil })
        case .archived: return searched.count(where: \.isArchived)
        case .tag(let tag): return searched.count(where: {
            $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        })
        }
    }

    private var selectionTitle: String {
        switch selection {
        case .root: return "Library"
        case .all: return "All Scripts"
        case .unfiled: return "Unfiled"
        case .folder(let id): return scripts.folderName(id)
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .archived: return "Archive"
        case .tag(let tag): return tag
        }
    }

    /// Folders and their children, in draw order, skipping collapsed
    /// branches. Computed here rather than recursively in the view so the
    /// recursion is testable arithmetic instead of nested `ViewBuilder`s.
    private var folderRows: [(folder: ScriptFolder, depth: Int)] {
        var out: [(ScriptFolder, Int)] = []
        var seen: Set<UUID> = []
        func walk(_ parent: UUID?, _ depth: Int) {
            // `seen` because the recursion here is a view, not pure code: a
            // cyclic parent in a hand-edited folders.json would otherwise
            // recurse until the stack gave out, and a sidebar is the one
            // place that takes the whole window down with it.
            for folder in scripts.childFolders(of: parent) where seen.insert(folder.id).inserted {
                out.append((folder, depth))
                if !collapsed.contains(folder.id) { walk(folder.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return out
    }

    private func hasChildren(_ folder: ScriptFolder) -> Bool {
        !scripts.childFolders(of: folder.id).isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: CuePalette.chromeRowHeight)
            newScriptRow
            SearchField(text: $search)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            // One scroll area showing one thing. Two stacked scroll views
            // in a 300pt rail is also how the painted backdrop ended up
            // buried under two opaque panels.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if selection == .root { rootList } else { openedLibrary }
                }
                .padding(.bottom, 10)
            }
        }
        .onChange(of: search) { _, text in
            // Typing a search from the root has to land somewhere, and
            // "all the scripts" is the only answer that isn't a folder.
            if !text.isEmpty, selection == .root { selection = .all }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
        .alert(folderPromptTitle, isPresented: $showingFolderPrompt) {
            TextField("Name", text: $folderNameDraft)
            Button("Create") { commitFolderPrompt() }
            Button("Cancel", role: .cancel) { folderNameDraft = "" }
        }
        .alert("New tag", isPresented: $showingTagPrompt) {
            TextField("Tag", text: $folderNameDraft)
            Button("Add") {
                if let doc = scripts.selected { scripts.addTag(folderNameDraft, to: doc.id) }
                folderNameDraft = ""
            }
            Button("Cancel", role: .cancel) { folderNameDraft = "" }
        } message: {
            Text("A word you would search for later. Applied to the open script.")
        }
    }

    private var folderPromptTitle: String {
        if renameTarget != nil { return "Rename folder" }
        return folderParent == nil ? "New folder" : "New subfolder"
    }

    private func commitFolderPrompt() {
        if let renameTarget {
            scripts.renameFolder(renameTarget, to: folderNameDraft)
            self.renameTarget = nil
        } else {
            let folder = scripts.createFolder(name: folderNameDraft, parent: folderParent)
            // A subfolder created inside a collapsed branch would be
            // invisible the moment it appeared.
            if let parent = folderParent { collapsed.remove(parent) }
            selection = .folder(folder.id)
        }
        folderNameDraft = ""
        folderParent = nil
    }

    private var newScriptRow: some View {
        Button(action: onNew) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.callout)
                Text("New script").font(.callout.weight(.medium))
                Spacer()
            }
            .foregroundStyle(hoveringNew ? CuePalette.ink : CuePalette.ink.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(CuePalette.hover, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hoveringNew = $0 }
        .accessibilityLabel("New script")
        .help("New script (⇧⌘N)")
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    // MARK: - Navigator

    /// The library, as browsable rows. Nothing here is a script; every row
    /// opens something.
    private var rootList: some View {
        VStack(alignment: .leading, spacing: 1) {
            NavRow(title: "All Scripts", icon: "tray.full",
                   count: count(.all), selected: false) { selection = .all }
            if !scripts.favorites.isEmpty {
                NavRow(title: "Favorites", icon: "star",
                       count: count(.favorites), selected: false) { selection = .favorites }
            }
            if !scripts.recentScripts.isEmpty {
                NavRow(title: "Recent", icon: "clock",
                       count: count(.recent), selected: false) { selection = .recent }
            }

            sectionHeader("Folders", action: "New folder") {
                folderNameDraft = ""
                folderParent = nil
                renameTarget = nil
                showingFolderPrompt = true
            }
            ForEach(folderRows, id: \.folder.id) { row in
                folderRow(row.folder, depth: row.depth)
            }
            let unfiledCount = count(.unfiled)
            if unfiledCount > 0 {
                NavRow(title: "Unfiled", icon: "tray",
                       count: unfiledCount, selected: false) { selection = .unfiled }
            }

            sectionHeader("Tags", action: "New tag") {
                folderNameDraft = ""
                showingTagPrompt = true
            }
            if scripts.allTags.isEmpty {
                Text("No tags yet")
                    .font(.caption)
                    .foregroundStyle(CuePalette.inkMuted)
                    .padding(.leading, NavRow.iconInset)
                    .padding(.top, 2)
            } else {
                ForEach(scripts.allTags, id: \.self) { tag in
                    NavRow(title: tag, icon: "tag",
                           count: count(.tag(tag)), selected: false) { selection = .tag(tag) }
                }
            }
            if !scripts.archivedScripts.isEmpty {
                Divider().padding(.vertical, 6).padding(.horizontal, 10)
                NavRow(title: "Archive", icon: "archivebox",
                       count: count(.archived), selected: false) { selection = .archived }
            }
        }
    }

    /// Inside one library: back, a header, and its scripts.
    private var openedLibrary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { selection = .root } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.bold))
                    Text("Library")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(CuePalette.inkMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to libraries")
            .padding(.top, 2)

            HStack(spacing: 6) {
                Text(selectionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CuePalette.ink.opacity(0.95))
                    .lineLimit(1)
                Text("\(visible.count)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(CuePalette.inkMuted)
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.top, 2)
            .padding(.bottom, 4)

            if visible.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(CuePalette.inkMuted)
                    .padding(.leading, 10)
                    .padding(.top, 6)
            } else {
                ForEach(visible) { doc in
                    ScriptRow(
                        doc: doc,
                        selected: doc.id == scripts.selectedID,
                        folderLabel: doc.folderID == nil ? nil : scripts.folderName(doc.folderID),
                        duration: ReadingWindow.durationString(
                            wordCount: doc.wordCount,
                            wordsPerSecond: wordsPerSecond),
                        allTags: scripts.allTags,
                        folderChoices: folderChoices,
                        currentFolder: doc.folderID,
                        isArchived: doc.isArchived,
                        onPick: { onPick(doc.id) },
                        onMove: { scripts.moveScript(doc.id, to: $0) },
                        onTagAdd: { scripts.addTag($0, to: doc.id) },
                        onTagRemove: { scripts.removeTag($0, from: doc.id) },
                        onFavorite: { scripts.toggleFavorite(doc.id) },
                        onArchive: { scripts.setArchived(!doc.isArchived, for: doc.id) },
                        onDuplicate: { scripts.duplicate(doc.id) },
                        onExport: { onExport(doc) },
                        onDelete: { scripts.delete(doc.id) }
                    )
                }
            }
        }
    }

    private func sectionHeader(_ title: String, action: String, prompt: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CuePalette.ink.opacity(0.75))
            Spacer()
            Button(action: prompt) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CuePalette.inkMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(action)
            .help(action)
        }
        .padding(.leading, NavRow.iconInset)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }

    private func folderRow(_ folder: ScriptFolder, depth: Int) -> some View {
        let kids = hasChildren(folder)
        return NavRow(title: folder.name,
                      icon: "folder",
                      count: scripts.scriptCount(in: folder.id),
                      indent: depth,
                      disclosure: kids ? (collapsed.contains(folder.id) ? "chevron.right" : "chevron.down") : nil,
                      onToggleDisclosure: kids ? { toggleCollapse(folder.id) } : nil,
                      selected: false) {
            selection = .folder(folder.id)
        }
        .contextMenu {
            Button("New Subfolder…") {
                folderNameDraft = ""
                folderParent = folder.id
                renameTarget = nil
                showingFolderPrompt = true
            }
            Button("New Script Here") {
                onNew()
                scripts.moveScript(scripts.selectedID ?? scripts.scripts.first?.id ?? UUID(),
                                   to: folder.id)
            }
            Divider()
            Button("Rename…") {
                folderNameDraft = folder.name
                folderParent = nil
                renameTarget = folder.id
                showingFolderPrompt = true
            }
            Button("Delete Folder", role: .destructive) {
                if selection == .folder(folder.id) { selection = .all }
                scripts.deleteFolder(folder.id)
            }
        }
    }

    private func toggleCollapse(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    // MARK: - List

    /// Inset, rounded at the top, on its own surface. Sitting the scripts
    /// *inside* the rail is what separates "where things are" from "the
    /// things" — two regions in one column, both drawn as rows, read as a
    /// single list no matter how the tones differ. It also lifts the rows
    /// off the painted backdrop, which was showing through behind them.
    /// Flat (id, name) pairs for the "Move to" menu, indented by depth so
    /// the hierarchy is visible in a menu that can't nest.
    private var folderChoices: [(id: UUID?, label: String)] {
        var out: [(UUID?, String)] = [(nil, "Unfiled")]
        for row in folderRows {
            out.append((row.folder.id,
                        String(repeating: "  ", count: row.depth) + row.folder.name))
        }
        return out
    }

    private var emptyMessage: String {
        if !search.isEmpty { return "No matches" }
        switch selection {
        case .archived: return "Nothing archived"
        case .favorites: return "No favorites yet"
        case .recent: return "Nothing opened yet"
        case .unfiled: return "Every script is in a folder"
        default: return "Nothing here yet"
        }
    }
}

/// One navigator row. Optional indent and disclosure triangle, so the same
/// row serves a smart group, a tag and a folder three levels down.
struct NavRow: View {
    /// Where a row's icon starts. The section headers line up with this.
    ///
    /// They used to sit flush left, which left the rail reading as a ragged
    /// column with a mystery gutter: headers at 10pt, row names at 55pt.
    /// A header is a label for a group, not a row, so it belongs on the
    /// icon's edge — and the numbers live in one place so the two can't
    /// drift apart again.
    static let iconInset: CGFloat = 26

    let title: String
    let icon: String
    let count: Int
    var indent: Int = 0
    var disclosure: String?
    /// Folding a branch is a different act from opening it, so the
    /// chevron is its own target. They shared a tap handler for a while,
    /// which meant you could not open a folder that had children without
    /// also folding it shut.
    var onToggleDisclosure: (() -> Void)?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(indent) * 12, height: 0)

                if let disclosure {
                    Image(systemName: disclosure)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(CuePalette.inkMuted)
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                        .onTapGesture { onToggleDisclosure?() }
                } else {
                    Color.clear.frame(width: 12)
                }
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(selected ? CuePalette.peach : CuePalette.muted)
                    .frame(width: 16)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? CuePalette.ink : CuePalette.ink.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(CuePalette.inkMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? CuePalette.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) scripts")
    }
}

/// One script: title, then a metadata line, then its tags. Selection is
/// carried by the accent title rather than a filled box.
struct ScriptRow: View {
    let doc: ScriptDocument
    let selected: Bool
    var folderLabel: String?
    let duration: String
    let allTags: [String]
    let folderChoices: [(id: UUID?, label: String)]
    let currentFolder: UUID?
    let isArchived: Bool
    var onPick: () -> Void
    var onMove: (UUID?) -> Void
    var onTagAdd: (String) -> Void
    var onTagRemove: (String) -> Void
    var onFavorite: () -> Void
    var onArchive: () -> Void
    var onDuplicate: () -> Void
    var onExport: () -> Void
    var onDelete: () -> Void
    @State private var hovered = false
    @State private var addingTag = false
    @State private var tagDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                CategoryBadge(name: folderLabel ?? doc.title)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(doc.title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? CuePalette.peach : CuePalette.ink.opacity(0.92))
                            .lineLimit(1)
                        if doc.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(CuePalette.peach)
                        }
                        if isArchived {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(CuePalette.inkMuted)
                        }
                    }
                    HStack(spacing: 4) {
                        if let folderLabel {
                            Text(folderLabel).lineLimit(1)
                            Text("·")
                        }
                        Text(duration).monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(CuePalette.inkMuted)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovered || selected {
                    Menu {
                        Section("Move to") {
                            ForEach(folderChoices, id: \.label) { choice in
                                Button {
                                    onMove(choice.id)
                                } label: {
                                    if choice.id == currentFolder {
                                        Label(choice.label, systemImage: "checkmark")
                                    } else {
                                        Text(choice.label)
                                    }
                                }
                            }
                        }
                        Divider()
                        Menu("Tags") {
                            ForEach(allTags, id: \.self) { tag in
                                Button(doc.tags.contains(tag) ? "Remove \(tag)" : "Add \(tag)") {
                                    if doc.tags.contains(tag) { onTagRemove(tag) } else { onTagAdd(tag) }
                                }
                            }
                            Divider()
                            Button("New Tag…") { addingTag = true }
                        }
                        Divider()
                        Button(doc.isFavorite ? "Unfavorite" : "Favorite") { onFavorite() }
                        Button(doc.isArchived ? "Unarchive" : "Archive") { onArchive() }
                        Button("Duplicate") { onDuplicate() }
                        Divider()
                        Button("Export…") { onExport() }
                        Button("Delete", role: .destructive) { onDelete() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(CuePalette.inkMuted)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            if !doc.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(doc.tags, id: \.self) { tag in
                        TagChip(name: tag) { onTagRemove(tag) }
                    }
                }
                .padding(.leading, 25)
            }
            if addingTag {
                HStack(spacing: 4) {
                    TextField("tag", text: $tagDraft)
                        .textFieldStyle(.plain)
                        .font(.caption2)
                        .onSubmit(commitTag)
                    Button("Add", action: commitTag)
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(CuePalette.peach)
                    Button("Cancel") { addingTag = false; tagDraft = "" }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(CuePalette.inkMuted)
                }
                .padding(.leading, 25)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(selected ? CuePalette.selection
                    : (hovered ? CuePalette.hover : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onPick() }
        .onHover { hovered = $0 }
        .contextMenu {
            Button(doc.isFavorite ? "Unfavorite" : "Favorite") { onFavorite() }
            Button("Duplicate") { onDuplicate() }
            Button(doc.isArchived ? "Unarchive" : "Archive") { onArchive() }
            Divider()
            Button("Export…") { onExport() }
            Button("Delete", role: .destructive) { onDelete() }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func commitTag() {
        onTagAdd(tagDraft)
        tagDraft = ""
        addingTag = false
    }
}

/// Tinted letter badge — one hue per name so the rail is scannable by
/// shape as well as by text. Hand-hashed: `hashValue` is seeded per
/// process, so rows would change colour between launches.
struct CategoryBadge: View {
    let name: String

    private var hue: Double {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Double(hash % 360) / 360
    }

    private var initial: String {
        String(name.first.map { String($0).uppercased() } ?? "?")
    }

    var body: some View {
        Text(initial)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(hue: hue, saturation: 0.35, brightness: 0.95).opacity(0.9))
            .frame(width: 17, height: 17)
            .background(Color(hue: hue, saturation: 0.30, brightness: 0.55).opacity(0.22),
                        in: RoundedRectangle(cornerRadius: 5))
    }
}

struct TagChip: View {
    let name: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            Text(name)
                .font(.system(size: 9, weight: .medium))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 6, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(name)")
            }
        }
        .foregroundStyle(CuePalette.inkMuted)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Color.white.opacity(0.07), in: Capsule())
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(CuePalette.muted)
            TextField("Search", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button(action: { text = "" }) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(in: RoundedRectangle(cornerRadius: 9))
    }
}
