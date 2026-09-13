import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
#endif

/// Whole-app screen-sharing invisibility.
///
/// `NSWindow.sharingType = .none` is Apple's documented mechanism for
/// this: the window is excluded from ScreenCaptureKit / screencapture /
/// screen-sharing frames. Textream uses it for its overlay only; Cuebar
/// applies it to *every* window (main, overlay, settings) so the app
/// can stay open during a call without leaking.
///
/// The guard captures each window's original sharing type on first
/// contact and restores it when disabled, so it never corrupts state.
/// New windows are caught redundantly on purpose: KVO on
/// `NSApplication.windows` is the primary signal, but it is known to
/// miss additions, so key/main/activation notifications back it up.
/// (That miss is exactly the "on by default but not working until
/// re-toggled" failure mode: the manual toggle runs applyToAll
/// directly, which always works.)
///
/// Not covered: the Dock icon, menu-bar presence, and capturers that
/// bypass the public APIs. Tested logic is nil here by necessity —
/// windows need a window server, so this is verified by build +
/// the manual self-test in TeleprompterTab, not unit tests.
@MainActor
final class SharingGuard {
    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private var saved: [ObjectIdentifier: (window: WeakWindow, original: NSWindow.SharingType)] = [:]
    private var observation: NSKeyValueObservation?
    private var keyObserver: (any NSObjectProtocol)?
    private var mainObserver: (any NSObjectProtocol)?
    private var activeObserver: (any NSObjectProtocol)?

    func setHidden(_ hidden: Bool) {
#if os(macOS)
        if hidden {
            startObserving()
            applyToAll()
        } else {
            stopObserving()
            restoreAll()
        }
#else
        _ = hidden
#endif
    }

    private func applyToAll() {
#if os(macOS)
        prune()
        for window in NSApplication.shared.windows {
            let id = ObjectIdentifier(window)
            if saved[id] == nil {
                saved[id] = (WeakWindow(window), window.sharingType)
            }
            window.sharingType = .none
        }
#endif
    }

    private func restoreAll() {
#if os(macOS)
        for entry in saved.values {
            entry.window.window?.sharingType = entry.original
        }
        saved.removeAll()
#endif
    }

    private func prune() {
#if os(macOS)
        saved = saved.filter { $0.value.window.window != nil }
#endif
    }

    private func startObserving() {
#if os(macOS)
        guard observation == nil else { return }
        observation = NSApplication.shared.observe(\.windows, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.applyToAll() }
        }
        let center = NotificationCenter.default
        let hop: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyToAll() }
        }
        keyObserver = center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                         object: nil, queue: .main, using: hop)
        mainObserver = center.addObserver(forName: NSWindow.didBecomeMainNotification,
                                          object: nil, queue: .main, using: hop)
        activeObserver = center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main, using: hop)
#endif
    }

    private func stopObserving() {
#if os(macOS)
        observation?.invalidate()
        observation = nil
        for observer in [keyObserver, mainObserver, activeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        keyObserver = nil
        mainObserver = nil
        activeObserver = nil
#endif
    }
}
