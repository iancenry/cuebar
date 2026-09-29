import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import os
#endif

/// Session-level key tap, so Cuebar's commands work while another app is in
/// front — the actual presenting case (overlay over Keynote, Zoom, a PDF).
///
/// The local `NSEvent` monitor cannot do this: it only sees events macOS
/// routes to *this* app, so the moment the presenter clicks into their deck
/// the prompter goes deaf. A `CGEvent` tap sees the whole session, but it
/// also means a privacy-relevant permission (Accessibility) and the power to
/// swallow other apps' keys — hence: **off by default, only while the
/// prompter overlay is up, and the same decision function the local monitor
/// uses** so the two can never both fire.
@MainActor
@Observable
final class GlobalHotkeys {
    enum Status: Equatable {
        case off
        case needsPermission
        case active
        case denied
        /// macOS refused to create the tap at all. The usual reason is that
        /// this build is sandboxed: a sandboxed app cannot install a
        /// session-level key tap whatever the user grants.
        case unavailable(String)

        var label: String {
            switch self {
            case .off: return "Off"
            case .needsPermission: return "Waiting for permission"
            case .active: return "Active while the prompter is up"
            case .denied: return "Blocked in System Settings"
            case .unavailable(let why): return why
            }
        }

        var needsPermissionHelp: Bool {
            self == .needsPermission || self == .denied
        }
    }

    private(set) var status: Status = .off
    /// The presenter opts in here; the tap still only runs while presenting.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            settings?.settings.globalHotkeys = isEnabled
            #if os(macOS)
            if isEnabled {
                // Ask once, at the moment the user says yes — a silent
                // failure here would look like a broken feature.
                // The prompt key is spelled out rather than read from the
                // C global: it is documented as this exact string, and
                // referencing the global is a concurrency error.
                let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
                _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            }
            #endif
            sync()
        }
    }

    #if os(macOS)
    /// Read by the tap callback, which runs on its own thread — so both
    /// facts it needs are locks, not actor state.
    private nonisolated let isFrontmost = OSAllocatedUnfairLock(initialState: true)
    private nonisolated let isPresenting = OSAllocatedUnfairLock(initialState: false)
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    private var sink: TapSink?
    private var workspaceObserver: NSObjectProtocol?
    #endif

    private weak var settings: SettingsStore?
    private weak var hotkeys: HotkeyCenter?
    private weak var overlay: OverlayController?

    /// Only settings is available at App-init time (the other collaborators
    /// are `@State` that don't exist yet), so the rest is attached from the
    /// view once they do.
    init(settings: SettingsStore) {
        self.settings = settings
        isEnabled = settings.settings.globalHotkeys
        #if os(macOS)
        // App-lifetime object, so the observer needs no teardown; it holds
        // `self` weakly anyway.
        // The tap runs before the local monitor, so the "Cuebar is
        // frontmost" flag has to be current. `NSWorkspace` is MainActor
        // state, so this reads it on a task — and `show()`/`hide()` also
        // write the flag synchronously, which covers the window that matters
        // (the panel opening while Cuebar comes forward).
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateFrontmost() }
        }
        updateFrontmost()
        sync()
        #endif
    }

    func attach(hotkeys: HotkeyCenter, overlay: OverlayController) {
        self.hotkeys = hotkeys
        self.overlay = overlay
        // Opening the panel brings Cuebar's own window forward, so record
        // that without waiting for the workspace notification.
        isFrontmost.withLock { $0 = true }
        // The panel knows when it opens and closes — including the paths
        // that run with the main window closed, which no view observes.
        // Called synchronously: a chord pressed between the panel opening
        // and the tap being installed would otherwise be lost.
        overlay.onPresentingChanged = { [weak self] presenting in
            if presenting { self?.presentingStarted() } else { self?.presentingEnded() }
            self?.sync()
        }
        #if os(macOS)
        sync()
        #endif
    }

    /// A rebind while presenting: the tap holds a snapshot of the map, so it
    /// has to be reinstalled or it keeps running the old command.
    func mapDidChange() {
        if tap != nil { stop() }
        sync()
    }

    /// The tap runs only while the prompter is up *and* the user asked for
    /// it. Any other time, another app's keys are its own business.
    #if !os(macOS)
    func sync() {}
    func mapDidChange() {}
    #else
    func sync() {
        let shouldRun = isEnabled && overlay?.isPresenting == true
        isPresenting.withLock { $0 = shouldRun }
        guard shouldRun else {
            stop()
            status = .off
            return
        }
        guard AXIsProcessTrusted() else {
            stop()
            status = .needsPermission
            return
        }
        guard tap == nil else { return }
        start()
    }

    private func start() {
        guard let hotkeys else { return }
        var context = HotkeyPolicy.Context()
        context.source = .global
        context.map = settings?.settings.shortcuts ?? .default
        // The presenting case: the panel is up, so Cuebar is "on stage"
        // even though the main window may be ordered out. Editing never
        // happens behind an overlay.
        context.hasWindow = true
        context.isEditing = false
        let box = TapSink(policyContext: context,
                          isFrontmost: isFrontmost,
                          isPresenting: isPresenting,
                          onTimeout: { [weak self] in
                              Task { @MainActor in self?.reEnableTap() }
                          },
                          perform: { [weak hotkeys] action in
                              Task { @MainActor in hotkeys?.perform(action) }
                          })
        sink = box
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<TapSink>.fromOpaque(refcon).takeUnretainedValue()
            return box.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(box).toOpaque())
        else {
            // Don't leave a refcon-carrying sink behind on a failed attempt.
            sink = nil
            status = .unavailable("macOS refused the key tap. It needs the "
                   + "Accessibility permission, and a sandboxed build cannot install one.")
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        status = .active
    }

    /// Recorded when the panel opens: `makeKey()` ran, so the local monitor
    /// is the hook that owns presses.
    func presentingStarted() {
        isFrontmost.withLock { $0 = true }
    }

    /// Recorded when the panel closes: Cuebar is no longer the frontmost
    /// app unless something else says so.
    func presentingEnded() {
        isFrontmost.withLock { $0 = false }
    }

    private func reEnableTap() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runSource, .commonModes) }
        tap = nil
        runSource = nil
        sink = nil
    }

    private func updateFrontmost() {
        let ours = Bundle.main.bundleIdentifier
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        isFrontmost.withLock { $0 = (ours != nil && ours == active) }
    }
    #endif

    func openPermissionSettings() {
        #if os(macOS)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url { NSWorkspace.shared.open(url) }
        #endif
    }
}

