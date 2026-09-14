import SwiftUI
import PromptCore

struct TypographyTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Preview") {
                ReadingPreview(settings: settings.settings)
                    .padding(.vertical, 4)
            }
            Section("Font") {
                Picker("Family", selection: $settings.settings.fontFamily) {
                    Text("Sans").tag(CueSettings.FontFamily.sans)
                    Text("Serif").tag(CueSettings.FontFamily.serif)
                    Text("Mono").tag(CueSettings.FontFamily.mono)
                    Text("Dyslexia").tag(CueSettings.FontFamily.dyslexia)
                }
                .pickerStyle(.segmented)
#if os(macOS)
                if settings.settings.fontFamily == .dyslexia {
                    Text(FontLoader.dyslexiaAvailable
                         ? "Using bundled OpenDyslexic (SIL-OFL)."
                         : "OpenDyslexic not loaded — using rounded fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
#endif
                Picker("Size", selection: $settings.settings.textSize) {
                    ForEach(CueSettings.TextSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Weight", selection: $settings.settings.fontWeight) {
                    Text("Regular").tag(CueSettings.FontWeight.regular)
                    Text("Medium").tag(CueSettings.FontWeight.medium)
                    Text("Semibold").tag(CueSettings.FontWeight.semibold)
                    Text("Bold").tag(CueSettings.FontWeight.bold)
                }
                .pickerStyle(.segmented)
                Slider(value: $settings.settings.prompterScale, in: 1.0...2.5, step: 0.1) {
                    Text("Prompter scale")
                }
            }
            Section("Color") {
                Picker("Text", selection: $settings.settings.textColor) {
                    Text("Paper").tag(CueSettings.TextColor.paper)
                    Text("White").tag(CueSettings.TextColor.white)
                    Text("Stone").tag(CueSettings.TextColor.stone)
                }
                .pickerStyle(.segmented)
                Picker("Background", selection: $settings.settings.surfaceStyle) {
                    Text("Espresso").tag(CueSettings.SurfaceStyle.espresso)
                    Text("Black").tag(CueSettings.SurfaceStyle.black)
                    Text("Slate").tag(CueSettings.SurfaceStyle.slate)
                }
                .pickerStyle(.segmented)
                Text("The notch island always stays black to melt into the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spacing") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Line spacing \(settings.settings.lineSpacing, specifier: "%.2f")").font(.callout)
                    Slider(value: $settings.settings.lineSpacing, in: 0.3...0.8, step: 0.05) {
                        Text("Line spacing")
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paragraph spacing \(settings.settings.paragraphSpacing, specifier: "%.2f")").font(.callout)
                    Slider(value: $settings.settings.paragraphSpacing, in: 0...1.5, step: 0.05) {
                        Text("Paragraph spacing")
                    }.labelsHidden()
                }
                Text("Paragraph gap applies between blank-line separated blocks.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Letter spacing \(settings.settings.letterSpacing, specifier: "%.1f")").font(.callout)
                    Slider(value: $settings.settings.letterSpacing, in: 0...1.5, step: 0.1) {
                        Text("Letter spacing")
                    }.labelsHidden()
                }
                Picker("Reading width", selection: $settings.settings.readingWidth) {
                    Text("Full").tag(nil as Double?)
                    Text("500").tag(500 as Double?)
                    Text("650").tag(650 as Double?)
                    Text("800").tag(800 as Double?)
                }
                .pickerStyle(.segmented)
                Picker("Alignment", selection: $settings.settings.textAlignment) {
                    Text("Left").tag(CueSettings.TextAlignment.leading)
                    Text("Center").tag(CueSettings.TextAlignment.center)
                }
                .pickerStyle(.segmented)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
