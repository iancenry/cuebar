import Testing
import Foundation
@testable import PromptCore

/// Two layers on purpose. The chrome can be light; the reading surface cannot
/// be light by accident, because it is read at three metres through a camera
/// and a white prompter is unreadable. These tests pin the rules, because the
/// whole feature rests on them and they are invisible on screen.
@Suite struct ThemeChoiceTests {
    @Test func chromeFollowsTheSystemUnlessChosen() {
        #expect(ThemeChoice.resolveChrome(choice: nil, systemIsDark: true)
                == ThemeCatalog.dark)
        #expect(ThemeChoice.resolveChrome(choice: nil, systemIsDark: false)
                == ThemeCatalog.light)
        #expect(ThemeChoice.resolveChrome(choice: "", systemIsDark: false)
                == ThemeCatalog.light, "an empty string means 'follow' too")
        #expect(ThemeChoice.resolveChrome(choice: ThemeCatalog.warm, systemIsDark: true)
                == ThemeCatalog.warm)
    }

    /// The rule that keeps a Light theme from producing a prompter nobody can
    /// read. This is the whole reason the layers are separate.
    @Test func aLightChromeDoesNotGiveYouALightPrompter() {
        let surface = ThemeChoice.resolveSurface(choice: nil,
                                                 chromeTheme: ThemeCatalog.light)
        #expect(surface == ThemeCatalog.dark)
    }

    @Test func aDarkChromeThemesThePrompterToo() {
        #expect(ThemeChoice.resolveSurface(choice: nil, chromeTheme: ThemeCatalog.oled)
                == ThemeCatalog.oled)
        #expect(ThemeChoice.resolveSurface(choice: nil, chromeTheme: ThemeCatalog.warm)
                == ThemeCatalog.warm)
    }

    /// Somebody presenting in a bright room asks for a light prompter on
    /// purpose, and is not overruled by the heuristic.
    @Test func anExplicitSurfaceChoiceIsHonouredEvenIfLight() {
        #expect(ThemeChoice.resolveSurface(choice: ThemeCatalog.light,
                                          chromeTheme: ThemeCatalog.dark)
                == ThemeCatalog.light)
    }

    /// Accessibility is a mode, not a preference: it cannot be lost to a theme
    /// choice in either layer.
    @Test func highContrastOverridesEverything() {
        #expect(ThemeChoice.resolveSurface(choice: nil, chromeTheme: ThemeCatalog.warm,
                                           isHighContrast: true)
                == ThemeCatalog.highContrast)
        #expect(ThemeChoice.resolveSurface(choice: ThemeCatalog.light,
                                          chromeTheme: ThemeCatalog.dark,
                                          isHighContrast: true)
                == ThemeCatalog.highContrast)
        #expect(ThemeChoice.resolveChrome(choice: ThemeCatalog.warm, systemIsDark: true,
                                          isHighContrast: true)
                == ThemeCatalog.highContrast)
    }

    @Test func theShippedThemesAreStableIdentifiers() {
        #expect(ThemeCatalog.shipped.count == 5)
        #expect(Set(ThemeCatalog.shipped).count == ThemeCatalog.shipped.count)
        #expect(ThemeCatalog.shipped.allSatisfy { !$0.isEmpty })
    }
}
