import SwiftUI
import PromptCore

/// Invisible wiring view: owns the playback ticker and every
/// engine/voice/overlay reaction. Lives in ContentView's background so
/// the layout body stays small enough for the type checker — and so
/// playback logic has exactly one home.
struct PlaybackDriver: View {
    @Bindable var engine: PromptEngine
    @Bindable var scripts: ScriptStore
    @Bindable var settings: SettingsStore
    @Bindable var overlay: OverlayController
    @Bindable var voice: VoiceTracker
    let tokens: [ScriptToken]
    @Binding var mode: PerformMode
    var pick: (UUID) -> Void
    @State private var lastTick: Date?
    @State private var voiceTask: Task<Void, Never>?

    /// Smart mode: voice matching drives while speaking; WPM auto-scroll
    /// kicks in after this many seconds of silence.
    private static let smartSilenceTimeout: TimeInterval = 2.0

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()) { date in
                tick(date)
            }
            .onAppear {
                engine.naturalPacing = settings.settings.naturalPacing
            }
            .onChange(of: settings.settings.naturalPacing) { _, pacing in
                engine.naturalPacing = pacing
            }
            .onChange(of: engine.isPlaying) { _, playing in
                if playing { mode = .perform }
                // Pop out by default: pressing Play presents the overlay,
                // so there's nothing to go looking for.
                if playing, !overlay.isShowing, settings.settings.popOutOnPlay {
                    overlay.show(engine: engine, settings: settings,
                                 tokens: tokens, voice: voice)
                }
                syncVoice()
            }
            .onChange(of: settings.settings.wordsPerMinute) { _, wpm in
                // Settings is the persisted source of truth; the engine is
                // the live player. Guard against round-trip ping-pong.
                let target = max(0.5, min(8.0, wpm / 60.0))
                if abs(engine.wordsPerSecond - target) > 0.001 {
                    engine.setSpeed(target)
                }
            }
            .onChange(of: engine.wordsPerSecond) { _, wps in
                // Keyboard shortcuts (Cmd+Up/Down) drive the engine
                // directly — mirror back so the Reading slider stays true.
                let wpm = max(30, min(480, wps * 60))
                if abs(settings.settings.wordsPerMinute - wpm) > 0.5 {
                    settings.settings.wordsPerMinute = wpm
                }
            }
            .onChange(of: engine.progress) { _, progress in
                advance(progress)
            }
            .onChange(of: engine.currentWordIndex) { _, index in
                autoPauseAtCue(index)
            }
            .onChange(of: settings.settings.guidance) { _, _ in
                syncVoice()
            }
            .onChange(of: settings.settings.speechLanguage) { _, language in
                voice.language = language
                // The running session keeps its locale; restart to apply.
                if voice.state == .listening {
                    restartVoice()
                } else {
                    voice.recycle()
                }
            }
    }

    private func tick(_ date: Date) {
        let delta: Double = lastTick.map { date.timeIntervalSince($0) } ?? 1.0 / 60
        lastTick = date
        voice.pollVoice()
        let guidance = settings.settings.guidance
        let denied = voice.state == .denied
        let speaking = voice.isSpeaking

        switch guidance {
        case .classic, .auto:
            engine.tick(delta)

        case .voiceActivated:
            if speaking { engine.tick(delta) }

        case .wordTracking:
            // Smart mode: voice matching drives (via VoiceTracker.transcript),
            // but WPM auto-scroll kicks in after silence. The mic-denied
            // fallback always uses WPM so the script still advances.
            if denied {
                engine.tick(delta)
            } else if speaking || !voiceSilentTooLong {
                // Voice is active or silence is within the grace window:
                // let the voice matcher drive (it calls confirmRead).
                // If the matcher hasn't fired yet (speech just started),
                // we still tick WPM so the highlight doesn't stall waiting
                // for the first transcript.
                if !speaking {
                    // Grace period: voice just stopped, matcher might still
                    // have a final match incoming. Don't tick — let the
                    // voice match land first.
                } else {
                    // While speaking, WPM also ticks as a gentle backup so
                    // the highlight doesn't freeze if the matcher is slow.
                    engine.tick(delta)
                }
            } else {
                // Silent too long: WPM fallback keeps the script moving.
                engine.tick(delta)
            }
        }
    }

    /// True when the last voice match was recent (within the grace window).
    private var voiceSilentTooLong: Bool {
        guard let last = voice.lastVoiceMatchDate else { return true }
        return Date().timeIntervalSince(last) > Self.smartSilenceTimeout
    }

    private func advance(_ progress: Double) {
        guard progress >= 1, !engine.isPlaying else { return }
        let autoNext: Bool = settings.settings.autoNextScript
        let current: UUID? = scripts.selectedID
        let ids: [UUID] = scripts.scripts.map(\.id)
        guard autoNext, let current, let idx = ids.firstIndex(of: current),
              idx + 1 < ids.count else {
            overlay.hide()
            return
        }
        pick(ids[idx + 1])
        engine.play()
    }

    /// Optional automatic pause: when the highlight steps onto a word that
    /// follows a [pause]/[wait]/[hold] cue, ease out. Manual jumps that land
    /// past the cue don't retro-trigger — only forward arrival does, via the
    /// currentWordIndex change stream.
    private func autoPauseAtCue(_ index: Int?) {
        guard settings.settings.pauseOnPauseCues,
              engine.isPlaying,
              let idx = index,
              Self.pauseCueWordIndices(tokens).contains(idx) else { return }
        engine.pause()
    }

    static func pauseCueWordIndices(_ tokens: [ScriptToken]) -> Set<Int> {
        ReadingWindow.pauseCueWordIndices(tokens)
    }

    static func isPauseCue(_ cue: String) -> Bool {
        ReadingWindow.isPauseCue(cue)
    }

    /// Whether the current guidance mode needs a live microphone.
    private var voiceMode: Bool {
        settings.settings.guidance.usesVoice
    }

    private func syncVoice() {
        voiceTask?.cancel()
        voiceTask = nil
        if engine.isPlaying, voiceMode {
            voice.language = settings.settings.speechLanguage
            voiceTask = Task {
                await voice.start(engine: engine,
                                  preferred: settings.settings.transcriptionEngine)
            }
        } else {
            voice.stop()
        }
    }

    private func restartVoice() {
        voice.stop()
        syncVoice()
    }
}
