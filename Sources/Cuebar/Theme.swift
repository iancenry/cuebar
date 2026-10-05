import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
import CoreText
#endif

// MARK: - Settings -> SwiftUI mapping (single place, every view shares it)

extension CueSettings.Accent {
    var color: Color {
        switch self {
        case .white: return .white
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .pink: return .pink
        case .orange: return .orange
        }
    }
}

extension CueSettings.FontFamily {
    func font(size: Double, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .sans:
            return .system(size: size, weight: weight)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .mono:
            return .system(size: size, weight: weight, design: .monospaced)
        case .dyslexia:
            if FontLoader.dyslexiaAvailable {
                let name = (weight == .bold || weight == .heavy || weight == .semibold)
                    ? "OpenDyslexic-Bold" : "OpenDyslexic-Regular"
                return .custom(name, size: size)
            }
            return .system(size: size, weight: weight, design: .rounded)
        }
    }

    /// Dyslexic readers benefit from looser spacing even on fallback fonts.
    var tracking: CGFloat { self == .dyslexia ? 0.6 : 0 }
}

extension CueSettings.TextSize {
    var label: String { rawValue.uppercased() }
}

extension CueSettings.FontWeight {
    var weight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

extension CueSettings.TextColor {
    var color: Color {
        switch self {
        case .paper: return CuePalette.ink
        case .white: return .white
        case .stone: return CuePalette.stone
        }
    }
}

extension CueSettings.SurfaceStyle {
    var color: Color {
        switch self {
        case .espresso: return CuePalette.surface
        case .black: return .black
        case .slate: return CuePalette.graphite
        }
    }
}

// MARK: - Cuebar palette (neutral graphite + peach)
//
// The prompter stays dark (camera-friendly) and neutral: a near-black
// reading canvas, graphite furniture, and peach reserved for the one
// thing that matters — the current word. Warm browns at low luminance
// read as muddy sepia, so all chrome stays gray and the accent does the
// talking. Chrome uses the same tokens so main window, overlay, and
// settings all speak one design language.

extension Color {
    /// The two forms a theme file needs, parsed by `RGBAColor` — which is in
    /// PromptCore precisely because this one function was wrong once and had
    /// no test.
    init(hex: String) {
        let value = RGBAColor(hex: hex)
        self.init(.sRGB, red: value.red, green: value.green, blue: value.blue,
                  opacity: value.alpha)
    }
}

/// The colours as SwiftUI values.
///
/// The token *data* moved to PromptCore (`ThemeTokens`, `ThemeTable`) so its
/// contrast could be tested; this is the only part that needs a renderer.
extension ThemeTokens {
    var cardColor: Color { Color(hex: card) }
    var hairlineColor: Color { Color(hex: hairline) }
    var hoverColor: Color { Color(hex: hover) }
    var selectionColor: Color { Color(hex: selection) }
    var surfaceColor: Color { Color(hex: surface) }
    var chromeColor: Color { Color(hex: chrome) }
    var sidebarColor: Color { Color(hex: sidebar) }
    var inkColor: Color { Color(hex: ink) }
    var mutedColor: Color { Color(hex: muted) }
    var inkMutedColor: Color { Color(hex: inkMuted) }
    var stoneColor: Color { Color(hex: stone) }
    var graphiteColor: Color { Color(hex: graphite) }
    var accentColor: Color { Color(hex: accent) }
    var onAccentColor: Color { Color(hex: onAccent) }
    var liveColor: Color { Color(hex: live) }
}

/// A theme, for the picker. A thin view over `ThemeSpec`: the table is the
/// single source of truth, so a theme cannot exist in the picker and not in
/// `applyThemes` (or the other way round).
struct CueTheme: Identifiable {
    var spec: ThemeSpec
    var id: String { spec.id }
    var name: String { spec.name }
    var symbol: String { spec.symbol }
    var summary: String { spec.summary }
    var tokens: ThemeTokens { spec.tokens }
    /// Whether this theme is meant for the reading surface as well as the
    /// chrome. A light chrome theme is not: it would give a white prompter.
    var isForSurface: Bool { spec.isForSurface }

    static var shipped: [CueTheme] { ThemeTable.themes.map { CueTheme(spec: $0) } }

    static func theme(_ id: String) -> CueTheme {
        CueTheme(spec: ThemeTable.theme(id))
    }
}

/// The palette, resolved.
///
/// `CuePalette` used to be a bag of `static let`s. It is now a bag of computed
/// reads through one shared token set, which is why the 287 call sites needed
/// no change at all: the name, and every colour's *meaning*, survived — only
/// where the values come from moved.
/// Holds the two resolved token sets.
///
/// A box rather than `@MainActor` statics, because `CuePalette` is read from
/// view `body` evaluation *and* from a handful of non-isolated helpers. The
/// invariant is one line: **every write happens on the main actor**, from
/// `applyThemes`, which is only ever called from settings and launch. Reads are
/// value copies of a `Sendable` struct.
final class PaletteBox: @unchecked Sendable {
    private static let storage = PaletteBox()
    static var shared: PaletteBox { storage }

