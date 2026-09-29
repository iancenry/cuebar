import SwiftUI
import PromptCore

struct TypographyTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsTab {
            SettingsSection(title: "Preview") {
                ReadingPreview(settings: settings.settings)
                SettingsCaption(text: "Live preview — reflects every tab.")
            }
            SettingsSection(title: "Font") {
                SettingRow(label: "Family") {
                    Picker("Family", selection: $settings.settings.fontFamily) {
                        Text("Sans").tag(CueSettings.FontFamily.sans)
                        Text("Serif").tag(CueSettings.FontFamily.serif)
                        Text("Mono").tag(CueSettings.FontFamily.mono)
                        Text("Dyslexia").tag(CueSettings.FontFamily.dyslexia)
                    }
                    .pickerStyle(.segmented)
                }
                #if os(macOS)
                if settings.settings.fontFamily == .dyslexia {
                    SettingsCaption(text: FontLoader.dyslexiaAvailable
                        ? "Using bundled OpenDyslexic (SIL-OFL)."
                        : "OpenDyslexic not loaded — using rounded fallback.")
                }
                #endif
                SettingRow(label: "Size") {
                    Picker("Size", selection: $settings.settings.textSize) {
                        ForEach(CueSettings.TextSize.allCases, id: \.self) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                SettingRow(label: "Weight") {
                    Picker("Weight", selection: $settings.settings.fontWeight) {
                        Text("Regular").tag(CueSettings.FontWeight.regular)
                        Text("Medium").tag(CueSettings.FontWeight.medium)
                        Text("Semibold").tag(CueSettings.FontWeight.semibold)
                        Text("Bold").tag(CueSettings.FontWeight.bold)
                    }
                    .pickerStyle(.segmented)
                }
                LabeledSlider(title: "Prompter scale",
                              display: String(format: "%.1f×", settings.settings.prompterScale),
                              value: $settings.settings.prompterScale,
                              range: 1.0...2.5, step: 0.1)
            }
            SettingsSection(title: "Color") {
                SettingRow(label: "Text") {
                    Picker("Text", selection: $settings.settings.textColor) {
                        Text("Paper").tag(CueSettings.TextColor.paper)
                        Text("White").tag(CueSettings.TextColor.white)
                        Text("Stone").tag(CueSettings.TextColor.stone)
                    }
                    .pickerStyle(.segmented)
                }
                SettingRow(label: "Background") {
                    Picker("Background", selection: $settings.settings.surfaceStyle) {
                        Text("Graphite").tag(CueSettings.SurfaceStyle.espresso)
                        Text("Black").tag(CueSettings.SurfaceStyle.black)
                        Text("Slate").tag(CueSettings.SurfaceStyle.slate)
                    }
                    .pickerStyle(.segmented)
                }
                SettingsCaption(text: "The notch island always stays black to melt into the menu bar.")
            }
            SettingsSection(title: "Spacing") {
                LabeledSlider(title: "Line spacing",
                              display: String(format: "%.2f", settings.settings.lineSpacing),
                              value: $settings.settings.lineSpacing,
                              range: 0.3...0.8, step: 0.05)
                LabeledSlider(title: "Paragraph spacing",
                              display: String(format: "%.2f", settings.settings.paragraphSpacing),
                              value: $settings.settings.paragraphSpacing,
                              range: 0...1.5, step: 0.05)
                LabeledSlider(title: "Letter spacing",
                              display: String(format: "%.1f", settings.settings.letterSpacing),
                              value: $settings.settings.letterSpacing,
                              range: 0...1.5, step: 0.1)
                SettingsCaption(text: "Paragraph gap applies between blank-line separated blocks.")
                SettingRow(label: "Reading width") {
                    Picker("Reading width", selection: $settings.settings.readingWidth) {
                        Text("Full").tag(nil as Double?)
                        Text("500").tag(500 as Double?)
                        Text("650").tag(650 as Double?)
                        Text("800").tag(800 as Double?)
                    }
                    .pickerStyle(.segmented)
                }
                SettingRow(label: "Alignment") {
                    Picker("Alignment", selection: $settings.settings.textAlignment) {
                        Text("Left").tag(CueSettings.TextAlignment.leading)
                        Text("Center").tag(CueSettings.TextAlignment.center)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}
