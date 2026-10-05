import Foundation

/// Whether a capture session can be built, and why not.
///
/// This is one `if` in the app layer, and it was **inverted** for a while:
/// `guard session.inputs.isEmpty else { throw .noInput }` threw on every
/// *successful* configuration — the good case — so a rehearsal recorded and
/// reported perfectly and never produced a clip. Nothing caught it: the app
/// launches, the run works, the report is right, and the one thing missing is
/// the thing the camera permission prompt was asked for.
///
/// So the decision lives here, where a test can pin it. The device calls stay
/// in `RunCapture`; only the verdict is pure.
public enum CapturePlan {
    public enum Failure: Equatable, Sendable {
        case noInput
        case noOutput
        case cannotWrite
    }

    /// `inputsAdded` is how many device inputs the session accepted; zero
    /// means neither a camera nor a microphone could be opened, which is the
    /// only way to end up with nothing to record from.
    public static func failure(inputsAdded: Int, canAddOutput: Bool) -> Failure? {
        guard inputsAdded > 0 else { return .noInput }
        guard canAddOutput else { return .noOutput }
        return nil
    }

    /// What a presenter should be told, in their language. A refused camera
    /// is not an error in the run.
    public static func message(for failure: Failure) -> String {
        switch failure {
        case .noInput:
            return "this machine has no camera or microphone to record with"
        case .noOutput:
            return "this machine cannot record video"
        case .cannotWrite:
            return "the file could not be created"
        }
    }
}

/// Where rehearsal clips live. In PromptCore with the rest of the capture
/// decisions so a test can assert on it without touching AVFoundation.
public enum RunCaptureFolder {
    /// `~/Documents/Cuebar/Runs`, beside the scripts: see `CuebarFiles` for
    /// why these are not in Application Support.
    ///
    /// Takes its root as an argument so a test can point it at a temporary
    /// directory — a test that creates folders in the user's Documents is a
    /// test that leaves evidence behind.
    public static func path(under root: URL? = nil) -> URL {
        let folder = (root ?? CuebarFiles.root).appendingPathComponent("Runs",
                                                                      isDirectory: true)
        CuebarFiles.ensureDirectory(folder)
        return folder
    }

    /// A destination that does **not** exist. `startRecording` throws an
    /// Objective-C exception when the file is already there, and an exception
    /// anywhere is an unconditional abort — so nothing may create this path.
    public static func freshDestination(named name: String, under root: URL? = nil) -> URL {
        let destination = path(under: root).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        return destination
    }
}
