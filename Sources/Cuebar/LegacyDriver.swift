import Foundation
import Speech
import AVFoundation
import PromptCore

/// SFSpeechRecognizer path: the legacy engine, available everywhere.
/// Needs the 50-second recycle plus retry armor because Apple ends these
/// tasks after ~60 seconds, and audio *may* leave the device. Kept as
/// the fallback for older macOS, unsupported locales, and anywhere the
/// on-device model can't be installed.
///
/// The tap and the audio engine are installed once per session and stay
/// put: recycles and retries swap only the recognition *request* (via a
/// lock-guarded box the tap reads). Tearing down and reinstalling the tap
/// every 50 s churned Apple's internal dispatch machinery on the realtime
/// path — the last thing a heap wants.
@MainActor
final class LegacyDriver: TranscriptionDriver {
    weak var events: TranscriptionEvents?
    private(set) var audioLevel = 0.0
    private(set) var isSpeaking = false
    var needsSpeechPermission: Bool { true }
    var displayName: String { "Legacy" }

    private var language = "en-US"
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var recycleWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var tapInstalled = false
    private let vad = VoiceActivityDetector()
    private let currentRequest = CurrentRequestBox()

    private static let recycleInterval = 50.0
    private static let retryDelay = 0.5
    private static let maxRetries = 10

    func start(language: String) async -> Bool {
        self.language = language
        vad.reset()
        retryCount = 0
        guard ensureAudio() else { return false }
        guard startTask() else {
            return false
        }
        return true
    }

    func stop() {
        stopTask()
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil
        tapInstalled = false
        vad.reset()
        audioLevel = 0
        isSpeaking = false
    }

    /// Script text changed: restart recognition without touching the
    /// microphone — no audible gap while typing in Edit mode.
    func resetTranscript() {
        stopTask()
        _ = startTask()
    }

    func poll() {
        let snapshot = vad.snapshot()
        audioLevel = snapshot.level
        isSpeaking = snapshot.speaking
    }

    /// Idempotent: a running engine survives recycles and retries.
    /// Installs the tap exactly once for the lifetime of the engine.
    private func ensureAudio() -> Bool {
        if audioEngine != nil { return true }
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            self.audioEngine = nil
            return false
        }
        if !tapInstalled {
            let vad = self.vad
            let box = self.currentRequest
            Self.installTap(on: audioEngine.inputNode, vad: vad, box: box)
            tapInstalled = true
        }
        return true
    }

    private func startTask() -> Bool {
        guard audioEngine != nil else { return false }
        guard let recognizer = Self.recognizer(for: language) else {
            return false
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        currentRequest.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString ?? ""
            let nsError = error as NSError?
            Task { @MainActor [weak self] in
                self?.handle(transcript: transcript, error: nsError)
            }
        }
        scheduleRecycle()
        return true
    }

    /// Nonisolated for the same reason as the analyzer's tap: the closure
    /// runs on the realtime audio thread. Any actor touch inside becomes
    /// a compile error, not a runtime trap.
    nonisolated private static func installTap(on node: AVAudioInputNode,
                                               vad: VoiceActivityDetector,
                                               box: CurrentRequestBox) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            vad.update(rms: VoiceActivityDetector.rms(of: buffer))
            if let request = box.get() {
                request.append(buffer)
            }
        }
    }

    private func handle(transcript: String, error: NSError?) {
        if let error {
            handleError(error)
            return
        }
        guard !transcript.isEmpty else { return }
        retryCount = 0
        events?.transcript(transcript)
    }

    private func handleError(_ error: NSError) {
        // Apple's end-of-session timeouts arrive as assistant-domain
        // errors; treat them as a normal recycle, not a failure.
        if error.domain == "kAFAssistantErrorDomain", [1110, 216, 203].contains(error.code) {
            resetTranscript()
            return
        }
        retryCount += 1
        guard retryCount <= Self.maxRetries else {
            stopTask()
            events?.failed(error.localizedDescription)
            return
        }
        stopTask()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.resetTranscript()
            }
        }
        retryWork?.cancel()
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
    }

    private func scheduleRecycle() {
        recycleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.resetTranscript() }
        }
        recycleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recycleInterval, execute: work)
    }

    /// Ends the task first, then the request — never touch the tap. The
    /// mic keeps flowing (VAD stays live); only the recognition task and
    /// request are replaced.
    private func stopTask() {
        recycleWork?.cancel()
        recycleWork = nil
        retryWork?.cancel()
        retryWork = nil
        if let request = currentRequest.get() {
            currentRequest.set(nil)
            request.endAudio()
        }
        task?.cancel()
        task = nil
    }

    /// One recognizer per language, reused across the ~50 s session
    /// recycles. Creating SFSpeechRecognizer kicks off model loading —
    /// rebuilding it on every recycle used to add a latency spike (and a
    /// fresh asset load) each time the session rolled over.
    private static var recognizerCache: [String: SFSpeechRecognizer] = [:]
    private static func recognizer(for language: String) -> SFSpeechRecognizer? {
        if let cached = recognizerCache[language] { return cached }
        let fresh = SFSpeechRecognizer(locale: Locale(identifier: language))
        if let fresh { recognizerCache[language] = fresh }
        return fresh
    }
}

/// Lock-guarded current-request holder the realtime tap reads. The tap is
/// installed once and must never be reinstalled, so request swaps go
/// through this box instead.
private final class CurrentRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { self.request = request }
    }

    func get() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.withLock { request }
    }
}
