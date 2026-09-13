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
}

#Preview("Prompter") {
    @Previewable @State var engine = PreviewHelper.engine(with: SampleTexts.welcome)
    @Previewable @State var settings = SettingsStore(inMemory: CueSettings())
    @Previewable @State var voice = VoiceTracker()
    @Previewable @State var follow = true
    return PrompterBody(engine: engine, tokens: PreviewHelper.tokens, settings: settings,
                        voice: voice, follow: $follow)
        .frame(width: 700, height: 500)
}

#Preview("Settings") {
    @Previewable @State var settings = SettingsStore(inMemory: CueSettings())
    return SettingsView(settings: settings)
        .frame(width: 560, height: 540)
}
