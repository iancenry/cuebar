import Testing
import Foundation
@testable import PromptCore

/// The watcher is the only thing standing between "the library is files" and
/// "editing a talk in another editor silently loses it".
///
/// These tests wait on real filesystem events rather than reasoning about the
/// API, because the first version of this watcher passed every reasoning-based
/// check and still reported nothing: it watched directories, and a directory
/// reports *entry* changes, never a file's content being written. A talk
/// edited in the user's own editor was invisible, and Cuebar's next save
/// overwrote it.
@MainActor
@Suite struct ScriptWatcherTests {
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A counter the watcher bumps, read after a wait.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() {
            lock.lock(); value += 1; lock.unlock()
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private func start(_ root: URL, _ counter: Counter) -> ScriptWatcher {
        ScriptWatcher(root: root) { counter.bump() }
    }

    /// FSEvents are not instantaneous and coalescing is deliberate, so a
    /// single wait with a generous margin is the honest shape of this
    /// assertion. `zero` waits long enough that a late event would be caught.
    /// Wait for the counter to move past `beyond`.
    ///
    /// `beyond` is not optional bookkeeping: after a folder is created the
    /// counter is already non-zero, so "wait for at least one" would return
    /// immediately and prove nothing about the *next* event.
    private func wait(for counter: Counter, beyond: Int = 0) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if counter.count > beyond { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// For the assertion that nothing should arrive: one debounce interval
    /// plus slack is enough to catch a late event.
    private func settle(_ counter: Counter) async throws {
        try await Task.sleep(for: .milliseconds(700))
    }

    /// The bug this suite exists for: a script in a *folder that already
    /// existed when the watcher started*, saved in place by another app.
    @Test func anInPlaceEditToAScriptInAnExistingFolderIsSeen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Talks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("Keynote.md")
        try "First.".write(to: script, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = start(root, counter)
        defer { _ = watcher }
        // An in-place write: truncate and write, no temp file, no rename.
        try "Second, in place.".write(to: script, atomically: false, encoding: .utf8)
        try await wait(for: counter)
        #expect(counter.count > 0, "an outside edit inside an existing folder went unseen")
    }

    @Test func anAtomicSaveOfAScriptInAnExistingFolderIsSeen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Talks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("Keynote.md")
        try "First.".write(to: script, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = start(root, counter)
        defer { _ = watcher }
        try "Second, atomically.".write(to: script, atomically: true, encoding: .utf8)
        try await wait(for: counter)
        #expect(counter.count > 0)
    }

    /// A folder made *after* the watcher started has to start reporting, or a
    /// talk dropped into a new folder never appears.
    @Test func aFolderCreatedAfterTheWatcherStartedIsSeen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let watcher = start(root, counter)
        defer { _ = watcher }

        let folder = root.appendingPathComponent("New", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await wait(for: counter)
        #expect(counter.count > 0, "a new folder was not noticed")

        let before = counter.count
        try "Hello.".write(to: folder.appendingPathComponent("Talk.md"),
                           atomically: false, encoding: .utf8)
        try await wait(for: counter, beyond: before)
        #expect(counter.count > before, "a script in a brand-new folder went unseen")
    }

    /// Cuebar's own save must not read back as an outside edit, which is what
    /// the store's echo window exists for — so the watcher *does* report it and
    /// the store ignores it. This test pins that the watcher is not silent, so
    /// a future "optimisation" that filters too much is caught.
    @Test func theWatchersOwnSavesAreReportedToo() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let watcher = start(root, counter)
        defer { _ = watcher }
        let library = ScriptLibrary(root: root)
        try library.write("Body.", metadata: nil,
                          to: root.appendingPathComponent("Talk.md"))
        try await wait(for: counter)
        #expect(counter.count > 0)
    }

    /// The failure the descriptor-per-file design had: the first *atomic* save
    /// replaces the file, so the descriptor pointed at a dead inode and the
    /// script was never watched again. Two in-place writes around one atomic
    /// one is exactly the sequence Cuebar itself performs.
    @Test func aScriptKeepsBeingWatchedAcrossAnAtomicSave() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Talks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("Keynote.md")
        try "One.".write(to: script, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = start(root, counter)
        defer { _ = watcher }

        try "Two.".write(to: script, atomically: false, encoding: .utf8)
        try await wait(for: counter)
        let afterInPlace = counter.count
        #expect(afterInPlace > 0, "in-place save unseen")

        // Cuebar's own write: temp file plus a replace.
        try "Three.".write(to: script, atomically: true, encoding: .utf8)
        try await wait(for: counter, beyond: afterInPlace)

        let afterAtomic = counter.count
        try "Four.".write(to: script, atomically: false, encoding: .utf8)
        try await wait(for: counter, beyond: afterAtomic)
        #expect(counter.count > afterAtomic,
                "the script stopped being watched after its first atomic save")
    }

    /// One descriptor per script is what broke a few-hundred-talk library: a
    /// Finder-launched app inherits a 256-descriptor budget, and past that
    /// every other `open` in Cuebar fails too — including the one that saves.
    @Test func theWatcherCostsOneDescriptorNotOnePerScript() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = open("/dev/null", O_RDONLY)
        if before >= 0 { close(before) }
        let descriptorCount = { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }

        let idle = descriptorCount()
        let counter = Counter()
        let watcher = start(root, counter)
        defer { _ = watcher }
        for i in 0..<300 {
            try "Body \(i).".write(to: root.appendingPathComponent("Talk \(i).md"),
                                    atomically: true, encoding: .utf8)
        }
        try await Task.sleep(for: .milliseconds(600))
        let after = descriptorCount()
        #expect(after - idle < 20,
                "watching 300 scripts cost \(after - idle) descriptors")
    }
}
