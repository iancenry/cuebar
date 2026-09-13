import SwiftUI
import PromptCore

struct ReadingTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Smooth scrolling", isOn: $settings.settings.smoothScroll)
            Text("Glide to the current word. Off jumps there instantly.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Current word") {
                Toggle("Highlight", isOn: $settings.settings.highlightCurrent)
                Picker("Style", selection: $settings.settings.highlightStyle) {
                    Text("Pill").tag(CueSettings.HighlightStyle.pill)
                    Text("Underline").tag(CueSettings.HighlightStyle.underline)
                    Text("Bold").tag(CueSettings.HighlightStyle.bold)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.settings.highlightCurrent)
                Picker("Color", selection: $settings.settings.highlight) {
                    ForEach(CueSettings.Accent.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.settings.highlightCurrent)
            }
            Section("Cues [like this]") {
                Toggle("Show cues", isOn: $settings.settings.showCues)
                Picker("Cue color", selection: $settings.settings.cueColor) {
                    ForEach(CueSettings.Accent.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Brightness", selection: $settings.settings.cueBrightness) {
                    Text("Dim").tag(CueSettings.CueBrightness.dim)
                    Text("Low").tag(CueSettings.CueBrightness.low)
                    Text("Medium").tag(CueSettings.CueBrightness.medium)
                    Text("Bright").tag(CueSettings.CueBrightness.bright)
                }
                .pickerStyle(.segmented)
                Text("[bracketed] directions render as badges and never count as words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Hide punctuation", isOn: $settings.settings.hidePunctuation)
            Text("Reading view drops punctuation; tracking is unaffected.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show progress", isOn: $settings.settings.showProgress)
            Toggle("Center line", isOn: $settings.settings.showCenterLine)
            Text("A quiet eye-line across the middle that Follow tracks onto.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Elapsed time", isOn: $settings.settings.showElapsed)
            Toggle("Auto next script", isOn: $settings.settings.autoNextScript)
            Section("Reading window") {
                HStack {
                    Text("Page size").font(.callout)
                    Spacer()
                    Text("\(settings.settings.clampedPageSize) words")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Stepper("", value: $settings.settings.pageSize, in: 50...600, step: 50)
                        .labelsHidden()
                }
                Text("Bounds how many words render at once — the efficiency win for long scripts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