#if os(macOS)
/// The tap callback's world. `@unchecked Sendable`: everything inside is
/// either a value, an unfair lock, or a closure that hops to the main actor —
/// and it is touched from exactly one thread (the tap's run loop).
final class TapSink: @unchecked Sendable {
    private let policyContext: HotkeyPolicy.Context
    private let isFrontmost: OSAllocatedUnfairLock<Bool>
    private let isPresenting: OSAllocatedUnfairLock<Bool>
    private let perform: @Sendable (ShortcutAction) -> Void
    /// Re-enable the tap after macOS turns it off. Main-actor hop inside.
    private let onTimeout: (@Sendable () -> Void)?

    init(policyContext: HotkeyPolicy.Context,
         isFrontmost: OSAllocatedUnfairLock<Bool>,
         isPresenting: OSAllocatedUnfairLock<Bool>,
         onTimeout: (@Sendable () -> Void)? = nil,
         perform: @escaping @Sendable (ShortcutAction) -> Void) {
        self.policyContext = policyContext
        self.isFrontmost = isFrontmost
        self.isPresenting = isPresenting
        self.onTimeout = onTimeout
        self.perform = perform
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long; the work here is a few
        // microseconds, but the 60 Hz ticker can still push it over, and a
        // silently dead tap would look like a broken feature.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = onTimeout { tap() }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        // Cheap guards first: a tap callback is a hot path for the whole
        // session, so an event we will forward should cost almost nothing.
        guard isPresenting.withLock({ $0 }) else { return Unmanaged.passUnretained(event) }
        let flags = event.flags
        var context = policyContext
        context.isFrontmost = isFrontmost.withLock { $0 }
        let chord = KeyChord(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                             modifiers: KeyChord.Modifiers(flags))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch HotkeyPolicy.decide(chord, isRepeat: isRepeat, context: context) {
        case .consume(let action):
            perform(action)
            return nil            // swallow: the presenting app is Cuebar's
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

extension KeyChord.Modifiers {
    init(_ flags: CGEventFlags) {
        var out: KeyChord.Modifiers = []
        if flags.contains(.maskCommand) { out.insert(.command) }
        if flags.contains(.maskControl) { out.insert(.control) }
        if flags.contains(.maskAlternate) { out.insert(.option) }
        if flags.contains(.maskShift) { out.insert(.shift) }
        self = out
    }
}
#endif
