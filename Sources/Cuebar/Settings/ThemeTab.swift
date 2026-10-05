import SwiftUI
import PromptCore

/// Theme: two rows, because chrome and the reading surface are two decisions.
///
/// A single "theme" picker is the mistake this page is built around. A
/// presenter who wants a light settings window does not want a white prompter,
/// and the only way to be sure of that is to never let one control both.
struct ThemeTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPage(title: "Theme",
                     subtitle: "How the app looks — and separately, what the camera sees.") {
            SettingsCard(title: "App") {
                // `followSystem` is the default and is a real choice, not a gap
                // in the list, so it leads.
                themeRow(choice: $settings.settings.theme,
                         caption: "The sidebar, editor, transport and this window.",
                         offersFollowSystem: true)
                Divider().overlay(CuePalette.hairline)
                ToggleRow(title: "High contrast",
                          isOn: $settings.settings.highContrast,
                          caption: "Pure black with heavy white text on the prompter. "
                                 + "Overrides the reading theme below, because it is an "
                                 + "accessibility mode rather than a look.")
            }
            SettingsCard(title: "Reading surface") {
                themeRow(choice: $settings.settings.surfaceTheme,
                         caption: "What the camera sees. A light app never makes this light — "
                                 + "that would be a white page on a stage.",
                         offersFollowSystem: true)
                if isLightSurface { surfaceWarning }
            }
            SettingsCard {
                SettingsCaption(text: "The reading surface follows the app theme, except when the "
                                    + "app theme is light — then it stays dark unless you choose "
                                    + "here.")
            }
        }
    }

    /// True when the *resolved* surface is light, which needs the same
    /// resolution the app uses — otherwise the warning would appear for a
    /// choice that never takes effect.
    private var isLightSurface: Bool {
        let chrome = ThemeChoice.resolveChrome(choice: settings.settings.theme,
                                               systemIsDark: false)
        let surface = ThemeChoice.resolveSurface(choice: settings.settings.surfaceTheme,
                                                 chromeTheme: chrome,
                                                 isHighContrast: settings.settings.highContrast)
        return ThemeCatalog.isLight(surface)
    }

    @ViewBuilder
    private var surfaceWarning: some View {
        // Not an error state: a light prompter reads well in a bright room and
        // badly in a dark one, and the presenter is the one who knows the room.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sun.max")
                .foregroundStyle(CuePalette.peach)
            SettingsCaption(text: "A light prompter reads well in a bright room and badly in a "
                                + "dark one. If you are presenting at night, turn this off.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CuePalette.peach.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: CuePalette.cardRadius))
    }

    /// A grid rather than a menu: a theme is a *look*, and you cannot judge a
    /// look from its name in a popup.
    private func themeRow(choice: Binding<String>, caption: String,
                          offersFollowSystem: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCaption(text: caption)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)],
                      spacing: 10) {
                if offersFollowSystem {
                    swatchCard(title: "Follow Mac",
                               subtitle: "Whichever the system is using",
                               selected: choice.wrappedValue.isEmpty,
                               swatches: [.init(.sRGB, white: 0.94, opacity: 1),
                                          .init(.sRGB, white: 0.10, opacity: 1),
                                          .init(.sRGB, white: 0.55, opacity: 1)]) {
                        choice.wrappedValue = ThemeChoice.followSystem
                    }
                }
                ForEach(CueTheme.shipped) { theme in
                    swatch(theme, choice: choice)
                }
            }
        }
    }

    @ViewBuilder
    private func swatch(_ theme: CueTheme, choice: Binding<String>) -> some View {
        // High Contrast is a mode, chosen by the toggle above — offering it here
        // as well would be two controls for one setting, and whichever the user
        // touched last would win.
        if !ThemeCatalog.isMode(theme.id) {
            swatchCard(title: theme.name,
                       subtitle: theme.summary,
                       selected: choice.wrappedValue == theme.id,
                       swatches: [theme.tokens.surfaceColor, theme.tokens.chromeColor,
                                  theme.tokens.accentColor, theme.tokens.inkColor]) {
                choice.wrappedValue = theme.id
            }
        }
    }

    private func swatchCard(title: String, subtitle: String, selected: Bool,
                            swatches: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, colour in
                        Rectangle().fill(colour).frame(height: 34)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CuePalette.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(CuePalette.inkMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CuePalette.card, in: RoundedRectangle(cornerRadius: CuePalette.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: CuePalette.cardRadius)
                    .strokeBorder(selected ? CuePalette.peach : CuePalette.hairline,
                                  lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}