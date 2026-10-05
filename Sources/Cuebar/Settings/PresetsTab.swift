import SwiftUI
import PromptCore

/// Presets, on their own page.
///
/// They were bolted to the top of Reading, which is the wrong place: a preset
/// changes the reading *and* the display and the voice, and "which of these do
/// I want for tonight?" is the first question a presenter has.
struct PresetsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPage(title: "Presets",
                     subtitle: "A starting point for the kind of talk you're giving. "
                        + "Change anything afterwards — a preset only sets what it lists.") {
            PresetRow(settings: settings)
            SettingsCard(title: "Preview") {
                ReadingPreview(settings: settings.settings)
                SettingsCaption(text: "Applies the moment you click one, and shows every "
                    + "change straight away.")
            }
        }
    }
}
