import SwiftUI
import AppKit
import PromptCore

struct DisplayTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var remote: RemoteController

    var body: some View {
        SettingsPage(title: "Display",
                     subtitle: "Where the prompter lives while you read.") {
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
            SettingsSection(title: "Phone Remote") {
                if let url = remote.url {
                    SettingRow(label: "Address") {
                        HStack(spacing: 6) {
                            Text(url)
                                .font(.caption)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(CuePalette.inkMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy address")
                        }
                    }
                    SettingsCaption(text: "Open it in Safari on a phone on the same network. The address changes every time — the old one stops working the moment the prompter comes down.")
                } else {
                    SettingsCaption(text: "Nothing to connect to yet. Pop the prompter out (⌥O) and the remote comes up while it is showing.")
                }
                ToggleRow(title: "Advertise on this network",
                          isOn: $settings.settings.advertiseRemote,
                          caption: "Lets a phone find “Cuebar” by name instead of you typing the address. Off by default: advertising is the one part of the remote that reaches onto the network uninvited, and macOS answers it with a permission prompt at full alert volume. Turning it on moves the address.")
                SettingsCaption(text: "A server on this network can move a live talk, so it only listens while the prompter is up, and the address is never advertised. The name alone carries no authority — the token in the address is the whole of it.")
                SettingRow(label: "Drive my deck") {
                    Picker("Deck app", selection: $settings.settings.deckApp) {
                        ForEach(CueSettings.DeckApp.allCases) { app in
                            Text(app.label).tag(app)
                        }
                    }
                }
                SettingsCaption(text: "A [slide] cue moves your Keynote or PowerPoint as you read. Off by default: controlling another app makes macOS ask for permission, and a consent dialog in the middle of setting up a teleprompter is the wrong surprise. The slide count, the badges and the phone's stepper all work with this off.")
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
