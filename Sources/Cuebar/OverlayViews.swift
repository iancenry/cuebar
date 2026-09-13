import SwiftUI
import PromptCore

/// Floating panel content. The panel renders the same PrompterBody as
/// the main window, with its own follow state.
struct OverlayPanelView: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore
    let tokens: [ScriptToken]
    @Bindable var voice: VoiceTracker
    @Binding var follow: Bool
    var island: Bool = false
    var menuBarHeight: Double = 0
    var onClose: () -> Void = {}

    var body: some View {
        if island {
            ZStack(alignment: .topTrailing) {
                Color.black
                VStack(spacing: 0) {
                    // The menu bar lives inside our top edge; start
                    // content below it so text never hides underneath.
                    Spacer().frame(height: menuBarHeight + 4)
                    PrompterBody(engine: engine, tokens: tokens, settings: settings,
                                 voice: voice, follow: $follow, surfaceOverride: .black, compact: true)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close overlay")
                .padding(.top, menuBarHeight + 8)
                .padding(.trailing, 12)
                .help("Close overlay")
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 24,
                                             bottomTrailingRadius: 24, topTrailingRadius: 0,
                                             style: .continuous))
            .frame(minWidth: settings.settings.overlayWidth,
                   minHeight: settings.settings.overlayHeight)
        } else {
            PrompterBody(engine: engine, tokens: tokens, settings: settings, voice: voice,
                         follow: $follow)
                .frame(minWidth: settings.settings.overlayWidth,
                       minHeight: settings.settings.overlayHeight)
        }
    }
}
