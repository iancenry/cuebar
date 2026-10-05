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
    let index: ScriptIndex
    @Binding var mode: PerformMode
    /// Rehearsal, so popping out on Play rehearses in the overlay too.
    var practice: PracticeController? = nil
    /// Where the presenter was. Written from the tick loop, so a quit loses at
    /// most the store's one-second coalesce window.
    var positions: PositionStore? = nil
    /// Where "the matcher last confirmed something" comes from. A reference so
    /// this view is not re-created with the tick loop; nil disables the state.
    var trackingConfirmations: VoiceTracker? = nil
    /// The rehearsal run. This view feeds it: the ticker is the only loop
    /// already awake, so the recorder's samples cannot disagree with the
    /// engine position they describe. It is optional so the driver can be
    /// built without one.
    var recorder: RunRecorder? = nil
    var pick: (UUID) -> Void
    @State private var voiceTask: Task<Void, Never>?
    @State private var ticker: Task<Void, Never>?
    /// Per-tick bookkeeping. A class on purpose: these fields change 60× a
    /// second, and as `@State` on the view every write invalidated
    /// `PlaybackDriver.body` (nine modifiers) to redraw a zero-size view.
    @State private var tickState = TickState()
    /// Where a crossed `[slide N]` goes. Owned by the app, not by this view:
    /// the phone's slide buttons and ⌥⇧→ move the same position, and a
    /// second counter here is how the deck and the prompter drift apart. The
    /// tick is still the only thing that *fires* cues, and it fires them
    /// straight through without waiting on a third-party app.
    let slideSync: SlideSyncing
    @State private var smartPause = SmartPauseState()
    /// Voice polling cadence: the VAD and level history were designed
    /// around ~8 Hz, and polling at the 60 Hz ticker rate republished
    /// mic state (and re-rendered every observer) 60× a second.
    private static let voicePollInterval: Double = 0.125
    /// The WPM fallback for voice-gated modes runs only during a short
    /// grace window after Play with a *live* mic — never forever, and
    /// never when the mic is off (that made the script cruise in
    /// silence).
    @State private var fallbackDeadline: Date?
    private static let fallbackGrace: TimeInterval = 3
    /// Smart mode: how long speech may continue without a confirmed
    /// match before the WPM timer takes over (paraphrasing, accents,
    /// noisy rooms). Matches are the primary driver.
    /// How recently the recognizer must have produced text to count as
    /// speech. Partial results arrive in bursts, so this has to be wider
    /// than the gap between them.
    private static let wordEvidenceWindow: TimeInterval = 1.5

    /// Hot-loop scratch. Reference semantics keep the 60 Hz writes out of
    /// SwiftUI's invalidation graph.
    final class TickState {
        var last: Date?
        var voicePollAccumulator: Double = 0
        /// Highest word index whose slide cues have been handed over.
        var lastTriggerWord = -1
        /// Last reading position seen, to spot a jump backwards. Kept in
        /// the tick box, not @State: this runs 60 times a second and the
        /// value only exists to be compared with the next tick.
        var lastWord = 0
    }

    /// Smart pause accumulators and state. Same reason as `TickState`.
    final class SmartPauseState {
        var silence: Double = 0
        var speech: Double = 0
        /// True when smart pause auto-paused playback; we only auto-resume
        /// if we were the ones who paused.
        var didAutoPause = false
        func reset() {
            silence = 0
            speech = 0
            didAutoPause = false
        }
    }
    /// Last word index the highlight arrived at, so a backwards jump out of
    /// a cue doesn't re-fire it (see `handleCueArrival`).
    @State private var lastCueArrival: Int?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                engine.naturalPacing = settings.settings.naturalPacing
                syncTicker()
            }
            .onChange(of: index) { _, _ in
                // A new script: every cue is un-armed.
                lastCueArrival = nil
            }
            .onDisappear {
                ticker?.cancel()
                ticker = nil
                // Same reasoning as the ticker: this view owns the loop, and
                // it goes away with the window.
                recorder?.stopIfRecording()
            }
            .onChange(of: settings.settings.naturalPacing) { _, pacing in
                engine.naturalPacing = pacing
            }
            .onChange(of: engine.isPlaying) { _, playing in
                if playing {
                    mode = .perform
                    voice.resetSpeechSeen()
                    fallbackDeadline = Date().addingTimeInterval(Self.fallbackGrace)
                } else {
                    fallbackDeadline = nil
                }
                // Reset smart pause state when playback starts/stops.
                if playing { smartPause.reset() }
                // Pop out by default: pressing Play presents the overlay,
                // so there's nothing to go looking for.
                if playing, !overlay.isShowing, settings.settings.popOutOnPlay {
                    overlay.show(engine: engine, settings: settings,
                                 index: index, voice: voice, practice: practice)
                }
                syncVoice()
                syncTicker()
                if playing {
                    // `currentWordIndex` doesn't change when Play starts, so
                    // a cue on the first line would never otherwise fire.
                    handleCueArrival(engine.currentWordIndex, force: true)
                }
            }
            .onChange(of: voice.state) { _, _ in
                syncTicker()
            }
            .onChange(of: voice.isMutedByUser) { _, muted in
                // Auto-resume is physically impossible without a mic, so a
                // mute abandons the auto-pause instead of leaving the app
                // parked with a flag nothing will ever clear.
                if muted, smartPause.didAutoPause { smartPause.reset() }
                syncVoice()
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
                // One clamp for every writer (see CueSettings).
                let wpm = min(480, max(30, wps * 60))
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
        let active = engine.isPlaying || voice.state == .listening || smartPause.didAutoPause
        if active {
            if ticker == nil {
                tickState.last = nil
                tickState.voicePollAccumulator = 0
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
            tickState.last = nil
            tickState.voicePollAccumulator = 0
        }
    }

    private func tick() {
        let now = Date()
        let delta: Double = tickState.last.map { now.timeIntervalSince($0) } ?? 1.0 / 60
        tickState.last = now
        tickState.voicePollAccumulator += delta
        if tickState.voicePollAccumulator >= Self.voicePollInterval {
            tickState.voicePollAccumulator = 0
            voice.pollVoice()
        }
        // Any pending confirmation walks on regardless of mode; a no-op
        // when nothing is queued, and the only thing that moves the
        // highlight in Smart mode.
        engine.glideStep(delta)

        // Reading position went backwards — a tap on an earlier word or a
        // re-read. Whatever the mic has heard so far describes the script
        // from *before* that, so those words are now ahead of the reader
        // and matching would confirm straight past them. Drop the
        // transcript. Polled rather than hooked to `jumpTo` so every
        // route back — tap, chord, restart — is covered by one check.
        let position = engine.currentWordIndex ?? 0
        if position < tickState.lastWord { voice.abandonTranscript() }
        tickState.lastWord = position

        // Practice mode's "the word you are reading is never a gap". Written
        // here, once per tick, rather than inside the prompter's view body —
        // a view that publishes the value it is about to read invalidates
        // itself mid-evaluation, which is a hang, then a dead app.
        practice?.noteCurrentWord(engine.currentWordIndex)
        recordPlace()

        // One sample of the rehearsal run. Fed from here rather than from a
        // timer of its own: a second loop would read the same engine at a
        // slightly different moment and could record a pause that never
        // happened. Cheap when idle — the recorder drops it in one compare.
        recorder?.sample(word: engine.currentWordIndex, speaking: voice.isSpeaking)

        fireCueTriggers()

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
           engine.isPlaying || smartPause.didAutoPause,
           !engine.isHolding {
            tickSmartPause(speaking: speaking, delta: delta)
        }

        switch guidance {
        case .classic, .auto:
            engine.tick(delta)

        case .voiceActivated:
            // Speak-to-scroll: the WPM timer is the engine here. Gated on
            // the recognizer producing words, NOT on the level meter — a
            // bang on the desk is loud enough to trip any VAD, and gating
            // on it let noise scroll the script on its own. The fallback
            // grace only covers the first seconds after Play. A deliberate
            // mute falls back to the clock on purpose — the presenter
            // asked to stop listening, not to stop reading.
            if spokeRecently || micFallbackActive || voice.isMutedByUser
                || engine.isStopping || engine.isHolding {
                engine.tick(delta)
            }

        case .wordTracking:
            // Matches are the only thing that moves the highlight here.
            //
            // This case used to run the WPM clock as a fallback — a 3s
            // post-Play grace plus a 2.5s stall timer — and both
            // fallbacks *destroyed the mode*. The clock walked the
            // highlight ahead of the reader, the script window slid past
            // the words they were actually saying, so nothing could ever
            // match, and the stall timer saw "no match" and kept ticking.
            // Measured on a live read: real transcripts arriving, zero
            // matches, `stalled=true` for the whole take. A bang on the
            // desk held the fallback open indefinitely, which is how noise
            // scrolled the script. Pressing Play also ran the script
            // through its first words before the reader said anything.
            //
            // The clock now only runs when the recognizer has never
            // delivered a single word — the level meter is then the only
            // evidence there is and a frozen prompter is the worse failure
            // — or when the presenter muted the mic on purpose.
            if engine.isStopping || engine.isHolding || voice.isMutedByUser
                || (voice.transcriptCount == 0 && voice.isSpeaking) {
                engine.tick(delta)
            }
            updateTrackingState(delta: delta)
        }
    }

    /// The safety net, and what it deliberately is *not*.
    ///
    /// Research first: a teleprompter that jumps 30 paragraphs is the single
    /// most-reported failure in this product class, and the fix that works is
    /// the one that makes uncertainty **stop** the prompter rather than send it
    /// off on the clock. Every competitor that recovers does it that way, and
    /// the closest indie one puts it plainly: every uncertainty resolves to
    /// waiting, never to scrolling away.
    ///
    /// What this does *not* do is show a percentage. Apple's per-segment
    /// confidence is unverified on device — reported as often-absent by the
    /// tools that read it, and never calibrated in anything we could find — and
    /// the research on graded certainty is that a number does not improve
    /// automation use, while a wrong-but-confident system is trusted *more*. A
    /// presenter cannot act on a number mid-sentence anyway.
    ///
    /// So the signals are our own and they are about one thing: how long since
    /// the matcher last confirmed a chain, while the mic is hearing speech.
    private func updateTrackingState(delta: Double) {
        // `naturalPacing` is the engine's *dwell* pacing and has nothing to do
        // with voice tracking — gating on it meant the two presets that turn it
        // off (Presentation, Interview) silently disabled the safety net. The
        // right gate is the guidance mode itself.
        guard mode == .perform, settings.settings.guidance == .wordTracking,
              !voice.isMutedByUser, !engine.isHolding, !engine.isStopping,
              let confirmations = trackingConfirmations else { return }
        let state = trackingState
        let spokenRecently = confirmations.recentConfirmation() != nil
        if spokenRecently {
            state.lostFor = 0
            state.consecutiveConfirmed += 1
            if state.consecutiveConfirmed >= 2 {
                state.uncertain = false
                overlay.showTrackingUncertain(false)
            }
            return
        }
        // Only a *prolonged* loss with speech arriving counts. A pause
        // mid-thought is the most normal thing in the world, and treating it as
        // a failure would make the mode unusable — which is the other thing
        // users complain about, and the more common of the two.
        guard voice.transcriptCount > 0 else { return }
        state.lostFor += delta
        guard state.lostFor > Self.trackingLossThreshold else { return }
        guard !state.uncertain else { return }
        state.uncertain = true
        state.consecutiveConfirmed = 0
        overlay.showTrackingUncertain(true)
    }

    /// The tracking state as a box, because this is written from the tick
    /// closure where `self` is captured immutably — the same reason the tick
    /// accumulators are not `@State`.
    private final class TrackingState: @unchecked Sendable {
        var lostFor: Double = 0
        var consecutiveConfirmed = 0
        var uncertain = false
    }
    private let trackingState = TrackingState()

    /// Long enough that a pause between sentences is not a failure, short
    /// enough that the presenter notices before they read past it.
    private static let trackingLossThreshold: Double = 1.6

    /// Hand the crossed slide cues to the sync layer, once, in order.
    ///
    /// A high-water mark rather than "the last one": a backwards jump must
    /// not re-fire everything the presenter rewound past — a re-read of
    /// slide 2 would drive the deck back to 2 while they are still talking
    /// about 5. A forward jump *does* fire, because after it the deck and
    /// the script genuinely disagree and the deck is the thing that should
    /// be corrected.
    private func fireCueTriggers() {
        guard !index.cuePlan.triggers.isEmpty else { return }
        let here = engine.currentWordIndex ?? 0
        guard here != tickState.lastTriggerWord else { return }
        let crossed = index.cuePlan.triggers(from: tickState.lastTriggerWord, to: here)
        tickState.lastTriggerWord = here
        guard !crossed.isEmpty else { return }
        slideSync.perform(crossed)
    }

    /// True when the recognizer produced text recently — the only proof of
    /// speech that noise can't fake.
    ///
    /// The one exception is a recognizer that has *never* delivered
    /// anything: then the level meter is all there is, and a prompter that
    /// refuses to move because transcription is broken is a worse failure
    /// than a VAD false positive. After the first transcript ever arrives,
    /// words are the only evidence that counts.
    private var spokeRecently: Bool {
        if let at = voice.lastWordDate {
            return Date().timeIntervalSince(at) < Self.wordEvidenceWindow
        }
        return voice.transcriptCount == 0 && voice.isSpeaking
    }

    /// True only while Play just started, the mic is actually alive, and
    /// it hasn't heard speech yet.
    private var micFallbackActive: Bool {
        guard let deadline = fallbackDeadline else { return false }
        return Date() < deadline
            && (voice.state == .listening || voice.state == .requesting)
            && !voice.speechSeenSincePlay
    }

    // MARK: - Smart Pause

    /// Accumulate silence/speech duration. Auto-pause when silence exceeds
    /// threshold; auto-resume when speech exceeds resume threshold.
    private func tickSmartPause(speaking: Bool, delta: Double) {
        let mode = settings.settings.smartPause
        if speaking {
            smartPause.silence = 0
            smartPause.speech += delta
            // Auto-resume: sustained speech after an auto-pause.
            if smartPause.didAutoPause,
               smartPause.speech >= mode.resumeThreshold {
                engine.play()
                smartPause.didAutoPause = false
                smartPause.speech = 0
                syncTicker()
                syncVoice()
            }
        } else {
            smartPause.speech = 0
            smartPause.silence += delta
            // Auto-pause: sustained silence.
            if !smartPause.didAutoPause,
               smartPause.silence >= mode.silenceThreshold {
                engine.pause(reason: .smartPause)
                smartPause.didAutoPause = true
                smartPause.silence = 0
                // Keep the ticker + mic alive: the auto-resume path needs
                // them to hear speech again while playback is stopped.
                syncTicker()
                syncVoice()
            }
        }
    }

    /// Note where the prompter is, and where voice last confirmed the reader
    /// was.
    ///
    /// Both are cheap and both are debounced by the store, so they can run on
    /// every tick. The point of this is an *unexpected* quit — a crash, a
    /// force-quit, a flat battery — so it has to be on the tick and not on a
    /// deliberate save.
    private func recordPlace() {
        guard let positions, let id = scripts.selectedID,
              let word = engine.currentWordIndex else { return }
        let total = index.wordTokenIndices.count
        if let confirmed = voice.recentConfirmation() {
            positions.recordConfirmedSpeech(wordIndex: confirmed, for: id, totalWords: total)
        } else {
            positions.record(ReadingPosition(wordIndex: word, totalWords: total), for: id)
        }
    }

    private func advance(_ progress: Double) {
        guard progress >= 1, !engine.isPlaying else { return }
        // The run is over. Rehearsal escalates on its own from here — it used
        // to be a documented behaviour with no call site anywhere, so the pass
        // only moved when the presenter clicked the chevron.
        practice?.advanceAfterRun()
        // This fires on every progress change (12-100 Hz), so the cheap
        // guard comes first and the script scan only on the final branch.
        // `liveScripts`, not `scripts`: the archive is not a queue. Walking
        // the full list auto-selected a talk the presenter had deliberately
        // put away — and because the list is ordered by most-recently-edited,
        // it was whichever archived script had been touched last.
        guard settings.settings.autoNextScript,
              let current = scripts.selectedID,
              let idx = scripts.liveScripts.firstIndex(where: { $0.id == current }),
              idx + 1 < scripts.liveScripts.count else {
            overlay.hide()
            return
        }
        let next = scripts.liveScripts[idx + 1].id
        // Do not touch the next talk's saved position: loading it here would
        // record word zero and erase where it was being read.
        positions?.forget(next)
        pick(next)
        // Play *after* the load, not before. `pick` publishes `selectedID`,
        // and the load that follows arrives in the next SwiftUI update pass
        // with `preservingPosition: false`, which stops playback. Calling
        // `play()` here was aimed at the *previous* script's words and was
        // undone a frame later, so "next script" meant "next script, loaded
        // and silent".
        Task { @MainActor in
            guard scripts.selectedID == next else { return }
            engine.play()
        }
    }

    /// Cue arrival. Timed cues hold playback for their duration; bare
    /// [pause]-family cues auto-pause when the setting is on.
    ///
    /// Forward-only: a jump *backwards* (a Previous Cue press, a restart,
    /// tapping an earlier word) re-entering a cue must not freeze the
    /// prompter on the way out of it. Starting playback on a cue does
    /// execute it — that's how `[pause 2s]` on the first line works — so
    /// the play transition passes `force`.
    private func handleCueArrival(_ word: Int?, force: Bool = false) {
        guard let idx = word else {
            lastCueArrival = nil
            return
        }
        // The mark moves *unconditionally*, so a backwards jump (restart,
        // Previous Cue, tapping an earlier word) both declines to re-fire the
        // cue it lands on and re-arms every cue after it. Without the
        // unconditional write, the mark would stay high and the rest of the
        // script would go un-cued for the rest of the run.
        let arriving = force || idx > (lastCueArrival ?? -1)
        lastCueArrival = idx
        // A soft stop is still a stop: a cue landing during the ease-out must
        // not cancel the pause the presenter just asked for.
        guard engine.isPlaying, !engine.isStopping, arriving else { return }
        let plan = index.cuePlan
        if let seconds = plan.holds[idx] {
            engine.hold(for: seconds)
            return
        }
        // Only an *arrival* auto-pauses. Re-running this on the play
        // transition (which `force` does, for a leading `[pause 2s]`) would
        // stop playback the instant the presenter pressed Play.
        if !force, settings.settings.pauseOnPauseCues, plan.pauses.contains(idx) {
            engine.pause(reason: .cue)
        }
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
        if (engine.isPlaying || smartPause.didAutoPause), voiceMode, !voice.isMutedByUser {
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
