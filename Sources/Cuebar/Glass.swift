import SwiftUI

/// Liquid Glass (macOS 26+) with a card-material fallback for older
/// systems. One home so every glass surface stays consistent.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
        } else {
            background(tint ?? CuePalette.card, in: shape)
        }
    }
}

@available(macOS 26, *)
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return content.glassEffect(glass, in: shape)
    }
}
