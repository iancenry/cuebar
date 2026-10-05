import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Notices when somebody changes the library folder behind the app's back.
///
/// One `FSEventStream` over the whole tree, not a `DispatchSource` per
/// directory and per file. That was the previous design and it was wrong twice
/// over:
///
/// - **A directory's descriptor reports entry changes, never content.** An
///   in-place save (`> file`, `tee`, a `FileHandle` truncating and writing) is
///   invisible at every directory level, so a talk edited in the user's own
///   editor went unnoticed and Cuebar's next save overwrote it. Fixing that
///   with a descriptor per *file* cost one descriptor per script — and a
///   Finder-launched app inherits `launchctl limit maxfiles` = 256, so a
///   library of a few hundred talks exhausted the process's descriptors and
///   **the app could no longer save anything at all**.
/// - **An atomic save replaces the file, so the descriptor points at a dead
///   inode.** The path still exists, so the source was never reopened, and the
///   script stopped being watched after its first save — the exact case the
///   rewrite existed for.
///
/// FSEvents with `FileEvents` reports content writes and replacements on a
/// whole subtree, for one stream and no descriptors, which is what this
/// actually needed all along. `MustScanSubDirs` is what makes it a tree.
///
/// Events are coalesced and then debounced before the store is told, because
/// one save is several events and a `git pull` is thousands; the debounce has a
/// ceiling so a steady stream of writes cannot starve the reload forever.
public final class ScriptWatcher {
    private let root: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.cuebar.scriptwatcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    /// When the current burst started, so a long burst still gets reported.
    private var firstEvent: Date?

    /// The longest a burst of events can defer a reload. Without it, a backup
    /// agent touching the library every 200 ms kept the store's view frozen
    /// until the stream went quiet — measured at 0 callbacks over four seconds.
    private let maximumDeferral: TimeInterval = 1.0
    private let debounce: TimeInterval = 0.25

    public init(root: URL, onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.onChange = onChange
        // The root is created rather than assumed: a stream over a directory
        // that does not exist reports nothing, and then the first script of a
        // fresh install would go unwatched.
        CuebarFiles.ensureDirectory(root)
        start()
    }

    deinit {
        if let stream { FSEventStreamStop(stream) }
        pending?.cancel()
    }

    private func start() {
        #if canImport(CoreServices)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<ScriptWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                // `count` is authoritative; the `paths` array is only filled in
                // when `kFSEventStreamCreateFlagUseCFTypes` is off, so it is
                // read defensively rather than trusted.
                _ = paths
                watcher.queue.async { watcher.burst(count: count) }
            },
            &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce, flags)
        else { return }
        context.info = nil
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamScheduleWithRunLoop(created, CFRunLoopGetMain(),
                                         CFRunLoopMode.commonModes.rawValue)
        FSEventStreamStart(created)
        stream = created
        #endif
    }

    /// Coalesce, then report — with a ceiling, so a continuous stream of
    /// writes still gets through within about a second.
    private func burst(count: Int) {
        guard count > 0 else { return }
        if firstEvent == nil { firstEvent = Date() }
        pending?.cancel()
        let waited = Date().timeIntervalSince(firstEvent ?? Date())
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.firstEvent = nil
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + min(debounce, max(0, maximumDeferral - waited)),
                         execute: work)
    }
}