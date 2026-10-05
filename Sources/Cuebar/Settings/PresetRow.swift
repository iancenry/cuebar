import SwiftUI
import PromptCore

/// Four presentations, plus whatever the user saves.
///
/// First in the Reading tab because it is the question a presenter actually
/// arrives with: "how do I set this up for a talk?" — not a list of
/// individual sliders.
struct PresetRow: View {
    @Bindable var settings: SettingsStore
    @State private var naming = false
    @State private var draftName = ""

    private var presets: [CuePreset] { CuePreset.builtIns + settings.settings.presets }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Built in")
                    .font(.headline)
                    .foregroundStyle(CuePalette.ink)
                Spacer(minLength: 8)
                Button {
                    draftName = ""
                    naming = true
                } label: {
                    Label("Save current as…", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.link)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(presets) { preset in
                    button(for: preset)
                }
            }
            if naming {
                HStack(spacing: 8) {
                    TextField("Preset name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { naming = false; return }
                        settings.settings.presets.append(
                            CuePreset.capturing(settings.settings, name: name))
                        settings.settings.presets.sort { $0.name < $1.name }
                        naming = false
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { naming = false }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
    }

    private func button(for preset: CuePreset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 12))
                Text(preset.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !preset.isBuiltIn {
                    Button {
                        settings.settings.presets.removeAll { $0.id == preset.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(CuePalette.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this preset")
                    .accessibilityLabel("Delete \(preset.name)")
                }
            }
            Text(preset.summary.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(CuePalette.inkMuted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(CuePalette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CuePalette.hairline, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            preset.apply(to: &settings.settings)
        }
        .help("Apply the \(preset.name) preset")
        .accessibilityLabel("Apply the \(preset.name) preset")
        .accessibilityHint(preset.summary.joined(separator: ", "))
    }
}
