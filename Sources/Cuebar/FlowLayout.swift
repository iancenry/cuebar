import SwiftUI
import PromptCore

/// Wrapping paragraph layout: flowing prompter text where every word
/// stays individually tappable. O(rows) layout, no lazy loading — pair
/// with pagination (see ScriptIndex) to bound the view count.
///
/// The arithmetic lives in `TextFlow` (PromptCore, fuzzed in tests) and the
/// measurements are cached per width: a page is ~300 pills and the prompter
/// re-lays-out on every word change, so measuring each pill twice per pass
/// was the layout cost. SwiftUI wipes the cache at the start of every pass,
/// so a cache can only ever be reused between `sizeThatFits` and
/// `placeSubviews` — within one pass, with the same subviews.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 12

    struct Cache {
        var width: CGFloat = -1
        var flow: TextFlow.Result?

        var isValid: Bool { flow != nil }
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 0
        let flow = measure(width: width, subviews: subviews, cache: &cache)
        let gaps = max(0, CGFloat(flow.lines.count - 1)) * lineSpacing
        return CGSize(width: width, height: CGFloat(flow.height) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout Cache) {
        guard cache.width == bounds.width, cache.isValid, let flow = cache.flow else {
            measure(width: bounds.width, subviews: subviews, cache: &cache)
            return placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
        }
        for i in subviews.indices {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + CGFloat(flow.x(for: i, spacing: spacing)),
                            y: bounds.minY + CGFloat(flow.y(for: i, lineSpacing: lineSpacing))),
                proposal: .unspecified)
        }
    }

    @discardableResult
    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) -> TextFlow.Result {
        if cache.width == width, let flow = cache.flow, flow.sizes.count == subviews.count {
            return flow
        }
        var sizes: [CGSize] = []
        sizes.reserveCapacity(subviews.count)
        for view in subviews { sizes.append(view.sizeThatFits(.unspecified)) }
        let flow = TextFlow.wrap(sizes: sizes, width: width,
                                 spacing: spacing, lineSpacing: lineSpacing)
        cache = Cache(width: width, flow: flow)
        return flow
    }
}
