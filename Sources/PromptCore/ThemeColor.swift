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
