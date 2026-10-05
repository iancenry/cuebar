import Foundation

/// A colour as four components, so a theme file is data and the palette can be
/// checked without a renderer.
///
/// Parsed **positionally**, byte pairs from the left: `RR GG BB`, then `AA` if
/// present.
///
/// The first version shifted the whole 32-bit value instead, which read the
/// alpha out of the *first* byte: `#FFFFFF14` — a 6% white wash — came out
/// `r=1, g=1, b=0.08, a=1`, which is opaque yellow. Every card, search field
/// and selection wash in the app painted itself that colour. Positional
/// parsing cannot make that mistake, and it is what `RGBAColorTests` pins.
public struct RGBAColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`. Anything unreadable is opaque black,
    /// which is visible rather than accidentally transparent.
    public init(hex text: String) {
        var digits = text
        if digits.hasPrefix("#") { digits.removeFirst() }
        func byte(_ index: Int) -> Double {
            let start = digits.index(digits.startIndex, offsetBy: index * 2)
            let end = digits.index(start, offsetBy: 2)
            guard digits.distance(from: start, to: end) == 2,
                  let value = UInt8(digits[start..<end], radix: 16) else { return 0 }
            return Double(value) / 255
        }
        let hasAlpha = digits.count == 8
        red = digits.count >= 6 ? byte(0) : 0
        green = digits.count >= 6 ? byte(1) : 0
        blue = digits.count >= 6 ? byte(2) : 0
        alpha = hasAlpha ? byte(3) : 1
    }

    public var hexString: String {
        func pair(_ value: Double) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        let base = "#\(pair(red))\(pair(green))\(pair(blue))"
        return alpha >= 1 ? base : base + pair(alpha)
    }
}

// MARK: - Contrast

extension RGBAColor {
    /// WCAG relative luminance.
    ///
    /// Composited over `background` first: a theme's `accent` is often drawn
    /// with an alpha, and an alpha'd colour's contrast is not its own — it is
    /// the contrast of the *result*.
    public func relativeLuminance(over background: RGBAColor? = nil) -> Double {
        let base = background ?? self
        let a = Swift.max(0, Swift.min(1, alpha))
        func mix(_ mine: Double, _ theirs: Double) -> Double { mine * a + theirs * (1 - a) }
        return 0.2126 * linearize(mix(red, base.red))
             + 0.7152 * linearize(mix(green, base.green))
             + 0.0722 * linearize(mix(blue, base.blue))
    }

    private func linearize(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// WCAG contrast ratio, 1:1 … 21:1.
    public func contrastRatio(against other: RGBAColor) -> Double {
        let a = relativeLuminance()
        let b = other.relativeLuminance()
        return (Swift.max(a, b) + 0.05) / (Swift.min(a, b) + 0.05)
    }
}

extension ThemeSpec {
    /// The contrast floor for text a presenter has to read.
    ///
    /// 4.5 is WCAG AA for normal-size text. The reading surface is held to a
    /// higher bar still, because it is read at three metres through a camera
    /// in a dark room rather than at a desk.
    public static let bodyContrast: Double = 4.5
    public static let largeContrast: Double = 3.0

    /// Every pair in this theme that fails its floor, as readable sentences.
    ///
    /// Returns a list rather than a bool so the failure can be *named* in a
    /// test. A theme that quietly ships at 3.8:1 is invisible in a unit test
    /// and invisible again on screen, and this is the only place either can
    /// catch it.
    public func contrastFailures() -> [String] {
        let tokens = self.tokens
        func ratio(_ a: String, _ b: String, over backdrop: String? = nil) -> Double {
            RGBAColor(hex: a).contrastRatio(against: RGBAColor(hex: backdrop ?? b))
        }
        var out: [String] = []
        func check(_ label: String, _ value: Double, _ floor: Double) {
            if value < floor {
                out.append("\(id): \(label) is \(String(format: "%.2f", value)):1, "
                           + "under \(String(format: "%.1f", floor)):1")
            }
        }
        // Body text on the two surfaces it is ever read on.
        check("ink on surface", ratio(tokens.ink, tokens.surface), Self.bodyContrast)
        check("ink on card", ratio(tokens.ink, tokens.card, over: tokens.surface),
              Self.bodyContrast)
        check("muted on surface", ratio(tokens.muted, tokens.surface), Self.bodyContrast)
        check("inkMuted on card", ratio(tokens.inkMuted, tokens.card, over: tokens.surface),
              Self.bodyContrast)
        // The accent is a *background*: the selected sidebar row, the live
        // transport button, a highlighted preset. Its label is `onAccent`.
        check("onAccent on accent", ratio(tokens.onAccent, tokens.accent), Self.bodyContrast)
        // 14pt regular is not large text, but the sidebar's symbols are
        // decorative — so this one is held only to the large floor.
        check("accent on surface", ratio(tokens.accent, tokens.surface), Self.largeContrast)
        // The recording dot, on a surface, at a glance.
        check("live on surface", ratio(tokens.live, tokens.surface), Self.largeContrast)
        return out
    }
}
