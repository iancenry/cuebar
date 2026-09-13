import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
#endif

/// Always-on-top overlay: one controller for notch / floating /
/// fullscreen. Placement math lives in ReadingWindow (tested);
/// this only translates screens and hosts the shared PrompterBody.
@MainActor
@Observable
final class OverlayController {
#if os(macOS)
    private var panel: NSPanel?
    private var hosting: NSHostingView<OverlayPanelView>?
    private var engine: PromptEngine?
    private var store: SettingsStore?
    private var voice: VoiceTracker?
    private var snapshot = CueSettings()
    private var islandMenuBar: Double = 28
    private var defaultSharing: NSWindow.SharingType = .readOnly
    private var closeObserver: (any NSObjectProtocol)?
    private weak var mainWindow: NSWindow?
    private var didHideMain = false
    /// Overlay follow state lives here — not in the view — so script
    /// edits (which rebuild rootView) can't silently re-enable it.
    var overlayFollow = true
    /// Notch island max width: beyond this it stops reading as hardware.
    private static let islandMaxWidth = 640.0
    var isShowing = false

    func toggle(engine: PromptEngine, settings: SettingsStore, tokens: [ScriptToken], voice: VoiceTracker) {
        isShowing ? hide() : show(engine: engine, settings: settings, tokens: tokens, voice: voice)
    }

    func show(engine: PromptEngine, settings: SettingsStore, tokens: [ScriptToken], voice: VoiceTracker) {
        // Rebuild path (e.g. overlay-mode switch): drop the panel but
        // leave a hidden main window hidden — no restore flicker.
        closePanel()
        self.engine = engine
        self.store = settings
        self.voice = voice
        self.snapshot = settings.settings
        let chrome = snapshot
        let island = chrome.overlayMode == .notch
        let screen = DisplayInfo.screen(index: chrome.fixedDisplayIndex, target: chrome.displayTarget)
        islandMenuBar = DisplayInfo.menuBarHeight(screen)
        // The island is narrower than a free window: it must read as
        // hardware, not as a window.
        let w = island ? min(max(chrome.overlayWidth, 300), Self.islandMaxWidth)
                       : min(max(chrome.overlayWidth, 280), 1200)
        let h = island ? min(max(chrome.overlayHeight, 200), 700)
                       : min(max(chrome.overlayHeight, 100), 900)
        let style: NSWindow.StyleMask = island
            ? [.borderless, .nonactivatingPanel]
            : [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView]
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: style, backing: .buffered, defer: false)
        // Above the menu bar so the island's top edge disappears into it.
        // Below it when the user opts out of always-on-top.
        p.level = island ? .popUpMenu : (chrome.alwaysOnTop ? .floating : .normal)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = !island
        p.hidesOnDeactivate = false
        p.hasShadow = snapshot.overlayMode != .fullscreen
        defaultSharing = p.sharingType
        if !island { p.title = "Cuebar" }
        if chrome.hideFromShare { p.sharingType = .none }
        p.backgroundColor = .clear
        p.isOpaque = false
        if chrome.transparencyEnabled {
            p.alphaValue = max(0.3, min(1.0, chrome.transparencyAmount))
        }
        let host = NSHostingView(rootView: OverlayPanelView(engine: engine, settings: settings, tokens: tokens,
                                                            voice: voice, follow: followBinding, island: island, menuBarHeight: islandMenuBar,
                                                            onClose: { [weak self] in self?.hide() }))
        p.contentView = host
        hosting = host
        place(p, mode: snapshot.overlayMode, screen: screen)
        if snapshot.overlayMode == .floating {
            restorePosition(into: p)
        }
        if chrome.hideMainWhilePresenting {
            mainWindow = NSApplication.shared.mainWindow
            mainWindow?.orderOut(nil)
            didHideMain = mainWindow != nil
        }
        p.orderFrontRegardless()
        p.makeKey()
        // The titled panel is closable: route the red X through hide()
        // so isShowing, main-window restore, and guard state stay true.
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel != nil, self.isShowing else { return }
                self.hide()
            }
        }
        panel = p
        isShowing = true
    }

    /// Live-refresh script text while the overlay stays open.
    func update(tokens: [ScriptToken]) {
        guard let engine, let store, let voice, isShowing else { return }
        let island = store.settings.overlayMode == .notch
        hosting?.rootView = OverlayPanelView(engine: engine, settings: store, tokens: tokens,
                                             voice: voice, follow: followBinding, island: island, menuBarHeight: islandMenuBar,
                                             onClose: { [weak self] in self?.hide() })
    }

    private var followBinding: Binding<Bool> {
        Binding(get: { self.overlayFollow }, set: { self.overlayFollow = $0 })
    }

    /// Live-apply chrome (transparency, sharing, size) to the open
    /// panel without rebuilding it. Sliders in Settings now work
    /// while the overlay is on screen.
    func applyChrome() {
        guard let panel, let store, isShowing else { return }
        snapshot = store.settings
        let chrome = snapshot
        panel.sharingType = chrome.hideFromShare ? .none : defaultSharing
        panel.alphaValue = chrome.transparencyEnabled
            ? max(0.3, min(1.0, chrome.transparencyAmount)) : 1.0
        panel.level = chrome.overlayMode == .notch ? .popUpMenu : (chrome.alwaysOnTop ? .floating : .normal)
        let island = chrome.overlayMode == .notch
        let w = island ? min(max(chrome.overlayWidth, 300), Self.islandMaxWidth)
                       : min(max(chrome.overlayWidth, 280), 1200)
        let h = island ? min(max(chrome.overlayHeight, 200), 700)
                       : min(max(chrome.overlayHeight, 100), 900)
        let screen = DisplayInfo.screen(index: chrome.fixedDisplayIndex, target: chrome.displayTarget)
        switch chrome.overlayMode {
        case .notch:
            // Grow/shrink around the top-center anchor: expansion is
            // always symmetric, never one-sided.
            if let screen {
                let o = ReadingWindow.notchIslandOrigin(screen: DisplayInfo.rect(screen.frame),
                                                        panelWidth: w, panelHeight: h)
                panel.setFrame(NSRect(x: o.x, y: o.y, width: w, height: h), display: true)
            }
        case .floating:
            // Resize around the panel's own center; it stays where it is.
            let cx = panel.frame.midX, cy = panel.frame.midY
            panel.setFrame(NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), display: true)
        case .fullscreen:
            if let screen { panel.setFrame(screen.frame, display: true) }
        }
    }

    func hide() {
        // Remember floating geometry so the panel reopens where the
        // user left it. Anchored modes recompute on show.
        if snapshot.overlayMode == .floating, let frame = panel?.frame {
            snapshot.floatingOriginX = Double(frame.origin.x)
            snapshot.floatingOriginY = Double(frame.origin.y)
            snapshot.overlayWidth = Double(frame.size.width)
            snapshot.overlayHeight = Double(frame.size.height)
            store?.settings = snapshot
        }
        closePanel()
        if didHideMain {
            mainWindow?.makeKeyAndOrderFront(nil)
            didHideMain = false
        }
        mainWindow = nil
    }

    /// Release the panel without touching the main window.
    private func closePanel() {
        // Detach first: close() posts willClose synchronously, and the
        // observer below must see a nil panel to avoid re-entering.
        let closing = panel
        panel = nil
        hosting = nil
        engine = nil
        store = nil
        voice = nil
        isShowing = false
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        closing?.close()
    }

    /// Re-seat a floating panel where the user left it ("remember
    /// position"). Anchored modes always recompute.
    private func restorePosition(into panel: NSPanel) {
        guard let x = snapshot.floatingOriginX, let y = snapshot.floatingOriginY else { return }
        let point = NSPoint(x: x, y: y)
        let onScreen = NSScreen.screens.contains { NSPointInRect(point, $0.frame) }
        guard onScreen else { return }
        panel.setFrameOrigin(point)
    }

    private func place(_ panel: NSPanel, mode: CueSettings.OverlayMode, screen: NSScreen?) {
        guard let screen else {
            panel.center()
            return
        }
        let size = panel.frame.size
        switch mode {
        case .notch:
            let o = ReadingWindow.notchIslandOrigin(screen: DisplayInfo.rect(screen.frame),
                                                    panelWidth: Double(size.width),
                                                    panelHeight: Double(size.height))
            panel.setFrameOrigin(NSPoint(x: o.x, y: o.y))
        case .floating:
            let o = ReadingWindow.floatingOrigin(visible: DisplayInfo.rect(screen.visibleFrame),
                                                 panelWidth: Double(size.width),
                                                 panelHeight: Double(size.height))
            panel.setFrameOrigin(NSPoint(x: o.x, y: o.y))
        case .fullscreen:
            panel.setFrame(screen.frame, display: true)
        }
    }
