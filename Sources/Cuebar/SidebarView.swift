import SwiftUI
import PromptCore

/// Script manager sidebar: searchable cards plus a live category box.
/// Tapping a category filters the list; the chevron on each row moves
/// the script between categories.
struct SidebarView: View {
    @Bindable var scripts: ScriptStore
    var wordsPerSecond: Double
    var onPick: (UUID) -> Void
    var onNew: () -> Void
    var onCategory: (String, UUID) -> Void
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

    private func count(for category: String) -> Int {
        scripts.scripts.filter { $0.category == category }.count
    }

    private func icon(for category: String) -> String {
        switch category.lowercased() {
        case "presentations": return "display"
        case "interviews": return "person"
        case "personal": return "star"
        default: return "tag"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scripts").font(.headline)
                Spacer()
                Button(action: onNew) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("New script")
                    .help("New script (Cmd-N)")
            }
            .padding([.horizontal, .top])
            SearchField(text: $search)
                .padding(.horizontal)
                .padding(.vertical, 6)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visible) { doc in
                        ScriptCard(
                            doc: doc,
                            selected: doc.id == scripts.selectedID,
                            duration: ReadingWindow.durationString(
                                wordCount: doc.wordCount,
                                wordsPerSecond: wordsPerSecond),
                            words: Self.countFormatter.string(for: doc.wordCount) ?? "\(doc.wordCount)",
                            categories: scripts.knownCategories,
                            onCategory: { onCategory($0, doc.id) },
                            onNewCategory: {
                                pendingCategoryDoc = doc.id
                                showingNewCategory = true
                            }
                        )
                        .onTapGesture { onPick(doc.id) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { scripts.delete(doc.id) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text("CATEGORIES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CuePalette.muted)
                    .padding(.horizontal, 4)
                CategoryRow(icon: "folder", name: "All Scripts",
                            count: scripts.scripts.count,
                            selected: filter == nil) {
                    filter = nil
                }
                ForEach(scripts.knownCategories, id: \.self) { name in
                    CategoryRow(icon: icon(for: name), name: name,
                                count: count(for: name),
                                selected: filter == name) {
                        filter = (filter == name) ? nil : name
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)
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

struct ScriptCard: View {
    let doc: ScriptDocument
    let selected: Bool
    let duration: String
    let words: String
    let categories: [String]
    var onCategory: (String) -> Void
    var onNewCategory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected ? CuePalette.peach : CuePalette.muted.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(doc.title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
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
                        .font(.caption)
                        .foregroundStyle(CuePalette.muted)
                        .padding(.leading, 4)
                }
                .menuStyle(.borderlessButton)
                .help("Move to category")
            }
            Text("\(words) words · \(duration)")
                .font(.caption)
                .foregroundStyle(CuePalette.muted)
                .monospacedDigit()
        }
        .padding(10)
        .background(CuePalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(CuePalette.peach.opacity(0.6), lineWidth: 1)
            }
        }
    }
}

struct CategoryRow: View {
    let icon: String
    let name: String
    let count: Int
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(name)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(selected ? CuePalette.ink : CuePalette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? CuePalette.card : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button(action: { text = "" }) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(CuePalette.card, in: RoundedRectangle(cornerRadius: 10))
    }
}
