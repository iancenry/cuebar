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

// MARK: - Cuebar Calm palette (warm paper + peach, mural-inspired)
//
// The prompter stays dark (camera-friendly) but warm: espresso
// background, paper-white ink, peach highlight, rose cues.
// Chrome uses the same tokens so main window, overlay, and
// settings all speak one design language.

enum CuePalette {
    /// Deep warm charcoal for the reading surface.
    static let surface = Color(red: 0.13, green: 0.11, blue: 0.095)
    /// Raised card fill on top of the surface.
    static let card = Color.white.opacity(0.05)
    /// Warm paper white for primary text.
    static let ink = Color(red: 0.965, green: 0.94, blue: 0.90)
    /// Muted taupe for secondary text.
    static let muted = Color(red: 0.66, green: 0.61, blue: 0.55)
    /// Warm stone for the alternate reading ink.
    static let stone = Color(red: 0.79, green: 0.74, blue: 0.68)
    /// Cool graphite reading surface.
    static let graphite = Color(red: 0.15, green: 0.15, blue: 0.16)
    /// Peach accent: progress, toggles, primary actions.
    static let peach = Color(red: 0.95, green: 0.63, blue: 0.42)
    /// Deep peach for text on the highlight pill.
    static let onHighlight = Color(red: 0.16, green: 0.10, blue: 0.06)
    /// Rose for stage cues.
    static let rose = Color(red: 0.91, green: 0.48, blue: 0.58)
    /// Live green dot for the Reading status.
    static let live = Color(red: 0.45, green: 0.85, blue: 0.55)

    static let cardRadius: CGFloat = 16
    static let pillRadius: CGFloat = 999
}

/// Status chip: "Reading… 00:14" / "Paused". Mural-style pill.
struct StatusPill: View {
    let isPlaying: Bool
    var showElapsed: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isPlaying ? CuePalette.live : CuePalette.muted)
                .frame(width: 7, height: 7)
            Text(isPlaying ? "Reading…" : "Paused")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isPlaying ? CuePalette.ink : CuePalette.muted)
            if isPlaying, showElapsed {
                ElapsedClock()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPlaying ? "Reading" : "Paused")
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(CuePalette.card, in: Capsule())
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
