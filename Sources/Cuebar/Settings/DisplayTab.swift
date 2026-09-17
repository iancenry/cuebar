import SwiftUI
import PromptCore

struct DisplayTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsTab {
            Section("Preview") {
                ReadingPreview(settings: settings.settings)
                    .padding(.vertical, 4)
                Text("Live preview — reflects Display, Typography, and Reading.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Overlay", selection: $settings.settings.overlayMode) {
                Text("Notch").tag(CueSettings.OverlayMode.notch)
                Text("Floating").tag(CueSettings.OverlayMode.floating)
                Text("Fullscreen").tag(CueSettings.OverlayMode.fullscreen)
            }
            .pickerStyle(.segmented)
            Text("Notch grows out of the camera housing like an expanded island. Floating is a draggable always-on-top panel. Fullscreen takes the target display.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Display", selection: $settings.settings.displayTarget) {
                Text("Follow Mouse").tag(CueSettings.DisplayTarget.followMouse)
                Text("Fixed Display").tag(CueSettings.DisplayTarget.fixed)
            }
            .pickerStyle(.segmented)
#if os(macOS)
            if settings.settings.displayTarget == .fixed {
                Picker("Fixed display", selection: $settings.settings.fixedDisplayIndex) {
                    ForEach(Array(DisplayInfo.names().enumerated()), id: \.offset) { i, name in
                        Text(name).tag(i)
                    }
                }
            }
#endif
            Toggle("Always on top", isOn: $settings.settings.alwaysOnTop)
            Text("Floating and notch panels stay above other apps. Off lets them slide behind.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Section("Pop-out") {
                Toggle("Pop out overlay when pressing Play", isOn: $settings.settings.popOutOnPlay)
                Text("Manual pop-out lives in the transport bar (expand icon) and the top-bar gear menu — pressing Play auto-presents when this is on.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Window opacity", isOn: $settings.settings.transparencyEnabled)
            Slider(value: $settings.settings.transparencyAmount, in: 0.3...1.0) {
                Text("Opacity \(Int(settings.settings.transparencyAmount * 100))%")
            }
            .disabled(!settings.settings.transparencyEnabled)
            Text("Applies instantly to the open overlay.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Hide from screen sharing", isOn: $settings.settings.hideFromShare)
            Text("Hides every Cuebar window — main, overlay, and settings — from recordings and calls. Self-test: open the overlay, run screencapture ~/Desktop/test.png, confirm Cuebar is missing from the photo.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Hide main window while presenting", isOn: $settings.settings.hideMainWhilePresenting)
            Text("The main window steps aside when the overlay opens and returns when it closes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Section("Dimensions") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width \(Int(settings.settings.overlayWidth))px").font(.callout)
                    Slider(value: $settings.settings.overlayWidth, in: 280...maxWidth, step: 10) {
                        Text("Width")
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Height \(Int(settings.settings.overlayHeight))px").font(.callout)
                    Slider(value: $settings.settings.overlayHeight, in: 100...900, step: 10) {
                        Text("Height")
                    }.labelsHidden()
                }
                if settings.settings.overlayMode == .notch {
                    Text("The notch island caps at 640 wide so it keeps reading as hardware.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Dragging the floating panel remembers its size and position.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.settings.floatingOriginX != nil {
                    Button("Forget saved position") {
                        settings.settings.floatingOriginX = nil
                        settings.settings.floatingOriginY = nil
                    }
                }
            }
            Button("Reset All") { settings.reset() }
        }
    }

    private var maxWidth: Double {
        settings.settings.overlayMode == .notch ? 640 : 1200
    }
}
