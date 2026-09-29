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

enum CuePalette {
    /// Near-black reading canvas — the darkest layer.
    static let surface = Color(red: 0.059, green: 0.059, blue: 0.067)
    /// Window furniture (top bar, transport, editor).
    static let chrome = Color(red: 0.106, green: 0.106, blue: 0.118)
    /// The library rail — one step under the chrome.
    static let sidebar = Color(red: 0.086, green: 0.086, blue: 0.094)
    /// Raised card fill on top of any surface.
    static let card = Color.white.opacity(0.06)
    /// Primary text.
    static let ink = Color(red: 0.925, green: 0.925, blue: 0.933)
    /// Secondary text.
    static let muted = Color(red: 0.541, green: 0.541, blue: 0.561)
    /// Alternate reading ink.
    static let stone = Color(red: 0.72, green: 0.72, blue: 0.74)
    /// Slate reading surface option.
    static let graphite = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// Sunset-orange accent: progress, toggles, primary actions, current word.
    /// More saturated than a peach so it doesn't read as tan on graphite.
    static let peach = Color(red: 1.0, green: 0.561, blue: 0.302)
    /// Deep brown for text on the peach highlight pill.
    static let onHighlight = Color(red: 0.10, green: 0.07, blue: 0.04)
    /// Live green dot for the Reading status.
    static let live = Color(red: 0.45, green: 0.85, blue: 0.55)
    /// Hairline separating chrome regions.
    static let hairline = Color.white.opacity(0.08)
    /// Hover wash for rows and quiet buttons.
    static let hover = Color.white.opacity(0.05)
    /// Selected/active wash — neutral so it never tints brown.
    static let selection = Color.white.opacity(0.085)

    static let cardRadius: CGFloat = 16
    /// Height of the floating chrome band: the tallest control (26pt) plus
    /// the strip's 5pt breathing room above and below. One constant, because
    /// the reading surface, the editor and the sidebar all have to start
    /// under the same line — a second guess here is what left the page
    /// climbing behind the pills in an earlier pass.
    static let chromeRowHeight: CGFloat = 36
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassSurface(in: Capsule())
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
