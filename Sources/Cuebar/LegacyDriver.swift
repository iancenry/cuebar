import Foundation
import Speech
import AVFoundation
import PromptCore

/// SFSpeechRecognizer path: the legacy engine, available everywhere.
/// Needs the 50-second recycle plus retry armor because Apple ends these
/// tasks after ~60 seconds, and audio *may* leave the device. Kept as
/// the fallback for older macOS, unsupported locales, and anywhere the
/// on-device model can't be installed.
@MainActor
final class LegacyDriver: TranscriptionDriver {
    weak var events: TranscriptionEvents?
    private(set) var audioLevel = 0.0
    private(set) var isSpeaking = false
    var needsSpeechPermission: Bool { true }
    var displayName: String { "Legacy" }

    private var language = "en-US"
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var recycleWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private let vad = VoiceActivityDetector()

    private static let recycleInterval = 50.0
    private static let retryDelay = 0.5
    private static let maxRetries = 10

    func start(language: String) async -> Bool {
        self.language = language
        vad.reset()
        retryCount = 0
        guard ensureAudio() else { return false }
        guard startTask() else {
            stopAudio()
            return false
        }
        return true
    }

    func stop() {
        stopTask()
        stopAudio()
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
        return true
    }

    private func startTask() -> Bool {
        guard let audioEngine else { return false }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            return false
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        audioEngine.inputNode.removeTap(onBus: 0)
        Self.installTap(on: audioEngine.inputNode, request: request, vad: vad)
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
    /// runs on the realtime audio thread. The build proves it here —
    /// any actor touch inside becomes a compile error, not a SIGTRAP.
    nonisolated private static func installTap(on node: AVAudioInputNode,
                                               request: SFSpeechAudioBufferRecognitionRequest,
                                               vad: VoiceActivityDetector) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            request.append(buffer)
            vad.update(rms: VoiceActivityDetector.rms(of: buffer))
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

    /// Ends the task first, then the tap, then the audio — never
    /// append-after-endAudio (Apple sample order).
    private func stopTask() {
        recycleWork?.cancel()
        recycleWork = nil
        retryWork?.cancel()
        retryWork = nil
        task?.cancel()
        task = nil
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
    }

    private func stopAudio() {
        if let audioEngine {
            audioEngine.stop()
        }
        audioEngine = nil
    }
}
