import Foundation

/// Where the presenter was, for each script.
///
/// "Never lose your place" is the feature that makes a teleprompter feel like
/// an instrument rather than a website. It means three positions rather than
/// one, because they answer different questions and only one of them is the
/// one to restore:
///
/// - `wordIndex` — where the prompter is. What you resume at.
/// - `spokenIndex` — the last word voice tracking *confirmed*. Where the
///   presenter had actually got to. Useful after a jump: it says whether the
///   prompter is ahead of the reader or behind.
/// - `viewedIndex` — the last word they deliberately jumped to. Restoring the
///   engine position after they stopped to look somewhere else is usually
///   wrong: they moved on purpose.
///
/// Stored per script id, in one file beside the scripts. This is app state and
/// deliberately *not* in the script's own front matter: a position changes many
/// times a minute, and rewriting a talk's file that often would mean an atomic
/// save (and a watcher event) per tick.
public struct ReadingPosition: Codable, Equatable, Sendable {
    public var wordIndex: Int
    public var spokenIndex: Int?
    public var viewedIndex: Int?
    public var updatedAt: Date
    /// The script's length when this was recorded. A script that has since been
    /// edited shorter must not restore a position past its end.
    public var totalWords: Int

    public init(wordIndex: Int, spokenIndex: Int? = nil, viewedIndex: Int? = nil,
                updatedAt: Date = Date(), totalWords: Int = 0) {
        self.wordIndex = max(0, wordIndex)
        self.spokenIndex = spokenIndex.map { max(0, $0) }
        self.viewedIndex = viewedIndex.map { max(0, $0) }
        self.updatedAt = updatedAt
        self.totalWords = totalWords
    }

    /// Can this position be restored into a script of `words` words?
    ///
    /// Compared on length rather than trusted outright: a talk edited from
    /// 800 words to 120 while Cuebar was closed must not open with the prompter
    /// 600 words past the end, which is a blank screen with no explanation.
    public func isRestorable(into words: Int) -> Bool {
        guard wordIndex > 0, wordIndex < words else { return false }
        guard totalWords > 0 else { return true }
        // Within 20% of the same length, or short enough that the position
        // cannot be past the end.
        return totalWords == words || abs(totalWords - words) <= max(4, totalWords / 5)
    }

    /// The index to resume at in a script of `words` words.
    public func resumeIndex(into words: Int) -> Int? {
        guard isRestorable(into: words) else { return nil }
        return min(wordIndex, max(0, words - 1))
    }
}

/// Per-script reading positions, persisted.
///
/// Coalesced like every other save in Cuebar: the position changes while the
/// presenter talks, and a file write per tick would be absurd. The window is
/// short (a second) because the point of the feature is surviving an *unexpected*
/// quit — a crash, a force-quit, a dead battery — so the worst case has to be
/// about a second of lost position, not a minute.
@MainActor
public final class PositionStore {
    /// How long to wait before writing. Deliberately short.
    private static let coalesce = 1.0
    private static let maximumDelay = 5.0

    private let url: URL
    private var positions: [UUID: ReadingPosition] = [:]
    private var saveTask: Task<Void, Never>?
    private var firstChange: Date?
    private var lastScheduled: [UUID: ReadingPosition] = [:]

    /// Files this app owns. `positions.json` lives beside the scripts so a user
    /// looking for "where does Cuebar keep my stuff" finds it in one place.
    public init(url: URL) {
        self.url = url
        load()
    }

    public convenience init() {
        self.init(url: CuebarFiles.root.appendingPathComponent("positions.json"))
    }

    public func position(for id: UUID) -> ReadingPosition? { positions[id] }

