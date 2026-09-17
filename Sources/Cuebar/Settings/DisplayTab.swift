import SwiftUI
import PromptCore

struct DisplayTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsTab {
            SettingsSection(title: "Preview") {
                ReadingPreview(settings: settings.settings)
                SettingsCaption(text: "Live preview — reflects every tab.")
            }
            SettingsSection(title: "Overlay") {
                SettingRow(label: "Placement") {
                    Picker("Overlay", selection: $settings.settings.overlayMode) {
                        Text("Notch").tag(CueSettings.OverlayMode.notch)
                        Text("Floating").tag(CueSettings.OverlayMode.floating)
                        Text("Fullscreen").tag(CueSettings.OverlayMode.fullscreen)
                    }
                    .pickerStyle(.segmented)
                }
                SettingsCaption(text: "Notch grows out of the camera housing like an expanded island. Floating is a draggable always-on-top panel. Fullscreen takes the target display.")
                SettingRow(label: "Display") {
                    Picker("Display", selection: $settings.settings.displayTarget) {
                        Text("Follow Mouse").tag(CueSettings.DisplayTarget.followMouse)
                        Text("Fixed").tag(CueSettings.DisplayTarget.fixed)
                    }
                    .pickerStyle(.segmented)
                }
                if settings.settings.displayTarget == .fixed {
                    SettingRow(label: "Screen") {
                        Picker("Fixed display", selection: $settings.settings.fixedDisplayIndex) {
                            ForEach(Array(DisplayInfo.names().enumerated()), id: \.offset) { i, name in
                                Text(name).tag(i)
                            }
                        }
                    }
                }
                ToggleRow(title: "Always on top",
                          isOn: $settings.settings.alwaysOnTop,
                          caption: "Floating and notch panels stay above other apps. Off lets them slide behind.")
                ToggleRow(title: "Pop out when pressing Play",
                          isOn: $settings.settings.popOutOnPlay,
                          caption: "Manual pop-out lives in the transport bar and the gear menu — pressing Play auto-presents when this is on.")
            }
            SettingsSection(title: "Opacity") {
                ToggleRow(title: "Window opacity",
                          isOn: $settings.settings.transparencyEnabled,
                          caption: "Applies instantly to the open overlay.")
                LabeledSlider(title: "Opacity",
                              display: "\(Int(settings.settings.transparencyAmount * 100))%",
                              value: $settings.settings.transparencyAmount,
                              range: 0.3...1.0)
                .disabled(!settings.settings.transparencyEnabled)
                .opacity(settings.settings.transparencyEnabled ? 1 : 0.4)
            }
            SettingsSection(title: "Privacy") {
                ToggleRow(title: "Hide from screen sharing",
                          isOn: $settings.settings.hideFromShare,
                          caption: "Hides every Cuebar window from recordings and calls. Self-test: open the overlay, run screencapture ~/Desktop/test.png, confirm Cuebar is missing.")
                ToggleRow(title: "Hide main window while presenting",
                          isOn: $settings.settings.hideMainWhilePresenting,
                          caption: "The main window steps aside when the overlay opens and returns when it closes.")
            }
            SettingsSection(title: "Dimensions") {
                LabeledSlider(title: "Width",
                              display: "\(Int(settings.settings.overlayWidth)) px",
                              value: $settings.settings.overlayWidth,
                              range: 280...maxWidth, step: 10)
                LabeledSlider(title: "Height",
                              display: "\(Int(settings.settings.overlayHeight)) px",
                              value: $settings.settings.overlayHeight,
                              range: 100...900, step: 10)
                if settings.settings.overlayMode == .notch {
                    SettingsCaption(text: "The notch island caps at 640 wide so it keeps reading as hardware.")
                }
                SettingsCaption(text: "Dragging the floating panel remembers its size and position.")
                if settings.settings.floatingOriginX != nil {
                    Button("Forget saved position") {
                        settings.settings.floatingOriginX = nil
                        settings.settings.floatingOriginY = nil
                    }
                }
            }
            HStack {
                Spacer()
                Button("Reset All", role: .destructive) { settings.reset() }
            }
        }
    }

    private var maxWidth: Double {
        settings.settings.overlayMode == .notch ? 640 : 1200
    }
}