    private let lock = NSLock()
    private var chromeTokens = CueTheme.theme(ThemeCatalog.dark).tokens
    private var surfaceTokens = CueTheme.theme(ThemeCatalog.dark).tokens

    var chrome: ThemeTokens {
        lock.lock(); defer { lock.unlock() }; return chromeTokens
    }

    var surface: ThemeTokens {
        lock.lock(); defer { lock.unlock() }; return surfaceTokens
    }

    func set(chrome: ThemeTokens, surface: ThemeTokens) {
        lock.lock(); defer { lock.unlock() }
        chromeTokens = chrome
        surfaceTokens = surface
    }
}

/// Resolve both layers from the user's choices, and publish them.
///
/// - Parameters:
///   - systemIsDark: the app's appearance right now, used only when the user
///     has not chosen a chrome theme.
///   - onChange: called after the palette moves, so a caller can refresh
///     anything that captured a colour.
@MainActor
func applyThemes(chromeChoice: String?, surfaceChoice: String?,
                 highContrast: Bool, systemIsDark: Bool) {
    let chromeID = ThemeChoice.resolveChrome(choice: chromeChoice,
                                            systemIsDark: systemIsDark)
    let surfaceID = ThemeChoice.resolveSurface(choice: surfaceChoice,
                                               chromeTheme: chromeID,
                                               isHighContrast: highContrast)
    let chromeTokens = CueTheme.theme(chromeID).tokens
    // High Contrast is a mode over the reading surface, not a second palette
    // for the whole app — the chrome keeps the user's chosen theme so the
    // settings window does not become a high-contrast artefact.
    let surfaceTokens: ThemeTokens = highContrast
        ? CueTheme.theme(ThemeCatalog.highContrast).tokens
        : CueTheme.theme(surfaceID).tokens
    PaletteBox.shared.set(chrome: chromeTokens, surface: surfaceTokens)
}

enum CuePalette {
    // MARK: - Chrome — sidebar, settings, editor, transport, sheets
    static var surface: Color { PaletteBox.shared.chrome.surfaceColor }
    static var chrome: Color { PaletteBox.shared.chrome.chromeColor }
    static var sidebar: Color { PaletteBox.shared.chrome.sidebarColor }
    static var card: Color { PaletteBox.shared.chrome.cardColor }
    static var ink: Color { PaletteBox.shared.chrome.inkColor }
    static var muted: Color { PaletteBox.shared.chrome.mutedColor }
    static var inkMuted: Color { PaletteBox.shared.chrome.inkMutedColor }
    static var stone: Color { PaletteBox.shared.chrome.stoneColor }
    static var graphite: Color { PaletteBox.shared.chrome.graphiteColor }
    static var peach: Color { PaletteBox.shared.chrome.accentColor }
    static var onHighlight: Color { PaletteBox.shared.chrome.onAccentColor }
    static var live: Color { PaletteBox.shared.chrome.liveColor }
    static var hairline: Color { PaletteBox.shared.chrome.hairlineColor }
    static var hover: Color { PaletteBox.shared.chrome.hoverColor }
    static var selection: Color { PaletteBox.shared.chrome.selectionColor }

    // MARK: - Reading surface — the prompter and its preview
    /// The canvas the script is read on. Separate from `chrome` so a light
    /// chrome theme cannot hand somebody a white prompter at three metres.
    static var readingSurface: Color { PaletteBox.shared.surface.surfaceColor }
    static var readingInk: Color { PaletteBox.shared.surface.inkColor }
    static var readingStone: Color { PaletteBox.shared.surface.stoneColor }
    static var readingGraphite: Color { PaletteBox.shared.surface.graphiteColor }
    static var readingAccent: Color { PaletteBox.shared.surface.accentColor }
    static var readingOnAccent: Color { PaletteBox.shared.surface.onAccentColor }
    /// The accent used *on the reading surface*. Named apart from `peach` so a
    /// change of chrome theme cannot repaint a cue the presenter has already
    /// chosen.
    static var cueAccent: Color { PaletteBox.shared.surface.accentColor }

