import Foundation

/// One theme: an id, a name, and a row of hex values.
///
/// The values live in PromptCore rather than beside the `Color`s on purpose.
/// They are pure data, so they can be *checked*: `contrastFailures` is how the
/// Light theme's 3.8:1 white-on-orange was found, and how it stays fixed. A
/// table of colours that only a renderer can read is a table nobody can audit.
public struct ThemeSpec: Sendable, Equatable {
    public var id: String
    public var name: String
    public var symbol: String
    public var summary: String
    public var tokens: ThemeTokens
    /// Whether this theme may also be the reading surface. A light chrome theme
    /// is not: it would give a white prompter.
    public var isForSurface: Bool

    public init(id: String, name: String, symbol: String, summary: String,
                tokens: ThemeTokens, isForSurface: Bool) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.tokens = tokens
        self.isForSurface = isForSurface
    }
}

/// The themes that ship.
///
/// Kept in step with `ThemeCatalog`'s ids: every id here must be in
/// `ThemeCatalog.shipped`, and every id there must resolve to one of these.
/// A theme reachable by id but absent from this table would silently fall back
/// to Dark, which is how a half-registered theme looks like a bug report.
public enum ThemeTable {
    public static let themes: [ThemeSpec] = [
        ThemeSpec(
            id: ThemeCatalog.dark, name: "Dark", symbol: "circle.lefthalf.filled",
            summary: "The one Cuebar has always shipped. Near-black, warm accent.",
            tokens: .dark("#0F0F11", "#1B1B1E", "#16161A", "#ECECEE", "#8A8A8F",
                          "#A8A8AF", "#B8B8BD", "#1C1C1F", "#FF8F4D",
                          "#1A120B", "#73D98C"),
            isForSurface: true),
        ThemeSpec(
            id: ThemeCatalog.oled, name: "OLED", symbol: "circle.fill",
            summary: "True black, for the OLED MacBooks. Saves power, hides seams.",
            tokens: .dark("#000000", "#0C0C0E", "#08080A", "#FFFFFF", "#8E8E93",
                          "#AEAEB2", "#C0C0C6", "#171719", "#FF9147",
                          "#1A120B", "#5BD98A"),
            isForSurface: true),
        ThemeSpec(
            id: ThemeCatalog.warm, name: "Warm", symbol: "flame",
            summary: "Sepia-toned. Gentler for a long rehearsal, and in a dark room.",
            tokens: .dark("#14110D", "#221D17", "#1B1712", "#F4EDE2", "#9A8F7E",
                          "#B5A794", "#C8B9A3", "#241F19", "#E9A05C",
                          "#1B1208", "#8FCB8A"),
            isForSurface: true),
        ThemeSpec(
            id: ThemeCatalog.light, name: "Light", symbol: "sun.max",
            summary: "For a bright room. The prompter stays dark on purpose.",
            // Two values here are darker than the first draft, both found by
            // ThemeContrastTests rather than by looking:
            //  - the accent was #D2622A, and white on it measured 3.8:1. The
            //    accent is a *background* — the selected sidebar row, the live
            //    transport button, a highlighted preset. Every other theme
            //    clears 8:1 on that pair.
            //  - `inkMuted` was #83838A at 3.5:1 on a card, which is every
            //    caption on every settings card.
            tokens: .light("#F6F6F7", "#FFFFFF", "#EFEFF1", "#1B1B1E", "#6B6B70",
                           "#64646D", "#4A4A50", "#E4E4E8", "#B4531C",
                           "#FFFFFF", "#1F8A45"),
            isForSurface: false),
        ThemeSpec(
            id: ThemeCatalog.highContrast, name: "High Contrast",
            symbol: "circle.righthalf.filled",
            summary: "Maximum contrast, no washes. A mode, not a look.",
            tokens: .dark("#000000", "#000000", "#000000", "#FFFFFF", "#FFFFFF",
                          "#FFFFFF", "#FFFFFF", "#000000", "#FFD400",
                          "#000000", "#00FF66"),
            isForSurface: true),
    ]

    /// The theme an id names, falling back to Dark.
    ///
    /// Falling back rather than trapping: a theme file that arrives from
    /// outside is just another row, and a row that cannot be read should show
    /// the default rather than take the prompter down mid-talk.
    public static func theme(_ id: String) -> ThemeSpec {
        themes.first { $0.id == id } ?? themes[0]
    }
}