import SwiftUI
import PromptCore

struct VoiceTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsTab {
            Picker("Mode", selection: $settings.settings.guidance) {
                Text("Word Tracking").tag(CueSettings.GuidanceMode.wordTracking)
                Text("Classic").tag(CueSettings.GuidanceMode.classic)
                Text("Voice-Activated").tag(CueSettings.GuidanceMode.voiceActivated)
            }
            .pickerStyle(.segmented)
            Text(guidanceBlurb).font(.caption).foregroundStyle(.secondary)
            Picker("Speech language", selection: $settings.settings.speechLanguage) {
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("German").tag("de-DE")
                Text("French").tag("fr-FR")
                Text("Italian").tag("it-IT")
                Text("Spanish").tag("es-ES")
            }
            Text("System Default input. The first run asks for Microphone access (plus Speech Recognition on the legacy path); the live level meter then appears in the prompter header.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Engine", selection: $settings.settings.transcriptionEngine) {
                Text("Automatic").tag(CueSettings.TranscriptionEngine.automatic)
                Text("On-device").tag(CueSettings.TranscriptionEngine.onDevice)
                Text("Legacy").tag(CueSettings.TranscriptionEngine.legacy)
            }
            .pickerStyle(.segmented)
            Text("Automatic uses the fully offline on-device model on macOS 26+, falling back to legacy recognition otherwise. Legacy may send audio to Apple.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var guidanceBlurb: String {
        switch settings.settings.guidance {
        case .wordTracking:
            return "Highlights each word as you say it. Needs mic + speech recognition."
        case .classic:
            return "Constant-speed scroll. No mic needed — manual-first and reliable."
        case .voiceActivated:
            return "Scrolls while you speak, pauses in silence. Needs mic."
        }
    }
}
