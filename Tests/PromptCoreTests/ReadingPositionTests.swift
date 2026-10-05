import Testing
import Foundation
@testable import PromptCore

/// "Never lose your place" is the feature that makes a teleprompter feel like
/// an instrument. Three positions, not one, because they answer different
/// questions — and the restore rules are where it goes wrong: a position from a
/// longer script opens a blank screen, and a slow writer must never undo a jump
/// the presenter just made.
@MainActor
@Suite struct ReadingPositionTests {
    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-positions-\(UUID().uuidString).json")
    }

    @Test func aPositionIsRestorableIntoTheSameScript() {
        let position = ReadingPosition(wordIndex: 340, totalWords: 800)
        #expect(position.isRestorable(into: 800))
        #expect(position.resumeIndex(into: 800) == 340)
    }

    /// A talk edited shorter while Cuebar was closed. Restoring 700 into a
    /// 120-word script is a blank prompter with no explanation.
    @Test func aPositionFromALongerScriptIsNotRestored() {
        let position = ReadingPosition(wordIndex: 700, totalWords: 800)
        #expect(!position.isRestorable(into: 120))
        #expect(position.resumeIndex(into: 120) == nil)
    }

    /// Reordered or lightly edited: close enough that the place is still the
    /// place. Rejecting these would make the feature feel broken after any edit.
    @Test func aLightEditStillRestores() {
        let position = ReadingPosition(wordIndex: 340, totalWords: 800)
        #expect(position.isRestorable(into: 812))
        #expect(position.isRestorable(into: 790))
    }

    @Test func theStartOfAScriptIsNotAPosition() {
        #expect(!ReadingPosition(wordIndex: 0, totalWords: 800).isRestorable(into: 800))
        #expect(!ReadingPosition(wordIndex: 800, totalWords: 800).isRestorable(into: 800))
    }

    @Test func positionsPersistAndReload() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let store = PositionStore(url: url)
        store.record(ReadingPosition(wordIndex: 42, totalWords: 100), for: id)
        store.saveNow()

        let reopened = PositionStore(url: url)
        #expect(reopened.position(for: id)?.wordIndex == 42)
    }

    /// A position from a slower writer must not rewind a jump the presenter just
    /// made — the symptom would be the prompter snapping back as they speak.
    @Test func aLatePositionNeverMovesTheReaderBackwards() {
        let id = UUID()
        let store = PositionStore(url: temporaryURL())
        store.record(ReadingPosition(wordIndex: 500, totalWords: 900), for: id)
        store.record(ReadingPosition(wordIndex: 120, updatedAt: Date(timeIntervalSinceNow: -5),
                                     totalWords: 900), for: id)
        #expect(store.position(for: id)?.wordIndex == 500)
    }

    @Test func theThreePositionsAreKeptApart() {
        let id = UUID()
        let store = PositionStore(url: temporaryURL())
        store.record(ReadingPosition(wordIndex: 100, totalWords: 500), for: id)
        store.recordConfirmedSpeech(wordIndex: 96, for: id, totalWords: 500)
        store.recordManualView(wordIndex: 40, for: id, totalWords: 500)
        let position = store.position(for: id)
        // Voice never rewinds the prompter (a late transcript word must not pull
        // the reader backwards), but a manual jump does move it — the presenter
        // asked for that word.
        #expect(position?.spokenIndex == 96)
        #expect(position?.viewedIndex == 40)
        #expect(position?.wordIndex == 40)
        #expect(store.position(for: id)?.totalWords == 500)
    }

    /// A script the presenter left halfway through is the one a fresh launch
    /// should reopen — ordered by when it was *touched*, not by its file date.
    @Test func theMostRecentlyReadScriptIsRecoverable() {
        let a = UUID(), b = UUID()
        let store = PositionStore(url: temporaryURL())
        store.record(ReadingPosition(wordIndex: 10, updatedAt: Date(timeIntervalSinceNow: -60),
                                      totalWords: 100), for: a)
        store.record(ReadingPosition(wordIndex: 20, updatedAt: Date(timeIntervalSinceNow: -5),
                                      totalWords: 100), for: b)
        #expect(store.mostRecent?.id == b)
    }

    /// The debounce must be short enough to matter. The whole point is
    /// surviving an *unexpected* quit, so the worst case is about a second of
    /// position, not a minute of it.
    @Test func aCrashLosesAtMostAboutASecond() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let store = PositionStore(url: url)
        store.record(ReadingPosition(wordIndex: 7, totalWords: 50), for: id)
        try await Task.sleep(for: .milliseconds(1600))
        #expect(PositionStore(url: url).position(for: id)?.wordIndex == 7,
                "an unexpected quit lost more than the coalesce window")
    }

    @Test func forgettingAScriptRemovesIt() {
        let id = UUID()
        let store = PositionStore(url: temporaryURL())
        store.record(ReadingPosition(wordIndex: 7, totalWords: 50), for: id)
        store.forget(id)
        #expect(store.position(for: id) == nil)
    }
}

/// The tracking safety net's decision rule, as a pure function so it can be
/// tested without a microphone.
///
/// Research drove the shape of this: a prompter that jumps is the most-reported
/// failure in the product class, and uncertainty has to resolve to *stopping*.
/// A presenter pause mid-sentence is the most normal event there is, so a short
/// gap is never a loss — that is the other complaint, and the more common one.
@Suite struct TrackingUncertaintyTests {
    /// Mirrors the driver's rule exactly. In the app it is a 60 Hz tick; here
    /// it is called with explicit deltas.
    struct Machine {
        static let lossThreshold: Double = 1.6
        var lostFor: Double = 0
        var consecutiveConfirmed = 0
        var uncertain = false

