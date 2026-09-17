import SwiftUI
import PromptCore

struct ReadingTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsTab {
            Section("Preview") {
                ReadingPreview(settings: settings.settings)
                    .padding(.vertical, 4)
            }
            Section("Speed") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Words per minute").font(.callout)
                        Spacer()
                        Text("\(Int(settings.settings.wordsPerMinute.rounded())) wpm")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        Stepper("", value: $settings.settings.wordsPerMinute, in: 30...480, step: 1)
                            .labelsHidden()
                    }
                    Slider(value: $settings.settings.wordsPerMinute, in: 30...480, step: 1) {
                        Text("Words per minute")
                    }.labelsHidden()
                }
                Text("Coarse keys ⌘↑/↓ move ±10 WPM; hold ⇧ for ±1 WPM fine steps.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Natural pacing", isOn: $settings.settings.naturalPacing)
                Text("Long words linger, commas breathe, sentence ends land. Off scrolls at a steady mechanical rate.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catch-up boost \(settings.settings.catchUpBoost, specifier: "%.1f")×").font(.callout)
                    Slider(value: $settings.settings.catchUpBoost, in: 1.2...2.5, step: 0.1) {
                        Text("Catch-up boost")
                    }.labelsHidden()
                }
                Text("Hold → or hold the × button in the transport bar to briefly run this much faster, then ease back.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scroll speed \(settings.settings.scrollSpeed, specifier: "%.2f")×").font(.callout)
                    Slider(value: $settings.settings.scrollSpeed, in: 0.25...2.0, step: 0.05) {
                        Text("Scroll speed")
                    }.labelsHidden()
                }
                Text("Words per minute drives the teleprompter; scroll speed controls how fast smooth scrolling glides to the current word.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Scrolling", selection: $settings.settings.smoothScroll) {
                Text("Smooth").tag(true)
                Text("Stepped").tag(false)
            }
            .pickerStyle(.segmented)
            Text(settings.settings.smoothScroll
                  ? "Glide to the current word at the scroll speed above."
                  : "Jump to the current word instantly.")
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
            Section("Pause") {
                Toggle("Pause at [pause] cues", isOn: $settings.settings.pauseOnPauseCues)
                Text("When the highlight reaches [pause], [wait], or [hold], ease to a stop.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Wheel releases Follow", isOn: $settings.settings.releaseFollowOnScroll)
                Text("Nudging the scroll wheel lets you look around without auto-scroll fighting you. Playback continues; Resume follow jumps back.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Ways to pause: ⌥Space, the transport button, clicking a word to jump (keeps playing), silence in Voice-Activated mode, or deny-free fallback in Word Tracking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
    }
}
