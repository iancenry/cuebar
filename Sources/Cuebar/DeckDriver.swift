import Foundation
import AppKit
import PromptCore

/// A slide deck Cuebar can move.
///
/// The protocol exists so the prompter never depends on any of this: a
/// `[slide 4]` renders as a badge, counts in the statistics, and moves the
/// phone's stepper whether or not a deck is ever connected. A presenter can
/// rehearse the whole talk with every driver switched off, and a deck that
/// fails to follow is visibly wrong rather than silently so.
@MainActor
protocol DeckDriving: AnyObject {
    var isConnected: Bool { get }
    /// Move to a 1-based slide number.
    func go(to slide: Int)
}

@MainActor extension CueSettings.DeckApp {
    /// The bundle identifier, so "is it running?" is a fact rather than a
    /// guess from a process name that localisation can change.
    var bundleID: String? {
        switch self {
        case .none: return nil
        case .keynote: return "com.apple.iWork.Keynote"
        case .powerPoint: return "com.microsoft.Powerpoint"
        }
    }

    var driver: DeckDriving? {
        switch self {
        case .none: return nil
        case .keynote, .powerPoint: return AppleScriptDeck(app: self)
        }
    }
}

/// Drives a deck by AppleScript, off the main actor.
///
/// Three things this deliberately is not careful about:
///
/// - **It is not fast.** An AppleScript call that crosses into another app
///   costs ~100ms and can block for longer while that app is busy. So it
///   runs on a private queue: the prompter's 60Hz tick must never wait on
///   Keynote, and a deck that hangs must not freeze the reading position.
/// - **It is not verified against a running deck.** The dictionaries are
///   Apple's and Microsoft's, and both have changed. Every call is wrapped
///   so a failure is a deck that didn't move, never a crash in the middle of
///   a talk, and the prompter carries on either way.
/// - **It asks for a permission.** Controlling another app is an Automation
///   consent on macOS, which means a system dialog the first time. That is
///   why `CueSettings.deckApp` defaults to `.none`: nobody should meet a
///   permission prompt because a teleprompter was installed.
@MainActor
final class AppleScriptDeck: DeckDriving {
    private let app: CueSettings.DeckApp
    private let queue = DispatchQueue(label: "cuebar.deck", qos: .utility)

    /// Last failure, for the settings panel to show. Not for the prompter:
    /// mid-talk, a caption about AppleScript is noise.
    private(set) var lastError: String?

    init(app: CueSettings.DeckApp) {
        self.app = app
    }

    var isConnected: Bool {
        guard let bundleID = app.bundleID else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    func go(to slide: Int) {
        let script = Self.script(for: app, slide: slide)
        guard let script else {
            lastError = "\(app.label) does not support being driven."
            return
        }
        // Hop off the main actor *before* building the script object: it is
        // the execution, not the construction, that blocks, and NSAppleScript
        // is not documented as safe to build off the main thread.
        let runner = ScriptRunner(script: script)
        queue.async {
            let error = runner.run()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // nil means the deck moved. Anything else is a sentence the
                // presenter can act on, kept for Settings.
                self.lastError = error
            }
        }
    }

    private static func script(for app: CueSettings.DeckApp, slide slideNumber: Int) -> String? {
        let n = max(1, slideNumber)
        switch app {
        case .keynote:
            return """
            tell application "Keynote"
                set theDocument to front document
                if (count of slides of theDocument) >= \(n) then
                    go to slide \(n) of theDocument
                end if
            end tell
            """
        case .powerPoint:
            // PowerPoint's dictionary is a moving target and the show window
            // is what the audience sees, so this targets the slideshow
            // rather than the edit view. If a future version renames it the
            // call errors and the deck simply doesn't move.
            return """
            tell application "Microsoft PowerPoint"
                go to slide \(n) of slide show window 1
            end tell
            """
        case .none:
            return nil
        }
    }
}

/// A one-shot script run, kept off the main actor. `NSAppleScript` is
/// main-thread-agnostic but not Sendable, so this is a reference the queue
/// closure can hold without pretending otherwise.
private final class ScriptRunner: @unchecked Sendable {
    private let script: String
    init(script: String) { self.script = script }

    /// nil on success, otherwise the error's message.
    func run() -> String? {
        guard let appleScript = NSAppleScript(source: script) else {
            return "The script could not be compiled."
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        guard let error, let code = error[NSAppleScript.errorNumber] as? Int, code != 0 else {
            return nil
        }
        return (error[NSAppleScript.errorMessage] as? String)
            ?? "AppleScript error \(code)."
    }
}
