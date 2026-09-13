import Foundation
import Observation
import Speech
import AVFoundation
import PromptCore

/// Voice orchestration: permissions, driver selection, transcript
/// matching, published mic state. Audio capture and recognition live in
/// the drivers (LegacyDriver / AnalyzerDriver); this stays thin.
///
/// Driver choice comes from Settings → Guidance → Engine:
/// automatic tries the on-device model first and falls back to legacy.
@MainActor
@Observable
final class VoiceTracker {
    enum State: Equatable {
        case idle
        case requesting
        case listening
        case stopped
        case denied
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var audioLevel = 0.0
    private(set) var isSpeaking = false
    private(set) var lastTranscript = ""
    private(set) var driverName = ""
    /// Recent input levels (~6 s at the 8 Hz ticker) for the waveform.
    /// Appends flat zeros when idle so the wave settles instead of freezing.
    private(set) var levelHistory: [Double] = Array(repeating: 0, count: 48)

    var language = "en-US"

    private var driver: (any TranscriptionDriver)?
    private weak var engine: PromptEngine?

    func start(engine: PromptEngine, preferred: CueSettings.TranscriptionEngine) async {
        self.engine = engine
        guard state != .listening, state != .requesting else { return }
        state = .requesting
        guard await Self.requestMicPermission() else {
            state = .denied
            return
        }
        if preferred != .legacy, #available(macOS 26, *) {
            let analyzer = AnalyzerDriver()
            analyzer.events = self
            if await analyzer.start(language: language) {
                driver = analyzer
                driverName = analyzer.displayName
                state = .listening
                return
            }
            if preferred == .onDevice {
                state = .error("On-device model unavailable for \(language).")
                return
            }
        } else if preferred == .onDevice {
            state = .error("On-device transcription needs macOS 26.")
            return
        }
        let legacy = LegacyDriver()
        legacy.events = self
        if legacy.needsSpeechPermission {
            guard await Self.requestSpeechPermission() else {
                state = .denied
                return
            }
        }
        guard await legacy.start(language: language) else {
            state = .error("Couldn't start speech recognition for \(language).")
            return
        }
        driver = legacy
        driverName = legacy.displayName
        state = .listening
    }

    func stop() {
        driver?.stop()
        driver = nil
        engine = nil
        driverName = ""
        audioLevel = 0
        isSpeaking = false
        if state == .listening || state == .requesting {
            state = .stopped
        }
    }

    /// Restart session state after a script change. Matching resumes from
    /// the current position; nothing jumps back.
    func recycle() {
        driver?.resetTranscript()
    }

    /// Called from the 8 Hz app ticker: refresh the published VAD state.
    func pollVoice() {
        guard state == .listening, let driver else {
            audioLevel = 0
            isSpeaking = false
            pushLevel(0)
            return
        }
        driver.poll()
        audioLevel = driver.audioLevel
        isSpeaking = driver.isSpeaking
        pushLevel(audioLevel)
    }

    private func pushLevel(_ level: Double) {
        levelHistory.append(level)
        if levelHistory.count > 48 {
            levelHistory.removeFirst(levelHistory.count - 48)
        }
    }

    // MARK: - Permissions (completion APIs wrapped; no version doubt)

    private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

extension VoiceTracker: TranscriptionEvents {
    func transcript(_ text: String) {
        guard state == .listening else { return }
        lastTranscript = text
        guard let engine, !text.isEmpty else { return }
        if let end = SpeechMatcher.matchEnd(transcript: text,
                                            words: engine.words,
                                            fromWordIndex: engine.currentWordIndex ?? 0) {
            engine.confirmReadThroughWord(end)
        }
    }

    func failed(_ message: String) {
        guard state == .listening || state == .requesting else { return }
        driver?.stop()
        driver = nil
        driverName = ""
        state = .error(message)
    }
}
