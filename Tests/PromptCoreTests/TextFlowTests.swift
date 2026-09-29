import Testing
import CoreGraphics
@testable import PromptCore

/// `FlowLayout` renders a page of ~300 pills on every word change, and a
/// highlighted word is taller than its neighbours. The bug this locks down:
/// one height for the whole block, which overlapped lines and
/// under-reported the paragraph.
@Suite struct TextFlowTests {
    @Test func eachLineKeepsItsOwnHeight() {
        let result = TextFlow.wrap(
            sizes: [CGSize(width: 50, height: 20), CGSize(width: 50, height: 20),
                    CGSize(width: 50, height: 34), CGSize(width: 50, height: 20)],
            width: 110, spacing: 10, lineSpacing: 14)
        #expect(result.lines.count == 2)
        #expect(result.lines[0].height == 20)
        #expect(result.lines[1].height == 34)
        #expect(result.height == 54)          // 20 + 34, not "last line only"
        // Line 2 starts below line 1 *plus* the gap — the tall word must not
        // lift the line it belongs to.
        #expect(result.y(for: 2, lineSpacing: 14) == 34)
        #expect(result.y(for: 3, lineSpacing: 14) == 34)
        #expect(result.y(for: 0, lineSpacing: 14) == 0)
    }

    @Test func positionsAreDerivedFromTheSameLines() {
        let sizes = [CGSize(width: 40, height: 18), CGSize(width: 40, height: 18),
                     CGSize(width: 40, height: 18), CGSize(width: 40, height: 18)]
        let result = TextFlow.wrap(sizes: sizes, width: 90, spacing: 10, lineSpacing: 12)
        #expect(result.lines.map(\.range) == [0..<2, 2..<4])
        #expect(result.x(for: 0, spacing: 10) == 0)
        #expect(result.x(for: 1, spacing: 10) == 50)
        #expect(result.x(for: 2, spacing: 10) == 0)
        #expect(result.y(for: 2, lineSpacing: 12) == 30)
    }

    /// Differential against the naive implementation, which is the shape
    /// the layout had before it was optimised.
    @Test func matchesTheNaiveLayout() {
        /// The shape the layout had before the cache, written out straight.
        func naive(sizes: [CGSize], width: Double, spacing: Double,
                   lineSpacing: Double) -> (breaks: [Range<Int>], y: [Double], height: Double) {
            var breaks: [Range<Int>] = []
            var y: [Double] = []
            var lineHeight = 0.0
            var x = 0.0
            var start = 0
            var lineTop = 0.0
            for i in sizes.indices {
                let size = sizes[i]
                if x > 0, x + size.width > width {
                    breaks.append(start..<i)
                    lineTop += lineHeight + lineSpacing
                    start = i
                    x = 0
                    lineHeight = 0
                }
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
                y.append(lineTop)
            }
            breaks.append(start..<sizes.count)
            return (breaks, y, lineTop + lineHeight)
        }

        var seed: UInt64 = 0xC0FFEE
        func next(_ upper: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(upper))
        }
        for _ in 0..<3_000 {
            let count = next(9)
            let spacing = Double(next(20)) / 2
            let lineSpacing = Double(next(24)) / 2
            let width = Double(20 + next(180)) / 2
            // Mixed heights on purpose: that is the case the bug needed.
            let sizes = (0..<count).map { _ in
                CGSize(width: Double(8 + next(70)), height: Double(10 + next(40)))
            }
            let flow = TextFlow.wrap(sizes: sizes, width: width,
                                     spacing: spacing, lineSpacing: lineSpacing)
            let expected = naive(sizes: sizes, width: width,
                                 spacing: spacing, lineSpacing: lineSpacing)
            if !sizes.isEmpty {
                #expect(flow.lines.map(\.range) == expected.breaks)
            }
            for i in sizes.indices {
                #expect(flow.y(for: i, lineSpacing: lineSpacing) == expected.y[i],
                        "y for \(i): \(sizes.map(\.width)) w=\(width)")
            }
            // `height` is the sum of the lines; the layout adds the gaps on
            // top, which is exactly what the naive version accumulated.
            let gaps = Double(max(0, flow.lines.count - 1)) * lineSpacing
            #expect(abs(flow.height + gaps - expected.height) < 0.0001,
                    "height: \(sizes.map(\.height)) w=\(width)")
        }
    }

    @Test func noLinesWithoutSubviews() {
        let empty = TextFlow.wrap(sizes: [], width: 300, spacing: 8, lineSpacing: 12)
        #expect(empty.lines.isEmpty)
        #expect(empty.height == 0)
    }

    @Test func aZeroWidthPutsOnePerLine() {
        let result = TextFlow.wrap(sizes: [CGSize(width: 10, height: 10),
                                           CGSize(width: 10, height: 10)],
                                   width: 0, spacing: 4, lineSpacing: 4)
        #expect(result.lines.map(\.range) == [0..<1, 1..<2])
    }
}