    /// Record where the prompter is. Cheap enough to call on every change.
    ///
    /// Merged, not replaced: a whole-struct write from the tick loop silently
    /// wiped `spokenIndex` and `viewedIndex` — so two of the three positions
    /// were never actually persisted. And a *lower* index is ignored, because a
    /// late write must not rewind a jump the presenter made, and because
    /// auto-next would otherwise erase the next talk's saved place by loading
    /// it at word zero.
    public func record(_ position: ReadingPosition, for id: UUID) {
        if let existing = positions[id] {
            guard existing.updatedAt <= position.updatedAt else { return }
            guard position.wordIndex >= existing.wordIndex else { return }
            positions[id] = ReadingPosition(
                wordIndex: position.wordIndex,
                spokenIndex: position.spokenIndex ?? existing.spokenIndex,
                viewedIndex: position.viewedIndex ?? existing.viewedIndex,
                updatedAt: position.updatedAt, totalWords: position.totalWords)
        } else {
            positions[id] = position
        }
        scheduleSave()
    }

    public func recordConfirmedSpeech(wordIndex: Int, for id: UUID, totalWords: Int) {
        var position = positions[id] ?? ReadingPosition(wordIndex: wordIndex,
                                                       totalWords: totalWords)
        position.wordIndex = max(position.wordIndex, wordIndex)
        position.spokenIndex = wordIndex
        position.updatedAt = Date()
        position.totalWords = totalWords
        positions[id] = position
        scheduleSave()
    }

    /// A jump the presenter made on purpose.
    public func recordManualView(wordIndex: Int, for id: UUID, totalWords: Int) {
        var position = positions[id] ?? ReadingPosition(wordIndex: wordIndex,
                                                       totalWords: totalWords)
        position.wordIndex = wordIndex
        position.viewedIndex = wordIndex
        position.updatedAt = Date()
        position.totalWords = totalWords
        positions[id] = position
        scheduleSave()
    }

    /// Forget a script. Called when a script is deleted, so a large library
    /// does not accumulate positions for talks that no longer exist.
    public func forget(_ id: UUID) {
        guard positions.removeValue(forKey: id) != nil else { return }
        scheduleSave()
    }

    /// The script most recently being read, which is what a fresh launch should
    /// reopen. Ordered by the time it was touched, not by the file's date, so
    /// the script the presenter was actually reading wins.
    public var mostRecent: (id: UUID, position: ReadingPosition)? {
        positions.max { $0.value.updatedAt < $1.value.updatedAt }
            .map { (id: $0.key, position: $0.value) }
    }

    // MARK: - Persistence

    /// Set when the file could not be read. Until a real position exists, the
    /// store writes nothing at all: the first version fell back to an empty
    /// dictionary and the next save *overwrote* the one file holding the thing a
    /// presenter cannot recreate. It is set aside instead, like a script the app
    /// cannot parse.
    private var isCorrupt = false

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([UUID: ReadingPosition].self,
                                                       from: data) else {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(
                at: url,
                to: url.deletingLastPathComponent()
                    .appendingPathComponent("positions.json.corrupt-\(stamp)"))
            isCorrupt = true
            return
        }
        positions = decoded
    }

    private func scheduleSave() {
        // Nothing changed: a 60 Hz loop that re-schedules a write on every tick
        // allocates a Task sixty times a second to do no work.
        guard positions != lastScheduled else { return }
        lastScheduled = positions
        if firstChange == nil { firstChange = Date() }
        saveTask?.cancel()
        let elapsed = Date().timeIntervalSince(firstChange ?? Date())
        let wait = min(Self.coalesce, max(0, Self.maximumDelay - elapsed))
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Write now, whatever is pending. Called on quit, and whenever the window
    /// is about to go away.
    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        firstChange = nil
        // A corrupt file is left alone until there is something real to write,
        // and a write with nothing to say is not a write.
        guard !isCorrupt else { return }
        guard !positions.isEmpty || FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try JSONEncoder().encode(positions)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic, and a no-op that cannot truncate an existing file: this
            // file holds the one thing the presenter cannot recreate.
            try data.write(to: url, options: .atomic)
        } catch {
            // Nowhere to report this. The in-memory positions are still right,
            // and the next write will try again.
        }
    }
}