import SwiftUI

/// Mic proof-of-life for voice modes: status dot, state label, and a
/// live input-level meter. If the meter never moves, the OS isn't
/// delivering mic audio — no amount of matching logic will help.
struct MicStatus: View {
    @Bindable var voice: VoiceTracker
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CuePalette.ink)
            if !compact, voice.state == .listening {
                LevelMeter(level: voice.audioLevel)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: CuePalette.chromeControlHeight)
        .glassSurface(in: Capsule())
        .help(help)
    }

    private var dot: Color {
        // A mute is a decision, not a failure — it must not look like one.
        if voice.isMutedByUser { return CuePalette.muted }
        switch voice.state {
        case .listening:
            return voice.isSpeaking ? CuePalette.live : CuePalette.peach
        case .requesting:
            return CuePalette.peach
        case .denied, .error:
            return .red
        case .idle, .stopped:
            return CuePalette.muted
        }
    }

    private var label: String {
        if voice.isMutedByUser { return "Muted" }
        switch voice.state {
        case .listening:
            return voice.isSpeaking ? "Hearing you" : "Listening…"
        case .requesting:
            return "Starting mic…"
        case .denied:
            return "Mic unavailable"
        case .error:
            return "Voice hiccup"
        case .idle, .stopped:
            return "Mic off"
        }
    }

    private var help: String {
        if voice.isMutedByUser {
            return "Muted on purpose — the prompter runs on the reading clock. Toggle Microphone to bring it back."
        }
        switch voice.state {
        case .denied:
            return "Allow Microphone + Speech Recognition in System Settings, then press Play again. Timer mode takes over meanwhile."
        case .error(let message):
            return message
        default:
            let engine = voice.driverName.isEmpty ? "—" : voice.driverName
            var info = "Engine: \(engine). The meter should move while you speak."
            if voice.transcriptCount == 0 {
                info += " No transcripts yet — recognition isn't delivering."
            } else {
                info += " Heard \(voice.transcriptCount) updates; last: “\(voice.lastTranscript.suffix(80))”."
            }
            return info
        }
    }
}

struct LevelMeter: View {
    var level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CuePalette.muted.opacity(0.3))
                Capsule().fill(CuePalette.peach)
                    .frame(width: geo.size.width * min(1, max(0, level)))
            }
        }
        .frame(width: 48, height: 6)
        .accessibilityLabel("Mic level")
    }
}

/// Scrolling audio-activity wave for the prompter footer. Driven by the
/// tracker's level history, so it's flat when the mic is off and alive
/// when it isn't — same proof-of-life idea as the header meter.
struct WaveformView: View {
    var levels: [Double]
    var barCount: Int = 24

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.suffix(barCount).enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > 0.02 ? CuePalette.peach : CuePalette.muted.opacity(0.35))
                    .frame(width: 2, height: max(3, CGFloat(level) * 22))
            }
        }
        .frame(height: 24)
        .accessibilityLabel("Audio activity")
    }
}
