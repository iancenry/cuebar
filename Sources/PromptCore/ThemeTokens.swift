import Foundation

/// One theme's colours, as hex strings.
///
/// Data, not `Color`s, so it can be tested without a renderer. The washes
/// (`card`, `hairline`, `hover`, `selection`) carry their own alpha, which is
/// why a light theme and a dark theme can share one set of names.
public struct ThemeTokens: Sendable, Equatable {
    public var surface = ""
    public var chrome = ""
    public var sidebar = ""
    public var card = ""       // rgba — the alpha is part of the value
    public var ink = ""
    public var muted = ""
    public var inkMuted = ""
    public var stone = ""
    public var graphite = ""
    public var accent = ""
    public var onAccent = ""
    public var live = ""
    public var hairline = ""
    public var hover = ""
    public var selection = ""

    public init(surface: String, chrome: String, sidebar: String, card: String,
                ink: String, muted: String, inkMuted: String, stone: String,
                graphite: String, accent: String, onAccent: String, live: String,
                hairline: String, hover: String, selection: String) {
        self.surface = surface
        self.chrome = chrome
        self.sidebar = sidebar
        self.card = card
        self.ink = ink
        self.muted = muted
        self.inkMuted = inkMuted
        self.stone = stone
        self.graphite = graphite
        self.accent = accent
        self.onAccent = onAccent
        self.live = live
        self.hairline = hairline
        self.hover = hover
        self.selection = selection
    }

    /// Dark themes start their washes with white and light themes with black,
    /// so `card`/`hairline`/`hover`/`selection` only need an alpha in the data.
    public static func dark(_ surface: String, _ chrome: String, _ sidebar: String,
                            _ ink: String, _ muted: String, _ inkMuted: String,
                            _ stone: String, _ graphite: String, _ accent: String,
                            _ onAccent: String, _ live: String) -> ThemeTokens {
        ThemeTokens(surface: surface, chrome: chrome, sidebar: sidebar,
                    card: "#FFFFFF14", ink: ink, muted: muted, inkMuted: inkMuted,
                    stone: stone, graphite: graphite, accent: accent,
                    onAccent: onAccent, live: live,
                    hairline: "#FFFFFF14", hover: "#FFFFFF0D", selection: "#FFFFFF16")
    }

    public static func light(_ surface: String, _ chrome: String, _ sidebar: String,
                             _ ink: String, _ muted: String, _ inkMuted: String,
                             _ stone: String, _ graphite: String, _ accent: String,
                             _ onAccent: String, _ live: String) -> ThemeTokens {
        ThemeTokens(surface: surface, chrome: chrome, sidebar: sidebar,
                    card: "#0000000A", ink: ink, muted: muted, inkMuted: inkMuted,
                    stone: stone, graphite: graphite, accent: accent,
                    onAccent: onAccent, live: live,
                    hairline: "#00000014", hover: "#00000008", selection: "#00000010")
    }
}