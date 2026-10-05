import SwiftUI
import PromptCore

/// Floating panel content. The panel renders the same PrompterBody as
/// the main window, with its own follow state.
struct OverlayPanelView: View {
    @Bindable var engine: PromptEngine
    @Bindable var settings: SettingsStore
    let index: ScriptIndex
    @Bindable var voice: VoiceTracker
    @Binding var follow: Bool
    /// Rehearsal, so the floating prompter hides the same words the window
    /// does — practising on one surface and presenting on another is how a
    /// rehearsal stops being one.
    var practice: PracticeController? = nil
    var island: Bool = false
    var menuBarHeight: Double = 0
    /// Voice tracking has lost the reader and the prompter has stopped rather
    /// than guessed. A state, never a percentage.
    var trackingUncertain: Bool = false
    var onClose: () -> Void = {}

    var body: some View {
        Group {
            if island {
                ZStack(alignment: .topTrailing) {
                    Color.black
                    VStack(spacing: 0) {
                        // The menu bar lives inside our top edge; start
                        // content below it so text never hides underneath.
                        Spacer().frame(height: menuBarHeight + 4)
                        PrompterBody(engine: engine, index: index, settings: settings,
                                     voice: voice, follow: $follow,
                                     surfaceOverride: .black, compact: true,
                                     practice: practice)
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
                .overlay(alignment: .top) {
                    if trackingUncertain { TrackingBadge().padding(.top, menuBarHeight + 8) }
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 24,
                                                 bottomTrailingRadius: 24, topTrailingRadius: 0,
                                                 style: .continuous))
                .frame(minWidth: settings.settings.overlayWidth,
                       minHeight: settings.settings.overlayHeight)
            } else {
                // The badge is an *overlay*: it cannot change the height of the
                // stack, because changing it would move the script the moment
                // tracking hiccuped.
                PrompterBody(engine: engine, index: index, settings: settings,
                             voice: voice, follow: $follow, practice: practice)
                    .overlay(alignment: .top) {
                        if trackingUncertain { TrackingBadge().padding(.top, 8) }
                    }
                    .frame(minWidth: settings.settings.overlayWidth,
                           minHeight: settings.settings.overlayHeight)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// "Listening — holding", said plainly.
///
/// No bar, no percentage. The research on voice tracking failure is unambiguous
/// about the failure being worth avoiding (jumping 30 paragraphs) and about the
/// number being worthless to a presenter mid-sentence; what helps is knowing
/// the prompter is *waiting* rather than wandering, and being able to put it
/// back with one action.
private struct TrackingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ear.trianglebadge.exclamationmark")
                .font(.system(size: 11))
            Text("Listening — holding your place")
                .font(.caption)
            Text("tap any line to jump there")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice tracking lost you. Holding your place. "
            + "Tap any line to resume.")
    }
}
