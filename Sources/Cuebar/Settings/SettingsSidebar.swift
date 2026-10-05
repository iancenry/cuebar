import SwiftUI
import PromptCore

/// The settings window's navigation, in the shape of a settings app people
/// already know: a search field, grouped sections, an icon and a label per
/// row, and the selected row filled.
///
/// It replaced a `TabView` strip across the top. Six tabs with icons but no
/// grouping and no way to find one without reading all the names is a strip
/// you have to *remember*; a sidebar you can search is one you can navigate.
/// Everything the strip held is still here — nothing was dropped to make room.
struct SettingsSidebar: View {
    /// One page of settings.
    struct Page: Identifiable {
        var id: String
        var title: String
        var symbol: String
        /// Extra words the search should also match, so "wpm" finds the page
        /// that calls it "Words per minute".
        var keywords: [String] = []
        /// Which group it sits in.
        var group: Group
        @ViewBuilder var content: () -> AnyView

        enum Group: String, CaseIterable {
            case essentials = "Essentials"
            case appearance = "Appearance"
            case library = "Library"
            case system = "System"

            var symbol: String {
                switch self {
                case .essentials: return "star"
                case .appearance: return "paintpalette"
                case .library: return "books.vertical"
                case .system: return "gearshape"
                }
            }
        }
    }

    var pages: [Page]
    @Binding var selection: String
    @State private var query = ""
    /// Groups can be folded away. Ten rows in four groups is short enough to
    /// scan, but a presenter who only ever touches Reading should not have to
    /// read past Script Tools to get there.
    @State private var collapsed: Set<Page.Group> = []

    private var filtered: [Page] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return pages }
        return pages.filter { page in
            page.title.lowercased().contains(needle)
                || page.symbol.contains(needle)
                || page.keywords.contains { $0.lowercased().contains(needle) }
        }
    }

    private func rows(in group: Page.Group) -> [Page] {
        collapsed.contains(group) ? [] : filtered.filter { $0.group == group }
    }

    /// Every group still shows its header when collapsed — a group that
    /// vanished entirely is a page that cannot be found.
    private func isEmpty(_ group: Page.Group) -> Bool {
        filtered.filter { $0.group == group }.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Page.Group.allCases, id: \.self) { group in
                        if !isEmpty(group) {
                            VStack(alignment: .leading, spacing: 2) {
                                header(group)
                                ForEach(rows(in: group)) { page in
                                    row(page)
                                }
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text("Nothing matches “\(query)”.")
                            .font(.callout)
                            .foregroundStyle(CuePalette.inkMuted)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 184)
        .background(
            ZStack {
                CuePalette.sidebar
                PaintedField().opacity(0.20)
                Color.black.opacity(0.06)
                LinearGradient(colors: [CuePalette.surface.opacity(0.30), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false))
        // Clipped, so a long label can never paint past the rail. Rows already
        // line-limit, but a pill drawn from a long string used to bleed into the
        // content pane.
        .clipped()
        .accessibilityLabel("Settings sections")
    }

    /// The group header doubles as the disclosure control.
    private func header(_ group: Page.Group) -> some View {
        let isCollapsed = collapsed.contains(group)
        return Button {
            if collapsed.contains(group) { collapsed.remove(group) }
            else { collapsed.insert(group) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CuePalette.inkMuted)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Text(group.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(CuePalette.inkMuted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.rawValue) settings")
        .accessibilityHint(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(CuePalette.inkMuted)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(CuePalette.ink)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(CuePalette.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(CuePalette.card, in: Capsule())
        .overlay { Capsule().strokeBorder(CuePalette.hairline, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func row(_ page: Page) -> some View {
        let isSelected = page.id == selection
        return Button {
            selection = page.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : CuePalette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6,
                                style: .continuous)
                    .fill(isSelected ? CuePalette.peach : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(page.title)
    }
}

/// One inset and one measure, shared by the title, the rule and the cards of
/// every settings page.
private let settingsPageInset: CGFloat = 24
private let settingsPageMeasure: CGFloat = 520

/// The page frame: title, one line of what it is for, then the cards. Every
/// settings page has the same shape, which is what makes a sidebar of nine
/// pages feel like one app instead of nine.
struct SettingsPage<Content: View>: View {
    var title: String
    var subtitle: String = ""
    @ViewBuilder let content: () -> Content

    /// One inset and one measure for the whole page: the title, the rule under
    /// it and the cards start on the same line and stop on the same line.
    ///
    /// The rule used to span the window while everything else sat inside a
    /// 520pt column, and the column was *centred* — `alignment: .top` means
    /// centred horizontally — so on a wide window the cards drifted away from
    /// the title above them and the left margin grew with the window.
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(CuePalette.ink)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(CuePalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, settingsPageInset)
            .padding(.top, 20)
            .padding(.bottom, 14)
            // Inside the measure, not across the window: a rule that runs the
            // full width of a wide window reads as a table, and it draws the
            // eye to the empty margin the cards are not using.
            Divider()
                .overlay(CuePalette.hairline)
                .padding(.horizontal, settingsPageInset)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    content()
                }
                .padding(.horizontal, settingsPageInset)
                .padding(.top, 18)
                .padding(.bottom, 26)
                // One measure for every card on every page, so nothing
                // stretches to a different width further down.
                .frame(maxWidth: settingsPageMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A card of related settings. The default settings furniture on macOS puts
/// every row in its own box; this groups them, so a page reads as a handful of
/// decisions rather than thirty.
struct SettingsCard<Content: View>: View {
    var title: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(CuePalette.ink)
            }
            VStack(alignment: .leading, spacing: 13) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CuePalette.card, in: RoundedRectangle(cornerRadius: CuePalette.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: CuePalette.cardRadius)
                    .strokeBorder(CuePalette.hairline, lineWidth: 1)
            }
        }
    }
}
/// The app's window background: the painted field over an **opaque** floor.
///
/// One definition for the main window and the settings window, because "the
/// same look" that is actually two copies of a `ZStack` is two copies that
/// drift.
///
/// The opaque part is load-bearing. `SidebarBackdrop` is deliberately
/// translucent — it is a real window with your desktop behind it — and reusing
/// that layer here let the main window's script titles show through the
/// settings sidebar. Translucency is not "the same look"; on a window stacked
/// over another window it is a rendering of whatever is behind it.
///
/// So: solid surface first, the paint on top at low opacity, and a tonal ramp
/// toward the content side. It reads as part of the app without being a window
/// you can see through.
struct ChromeField: View {
    var body: some View {
        ZStack {
            CuePalette.surface
            PaintedField().opacity(0.30)
            Color.black.opacity(0.10)
            LinearGradient(colors: [CuePalette.surface.opacity(0.45),
                                    CuePalette.surface.opacity(0.72)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .allowsHitTesting(false)
    }
}
