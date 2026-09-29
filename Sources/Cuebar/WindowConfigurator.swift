import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Hides the app's own title-bar furniture.
///
/// The title bar stays out of the way so the canvas and the sidebar reach
/// the window's top edge and the chrome can float on the reading surface.
/// It is deliberately *not* full-size content: the title-bar strip is
/// transparent, so it blends with whatever is behind it, and the chrome
/// gets its tightness from `ignoresSafeArea` in the layout instead — a
/// forced `fullSizeContentView` changes window semantics (and re-frames
/// the split view) for no visual gain.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The sidebar's traffic lights sit over our own chrome, so they must
        // not paint a strip of their own.
        window.isMovableByWindowBackground = false
        window.isMovableByWindowBackground = false
    }
}
