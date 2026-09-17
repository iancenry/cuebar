import SwiftUI

/// Scrollable settings page. A bare Form inside the fixed-size Settings
/// scene clips overflowing content with no way to reach it — this wraps
/// the form in a ScrollView and pads it from the window edges.
struct SettingsTab<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            Form {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
