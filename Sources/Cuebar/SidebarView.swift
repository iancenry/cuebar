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
    @State private var filter: String? = nil
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""
    @State private var pendingCategoryDoc: UUID? = nil

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private var searched: [ScriptDocument] {
        guard !search.isEmpty else { return scripts.scripts }
        return scripts.scripts.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.body.localizedCaseInsensitiveContains(search)
        }
    }

    private var visible: [ScriptDocument] {
        guard let filter else { return searched }
        return searched.filter { $0.category == filter }
    }

    private var countsByCategory: [String: Int] {
        var counts: [String: Int] = [:]
        for doc in scripts.scripts {
            counts[doc.category, default: 0] += 1
        }
        return counts
    }

    /// Scripts under each folder for the tree, honoring the search text.
    private func scripts(in category: String) -> [ScriptDocument] {
        searched.filter { $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Action row: the sidebar's primary verb, Codex-style.
            Button(action: onNew) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.callout)
                    Text("New script")
                        .font(.callout)
                    Spacer()
                }
                .foregroundStyle(CuePalette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    Text("Library")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CuePalette.muted)
                        .padding(.leading, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    LibraryFolder(name: "All Scripts",
                                  count: scripts.scripts.count,
                                  selected: filter == nil) {
                        filter = nil
                    }
                    // One folder per category; scripts nest beneath.
                    ForEach(scripts.knownCategories, id: \.self) { category in
                        LibraryFolder(name: category,
                                      count: countsByCategory[category] ?? 0,
                                      selected: filter == category) {
                            filter = (filter == category) ? nil : category
                        }
                    if filter == nil || filter == category {
                        ForEach(scripts(in: category)) { doc in
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
                    if visible.isEmpty && !scripts.scripts.isEmpty {
                        Text(search.isEmpty ? "Nothing in this folder" : "No matches")
                            .font(.caption)
                            .foregroundStyle(CuePalette.muted)
                            .padding(.leading, 10)
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, 10)
            }
        }
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .font(.callout)
                    .foregroundStyle(selected ? CuePalette.peach : CuePalette.muted)
                    .frame(width: 16)
                Text(name)
                    .font(.callout.weight(selected ? .medium : .regular))
                    .foregroundStyle(CuePalette.ink)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(CuePalette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? CuePalette.card : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One script under its folder — single-line title, duration on the
/// right, subtle highlight when selected.
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

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(selected ? CuePalette.peach : CuePalette.muted.opacity(0.35))
                .frame(width: 5, height: 5)
            Text(doc.title)
                .font(.callout.weight(selected ? .medium : .regular))
                .foregroundStyle(CuePalette.ink.opacity(selected ? 1 : 0.85))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(duration)
                .font(.caption2).monospacedDigit()
                .foregroundStyle(CuePalette.muted)
                .lineLimit(1)
            Menu {
                Section("Move to") {
                    ForEach(categories, id: \.self) { name in
                        Button(name) { onCategory(name) }
                            .disabled(name == doc.category)
                    }
                    Divider()
                    Button("New category…") { onNewCategory() }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(CuePalette.muted)
                    .padding(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move to category")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(selected ? CuePalette.card : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onPick() }
        .contextMenu {
            Button("Export…") { onExport() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button(action: { text = "" }) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(in: RoundedRectangle(cornerRadius: 10))
    }
}
