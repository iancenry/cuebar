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
    @State private var ticker: Task<Void, Never>?
    /// Voice polling cadence: the VAD and level history were designed
    /// around ~8 Hz, and polling at the 60 Hz ticker rate republished
    /// mic state (and re-rendered every observer) 60× a second.
    @State private var voicePollAccumulator: Double = 0
    private static let voicePollInterval: Double = 0.125
    /// Smart pause: accumulators and state for speech-silence detection.
    @State private var smartPauseSilenceAccumulator: Double = 0
    @State private var smartPauseSpeechAccumulator: Double = 0
    /// True when smart pause auto-paused playback; we only auto-resume
    /// if we were the ones who paused.
    @State private var smartPauseDidAutoPause: Bool = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                engine.naturalPacing = settings.settings.naturalPacing
                syncTicker()
            }
            .onDisappear {
                ticker?.cancel()
                ticker = nil
            }
            .onChange(of: settings.settings.naturalPacing) { _, pacing in
                engine.naturalPacing = pacing
            }
            .onChange(of: engine.isPlaying) { _, playing in
                if playing {
                    mode = .perform
                    voice.resetSpeechSeen()
                }
                // Reset smart pause state when playback starts/stops.
                if playing {
                    smartPauseSilenceAccumulator = 0
                    smartPauseSpeechAccumulator = 0
                    smartPauseDidAutoPause = false
                }
                // Pop out by default: pressing Play presents the overlay,
                // so there's nothing to go looking for.
                if playing, !overlay.isShowing, settings.settings.popOutOnPlay {
                    overlay.show(engine: engine, settings: settings,
                                 tokens: tokens, voice: voice)
                }
                syncVoice()
                syncTicker()
            }
            .onChange(of: voice.state) { _, _ in
                syncTicker()
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
                handleCueArrival(index)
            }
            .onChange(of: settings.settings.guidance) { _, _ in
                syncVoice()
                syncTicker()
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

    /// The ticker only earns its CPU while something can actually change:
    /// playing, a live mic (level meter + VAD), or a smart pause waiting
    /// for speech to auto-resume. Idle time now costs zero timers instead
    /// of 60 wakeups a second.
    ///
    /// The loop is a MainActor task, not a run-loop Timer: every tick runs
    /// *inside* a real task on the main executor, so no `MainActor
    /// .assumeIsolated` is needed — that call crashes in the Swift 6.2
    /// runtime when the runloop fires a Timer outside any task context.
    private func syncTicker() {
        let active = engine.isPlaying || voice.state == .listening || smartPauseDidAutoPause
        if active {
            if ticker == nil {
                lastTick = nil
                voicePollAccumulator = 0
                ticker = Task { [self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(16))
                        if Task.isCancelled { break }
                        tick()
                    }
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
            lastTick = nil
            voicePollAccumulator = 0
        }
    }

    private func tick() {
        let now = Date()
        let delta: Double = lastTick.map { now.timeIntervalSince($0) } ?? 1.0 / 60
        lastTick = now
        voicePollAccumulator += delta
        if voicePollAccumulator >= Self.voicePollInterval {
            voicePollAccumulator = 0
            voice.pollVoice()
        }
        let guidance = settings.settings.guidance
        let speaking = voice.isSpeaking

        // Smart pause: accumulate silence/speech and auto-pause/resume.
        // Armed only once the mic has actually heard speech — otherwise a
        // silent mic reads as "eternal silence" and instantly auto-pauses.
        // Stays armed after the auto-pause (isPlaying goes false there):
        // without it the auto-RESUME branch could never run again. Holds
        // are excluded: a scripted 2 s wait isn't the reader going quiet.
        if guidance.usesVoice, settings.settings.smartPause != .off,
           voice.speechSeenSincePlay,
           engine.isPlaying || smartPauseDidAutoPause,
           !engine.isHolding {
            tickSmartPause(speaking: speaking, delta: delta)
        }

        switch guidance {
        case .classic, .auto:
            engine.tick(delta)

        case .voiceActivated, .wordTracking:
            // Speak-to-scroll — until the mic has picked up its first
            // speech this session, keep ticking so Play is never a no-op
            // (a silent or wrong-input mic used to freeze the prompter).
            // The matcher (wordTracking) corrects position on top of the
            // ticking. The eased stop after pause() and the timed-cue
            // countdown must always tick, or neither ever settles.
            if speaking || !voice.speechSeenSincePlay
                || engine.isStopping || engine.isHolding {
                engine.tick(delta)
            }
        }
    }

    // MARK: - Smart Pause

    /// Accumulate silence/speech duration. Auto-pause when silence exceeds
    /// threshold; auto-resume when speech exceeds resume threshold.
    private func tickSmartPause(speaking: Bool, delta: Double) {
        let mode = settings.settings.smartPause
        if speaking {
            smartPauseSilenceAccumulator = 0
            smartPauseSpeechAccumulator += delta
            // Auto-resume: sustained speech after an auto-pause.
            if smartPauseDidAutoPause,
               smartPauseSpeechAccumulator >= mode.resumeThreshold {
                engine.play()
                smartPauseDidAutoPause = false
                smartPauseSpeechAccumulator = 0
                syncTicker()
                syncVoice()
            }
        } else {
            smartPauseSpeechAccumulator = 0
            smartPauseSilenceAccumulator += delta
            // Auto-pause: sustained silence.
            if !smartPauseDidAutoPause,
               smartPauseSilenceAccumulator >= mode.silenceThreshold {
                engine.pause()
                smartPauseDidAutoPause = true
                smartPauseSilenceAccumulator = 0
                // Keep the ticker + mic alive: the auto-resume path needs
                // them to hear speech again while playback is stopped.
                syncTicker()
                syncVoice()
            }
        }
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

    /// Cue arrival, forward-only (jumps past a cue never retro-trigger):
    /// timed cues hold playback for their duration, bare [pause]-family
    /// cues auto-pause when the setting is on.
    private func handleCueArrival(_ index: Int?) {
        guard engine.isPlaying, let idx = index else { return }
        if let seconds = ReadingWindow.timedHoldCues(tokens)[idx] {
            engine.hold(for: seconds)
            return
        }
        if settings.settings.pauseOnPauseCues,
           Self.pauseCueWordIndices(tokens).contains(idx) {
            engine.pause()
        }
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
        // Keep the mic alive through a smart auto-pause — killing it here
        // would make auto-resume physically impossible (silence can't
        // un-pause anything if nobody is listening).
        if (engine.isPlaying || smartPauseDidAutoPause), voiceMode {
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