    static let cardRadius: CGFloat = 16
    /// The band the floating chrome floats in: a 24pt control with 4pt of
    /// air above and below. The window's title-bar strip is 28pt and macOS
    /// centres the traffic lights on its midline, so a 32pt band puts the
    /// controls 2pt below that line — close enough to read as level, and
    /// the air is what stops the pills looking glued to the window edge.
    /// The earlier 39pt band (control plus its own padding) hung them 5.5pt
    /// low, which read as "not centred" even though the row was symmetric.
    /// One constant, because the page, the editor and the sidebar all have
    /// to start under the same line.
    static let chromeRowHeight: CGFloat = 32
    /// Height of a control in the band. Has to leave the line above with
    /// 2pt to spare, or the control grows the row and drops the chrome
    /// below the lights again.
    static let chromeControlHeight: CGFloat = 24
    /// Side margin for the band. Generous on purpose: in fullscreen the
    /// window's edge *is* the screen's edge, so a 12pt margin left the
    /// gear reading as clipped rather than inset.
    static let chromeRowMargin: CGFloat = 16
}

/// Status chip: "Reading… 00:14" / "Holding 1.4s" / "Paused". Mural pill.
struct StatusPill: View {
    let isPlaying: Bool
    var showElapsed: Bool = true
    /// Countdown while a timed cue ([pause 2s]) freezes playback.
    var holdRemaining: TimeInterval? = nil
    /// Why it stopped. A prompter that went quiet by itself must say so, or
    /// the presenter has no idea whether to say something.
    var pauseReason: PromptEngine.PauseReason? = nil
    /// Distance from the target length (see `PaceTarget`). Positive is
    /// behind. Shown once the run exists — a fresh script has no pace to
    /// judge, and "+0:00" next to it is noise.
    var drift: TimeInterval? = nil

    private var label: String {
        if let r = holdRemaining, r > 0.05 {
            return "Holding \(String(format: "%.1f", r))s"
        }
        guard !isPlaying else { return "Reading…" }
        if let reason = pauseReason?.label {
            return "Paused — \(reason)"
        }
        return "Paused"
    }

    /// A run exists the moment anything has happened to it. Before that the
    /// pill stays a status only; afterwards the pace readout earns its place
    /// — and being able to see "behind" while paused is the point of it.
    private var runHasStarted: Bool {
        isPlaying || holdRemaining != nil || pauseReason != nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(holdRemaining != nil ? CuePalette.peach
                      : (isPlaying ? CuePalette.live : CuePalette.muted))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isPlaying ? CuePalette.ink : CuePalette.muted)
            if isPlaying, showElapsed {
                ElapsedClock()
            }
            if showElapsed, runHasStarted, let drift {
                Text(PaceTarget.format(drift))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(drift < 0 ? CuePalette.live : CuePalette.peach)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(drift.map { PaceTarget.format($0) }.map { label + ", " + $0 } ?? label)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: CuePalette.chromeControlHeight)
        .glassSurface(in: Capsule())
    }
}

extension StatusPill {
    /// The live run's drift, or nil with no target. One computation for
    /// every call site — the pill in the window header, the dock, and the
    /// phone all read the same number, or they end up disagreeing.
    static func drift(engine: PromptEngine, targetMinutes: Double?) -> TimeInterval? {
        guard let minutes = targetMinutes, let word = engine.currentWordIndex else { return nil }
        return PaceTarget.drift(word: word, totalWords: engine.words.count,
                                wordsPerSecond: engine.wordsPerSecond,
                                targetSeconds: minutes * 60)
    }
}

