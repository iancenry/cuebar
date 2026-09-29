import Foundation
import AVFoundation

/// Contract for transcription back ends. VoiceTracker orchestrates
/// (permissions, state, matching); drivers own audio capture and the
/// recognition session. Two implementations: LegacyDriver
/// (SFSpeechRecognizer, everywhere) and AnalyzerDriver (SpeechAnalyzer,
/// macOS 26+, fully on-device).
@MainActor
protocol TranscriptionDriver: AnyObject {
    var events: TranscriptionEvents? { get set }
    var audioLevel: Double { get }
    var isSpeaking: Bool { get }
    var needsSpeechPermission: Bool { get }
    var displayName: String { get }
    func start(language: String) async -> Bool
    func stop()
    func resetTranscript()
    func poll()
}

/// Driver -> tracker callbacks. Implemented by VoiceTracker.
@MainActor
protocol TranscriptionEvents: AnyObject {
    func transcript(_ text: String)
    func failed(_ message: String)
}

/// Adaptive voice-activity detector shared by both drivers. Runs on the
/// audio tap thread under a lock; the owning driver polls snapshots at
/// ticker rate. A plain class on purpose: tap closures are nonisolated.
/// The lock guards every mutable field, which is the documented contract
/// for the unchecked Sendable conformance below.
final class VoiceActivityDetector: @unchecked Sendable {
    /// Noise floor bounds. The ceiling is the important one: it is well
    /// below the level of speech, so a loud room can never raise the bar
    /// until normal talking fails to trip it.
    private static let floorFloor: Double = 0.002
    private static let floorCeiling: Double = 0.03
    /// Rise rate per *sample*. The old 0.0005 adapted at ~24/s at 48 kHz,
    /// which meant a single bang pushed the floor past the level of
    /// ordinary speech in milliseconds and the detector stayed deaf for
    /// the rest of the session — the presenter drumming on the desk
    /// silenced their own prompter. A floor should creep, not sprint.
    private static let floorRiseRate: Double = 0.00002

    private let lock = NSLock()
    private var smoothed = 0.0
    private var floor = 0.02
    private var silenceTicks = 0
    private var wasSpeaking = false

    func update(rms: Double) {
        lock.withLock {
            guard rms.isFinite else { return }
            smoothed = smoothed * 0.7 + min(rms, 1.0) * 0.3
            if rms < floor {
                floor = max(Self.floorFloor, rms)
            } else {
                floor = min(Self.floorCeiling,
                            floor + (rms - floor) * Self.floorRiseRate)
            }
        }
    }

    /// Called at ~8 Hz. Hangover keeps `speaking` true briefly through
    /// natural word gaps so scrolling doesn't stutter.
    func snapshot() -> (level: Double, speaking: Bool) {
        lock.withLock {
            let threshold = max(0.012, floor * 2.5)
            if smoothed > threshold {
                silenceTicks = 0
                wasSpeaking = true
            } else {
                silenceTicks += 1
                if silenceTicks > 3 {
                    wasSpeaking = false
                }
            }
            return (min(1, smoothed * 4), wasSpeaking)
        }
    }

    func reset() {
        lock.withLock {
            smoothed = 0
            floor = Self.floorFloor
            silenceTicks = 0
            wasSpeaking = false
        }
    }

    /// Real-time safe: plain math on the tap buffer.
    static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channel = data[0]
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0 ..< n {
            sum += channel[i] * channel[i]
        }
        return Double(sqrt(sum / Float(n)))
    }
}
