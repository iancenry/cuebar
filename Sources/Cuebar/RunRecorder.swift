import Foundation
import Observation
import PromptCore

/// The app side of a rehearsal run: watch the engine, watch the mic, and
/// hand the samples to `RunReport` when the presenter stops.
///
/// Two things it deliberately does *not* own: the sampling cadence (the
/// playback ticker calls `sample` — it is the only loop already running, and
/// a second timer would only ever disagree with it) and the results UI.
/// Keeping the recorder a box of numbers means the report can be built for a
/// run that never touched the camera, the mic, or the network.
@MainActor
@Observable
final class RunRecorder {
    enum State: Equatable {
        case idle
        case recording
        /// Stopped, with a report to show.
        case finished
    }

    private(set) var state: State = .idle
    /// When the run started, so the HUD can keep its own clock. Deliberately
    /// *not* an observed "elapsed" property: an 8 Hz write to app-lifetime
    /// state repaints every observer of the recorder, and the only thing that
    /// needs a ticking number is one caption in one view.
    private(set) var startedAt: Date?
    private(set) var samples: [RunReport.Sample] = []
    private(set) var result: RunReport.Result?
    /// The movie, when a camera was available and the user allowed it.
    private(set) var recordingURL: URL?

    /// Whether this run is writing video. A run without one is still a full
    /// run: the report is the point, the clip is the souvenir.
    private(set) var isCapturingVideo = false
    private(set) var captureIssue: String?

    private var startDate: Date?
    private var capture: RunCapture?
    /// The last position and voice state the tick loop reported, so a
    /// heartbeat can say "still here, still not speaking" without reading the
    /// engine itself.
    private var lastWord: Int?
    private var lastSpeaking = false
    /// Bumped by every start and stop. `start()` and `stop()` are async at the
    /// edges (permissions, the camera, a delegate hop), so a run begun while
    /// the previous one is still stopping will get the *old* capture's answer
    /// a moment later — and write the previous rehearsal's clip into the new
    /// report. Anything that comes back late is compared against this and
    /// dropped.
    private var generation = 0
    /// Sampling cadence. A quarter second is fast enough to see a 0.75 s
    /// pause as a pause rather than a rounding error, and slow enough that a
    /// 45-minute rehearsal is 10 800 samples.
    static let sampleInterval: TimeInterval = 0.25

    var isRecording: Bool { state == .recording }

    /// What the current script is, so a run started from the transport (which
    /// knows nothing about the script) still reports against it. Set once per
    /// script by the view tree's lifecycle, next to `adopt`.
    var scriptWords = 0
    var scriptSections: [Int] = []

    /// Point the recorder at the script on stage.
    func describe(words: Int, sections: [ScriptSection]) {
        scriptWords = words
        scriptSections = sections.map(\.wordIndex)
    }

    /// The report sheet. Owned here because the recorder outlives the window:
    /// a run started, the window closed, the run stopped — the report still
    /// has somewhere to appear.
    var isShowingReport = false

    /// Start or stop, whichever is not happening.
    func toggle() {
        if isRecording { stop() } else { start() }
    }

    /// Start watching. `capture` decides whether video is possible.
    func start(capture: RunCapture? = RunCapture()) {
        guard state != .recording else { return }
        // A capture left over from a run that has already stopped would keep
        // the camera light on with nothing pointing at it.
        if let previous = self.capture, previous !== capture {
            Task { _ = await previous.stop() }
        }
        generation += 1
        let mine = generation
        samples = []
        result = nil
        recordingURL = nil
        captureIssue = nil
        startDate = Date()
        startedAt = startDate
        self.capture = capture
        state = .recording
        // Always take a sample at t=0 so a run that is stopped immediately
        // still reports its length rather than nothing.
        samples.append(RunReport.Sample(time: 0, word: nil, speaking: false))
        if let capture {
            Task { [weak self] in
                let started = await capture.start()
                guard let self, self.generation == mine else { return }
                // A capture that failed to start must not undo the run: the
                // telemetry is unaffected, and the HUD says why the clip is
                // missing.
                if started {
                    self.isCapturingVideo = true
                } else {
                    self.isCapturingVideo = false
                    self.captureIssue = capture.issue
                }
            }
        }
    }

