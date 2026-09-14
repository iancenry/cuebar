import SwiftUI
import PromptCore
#if os(macOS)
import AppKit
#endif

/// Hold-→ to catch up: while the right-arrow key is held (no modifiers)
/// in Perform mode, the engine runs at the configured catch-up boost;
/// releasing eases back through the velocity filter.
///
/// The scroll-wheel twin lives in PrompterBody (wheel releases Follow);
/// the pointer twin is HoldBoostButton in the transport bar.
struct BoostKeys: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore
    @Binding var mode: PerformMode

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
#if os(macOS)
            .onAppear { install() }
            .onDisappear { remove() }
            .onChange(of: mode) { _, new in
                if new != .perform { engine.setBoost(1.0) }
            }
#else
#endif
    }

#if os(macOS)
    @State private var monitors: [Any] = []

    private func install() {
        remove()
        // Local monitors run on the main thread; the engine hop is only
        // for MainActor isolation. Mode is read synchronously so Edit-mode
        // arrow keys (text cursor) always pass through untouched.
        let modeBinding = $mode
        let down = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [engine, settings] event in
            guard event.keyCode == 124 else { return event }
            guard modeBinding.wrappedValue == .perform else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control])
            guard flags.isEmpty else { return event }
            Task { @MainActor in
                engine.setBoost(settings.settings.clampedCatchUpBoost)
            }
            return nil
        }
        let up = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [engine] event in
            guard event.keyCode == 124 else { return event }
            Task { @MainActor in
                engine.setBoost(1.0)
            }
            return event
        }
        monitors = [down, up].compactMap { $0 }
    }

    private func remove() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        engine.setBoost(1.0)
    }
#endif
}
