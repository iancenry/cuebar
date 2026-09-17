import SwiftUI
import PromptCore

/// Script manager sidebar: search, category chips, and script cards.
/// Categories live in a chip row under the search field so the script
/// list gets the full height.
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

    /// One pass over the scripts instead of a scan per category row.
    private var countsByCategory: [String: Int] {
        var counts: [String: Int] = [:]
        for doc in scripts.scripts {
            counts[doc.category, default: 0] += 1
        }
        return counts
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
            .padding(.bottom, 8)
            SearchField(text: $search)
                .padding(.horizontal)
                .padding(.bottom, 10)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                CategoryChip(name: "All", count: scripts.scripts.count,
                             selected: filter == nil) { filter = nil }
                ForEach(scripts.knownCategories, id: \.self) { name in
                    CategoryChip(name: name, count: countsByCategory[name] ?? 0,
                                 selected: filter == name) {
                        filter = (filter == name) ? nil : name
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing: 6) {
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
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(doc.id) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { scripts.delete(doc.id) }
                        }
                    }
                    if visible.isEmpty {
                        Text(search.isEmpty ? "No scripts here yet" : "No matches")
                            .font(.caption)
                            .foregroundStyle(CuePalette.muted)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
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
        HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(selected ? CuePalette.peach : CuePalette.muted.opacity(0.25))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(words) words · \(duration)")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
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
                    .padding(6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move to category")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            selected ? CuePalette.card : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(CuePalette.peach.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

struct CategoryChip: View {
    let name: String
    let count: Int
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(name)
                    .font(.caption.weight(selected ? .semibold : .regular))
                Text("\(count)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(selected ? CuePalette.onHighlight.opacity(0.75) : CuePalette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? CuePalette.peach : CuePalette.card, in: Capsule())
            .foregroundStyle(selected ? CuePalette.onHighlight : CuePalette.ink)
        }
        .buttonStyle(.plain)
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
