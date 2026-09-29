#!/usr/bin/env swift

// Removes something from an image by rebuilding what was behind it.
//
//   swift Scripts/inpaint.swift <in> <out> <x> <y> <w> <h> [options]
//
//     --feather <px>       blend band at the hole's edge        (default 18)
//     --passes <n>         solve iterations                      (default 1400)
//     --donor <x> <y>      a region of the same painting to copy structure from
//     --donor-feather <px> blend band for the donor              (default 44)
//
// Two stages, because neither alone is enough on a painting:
//
//  1. **A harmonic fill.** Every pixel inside the hole becomes the average
//     of its neighbours each pass, with the boundary held fixed, so the
//     result matches the pixels around the hole *exactly* at the edges.
//     That continuity is the whole reason to use it.
//
//  2. **A donor paste for structure.** The fill is smooth, and smooth is
//     what reads as a smudge — a retouched patch is obvious because it has
//     no shapes in it, not because its colour is wrong. So a region of the
//     same painting is pasted over the fill, colour-matched to the
//     surrounding and blended over a wide band. Only structure comes from
//     the donor; the low frequencies at the seam still come from stage 1.
//
// Three traps, all of which produced a plausible-looking image in the wrong
// place, and are worth knowing about before changing anything here:
//
//  - **A bitmap context filled by `draw(image, in:)` is already top-down**
//    (row 0 is the image's top row), and `CGImage(…provider:)` reads it the
//    same way, so the bytes round-trip unchanged. The reflex to flip a
//    CoreGraphics buffer is wrong here: flipping both ends cancels out for
//    the image but leaves the *edit* mirrored about the centre of the hole.
//  - **`CGContext(data: &array)` does not write into the array.** The
//    context keeps the pointer it was handed, which is a temporary; the
//    write lands in the copy and the original is untouched.
//  - **A context over memory is entitled to return nil from `makeImage()`.**
//    Build the image from a `CGDataProvider` over the bytes instead.
//
// Judge the result *at the size it will be seen*: `PaintedField` blurs this
// by 13pt after scaling it into the rail, which forgives a great deal.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments

struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 1_000_000) / 1_000_000 }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + unit() * (hi - lo) }
}

let argv = CommandLine.arguments
guard argv.count >= 7 else {
    print("usage: inpaint.swift <in> <out> <x> <y> <w> <h> [options]")
    exit(2)
}
func option(_ name: String, default fallback: Int) -> Int {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return fallback }
    return Int(argv[i + 1])!
}
let inPath = argv[1], outPath = argv[2]
let holeX = Int(argv[3])!, holeY = Int(argv[4])!
let holeW = Int(argv[5])!, holeH = Int(argv[6])!
let feather = Float(option("--feather", default: 18))
let passes = option("--passes", default: 1400)
let donorFeather = Float(option("--donor-feather", default: 44))
let donor: (Int, Int)? = {
    guard let i = argv.firstIndex(of: "--donor"), i + 2 < argv.count else { return nil }
    return (Int(argv[i + 1])!, Int(argv[i + 2])!)
}()

// MARK: - Load

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("cannot read \(inPath)")
}
let W = image.width, H = image.height
var pixels = [UInt8](repeating: 0, count: W * H * 4)
pixels.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H,
                              bitsPerComponent: 8, bytesPerRow: W * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("no context")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
}
let original = pixels          // the donor has to come from untouched painting

var rng = Rng(seed: 0xBEEF)
@inline(__always) func at(_ x: Int, _ y: Int, _ c: Int) -> Float {
    Float(pixels[(y * W + x) * 4 + c])
}

// MARK: - Mask
//
// Jittered, because the single thing that gives a retouch away is a straight
// line. A clean rectangle edge reads as "erased" even when the colour is
// perfect, and a few pixels of noise on the boundary costs nothing.

var mask = [Float](repeating: 0, count: W * H)
for y in holeY..<(holeY + holeH) {
    for x in holeX..<(holeX + holeW) {
        guard x >= 0, y >= 0, x < W, y < H else { continue }
        let dx = min(x - holeX, holeX + holeW - 1 - x)
        let dy = min(y - holeY, holeY + holeH - 1 - y)
        let jitter = Float(rng.unit() - 0.5) * 8
        mask[y * W + x] = min(1, max(0, (Float(min(dx, dy)) + jitter) / max(1, feather)))
    }
}

// MARK: - Stage 1: harmonic fill

var field = [Float](repeating: 0, count: W * H * 3)
for i in 0..<(W * H) {
    for c in 0..<3 { field[i * 3 + c] = Float(pixels[i * 4 + c]) }
}
@inline(__always) func sample(_ x: Int, _ y: Int, _ c: Int) -> Float? {
    guard x >= 0, y >= 0, x < W, y < H else { return nil }
    return field[(y * W + x) * 3 + c]
}
for _ in 0..<passes {
    for y in holeY..<(holeY + holeH) {
        for x in holeX..<(holeX + holeW) {
            guard x >= 0, y >= 0, x < W, y < H, mask[y * W + x] >= 1 else { continue }
            let i = (y * W + x) * 3
            for c in 0..<3 {
                var sum: Float = 0, n: Float = 0
                if let v = sample(x + 1, y, c) { sum += v; n += 1 }
                if let v = sample(x - 1, y, c) { sum += v; n += 1 }
                if let v = sample(x, y + 1, c) { sum += v; n += 1 }
                if let v = sample(x, y - 1, c) { sum += v; n += 1 }
                if n > 0 { field[i + c] = sum / n }
            }
        }
    }
}
for i in 0..<(W * H) {
    let m = mask[i]
    guard m > 0 else { continue }
    for c in 0..<3 {
        let base = Float(original[i * 4 + c])
        pixels[i * 4 + c] = UInt8(max(0, min(255, field[i * 3 + c] * m + base * (1 - m))))
    }
}

