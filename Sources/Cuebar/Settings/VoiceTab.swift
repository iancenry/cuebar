import SwiftUI
import PromptCore

struct VoiceTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsTab {
            SettingsSection(title: "Follow mode") {
                SettingRow(label: "Mode") {
                    Picker("Mode", selection: $settings.settings.guidance) {
                        ForEach(CueSettings.GuidanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                SettingsCaption(text: guidanceBlurb)
            }
            SettingsSection(title: "Speech") {
                SettingRow(label: "Language") {
                    Picker("Speech language", selection: $settings.settings.speechLanguage) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("German").tag("de-DE")
                        Text("French").tag("fr-FR")
                        Text("Italian").tag("it-IT")
                        Text("Spanish").tag("es-ES")
                    }
                }
                SettingsCaption(text: "The first run asks for Microphone access (plus Speech Recognition on the legacy path). The level meter then lives in the prompter header.")
            }
            SettingsSection(title: "Engine") {
                SettingRow(label: "Engine") {
                    Picker("Engine", selection: $settings.settings.transcriptionEngine) {
                        Text("Automatic").tag(CueSettings.TranscriptionEngine.automatic)
                        Text("On-device").tag(CueSettings.TranscriptionEngine.onDevice)
                        Text("Legacy").tag(CueSettings.TranscriptionEngine.legacy)
                    }
                    .pickerStyle(.segmented)
                }
                SettingsCaption(text: "Automatic uses the fully offline on-device model on macOS 26+, falling back to legacy recognition otherwise. Legacy may send audio to Apple.")
            }
        }
    }

    private var guidanceBlurb: String {
        switch settings.settings.guidance {
        case .classic:
            return "Constant-speed scroll. No mic needed — manual-first and reliable."
        case .auto:
            return "Scroll at your configured WPM. No mic needed — great when you know your pace."
        case .voiceActivated:
            return "Scrolls while you speak, pauses in silence. Follows your speed but not your words."
        case .wordTracking:
            return "Follows what you're actually saying — tolerates skipped words, repeats, and fillers. Holds still when you go quiet; scrolls at WPM until the mic hears you."
        }
    }
}
