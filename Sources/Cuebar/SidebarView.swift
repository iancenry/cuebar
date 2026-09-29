import SwiftUI
import PromptCore

/// Script manager sidebar, Codex-style: a quiet library tree. "New
/// script" sits up top like an action, folders list the categories, and
/// each script is an indented plain row under its folder.
struct SidebarView: View {
    @Bindable var scripts: ScriptStore
    var wordsPerSecond: Double
    var onPick: (UUID) -> Void
    var onNew: () -> Void
    var onCategory: (String, UUID) -> Void
    var onExport: (ScriptDocument) -> Void = { _ in }
    @State private var search = ""
    /// Two levels, not a filter. A filter keeps the folder list on screen
    /// and appends the scripts under it, which is the thing that read as
    /// "one undifferentiated run" — a script visible under its folder *and*
    /// in All Scripts, with nothing saying which list you were looking at.
    /// Opening a library replaces the list; a back row returns to it.
    private enum Library: Equatable {
        case root        // the folders
        case all         // every script
        case category(String)
    }
    @State private var library: Library = .root
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""
    @State private var pendingCategoryDoc: UUID? = nil
    @State private var hoveringNew = false

    private var searched: [ScriptDocument] {
        guard !search.isEmpty else { return scripts.scripts }
        return scripts.scripts.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.body.localizedCaseInsensitiveContains(search)
        }
    }



    private var countsByCategory: [String: Int] {
        var counts: [String: Int] = [:]
        for doc in scripts.scripts {
            counts[doc.category, default: 0] += 1
        }
        return counts
    }

    private var visible: [ScriptDocument] {
        switch library {
        case .root, .all:
            return searched
        case .category(let name):
            return searched.filter { $0.category == name }
        }
    }

    private var openLibraryName: String {
        switch library {
        case .root, .all: return "All Scripts"
        case .category(let name): return name
        }
    }

    var body: some View {
        // Computed once per body pass: these were `private var`s read 5-11
        // times below, and each read re-filtered every script body.
        let counts = countsByCategory
        VStack(spacing: 0) {
            // Clears the traffic lights, which float over this corner.
            // The band is the height of the content column's floating
            // chrome, so the library starts under the toolbar row instead
            // of beside it — and the pill is a control, not a divider, so
            // putting the two on one line would misread as a header.
            Color.clear.frame(height: CuePalette.chromeRowHeight)
            // The sidebar's primary verb, but not a button-shaped button:
            // a filled capsule with a stroke next to a list of plain rows
            // read as a dialog welded to the rail. Wash on hover only.
            Button(action: onNew) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.callout)
                    Text("New script")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(hoveringNew ? CuePalette.ink : CuePalette.ink.opacity(0.88))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(CuePalette.hover, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { hoveringNew = $0 }
            .animation(.easeOut(duration: 0.12), value: hoveringNew)
            .accessibilityLabel("New script")
            .help("New script (Cmd-N)")
            .padding(.horizontal, 10)
            .padding(.top, 10)
            SearchField(text: $search)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // A heading, not a stencil: semibold at reading size
                    // with the count beside it, the way a section of a
                    // list announces itself. The small-caps treatment
                    // shouted a two-word label.
                    HStack(spacing: 6) {
                        Text("Library")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CuePalette.ink.opacity(0.95))
                        Text("\(scripts.knownCategories.count)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(CuePalette.inkMuted)
                        Spacer()
                    }
                    .padding(.leading, 10)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                    switch library {
                    case .root:
                        // The folders. Nothing else is on screen, so there
                        // is no ambiguity about what a row below would mean.
                        LibraryFolder(name: "All Scripts",
                                      count: scripts.scripts.count,
                                      selected: false) {
                            library = .all
                        }
                        ForEach(scripts.knownCategories, id: \.self) { category in
                            LibraryFolder(name: category,
                                          count: counts[category] ?? 0,
                                          selected: false) {
                                library = .category(category)
                            }
                        }

                    case .all, .category:
                        // Inside a library. The back row is the way out, and
                        // it names where it goes — a chevron alone in a
                        // 300pt rail is a puzzle.
                        Button { library = .root } label: {
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

                        HStack(spacing: 6) {
                            Text(openLibraryName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CuePalette.ink.opacity(0.95))
                                .lineLimit(1)
                            Text("\(visible.count)")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(CuePalette.inkMuted)
                            Spacer()
                        }
                        .padding(.leading, 10)
                        .padding(.top, 4)
                        .padding(.bottom, 4)

                        if visible.isEmpty {
                            Text(search.isEmpty
                                 ? "Nothing in \(openLibraryName)"
                                 : "No matches")
                                .font(.caption)
                                .foregroundStyle(CuePalette.inkMuted)
                                .padding(.leading, 10)
                                .padding(.top, 6)
                        } else {
                            ForEach(visible) { doc in
                                ScriptRow(
                                    doc: doc,
                                    selected: doc.id == scripts.selectedID,
                                    duration: ReadingWindow.durationString(
                                        wordCount: doc.wordCount,
                                        wordsPerSecond: wordsPerSecond),
                                    categories: scripts.knownCategories,
                                    onPick: { onPick(doc.id) },
                                    onCategory: { onCategory($0, doc.id) },
                                    onNewCategory: {
                                        pendingCategoryDoc = doc.id
                                        showingNewCategory = true
                                    },
                                    onExport: { onExport(doc) },
                                    onDelete: { scripts.delete(doc.id) }
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        // Same opt-out as the content column, so the library starts level
        // with the canvas instead of a title-bar's worth of margin lower.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
        .alert("New category", isPresented: $showingNewCategory) {
            TextField("Name", text: $newCategoryName)
            Button("Add") {
                let name = newCategoryName.trimmingCharacters(in: .whitespaces)
                if let id = pendingCategoryDoc, !name.isEmpty {
                    onCategory(name, id)
                }
                newCategoryName = ""
                pendingCategoryDoc = nil
            }
            Button("Cancel", role: .cancel) {
                newCategoryName = ""
                pendingCategoryDoc = nil
            }
        }
    }
}

/// Folder row: category header, click filters the library to it.
struct LibraryFolder: View {
    let name: String
    let count: Int
    let selected: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .font(.callout)
                    .foregroundStyle(selected ? CuePalette.peach : CuePalette.muted)
                    .frame(width: 16)
                Text(name)
                    .font(.callout.weight(selected ? .medium : .regular))
                    .foregroundStyle(selected ? CuePalette.ink : CuePalette.ink.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(CuePalette.inkMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? CuePalette.selection
                        : (hovered ? CuePalette.hover : Color.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// One script under its folder: title over a category · duration line,
/// with a tinted letter badge for the category. Selection is carried by the
/// accent title and a faint wash rather than a filled box. All row actions
/// live behind one hover-revealed ⋯ menu and the context menu — never a
/// stack of inline chevrons.
struct ScriptRow: View {
    let doc: ScriptDocument
    let selected: Bool
    let duration: String
    let categories: [String]
    var onPick: () -> Void
    var onCategory: (String) -> Void
    var onNewCategory: () -> Void
    var onExport: () -> Void
    var onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CategoryBadge(name: doc.category)
            // Title over a metadata line. One line of text per row left a
            // flat grey list with nothing to scan; the second line is what
            // gives the eye a shape to hold, and it is where the category
            // and length live instead of competing with the title.
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? CuePalette.peach : CuePalette.ink.opacity(0.92))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(doc.category)
                        .lineLimit(1)
                    Text("·")
                    Text(duration)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(CuePalette.inkMuted)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered || selected {
                Menu {
                    Section("Move to") {
                        ForEach(categories, id: \.self) { name in
                            Button(name) { onCategory(name) }
                                .disabled(name == doc.category)
                        }
                        Divider()
                        Button("New category…") { onNewCategory() }
                    }
                    Divider()
                    Button("Export…") { onExport() }
                    Button("Delete", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(CuePalette.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(selected ? CuePalette.selection
                    : (hovered ? CuePalette.hover : Color.clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onPick() }
        .onHover { hovered = $0 }
        .contextMenu {
            Section("Move to") {
                ForEach(categories, id: \.self) { name in
                    Button(name) { onCategory(name) }
                        .disabled(name == doc.category)
                }
                Button("New category…") { onNewCategory() }
            }
            Divider()
            Button("Export…") { onExport() }
            Button("Delete", role: .destructive) { onDelete() }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Tinted letter badge, one hue per category so the rail is scannable by
/// shape as well as by text. The hash is computed by hand because
/// `hashValue` is seeded per process — rows would change colour on every
/// launch.
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
