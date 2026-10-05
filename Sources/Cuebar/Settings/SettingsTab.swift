import SwiftUI

/// Scrollable settings page: one centered, readable column with a
/// consistent section rhythm. Replaces the Form-based layout whose
/// trailing label column clipped long labels ("Speech language",
/// "Brightness") off the window's left edge.
struct SettingsTab<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                content()
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
    }
}

/// A titled group of settings, rendered as a card.
///
/// It was a bare heading once, when every setting in the app lived in one flat
/// scroll. With the page-per-section sidebar each group is a decision the user
/// makes, and a card per decision is what makes nine pages read as one app.
struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder let content: () -> Content

    /// A preview draws its own frame, so a card around it is a box inside a
    /// box. Such sections opt out of the card.
    var isSelfFramed: Bool { title == "Preview" }

    var body: some View {
        if isSelfFramed {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(CuePalette.ink)
                content()
            }
        } else {
            SettingsCard(title: title) { content() }
        }
    }
}

/// Label in a fixed leading column (never clipped), control fills the
/// rest — the pickers and segmented controls row layout.
struct SettingRow<Control: View>: View {
    var label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.callout)
                .foregroundStyle(CuePalette.ink)
                .frame(width: 118, alignment: .leading)
            // The row already names the control. Without this every picker
            // printed its own title too — "Family  Family  Sans Serif Mono" —
            // because the row's leading label is not the same thing as a
            // picker's label, and SwiftUI draws both.
            control()
                .labelsHidden()
        }
    }
}

/// Title + current value on one line, slider spanning the full width
/// below. Sliders never sit in the label column (that's what clipped
/// "pacity 95%" off-screen).
struct LabeledSlider: View {
    var title: String
    var display: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(CuePalette.ink)
                Spacer()
                Text(display)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

/// Checkbox with its explainer aligned under it.
struct ToggleRow: View {
    var title: String
    @Binding var isOn: Bool
    var caption: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: $isOn)
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Secondary explainer text under a control.
struct SettingsCaption: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
