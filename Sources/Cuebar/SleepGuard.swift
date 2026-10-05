import Foundation

/// Holds a power assertion while the prompter is in use, so the Mac's
/// display never sleeps in front of an audience.
///
/// `ProcessInfo.beginActivity` rather than an `IOPMAssertionCreateWithDescription`
/// call: it is the supported path, it needs no IOKit import, and it is
/// sandbox-safe. Both display and system sleep are held — a presenter mid-talk
/// is not "idle" in any sense the OS can detect, because standing at a lectern
/// produces no input.
///
/// Idempotent on purpose: the callers are edge handlers (play started,
/// overlay shown, setting toggled) and any of them firing twice must not
/// stack assertions that outlive the prompter. One assertion, one release.
@MainActor
final class SleepGuard {
    // beginActivity returns `id <NSObject>` in today's SDK — the typed
    // `NSProcessInfoActivity` token is gone from the header, so the token
    // is held as the protocol it is declared as and handed straight back.
    private var activity: (any NSObjectProtocol)?

    func setActive(_ active: Bool) {
        if active {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled,
                          .idleSystemSleepDisabled],
                reason: "Cuebar prompter is up")
        } else {
            guard let held = activity else { return }
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }
}