// MARK: - Stage 2: donor paste for structure

if let (dx, dy) = donor {
    // A small shift, so the paste does not sit at exactly the offset it was
    // taken from and read as a stamp.
    let shiftX = Int(rng.range(-5, 5)), shiftY = Int(rng.range(-5, 5))

    // Colour-match: compare the donor's mean against the mean of the ring
    // just outside the hole, and correct per channel. Without this the paste
    // is a slightly different light than the cloud it lands in, and a wide
    // blend band makes that *more* visible, not less.
    var donorMean = [Double](repeating: 0, count: 3)
    var ringMean = [Double](repeating: 0, count: 3)
    var donorCount = 0.0, ringCount = 0.0
    for y in 0..<holeH {
        for x in 0..<holeW {
            let sx = dx + x + shiftX, sy = dy + y + shiftY
            guard sx >= 0, sy >= 0, sx < W, sy < H else { continue }
            donorCount += 1
            for c in 0..<3 { donorMean[c] += Double(original[(sy * W + sx) * 4 + c]) }
        }
    }
    for y in (holeY - 12)..<(holeY + holeH + 12) {
        for x in (holeX - 12)..<(holeX + holeW + 12) {
            let inside = x >= holeX && x < holeX + holeW && y >= holeY && y < holeY + holeH
            guard !inside, x >= 0, y >= 0, x < W, y < H else { continue }
            ringCount += 1
            for c in 0..<3 { ringMean[c] += Double(pixels[(y * W + x) * 4 + c]) }
        }
    }
    if donorCount == 0 || ringCount == 0 {
        print("warning: donor or ring was empty, keeping the harmonic fill")
        // Nothing to paste from. The fill alone is a smudge, but a smudge
        // beats writing nothing.
    } else {
        var gain = [Double](repeating: 1, count: 3)
    for c in 0..<3 {
        let d = donorMean[c] / donorCount, r = ringMean[c] / ringCount
        // Gain rather than an offset: a difference in *lightness* is the
        // common case, and a gain scales a cloud's internal contrast with it
        // instead of flattening it the way a subtraction would.
        gain[c] = d > 8 ? max(0.75, min(1.3, r / d)) : 1
    }

    // Wide, smooth, jittered blend band: 1 in the core, easing to 0 well
    // inside the hole's edge so the donor's own boundary never lands on the
    // fill's boundary.
    var paste = [Float](repeating: 0, count: W * H)
    for y in holeY..<(holeY + holeH) {
        for x in holeX..<(holeX + holeW) {
            guard x >= 0, y >= 0, x < W, y < H else { continue }
            let edge = Float(min(x - holeX, holeX + holeW - 1 - x,
                                 y - holeY, holeY + holeH - 1 - y))
            let wobble = Float(rng.unit() - 0.5) * 26
            let t = min(1, max(0, (edge + wobble) / max(1, donorFeather)))
            // smoothstep, so the band has no visible knee
            paste[y * W + x] = t * t * (3 - 2 * t)
        }
    }

    for y in holeY..<(holeY + holeH) {
        for x in holeX..<(holeX + holeW) {
            guard x >= 0, y >= 0, x < W, y < H else { continue }
            let p = paste[y * W + x]
            guard p > 0 else { continue }
            let sx = dx + (x - holeX) + shiftX, sy = dy + (y - holeY) + shiftY
            guard sx >= 0, sy >= 0, sx < W, sy < H else { continue }
            for c in 0..<3 {
                let d = min(255, Double(original[(sy * W + sx) * 4 + c]) * gain[c])
                let v = Float(d) * p + Float(pixels[(y * W + x) * 4 + c]) * (1 - p)
                pixels[(y * W + x) * 4 + c] = UInt8(max(0, min(255, v)))
            }
        }
    }
    }
}

// MARK: - Canvas tooth
//
// The painting's surface is visible at full resolution, and a patch of
// perfectly clean pixels in the middle of a textured painting is the thing
// that gives a retouch away. Strongest where the paste is weakest, because
// that is where the original grain was lost.

for y in holeY..<(holeY + holeH) {
    for x in holeX..<(holeX + holeW) {
        guard x >= 0, y >= 0, x < W, y < H else { continue }
        let m = mask[y * W + x]
        guard m > 0 else { continue }
        for c in 0..<3 {
            let grain = Float(rng.unit() - 0.5) * (1 - m) * 8
            let v = Float(pixels[(y * W + x) * 4 + c]) + grain
            pixels[(y * W + x) * 4 + c] = UInt8(max(0, min(255, v)))
        }
    }
}

// MARK: - Write

guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let outImage = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                             provider: provider, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.jpeg.identifier as CFString, 1, nil)
else { fatalError("cannot write \(outPath)") }
CGImageDestinationAddImage(dest, outImage,
                           [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("inpainted \(holeW)×\(holeH) at (\(holeX),\(holeY))"
      + (donor.map { ", donor (\($0.0),\($0.1))" } ?? "")
      + " -> \(outPath)")
