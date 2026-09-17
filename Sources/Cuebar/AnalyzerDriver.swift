import Foundation
import Speech
import AVFoundation
import PromptCore

/// SpeechAnalyzer path (macOS 26+): fully on-device transcription with no
/// server fallback, no 60-second session limit, and volatile + finalized
/// result streams. Model assets download once via AssetInventory.
///
/// The mic tap follows Apple's canonical live-capture pattern: tap in the
/// node's own format, convert with an explicit AVAudioConverter into the
/// analyzer's preferred format. The tap is installed once per session and
/// never flaps — pinning it to a foreign format made the engine build its
/// own internal converter machinery whose teardown corrupted heap state
/// across stop/restart cycles.
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
        // Canonical live-capture wiring (Apple's sample): tap in the node's
        // native format, one converter built from that same format right
        // before the tap, conversion in the tap. Nothing actor-isolated is
        // captured — the closure runs on the realtime audio thread.
        let inputNode = audioEngine.inputNode
        let vad = self.vad
        let hardware = inputNode.outputFormat(forBus: 0)
        // The analyzer's format is a lower sample rate (typically 16 kHz vs
        // the mic's 48 kHz), so the conversion is a sample-rate conversion.
        // The single-buffer push variant of convert() explicitly cannot do
        // that and throws an uncatchable ObjC exception (_AVAE_Check); the
        // block-based pull variant is the documented path for it.
        guard let converter = AVAudioConverter(from: hardware, to: format) else {
            stop()
            return false
        }
        Self.installTap(on: inputNode, vad: vad, converter: converter, continuation: continuation)
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            return false
        }

        // Results are consumed off the main actor; only state updates hop.
        // Volatile results arrive dozens of times a second — running the
        // whole loop on the main actor churned main-actor job scheduling
        // for nothing.
        let onTranscript = self
        resultsTask = Task.detached { [weak onTranscript] in
            await onTranscript?.consumeResults(transcriber: transcriber)
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

    /// Nonisolated on purpose: the loop body (result iteration + string
    /// conversion) runs on the detached task's own executor; only state
    /// updates hop to the main actor. As a method of a @MainActor class
    /// it would otherwise pull the whole loop back onto the main actor.
    nonisolated private func consumeResults(transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                guard !Task.isCancelled else { return }
                let piece = String(result.text.characters)
                let isFinal = result.isFinal
                await MainActor.run { [weak self] in
                    self?.absorb(piece, isFinal: isFinal)
                }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.events?.failed("On-device transcription ended unexpectedly.")
            }
        }
    }

    private func absorb(_ piece: String, isFinal: Bool) {
        if isFinal {
            finalizedText = Self.appendFinal(finalizedText, piece)
            volatileText = ""
        } else {
            volatileText = piece
        }
        let combined = (finalizedText + " " + volatileText)
            .trimmingCharacters(in: .whitespaces)
        events?.transcript(combined)
    }

    /// Append a finalized segment, keeping the accumulator bounded. The
    /// transcript is only ever matched from the tail, so past a few KB the
    /// oldest text is dead weight — and the old O(session) string rebuild
    /// on every volatile result slowly ate the main thread.
    static func appendFinal(_ acc: String, _ text: String) -> String {
        var joined = acc.isEmpty ? text : acc + " " + text
        let maxChars = 2000
        guard joined.count > maxChars else { return joined }
        let cut = joined.index(joined.endIndex, offsetBy: -maxChars)
        if let space = joined[cut...].firstIndex(of: " ") {
            joined = String(joined[joined.index(after: space)...])
        } else {
            joined = String(joined[cut...])
        }
        return joined
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
                                               converter: AVAudioConverter,
                                               continuation: AsyncStream<AnalyzerInput>.Continuation) {
        // Pin the tap to the converter's own input format and allocate the
        // output buffer in the converter's own output format — the two
        // invariants convert() checks. The tap format is fixed at install
        // time, so tap buffers always match, route changes included.
        let inputFormat = converter.inputFormat
        let target = converter.outputFormat
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            vad.update(rms: VoiceActivityDetector.rms(of: buffer))
            guard buffer.format == inputFormat, buffer.frameLength > 0 else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            // Pull-style conversion: feed this one buffer, then signal end
            // of the current input so the converter flushes what it can.
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: out))
        }
    }
}
