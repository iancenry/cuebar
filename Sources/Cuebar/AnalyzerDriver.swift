import Foundation
import Speech
import AVFoundation
import PromptCore

/// SpeechAnalyzer path (macOS 26+): fully on-device transcription with no
/// server fallback, no 60-second session limit, and volatile + finalized
/// result streams. Model assets download once via AssetInventory.
///
/// Because sessions are long-lived, `resetTranscript` only clears the
/// accumulated text — no teardown, no mic gap, unlike the legacy driver.
@available(macOS 26, *)
@MainActor
final class AnalyzerDriver: TranscriptionDriver {
    weak var events: TranscriptionEvents?
    private(set) var audioLevel = 0.0
    private(set) var isSpeaking = false
    var needsSpeechPermission: Bool { false }
    var displayName: String { "On-device" }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var inputTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var finalizedText = ""
    private var volatileText = ""
    private let vad = VoiceActivityDetector()

    func start(language: String) async -> Bool {
        let locale = Locale(identifier: language)
        finalizedText = ""
        volatileText = ""
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return false
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber
        guard await ensureAssets(for: transcriber) else { return false }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return false
        }
        self.targetFormat = format
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            return false
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        inputTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch is CancellationError {
            } catch {
                self?.events?.failed("On-device transcription failed to start.")
            }
        }

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        let hardware = inputNode.outputFormat(forBus: 0)
        if hardware.sampleRate != format.sampleRate
            || hardware.channelCount != format.channelCount
            || hardware.commonFormat != format.commonFormat {
            converter = AVAudioConverter(from: hardware, to: format)
        }
        let vad = self.vad
        Self.installTap(on: inputNode, vad: vad, converter: converter,
                        target: format, continuation: continuation)
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            return false
        }

        resultsTask = Task { [weak self] in
            await self?.consumeResults()
        }
        return true
    }

    func stop() {
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputTask?.cancel()
        inputTask = nil
        if let analyzer {
            let running = analyzer
            Task { await running.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        converter = nil
        finalizedText = ""
        volatileText = ""
        vad.reset()
        audioLevel = 0
        isSpeaking = false
    }

    func resetTranscript() {
        finalizedText = ""
        volatileText = ""
    }

    func poll() {
        let snapshot = vad.snapshot()
        audioLevel = snapshot.level
        isSpeaking = snapshot.speaking
    }

    private func consumeResults() async {
        guard let transcriber else { return }
        do {
            for try await result in transcriber.results {
                guard !Task.isCancelled else { return }
                if result.isFinal {
                    let text = String(result.text.characters)
                    finalizedText += finalizedText.isEmpty ? text : " " + text
                    volatileText = ""
                } else {
                    volatileText = String(result.text.characters)
                }
                let combined = (finalizedText + " " + volatileText)
                    .trimmingCharacters(in: .whitespaces)
                events?.transcript(combined)
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            events?.failed("On-device transcription ended unexpectedly.")
        }
    }

    private func ensureAssets(for transcriber: SpeechTranscriber) async -> Bool {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { return true }
        guard status != .unsupported else { return false }
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return false
        }
        do {
            try await request.downloadAndInstall()
            return true
        } catch {
            return false
        }
    }

    /// Tap installation lives in a nonisolated context on purpose: the
    /// closure runs on Apple's realtime audio thread, and anything
    /// MainActor-isolated in here traps at runtime instead of erroring
    /// at build time. If this function ever touches the actor, the
    /// build breaks — which is exactly the guarantee we want.
    nonisolated private static func installTap(on node: AVAudioInputNode,
                                               vad: VoiceActivityDetector,
                                               converter: AVAudioConverter?,
                                               target: AVAudioFormat,
                                               continuation: AsyncStream<AnalyzerInput>.Continuation) {
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            vad.update(rms: VoiceActivityDetector.rms(of: buffer))
            var outgoing: AVAudioPCMBuffer? = buffer
            if let converter {
                outgoing = convert(buffer, converter: converter, target: target)
            }
            if let outgoing {
                continuation.yield(AnalyzerInput(buffer: outgoing))
            }
        }
    }

    /// Explicitly nonisolated: called from the realtime audio thread.
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer,
                                            converter: AVAudioConverter,
                                            target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard capacity > 16,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        do {
            try converter.convert(to: out, from: buffer)
            return out
        } catch {
            return nil
        }
    }
}
