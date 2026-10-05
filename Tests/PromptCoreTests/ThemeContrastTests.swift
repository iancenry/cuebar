import Testing
@testable import PromptCore

/// Every shipped theme has to be readable, and the check is arithmetic.
///
/// Light shipped at 3.8:1 white-on-orange — the selected sidebar row, the live
/// transport button, a highlighted preset — and nothing in the build would have
/// said so. Themes are data, so this can be a test rather than an opinion.
@Suite struct ThemeContrastTests {
    @Test func everyShippedThemeIsReadable() {
        for theme in ThemeTable.themes {
            let failures = theme.contrastFailures()
            #expect(failures.isEmpty, "\n\(failures.joined(separator: "\n"))")
        }
    }

    /// The ids a user can pick have to be the ids that resolve. A theme listed in
    /// the picker but absent from the table falls back to Dark silently, which
    /// reads as "the picker is broken" rather than "the table is short".
    @Test func theCatalogAndTheTableAgree() {
        #expect(ThemeCatalog.shipped.count == ThemeTable.themes.count)
        for id in ThemeCatalog.shipped {
            #expect(ThemeTable.themes.contains { $0.id == id },
                    "\(id) is in the catalog but not in the table")
            #expect(ThemeTable.theme(id).id == id, "\(id) does not resolve to itself")
        }
    }

    /// A theme's two layers are the whole design: only a theme marked for the
    /// surface may become the prompter, and High Contrast is a mode.
    @Test func onlyOneShippedThemeIsLight() {
        let light = ThemeTable.themes.filter { ThemeCatalog.isLight($0.id) }
        #expect(light.count == 1)
        #expect(!light[0].isForSurface,
                "a light theme marked for the surface is a white prompter")
    }

    /// The alpha'd washes must not be *invisible*: a card that renders the same
    /// as the surface behind it is a card with no edge.
    @Test func cardsAreDistinguishableFromTheirSurface() {
        for theme in ThemeTable.themes {
            let card = RGBAColor(hex: theme.tokens.card)
            #expect(card.alpha > 0, "\(theme.id) has a fully transparent card")
            #expect(card.alpha < 0.5,
                    "\(theme.id)'s card is nearly opaque; it would read as a second surface")
        }
    }
}
