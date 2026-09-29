import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Whether the window owns the whole screen.
///
/// Fullscreen is the one case where "centre of the column" and "centre of
/// the screen" are the same thing, and it is the case the transport dock
/// has to agree with: a notched Mac's centre line is a physical landmark,
/// so a play button half a sidebar off it reads as a bug, not a layout.
/// AppKit's fullscreen notifications are the obvious source, but the block
/// API hands them to a nonisolated closure and jumping back to the main
/// actor from one is the same trap as the ticker. Layout is a better
/// signal anyway — it is main-actor, it fires on the resize that *causes*
/// fullscreen, and it also catches a window resized onto a notch display.
@Observable
@MainActor
final class WindowState {
    var isFullscreen = false
}

/// Reports its window's fullscreen state on every layout pass.
@MainActor
final class WindowWatcher: NSView {
    var onLayout: ((NSWindow) -> Void)?

    override func layout() {
        super.layout()
        if let window { onLayout?(window) }
    }
}

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
    var state: WindowState

    func makeNSView(context: Context) -> NSView {
        let view = WindowWatcher(frame: .zero)
        view.onLayout = { window in
            state.isFullscreen = window.styleMask.contains(.fullScreen)
        }
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        // Belt and braces: the watcher owns the flag, but a re-render also
        // catches it, so a missed layout pass can't leave the dock stranded
        // on the column's centre.
        state.isFullscreen = window.styleMask.contains(.fullScreen)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The sidebar's traffic lights sit over our own chrome, so they must
        // not paint a strip of their own.
        window.isMovableByWindowBackground = false
    }
}
