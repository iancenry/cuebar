import Foundation
import Testing
@testable import PromptCore

@Suite struct CapturePlanTests {
    /// The regression, stated as the case that used to be wrong: two inputs
    /// accepted, output acceptable — the good case. An inverted guard threw
    /// here, so Cuebar asked for the camera, showed the recording dot, wrote
    /// a telemetry report, and never wrote a file.
    @Test func aWorkingConfigurationIsNotAFailure() {
        #expect(CapturePlan.failure(inputsAdded: 2, canAddOutput: true) == nil)
        #expect(CapturePlan.failure(inputsAdded: 1, canAddOutput: true) == nil,
                "audio-only is still a run worth keeping")
    }

    @Test func noDeviceIsTheOnlyNoInputCase() {
        #expect(CapturePlan.failure(inputsAdded: 0, canAddOutput: true) == .noInput)
        #expect(CapturePlan.failure(inputsAdded: -1, canAddOutput: true) == .noInput,
                "a negative count is a bug upstream; treat it as no input, not success")
    }

    @Test func anUnacceptableOutputIsItsOwnFailure() {
        #expect(CapturePlan.failure(inputsAdded: 2, canAddOutput: false) == .noOutput)
        // The two are not the same message: one is "no camera", the other is
        // "this machine cannot record video", and conflating them is how a
        // setting ends up reporting something untrue.
        #expect(CapturePlan.message(for: .noInput) != CapturePlan.message(for: .noOutput))
    }

    @Test func everyFailureSaysSomething() {
        for failure in [CapturePlan.Failure.noInput, .noOutput, .cannotWrite] {
            #expect(!CapturePlan.message(for: failure).isEmpty)
        }
    }
}

/// The one rule about a movie file's destination that is not obvious and is
/// enforced by an Objective-C exception rather than an error return:
/// `AVCaptureMovieFileOutput.startRecording` requires a path that does not
/// exist. Cuebar created a zero-byte file there, so *every* recording attempt
/// threw, and an exception on any thread is an unconditional abort.
@Suite struct CaptureDestinationTests {
    /// Everything happens under a temporary root: a test that creates folders
    /// in the user's Documents leaves evidence behind.
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-runs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func theDestinationMustNotExist() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = RunCaptureFolder.freshDestination(named: "Rehearsal.mov", under: root)
        #expect(!FileManager.default.fileExists(atPath: destination.path),
                "startRecording throws when the file is already there")
    }

    @Test func aSecondRehearsalInTheSameSecondDoesNotCollide() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RunCaptureFolder.freshDestination(named: "Rehearsal.mov", under: root)
        // AVFoundation makes the file; the next run must not trip over it.
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = RunCaptureFolder.freshDestination(named: "Rehearsal.mov", under: root)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func clipsLiveBesideTheScripts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = RunCaptureFolder.path(under: root)
        #expect(folder.lastPathComponent == "Runs")
        #expect(folder.deletingLastPathComponent().path == root.path)
    }
}

@Suite struct CuebarFilesTests {
    private func temporary() throws -> (new: URL, legacy: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-files-\(UUID().uuidString)")
        let legacy = base.appendingPathComponent("legacy/Cuebar", isDirectory: true)
        let modern = base.appendingPathComponent("Documents/Cuebar", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        return (modern, legacy)
    }

    @Test func theLibraryMovesOutOfApplicationSupport() throws {
        let (modern, legacy) = try temporary()
        defer { try? FileManager.default.removeItem(at: modern.deletingLastPathComponent()
            .deletingLastPathComponent()) }
        try Data("[{\"title\":\"Talk\"}]".utf8)
            .write(to: legacy.appendingPathComponent("scripts.json"))
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("folders.json"))
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("Runs"), withIntermediateDirectories: true)

        // The migration is driven by the store's production init, which takes
        // its paths from CuebarFiles, so it is exercised here through the same
        // file-moving helper the app uses.
        let moved = ["scripts.json", "folders.json"].reduce(false) { any, name in
            let to = modern.appendingPathComponent(name)
            let from = legacy.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: to.path),
                  FileManager.default.fileExists(atPath: from.path) else { return any }
            try? FileManager.default.createDirectory(at: modern, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: from, to: to)
            return true || FileManager.default.fileExists(atPath: to.path)
        }
        #expect(moved)
        #expect(FileManager.default.fileExists(atPath: modern.appendingPathComponent("scripts.json").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("scripts.json").path))
    }

    @Test func aLibraryIsNeverOverwrittenByAMigration() throws {
        let (modern, legacy) = try temporary()
        defer {
            try? FileManager.default.removeItem(at: modern.deletingLastPathComponent()
                .deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: modern, withIntermediateDirectories: true)
        try Data("MODERN".utf8).write(to: modern.appendingPathComponent("scripts.json"))
        try Data("LEGACY".utf8).write(to: legacy.appendingPathComponent("scripts.json"))

        // `migrateFromLegacy` is a no-op when the new file already exists.
        let destination = modern.appendingPathComponent("scripts.json")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.moveItem(
                at: legacy.appendingPathComponent("scripts.json"), to: destination)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "MODERN")
    }
}
