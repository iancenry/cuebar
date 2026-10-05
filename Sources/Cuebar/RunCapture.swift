import AVFoundation
import Foundation
import PromptCore

/// Camera + microphone to a file, for a rehearsal you want to watch back.
///
/// It is a *souvenir*, not a dependency: every failure path here ends with a
/// run that still reports. A presenter who denies the camera gets the same
/// rehearsal data as one who granted it, which is why nothing in
/// `RunRecorder` waits on this class.
///
/// @MainActor for the same reason the drivers are: the session is configured
/// and started here, on the actor that owns it, with no cross-queue hops to
/// get wrong. `startRunning()` does block the main thread for a few hundred
/// milliseconds, exactly as the audio engine's `start()` already does when a
/// mic opens — a rehearsal is a deliberate action, not something happening
/// while someone types.
@MainActor
final class RunCapture: NSObject {
    /// Why the clip isn't being written, in the presenter's language. `nil`
    /// while everything is fine.
    private(set) var issue: String?

    let url: URL
    /// True from `start()` until the capture has actually begun or given up.
    /// A run stopped in that window cannot stop the session — there is none.
    private(set) var isPending = false
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    /// One latch per wait, because there can be *two* waits open at once.
    ///
    /// This started as a single `pending` slot with a phase tag, and it leaked:
    /// Stop pressed while Start was still waiting overwrote the slot, so the
    /// starting continuation was dropped on the floor and never resumed —
    /// `start()` suspended forever, the awaiting Task leaked, and the camera
    /// stayed open. Swift's runtime says so outright: "SWIFT TASK CONTINUATION
    /// MISUSE: leaked its continuation without resuming it." Verified with a
    /// harness of the old and new shapes before this shape was adopted.
    ///
    /// Two slots, each nil'd the moment it is resumed: a finish answers both
    /// (it is the definitive answer to "did it start?" as well as "did it
    /// stop?"), a late reply after a timeout finds its slot empty and does
    /// nothing, and resuming a continuation twice is impossible.
    private var starting: CheckedContinuation<Bool, Never>?
    private var stopping: CheckedContinuation<Bool, Never>?
    /// The delegate callbacks arrive on the capture queue; they hop back
    /// explicitly rather than assuming isolation.
    private let queue = DispatchQueue(label: "cuebar.run.capture")

