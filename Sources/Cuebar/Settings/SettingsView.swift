import SwiftUI
import PromptCore

/// Display first — it answers "where do I read?" before anything else.
struct SettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            DisplayTab(settings: settings)
                .tabItem { Label("Display", systemImage: "rectangle.on.rectangle") }
            TypographyTab(settings: settings)
                .tabItem { Label("Typography", systemImage: "textformat") }
            ReadingTab(settings: settings)
                .tabItem { Label("Reading", systemImage: "book") }
            VoiceTab(settings: settings)
                .tabItem { Label("Voice", systemImage: "waveform") }
        }
        .padding()
        .tint(CuePalette.peach)
    }
}
