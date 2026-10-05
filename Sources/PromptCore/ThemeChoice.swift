import Foundation

/// Which theme is in force, and why.
///
/// Two layers, deliberately, because they have different requirements. The
/// **chrome** — sidebar, settings, editor, transport — can be any well-designed
/// palette, including a light one, because it is looked at from half a metre
/// away. The **reading surface** is read at three metres through a camera in a
/// dark room, where near-black and high luminance are the design, not a taste.
/// Tying them together is how a Light theme ends up producing a prompter nobody
/// can read.
///
/// So: chrome follows the system unless the user says otherwise, and the
/// reading surface never follows the system at all.
public enum ThemeChoice {
    /// `nil` means "follow the system" for chrome.
    public static let followSystem = ""

    /// The chrome theme's id.
    ///
    /// Falls back to the app's own dark theme when the system is light, unless
    /// the user has explicitly chosen one — an explicit choice always wins,
    /// including over High Contrast's chrome override, because High Contrast
    /// is about the *reading* surface.
    public static func resolveChrome(choice: String?, systemIsDark: Bool,
                                     isHighContrast: Bool = false) -> String {
        if isHighContrast { return ThemeCatalog.highContrast }
        if let choice, !choice.isEmpty { return choice }
        return systemIsDark ? ThemeCatalog.dark : ThemeCatalog.light
    }

    /// The reading surface's id.
    ///
    /// Three rules, in order:
    /// 1. High Contrast overrides everything — it is an accessibility mode, not
    ///    a preference, so it cannot be lost to a theme choice.
    /// 2. An explicit surface choice is honoured even if it is a light theme:
    ///    somebody presenting in a bright room asked for that on purpose.
    /// 3. Otherwise the surface follows the chrome theme — *unless* that theme
    ///    is light, in which case it falls back to dark. This is the rule that
    ///    keeps "Light chrome" from producing an unreadable prompter.
    public static func resolveSurface(choice: String?, chromeTheme: String,
                                      isHighContrast: Bool = false) -> String {
        if isHighContrast { return ThemeCatalog.highContrast }
        if let choice, !choice.isEmpty { return choice }
        return ThemeCatalog.isLight(chromeTheme) ? ThemeCatalog.dark : chromeTheme
    }
}

/// The themes that ship, by id.
///
/// The colours live in the app layer (they are `Color`s); what lives here is
/// the *list* and the one fact the resolution rule needs — which of them are
/// light — so the rule is testable without a renderer.
///
/// Themes are data on purpose. Once a theme is a row of hex values, thirty of
/// them is a data file rather than thirty pull requests, and one that arrives
/// from outside is just another row.
public enum ThemeCatalog {
    public static let dark = "dark"
    public static let oled = "oled"
    public static let warm = "warm"
    public static let light = "light"
    public static let highContrast = "high-contrast"

    public static let shipped: [String] = [dark, oled, warm, light, highContrast]

    /// Light themes get a dark reading surface unless the presenter asks for
    /// something else. See `resolveSurface`.
    public static func isLight(_ id: String) -> Bool {
        id == light
    }

    /// True for a theme that should not be selectable for the chrome — High
    /// Contrast is a mode, chosen in its own row, not from the same list.
    public static func isMode(_ id: String) -> Bool {
        id == highContrast
    }
}