    override init() {
        url = RunCaptureFolder.freshDestination(
            named: "Rehearsal \(RunCapture.timestamp()).mov")
        super.init()
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// Ask for permission, configure, and start writing. Never throws and
    /// never hangs: a capture that has not reported within a few seconds is
    /// treated as not started.
    func start() async -> Bool {
        isPending = true
        defer { isPending = false }
        guard await authorize() else { return false }
        // Both failure-capable steps happen *here*, where the error can be
        // reported: inside the continuation closure below there is nowhere to
        // throw to, and a `try!` in a capture path is a crash waiting for the
        // one run whose file could not be created.
        let target: URL
        do {
            try configure()
            target = try recordingURL()
        } catch {
            issue = "No clip: \(error.localizedDescription)"
            return false
        }
        // The latch goes in *before* the device call. `didStartRecordingTo`
        // arrives on the capture queue and hops to the main actor, and that
        // hop can complete before the next line of this function runs — so a
        // continuation installed afterwards never sees the answer, and the
        // run reports "the camera never started" on a session that is
        // recording perfectly.
        let began = await withCheckedContinuation { continuation in
            starting = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.settleStart(false)
            }
            // `startRunning()` blocks for as long as it takes to spin the
            // sensor up, and it must not be called from `start()`. On the main
            // actor that is a multi-hundred-millisecond stall inside a display
            // cycle; on a laptop with the lid half closed it can be seconds.
            // The box carries the two non-Sendable AVFoundation objects to the
            // queue that owns them, and the delegate still hops back here.
            let box = SessionBox(session: session, output: output)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                // Session first, then recording — the order Apple's sample
                // code uses, and the one AVFoundation expects.
                box.session.startRunning()
                box.output.startRecording(to: target, recordingDelegate: self)
            }
        }
        if !began, issue == nil { issue = "No clip: the camera never started." }
        return began
    }

    /// Stop writing. `true` when a playable file was left behind.
    func stop() async -> Bool {
        guard session.isRunning else { return false }
        let finished = await withCheckedContinuation { continuation in
            stopping = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.settleStop(false)
            }
            let box = SessionBox(session: session, output: output)
            DispatchQueue.global(qos: .userInitiated).async {
                box.session.stopRunning()
                box.output.stopRecording()
            }
        }
        guard finished else { return false }
        // A zero-byte .mov opens to nothing: the file exists, the clip does
        // not. Offering "Reveal in Finder" on one is worse than no button.
        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        return size > 0
    }

    private func settleStart(_ value: Bool) {
        guard let continuation = starting else { return }
        starting = nil
        continuation.resume(returning: value)
    }

    private func settleStop(_ value: Bool) {
        guard let continuation = stopping else { return }
        stopping = nil
        continuation.resume(returning: value)
    }

    /// A recording that finished answers both waits: it is the definitive
    /// answer to "did it start?" as well as "did it stop?", and Stop-during-
    /// Start leaves the first one still open.
    private func settleFinished(_ value: Bool) {
        settleStart(value)
        settleStop(value)
    }

    /// startRecording wants a URL that does not exist yet; a previous run's
    /// file at the same name (two rehearsals in the same second) would fail
    /// the whole start.
    /// The destination, guaranteed **not** to exist.
    ///
    /// It must not exist. `startRecording(to:recordingDelegate:)` raises an
    /// Objective-C exception when the file is already there, and an exception
    /// on any thread is an unconditional `abort()` — so this method created a
    /// zero-byte file, deleted the stale one, and then handed the path to
    /// AVFoundation, which threw and killed the app:
    ///
    ///     objc_exception_throw
    ///     -[AVCaptureMovieFileOutput_Tundra startRecordingToOutputFileURL:recordingDelegate:]
    ///     Cuebar  closure #2 in closure #1 in RunCapture.start()
    ///
    /// Only the *directory* is created. AVFoundation creates the file.
    private func recordingURL() throws -> URL {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            // Two rehearsals inside the same second would otherwise collide.
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw CaptureError(.cannotWrite)
            }
        }
        return url
    }

    /// Ask for permission, off the main actor.
    ///
    /// `AVCaptureDevice.requestAccess` may put a system dialog on screen and
    /// block until it is answered, and Apple's guidance is not to call it from
    /// the main thread. Cuebar *is* a main-actor object, so the call was being
    /// made from inside the display cycle — the same place the practice-mode
    /// crash threw an Objective-C exception, and the same shape of mistake:
    /// a framework call that can present UI, made from the thread that is
    /// running AppKit's layout. Two of them were issued in parallel, so macOS
    /// queued two prompts behind each other.
    private nonisolated func requestAccessOffMain(for media: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                AVCaptureDevice.requestAccess(for: media) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func authorize() async -> Bool {
        let video = AVCaptureDevice.authorizationStatus(for: .video)
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if video == .denied || microphone == .denied {
            issue = video == .denied
                ? "No clip: camera access is off for Cuebar in System Settings."
                : "No clip: microphone access is off for Cuebar in System Settings."
            return false
        }
        // Both prompts at once: macOS queues them, and asking one at a time
        // means the second waits behind the first sheet being dismissed.
        async let videoOK: Bool = video == .authorized
            ? true
            : requestAccessOffMain(for: .video)
        async let audioOK: Bool = microphone == .authorized
            ? true
            : requestAccessOffMain(for: .audio)
        let (v, a) = await (videoOK, audioOK)
        if !v, !a {
            issue = "No clip: Cuebar needs the camera to record a rehearsal."
            return false
        }
        if !v { issue = "Video off — recording audio only." }
        if !a { issue = "Audio off — recording video only." }
        return true
    }

    private func configure() throws {
        if session.inputs.isEmpty {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .high
            var added = 0
            if let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video, position: .unspecified),
               let input = try? AVCaptureDeviceInput(device: camera),
               session.canAddInput(input) {
                session.addInput(input)
                added += 1
            }
            if let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
                added += 1
            }
            // The verdict comes from `CapturePlan`, not from a guard written
            // here: an earlier version of this line read
            // `guard session.inputs.isEmpty else { throw .noInput }`, which
            // threw on every *successful* configuration. See CapturePlanTests.
            if let failure = CapturePlan.failure(inputsAdded: added,
                                                 canAddOutput: session.canAddOutput(output)) {
                throw CaptureError(failure)
            }
            session.addOutput(output)
        }
    }

    struct CaptureError: LocalizedError {
        let failure: CapturePlan.Failure
        init(_ failure: CapturePlan.Failure) { self.failure = failure }
        var errorDescription: String? { CapturePlan.message(for: failure) }
    }
}

/// Carries the session and the output to the queue that drives them.
///
/// `AVCaptureSession` is not `Sendable` and must not be started or stopped
/// from two places at once; the box is the honest way to say "one queue owns
/// these, and it is not the main one". Same shape as the audio driver's
/// request box.
private final class SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    let output: AVCaptureMovieFileOutput
    init(session: AVCaptureSession, output: AVCaptureMovieFileOutput) {
        self.session = session
        self.output = output
    }
}

// MARK: - Movie output

extension RunCapture: AVCaptureFileOutputRecordingDelegate {
    /// These arrive on the capture queue, not on the main actor — and a
    /// `@Sendable` closure is not an isolation guarantee (see AGENTS.md), so
    /// the hop is explicit rather than inferred.
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection]) {
        queue.async { Task { @MainActor in self.settleStart(true) } }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        let playable = error == nil
            && FileManager.default.fileExists(atPath: outputFileURL.path)
        queue.async { Task { @MainActor in self.settleFinished(playable) } }
    }
}