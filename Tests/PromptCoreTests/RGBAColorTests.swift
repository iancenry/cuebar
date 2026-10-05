import Testing
import Foundation
@testable import PromptCore

/// A theme is a row of hex strings, so the parser is load-bearing: every card,
/// wash and hairline in the app goes through it.
///
/// The bug these pin: reading alpha out of the *first* byte instead of the
/// last. `#FFFFFF14` is a 6% white wash and came out `r=1, g=1, b=0.08, a=1` —
/// opaque yellow — which painted the entire settings window yellow.
@Suite struct RGBAColorTests {
    @Test func sixDigitsAreFullyOpaque() {
        let colour = RGBAColor(hex: "#FF8F4D")
        #expect(abs(colour.red - 1.0) < 0.01)
        #expect(abs(colour.green - 0.561) < 0.01)
        #expect(abs(colour.blue - 0.302) < 0.01)
        #expect(colour.alpha == 1)
    }

    /// The one that went wrong.
    @Test func theLastPairIsTheAlpha() {
        let wash = RGBAColor(hex: "#FFFFFF14")
        #expect(wash.red == 1 && wash.green == 1 && wash.blue == 1,
                "the wash must stay white")
        #expect(abs(wash.alpha - Double(0x14) / 255) < 0.001,
                "alpha is the last byte pair, not the first")
    }

    @Test func everyWashInTheShippedThemesParsesAsItsColour() {
        // The exact values `CueTheme` uses, so a typo in a theme row is caught
        // here rather than on screen.
        for hex in ["#FFFFFF14", "#FFFFFF0D", "#FFFFFF16", "#0000000A",
                    "#00000014", "#00000008", "#00000010"] {
            let colour = RGBAColor(hex: hex)
            let wantsBlack = hex.hasPrefix("#000000")
            #expect(abs(colour.alpha - Double(UInt8(hex.suffix(2), radix: 16)!) / 255) < 0.001,
                    "\(hex) alpha")
            if wantsBlack {
                #expect(colour.red == 0 && colour.green == 0 && colour.blue == 0)
            } else {
                #expect(colour.red == 1 && colour.green == 1 && colour.blue == 1)
            }
        }
    }

    @Test func nonsenseIsVisibleRatherThanTransparent() {
        #expect(RGBAColor(hex: "nope") == RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(RGBAColor(hex: "").alpha == 1)
    }

    @Test func itRoundTrips() {
        #expect(RGBAColor(hex: "#FF8F4D").hexString == "#FF8F4D")
        #expect(RGBAColor(hex: "#FFFFFF14").hexString == "#FFFFFF14")
    }

    @Test func theLeadingHashIsOptional() {
        #expect(RGBAColor(hex: "FF8F4D") == RGBAColor(hex: "#FF8F4D"))
    }
}
