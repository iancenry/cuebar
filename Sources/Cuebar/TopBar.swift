import SwiftUI
import PromptCore

/// Slim content-column strip: the mode switcher, alone.
///
/// No app title — the menu bar and Dock already carry the name, and the
/// traffic lights live over the sidebar. No settings cog either: it is in the
/// menu bar, where every other Mac app keeps it, and a duplicate control in two
/// places is a control that drifts. The live status moved to the transport
/// dock's trailing group, level with Practice and Record, so the top edge
/// carries nothing but the mode you are in.
struct TopBar: View {
    @Bindable var settings: SettingsStore
    @Bindable var engine: PromptEngine
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    let index: ScriptIndex
    /// Rehearsal, so the floating prompter hides what the window hides.
    var practice: PracticeController? = nil
    @Binding var mode: PerformMode

    var body: some View {
        HStack(spacing: 10) {
            ModeSwitcher(mode: $mode)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CuePalette.chromeRowMargin)
        // Fixed, not derived: whatever a control measures, the band stays
        // the title-bar line and the controls centre on it.
        .frame(height: CuePalette.chromeRowHeight)
    }
}

/// Compact Perform/Edit switch — a branded two-segment capsule instead
/// of the chunky native segmented control.
struct ModeSwitcher: View {
    @Binding var mode: PerformMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.perform, "Perform")
            segment(.edit, "Edit")
        }
        .padding(2)
        .frame(height: CuePalette.chromeControlHeight)
        .glassSurface(in: Capsule())
    }

    private func segment(_ value: PerformMode, _ title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { mode = value }
        } label: {
            Text(title)
                .font(.callout.weight(mode == value ? .semibold : .regular))
                .foregroundStyle(mode == value ? CuePalette.onHighlight : CuePalette.ink.opacity(0.65))
                .padding(.horizontal, 13)
                .padding(.vertical, 2)
                .background {
                    if mode == value {
                        Capsule().fill(CuePalette.peach)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}