#else
    var isShowing = false
    func toggle(engine: PromptEngine, settings: SettingsStore, tokens: [ScriptToken], voice: VoiceTracker) {}
    func show(engine: PromptEngine, settings: SettingsStore, tokens: [ScriptToken], voice: VoiceTracker) {}
    func update(tokens: [ScriptToken]) {}
    func hide() {}
#endif
}

#if os(macOS)
/// AppKit screen queries, kept out of views and out of PromptCore.
enum DisplayInfo {
    static func names() -> [String] {
        let screens = NSScreen.screens
        return screens.enumerated().map { i, s in
            s.localizedName.isEmpty ? "Display \(i + 1)" : s.localizedName
        }
    }

    static func screen(index: Int, target: CueSettings.DisplayTarget) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        switch target {
        case .followMouse:
            let mouse = NSEvent.mouseLocation
            return screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? screens[0]
        case .fixed:
            return screens[ReadingWindow.clampedDisplayIndex(index, screenCount: screens.count)]
        }
    }

    static func rect(_ r: NSRect) -> ReadingWindow.Rect {
        ReadingWindow.Rect(x: Double(r.origin.x), y: Double(r.origin.y),
                           width: Double(r.size.width), height: Double(r.size.height))
    }

    static func menuBarHeight(_ screen: NSScreen?) -> Double {
        guard let s = screen else { return 28 }
        return ReadingWindow.menuBarHeight(screenHeight: Double(s.frame.height),
                                           visibleHeight: Double(s.visibleFrame.height))
    }
}
#endif
