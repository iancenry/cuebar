import CoreGraphics
import Foundation

/// Wrapping layout arithmetic, kept pure so it can be fuzzed without
/// SwiftUI. The prompter re-lays-out on every word change, and a
/// highlighted word is taller than its neighbours — so line heights are
/// per line, never one value for the block (that mistake overlapped lines
/// and under-reported the paragraph).
public enum TextFlow: Sendable {
    public struct Line: Equatable, Sendable {
        /// Subview indices on this line.
        public let range: Range<Int>
        public let height: Double
    }

    public struct Result: Equatable, Sendable {
        public let sizes: [CGSize]
        public let lines: [Line]

        public func x(for index: Int, spacing: Double) -> Double {
            let line = lines.first { $0.range.contains(index) }?.range.lowerBound ?? 0
            var x = 0.0
            for i in line..<index { x += sizes[i].width + spacing }
            return x
        }

        public func y(for index: Int, lineSpacing: Double) -> Double {
            var y = 0.0
            for line in lines {
                if line.range.contains(index) { return y }
                y += line.height + lineSpacing
            }
            return y
        }

        /// Total height: every line's own height plus the gaps between them.
        public var height: Double {
            guard !lines.isEmpty else { return 0 }
            return lines.reduce(0) { $0 + $1.height }
        }
    }

    /// One box per subview, wrapped into lines of `width`.
    public static func wrap(sizes: [CGSize], width: Double,
                            spacing: Double, lineSpacing: Double) -> Result {
        guard !sizes.isEmpty else { return Result(sizes: [], lines: []) }
        var lines: [Line] = []
        var start = 0
        var x = 0.0
        var lineHeight = 0.0
        for i in sizes.indices {
            let size = sizes[i]
            if x > 0, x + size.width > width {
                lines.append(Line(range: start..<i, height: lineHeight))
                start = i
                x = 0
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        lines.append(Line(range: start..<sizes.count, height: lineHeight))
        return Result(sizes: sizes, lines: lines)
    }
}