struct ElapsedClock: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: 1.0)) { ctx in
            Text(clockString(ctx.date.timeIntervalSince(start)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func clockString(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}


// MARK: - Bundled OpenDyslexic (SIL-OFL, see Resources/OFL.txt)

enum FontLoader {
    static func register() {
#if os(macOS)
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "otf", subdirectory: nil) else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
#endif
    }

    static var dyslexiaAvailable: Bool {
#if os(macOS)
        NSFont(name: "OpenDyslexic-Regular", size: 12) != nil
            || NSFont(name: "OpenDyslexic", size: 12) != nil
#else
        return false
#endif
    }
}

extension CueSettings.FontFamily {
    /// A CoreText font for the same face, or nil when there isn't one to ask
    /// about.
    ///
    /// The mask slot needs a real measurement and must not be built by
    /// bridging a SwiftUI `Font` to AppKit: `Font.custom("OpenDyslexic-Bold")`
    /// has no `NSFont` to bridge to, and the bridge threw inside the window
    /// layout pass — an Objective-C exception on the display cycle, which is an
    /// unconditional abort. CoreText takes a PostScript name, so this path has
    /// no bridging in it at all.
    /// CoreText name for a face at a weight, where there is one.
    func coreTextName(weight: Font.Weight) -> String? {
        guard self == .dyslexia, FontLoader.dyslexiaAvailable else { return nil }
        return (weight == .bold || weight == .heavy || weight == .semibold)
            ? "OpenDyslexic-Bold" : "OpenDyslexic-Regular"
    }
}

/// Width of a masked word, measured rather than guessed.
///
/// The arithmetic this replaces (`0.5 em` per character) was systematically
/// wrong in both directions: about 21% *wide* on ordinary English prose, and
/// about 40% *narrow* on capitals, CJK and emoji — which is why the page
/// re-wrapped the moment a word was unmasked, in a mode whose entire promise
/// is that the page does not move. Nothing ever clipped; it reflowed.
///
/// Over-estimating is free (a slot slightly too wide), so the measurement is
/// padded a little and rounded up. Memoised on everything that affects it,
/// because this is asked once per visible word per render.
@MainActor
enum MaskedWordWidth {
    /// Measured on the main actor, where the layout that asks is running, and
    /// never from anywhere else — so a plain dictionary is the right amount of
    /// machinery.
    private static var cache: [Key: CGFloat] = [:]
    private struct Key: Hashable {
        let text: String
        let name: String?
        let size: Double
        let bold: Bool
        let tracking: CGFloat
    }
    private static let limit = 4096

    static func width(of text: String, family: CueSettings.FontFamily, size: Double,
                      bold: Bool, tracking: CGFloat) -> CGFloat {
        let key = Key(text: text, name: family.coreTextName(weight: bold ? .bold : .regular),
                      size: size, bold: bold, tracking: tracking)
        if let cached = cache[key] { return cached }
        let measured = measure(key: key)
        if cache.count > limit { cache.removeAll(keepingCapacity: true) }
        cache[key] = measured
        return measured
    }

    private static func measure(key: Key) -> CGFloat {
        let characters = max(1, key.text.count)
        // The floor: a one- or two-letter gap is wider than the word it
        // stands in for, which reads as a deliberate redaction bar.
        var width = max(28, fontFor(key).map { typographicWidth(of: key.text, font: $0) }
                        ?? CGFloat(characters) * CGFloat(key.size) * 0.5)
        width += key.tracking * CGFloat(characters)
        // Over-estimate rather than clip.
        return ceil(width) + 2
    }

    private static func fontFor(_ key: Key) -> CTFont? {
        if let name = key.name {
            return CTFontCreateWithName(name as CFString, CGFloat(key.size), nil)
        }
        // The system faces: a monospaced design changes the answer enough to
        // be worth naming.
        if key.name == nil {
            let base: String = CTFontCopyPostScriptName(
                CTFontCreateUIFontForLanguage(.system, CGFloat(key.size), nil) ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(key.size), nil)) as String
            return CTFontCreateWithName(base as CFString, CGFloat(key.size), nil)
        }
        return nil
    }

    private static func typographicWidth(of text: String, font: CTFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// Applies the chosen themes, and keeps them applied.
///
/// One owner for the whole app, on both windows. `PaletteBox` is global, so if
/// the main window and the settings window each resolved themes on their own
/// they would disagree for as long as the second one stayed open — a settings
/// window showing a different palette from the window it was opened from.
///
/// Applied at the *scene* roots rather than inside a settings page: a theme is
/// not a setting you can see, it is the thing every other setting is drawn with.
struct CuebarTheming: ViewModifier {
    @Bindable var settings: SettingsStore
    /// The system's appearance, which is only consulted when the user has not
    /// chosen a chrome theme. Read from the environment rather than
    /// `NSApp.effectiveAppearance` so that the app following the system is a
    /// *rendering* decision, not a poll.
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(chromeScheme)
            .onAppear { refresh() }
            .onChange(of: settings.settings.theme) { _, _ in refresh() }
            .onChange(of: settings.settings.surfaceTheme) { _, _ in refresh() }
            .onChange(of: settings.settings.highContrast) { _, _ in refresh() }
            .onChange(of: systemScheme) { _, _ in refresh() }
    }

    /// The window's own appearance, or `nil` to follow the system.
    ///
    /// `nil` matters: forcing `.dark` on a system in Light Mode makes every
    /// control wrong, and forcing a scheme when the user asked to follow the
    /// system is the app overriding them with a preference they never set.
    private var chromeScheme: ColorScheme? {
        let choice = settings.settings.theme
        guard !choice.isEmpty else { return nil }
        let resolved = ThemeChoice.resolveChrome(choice: choice,
                                                 systemIsDark: systemScheme == .dark)
        return ThemeCatalog.isLight(resolved) ? .light : .dark
    }

    private func refresh() {
        applyThemes(chromeChoice: settings.settings.theme,
                    surfaceChoice: settings.settings.surfaceTheme,
                    highContrast: settings.settings.highContrast,
                    systemIsDark: systemScheme == .dark)
    }
}

extension View {
    func cuebarTheming(_ settings: SettingsStore) -> some View {
        modifier(CuebarTheming(settings: settings))
    }
}