    /// Called from the playback ticker, at its own cadence. Cheap when not
    /// recording: one comparison.
    func sample(word: Int?, speaking: Bool) {
        guard state == .recording, let startDate else { return }
        lastWord = word
        lastSpeaking = speaking
        append(time: now(after: startDate))
    }

    /// Record the passage of time when the tick loop is *not* running.
    ///
    /// The ticker only runs while something can change — playing, a live mic,
    /// a smart pause waiting to resume — so a rehearsed pause with the prompter
    /// stopped and the mic idle left the recorder with nothing at all. The
    /// clock froze mid-thought, the report came out short, and the pause the
    /// presenter most wants to know about (the one where they thought) was the
    /// one that vanished. A heartbeat repeats the last known position, which is
    /// exactly what a pause looks like from here: the same word, nobody
    /// speaking.
    ///
    /// It reads nothing: no second loop touches the engine, and it shares the
    /// same interval gate, so the two sources cannot interleave into a
    /// fabricated gap.
    func heartbeat() {
        guard state == .recording, let startDate else { return }
        append(time: now(after: startDate), word: lastWord, speaking: lastSpeaking)
    }

    private func now(after start: Date) -> TimeInterval {
        Date().timeIntervalSince(start)
    }

    private func append(time: TimeInterval, word: Int? = nil, speaking: Bool? = nil) {
        // `last?.time` rather than `samples[count - 1].time`: this runs at
        // 60 Hz, and an index that is only correct because of something
        // `start()` happens to do is an index that will crash the prompter the
        // day somebody tidies `start()`.
        guard time - (samples.last?.time ?? Self.sampleInterval) >= Self.sampleInterval else { return }
        samples.append(RunReport.Sample(time: time,
                                        word: word ?? lastWord,
                                        speaking: speaking ?? lastSpeaking))
    }

    /// Stop and build the report, then ask for it to be shown.
    @discardableResult
    func stop() -> RunReport.Result? {
        guard state == .recording else { return result }
        state = .finished
        // A capture still sitting on the permission prompt cannot be stopped —
        // it has not started a session — and it must not keep writing state
        // into a run that has ended. The generation bump below already drops
        // its late answer; this records why, for whoever reads the log next.
        if let capture, capture.isPending {
            captureIssue = capture.issue ?? "No clip: still waiting on the camera and "
                + "microphone permission."
        }
        generation += 1
        let mine = generation
        if let capture {
            let url = capture.url
            Task { [weak self] in
                let finished = await capture.stop()
                // A newer run owns the state now; this clip belongs to a
                // rehearsal that is already over.
                guard let self, self.generation == mine else { return }
                self.isCapturingVideo = false
                self.recordingURL = finished ? url : nil
            }
        }
        let report = RunReport.result(samples: samples,
                                      totalWords: scriptWords,
                                      sectionStarts: scriptSections)
        result = report
        isShowingReport = true
        return report
    }

    func dismissReport() {
        isShowingReport = false
    }

    /// The window went away mid-run. Stop rather than leave the camera
    /// recording with no UI to stop it — a rehearsal tool that keeps the
    /// indicator light on after its window closed is the kind of bug that
    /// gets an app uninstalled.
    func stopIfRecording() {
        guard isRecording else { return }
        stop()
        // Nothing is going to show the report.
        isShowingReport = false
    }

    /// Throw the report away and stand down for the next run.
    func reset() {
        state = .idle
        startedAt = nil
        samples = []
        result = nil
        recordingURL = nil
        captureIssue = nil
        capture = nil
    }

}
