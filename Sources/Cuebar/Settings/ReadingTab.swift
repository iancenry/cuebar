import SwiftUI
import PromptCore

struct ReadingTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsTab {
            SettingsSection(title: "Preview") {
                ReadingPreview(settings: settings.settings)
            }
            SettingsSection(title: "Speed") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Words per minute")
                            .font(.callout)
                            .foregroundStyle(CuePalette.ink)
                        Spacer()
                        Text("\(Int(settings.settings.wordsPerMinute.rounded())) wpm")
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("", value: $settings.settings.wordsPerMinute, in: 30...480, step: 1)
                            .labelsHidden()
                            .fixedSize()
                    }
                    Slider(value: $settings.settings.wordsPerMinute, in: 30...480, step: 1)
                }
                SettingsCaption(text: "⌘↑/↓ move ±10 WPM; hold ⇧ for ±1 WPM fine steps.")
                ToggleRow(title: "Natural pacing",
                          isOn: $settings.settings.naturalPacing,
                          caption: "Long words linger, commas breathe, sentence ends land. Off scrolls at a steady mechanical rate.")
                LabeledSlider(title: "Catch-up boost",
                              display: String(format: "%.1f×", settings.settings.catchUpBoost),
                              value: $settings.settings.catchUpBoost,
                              range: 1.2...2.5, step: 0.1)
                SettingsCaption(text: "Hold → or hold the × button in the transport bar to briefly run this much faster, then ease back.")
                LabeledSlider(title: "Scroll speed",
                              display: String(format: "%.2f×", settings.settings.scrollSpeed),
                              value: $settings.settings.scrollSpeed,
                              range: 0.25...2.0, step: 0.05)
                SettingsCaption(text: "How fast smooth scrolling glides to the current word.")
            }
            SettingsSection(title: "Scrolling") {
                SettingRow(label: "Style") {
                    Picker("Scrolling", selection: $settings.settings.smoothScroll) {
                        Text("Smooth").tag(true)
                        Text("Stepped").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                SettingsCaption(text: settings.settings.smoothScroll
                    ? "Glide to the current word at the scroll speed above."
                    : "Jump to the current word instantly.")
            }
            SettingsSection(title: "Current word") {
                ToggleRow(title: "Highlight",
                          isOn: $settings.settings.highlightCurrent)
                SettingRow(label: "Style") {
                    Picker("Style", selection: $settings.settings.highlightStyle) {
                        Text("Pill").tag(CueSettings.HighlightStyle.pill)
                        Text("Underline").tag(CueSettings.HighlightStyle.underline)
                        Text("Bold").tag(CueSettings.HighlightStyle.bold)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.settings.highlightCurrent)
                }
                SettingRow(label: "Color") {
                    Picker("Color", selection: $settings.settings.highlight) {
                        ForEach(CueSettings.Accent.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.settings.highlightCurrent)
                }
            }
            SettingsSection(title: "Cues [like this]") {
                ToggleRow(title: "Show cues",
                          isOn: $settings.settings.showCues,
                          caption: "[bracketed] directions render as badges and never count as words. Timed cues execute: [pause 2s] holds the prompter for 2 seconds, then continues.")
                SettingRow(label: "Cue color") {
                    Picker("Cue color", selection: $settings.settings.cueColor) {
                        ForEach(CueSettings.Accent.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.settings.showCues)
                }
                SettingRow(label: "Brightness") {
                    Picker("Brightness", selection: $settings.settings.cueBrightness) {
                        Text("Dim").tag(CueSettings.CueBrightness.dim)
                        Text("Low").tag(CueSettings.CueBrightness.low)
                        Text("Medium").tag(CueSettings.CueBrightness.medium)
                        Text("Bright").tag(CueSettings.CueBrightness.bright)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.settings.showCues)
                }
            }
            SettingsSection(title: "Punctuation") {
                ToggleRow(title: "Hide punctuation",
                          isOn: $settings.settings.hidePunctuation,
                          caption: "Reading view drops punctuation; tracking is unaffected.")
            }
            SettingsSection(title: "Pause") {
                ToggleRow(title: "Pause at [pause] cues",
                          isOn: $settings.settings.pauseOnPauseCues,
                          caption: "Bare [pause], [wait] and [hold] ease to a stop on arrival. Timed cues ([pause 2s], [hold 500ms], [breath 1.5]) wait their duration automatically, regardless of this setting.")
                SettingRow(label: "Smart pause") {
                    Picker("Smart pause", selection: $settings.settings.smartPause) {
                        ForEach(CueSettings.SmartPauseMode.allCases, id: \.self) { mode in
                            Text(mode == .off ? "Off" : mode.rawValue.capitalized).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }
                SettingsCaption(text: "Auto-pause when you stop speaking; auto-resume when you start again. Works in Voice or Smart mode.")
                ToggleRow(title: "Wheel releases Follow",
                          isOn: $settings.settings.releaseFollowOnScroll,
                          caption: "Nudging the scroll wheel lets you look around without auto-scroll fighting you. Resume follow jumps back.")
            }
            SettingsSection(title: "While reading") {
                ToggleRow(title: "Show progress",
                          isOn: $settings.settings.showProgress)
                ToggleRow(title: "Center line",
                          isOn: $settings.settings.showCenterLine,
                          caption: "A quiet eye-line across the middle that Follow tracks onto.")
                ToggleRow(title: "Elapsed time",
                          isOn: $settings.settings.showElapsed)
                ToggleRow(title: "Auto next script",
                          isOn: $settings.settings.autoNextScript)
            }
            SettingsSection(title: "Reading window") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Page size")
                            .font(.callout)
                            .foregroundStyle(CuePalette.ink)
                        Spacer()
                        Text("\(settings.settings.clampedPageSize) words")
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("", value: $settings.settings.pageSize, in: 50...600, step: 50)
                            .labelsHidden()
                            .fixedSize()
                    }
                    SettingsCaption(text: "Bounds how many words render at once — the efficiency win for long scripts.")
                }
            }
        }
    }
}