        /// - Parameters:
        ///   - confirmed: the matcher confirmed a chain on this tick.
        ///   - heardSpeech: the recogniser has delivered words at all. With no
        ///     transcript ever, a frozen prompter is the worse failure — that
        ///     rule lives in the driver, not here.
        mutating func tick(delta: Double, confirmed: Bool, heardSpeech: Bool) {
            if confirmed {
                lostFor = 0
                consecutiveConfirmed += 1
                if consecutiveConfirmed >= 2 { uncertain = false }
                return
            }
            guard heardSpeech else { return }
            lostFor += delta
            guard lostFor > Machine.lossThreshold, !uncertain else { return }
            uncertain = true
            consecutiveConfirmed = 0
        }
    }

    @Test func aPauseBetweenSentencesIsNotAFailure() {
        var machine = Machine()
        // 1.5s of silence: a breath, not a loss.
        machine.tick(delta: 1.5, confirmed: false, heardSpeech: true)
        #expect(!machine.uncertain)
        // …and it resumes without a false alarm having been raised.
        machine.tick(delta: 0.1, confirmed: true, heardSpeech: true)
        machine.tick(delta: 0.1, confirmed: true, heardSpeech: true)
        #expect(!machine.uncertain)

    }

    @Test func aProlongedLossStopsAndSaysSo() {
        var machine = Machine()
        for _ in 0..<40 { machine.tick(delta: 0.1, confirmed: false, heardSpeech: true) }
        #expect(machine.uncertain)
        // …and it stays raised rather than flickering on every tick.
        for _ in 0..<20 { machine.tick(delta: 0.1, confirmed: false, heardSpeech: true) }
        #expect(machine.uncertain)
    }

    /// Two confirmations to re-arm, so one stray match cannot flip the state
    /// back and forth while the presenter is talking.
    @Test func twoConfirmationsRearm() {
        var machine = Machine()
        for _ in 0..<40 { machine.tick(delta: 0.1, confirmed: false, heardSpeech: true) }
        #expect(machine.uncertain)
        machine.tick(delta: 0.1, confirmed: true, heardSpeech: true)
        #expect(machine.uncertain, "one confirmation is not enough to re-arm")
        machine.tick(delta: 0.1, confirmed: true, heardSpeech: true)
        #expect(!machine.uncertain)
    }

    /// A recogniser that has never delivered a word is a different failure, and
    /// the driver's job there is to keep the prompter moving rather than freeze
    /// it. This machine must not claim a loss it cannot see.
    @Test func noTranscriptYetIsNotAStall() {
        var machine = Machine()
        for _ in 0..<40 { machine.tick(delta: 0.1, confirmed: false, heardSpeech: false) }
        #expect(!machine.uncertain)
    }
}

/// The re-audit found that the tick loop's write *replaced* the whole struct,
/// which silently wiped two of the three positions, and that a *lower* index was
/// accepted — so auto-next erased the next talk's saved place by loading it at
/// word zero. Both are the "never lose your place" feature failing quietly.
@MainActor
@Suite struct PositionMergeTests {
    @Test func recordingThePrompterPositionKeepsTheOtherTwo() {
        let id = UUID()
        let store = PositionStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("merge-\(UUID().uuidString).json"))
        store.recordManualView(wordIndex: 40, for: id, totalWords: 500)
        store.recordConfirmedSpeech(wordIndex: 55, for: id, totalWords: 500)
        store.record(ReadingPosition(wordIndex: 57, totalWords: 500), for: id)
        let position = store.position(for: id)
        #expect(position?.wordIndex == 57)
        #expect(position?.spokenIndex == 55, "the tick loop wiped the spoken position")
        #expect(position?.viewedIndex == 40, "the tick loop wiped the viewed position")
    }

    @Test func aLaterTickNeverRewindsTheReader() {
        let id = UUID()
        let store = PositionStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rewind-\(UUID().uuidString).json"))
        store.record(ReadingPosition(wordIndex: 700, totalWords: 900), for: id)
        store.record(ReadingPosition(wordIndex: 0, totalWords: 900), for: id)
        #expect(store.position(for: id)?.wordIndex == 700,
                "a load at word zero erased the saved place")
    }

    /// A manual jump *is* allowed to move the prompter backwards, and it is
    /// recorded — otherwise "jump back and re-read this" loses its place.
    @Test func aManualJumpIsAllowedBackwards() {
        let id = UUID()
        let store = PositionStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manual-\(UUID().uuidString).json"))
        store.record(ReadingPosition(wordIndex: 700, totalWords: 900), for: id)
        store.recordManualView(wordIndex: 20, for: id, totalWords: 900)
        #expect(store.position(for: id)?.wordIndex == 20)
    }

    /// The one artefact a presenter cannot recreate must not be overwritten by a
    /// store that could not read it.
    @Test func aCorruptFileIsSetAsideNotOverwritten() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("positions-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                        .appendingPathComponent(url.lastPathComponent
                            .replacingOccurrences(of: "positions-corrupt", with: "positions.json.corrupt"))) }
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)

        let store = PositionStore(url: url)
        store.record(ReadingPosition(wordIndex: 5, totalWords: 50), for: UUID())
        store.saveNow()

        let parked = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
            .filter { $0.contains("positions.json.corrupt") }
        #expect(!parked.isEmpty, "a corrupt position file was destroyed")
    }
}
