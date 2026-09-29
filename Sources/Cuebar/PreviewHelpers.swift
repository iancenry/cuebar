import SwiftUI
import PromptCore

/// Preview helpers. Open Package.swift in Xcode and press the canvas
/// Play button — the closest Swift gets to web-style HMR.

@MainActor
enum PreviewHelper {
    static func engine(with text: String, at fraction: Double = 0.4) -> PromptEngine {
        let e = PromptEngine()
        e.loadScript(text)
        e.confirmRead(upTo: Int(Double(e.totalCharCount) * fraction), allowBacktrack: true)
        return e
    }

    static var tokens: [ScriptToken] { ScriptParser.parse(SampleTexts.welcome) }
    static var index: ScriptIndex { ScriptIndex(tokens: tokens) }

    static func hotkeys(for settings: SettingsStore) -> HotkeyCenter {
        HotkeyCenter(settings: settings)
    }

    static func globalHotkeys(for settings: SettingsStore) -> GlobalHotkeys {
        GlobalHotkeys(settings: settings)
    }

    /// A disarmed remote, so the preview shows the "nothing to connect to
    /// yet" state rather than a live server in the preview canvas.
    @MainActor static let remote = RemoteController()
}

#Preview("Prompter") {
    @Previewable @State var engine = PreviewHelper.engine(with: SampleTexts.welcome)
    @Previewable @State var settings = SettingsStore(inMemory: CueSettings())
    @Previewable @State var voice = VoiceTracker()
    @Previewable @State var follow = true
    return PrompterBody(engine: engine, index: PreviewHelper.index,
                        settings: settings, voice: voice, follow: $follow)
        .frame(width: 700, height: 500)
}

#Preview("Settings") {
    @Previewable @State var settings = SettingsStore(inMemory: CueSettings())
    let center = PreviewHelper.hotkeys(for: settings)
    return SettingsView(settings: settings, hotkeys: center,
                        globalHotkeys: PreviewHelper.globalHotkeys(for: settings),
                        remote: PreviewHelper.remote)
        .frame(width: 560, height: 540)
}
