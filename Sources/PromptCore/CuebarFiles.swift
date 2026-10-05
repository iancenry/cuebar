import Foundation

/// Where Cuebar keeps the user's own files.
///
/// **Not** Application Support. That is a system directory, hidden in Finder by
/// default, excluded from the user's document backups, and impossible to reach
/// without `Cmd-Shift-G`. Fine for a cache. Wrong for two things:
///
/// - the scripts somebody wrote, imported and edits by hand, and
/// - rehearsal clips they want to keep, watch, or put in iCloud.
///
/// `~/Documents/Cuebar` is visible, backed up with everything else, and one
/// place to look. Cuebar is not sandboxed (`make-app.sh` ad-hoc signs without
/// `--entitlements`), so no permission prompt is involved; if that ever
/// changes, Documents is exactly the directory a sandboxed app has to declare
/// `user-selected.read-write` for anyway.
public enum CuebarFiles {
    public static let folderName = "Cuebar"

    /// The user's documents, if we can write there.
    ///
    /// Falls back to the old location rather than failing: a library that
    /// cannot be written is better than an app that will not start.
    public static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let wanted = documents.appendingPathComponent(folderName, isDirectory: true)
        if isWritable(wanted) { return wanted }
        // Documents can be refused — TCC protects it for some processes, and
        // a read-only or migrated home refuses writes silently. Probed rather
        // than assumed, because "the app started and then lost my scripts" is
        // much worse than a library in the old place.
        return legacyRoot
    }

    static var legacyRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The scripts themselves: one Markdown file per script, in real
    /// folders, so the library is something the user owns rather than
    /// something the app hides. See `ScriptFile` for the file format.
    public static var scriptsDirectory: URL { root.appendingPathComponent("Scripts", isDirectory: true) }
    public static var runs: URL { root.appendingPathComponent("Runs", isDirectory: true) }

    // The single-file library Cuebar used to keep. Read once, on the first
    // launch of a build that stores scripts as files, then set aside — never
    // deleted, and never written again.
    public static var legacyLibrary: URL { root.appendingPathComponent("scripts.json") }
    public static var legacyFolders: URL { root.appendingPathComponent("folders.json") }
    public static var legacyCategories: URL { root.appendingPathComponent("categories.json") }

    /// Every file that belongs in the folder.
    public static var libraryFiles: [URL] { [legacyLibrary, legacyFolders, legacyCategories] }

    /// Move the library out of Application Support, once.
    ///
    /// Called on every launch and a no-op after the first: it moves a file only
    /// when the new location does **not** already have it, so a half-finished
    /// migration cannot destroy the copy that is already there. Returns whether
    /// anything moved, which is only used by tests.
    @discardableResult
    public static func migrateFromLegacy() -> Bool {
        var movedAnything = false
        ensureDirectory(root)
        for file in libraryFiles {
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            let old = legacyRoot.appendingPathComponent(file.lastPathComponent)
            guard FileManager.default.fileExists(atPath: old.path) else { continue }
            do {
                try FileManager.default.moveItem(at: old, to: file)
                movedAnything = true
            } catch {
                // A library that could not be moved is left where it is; the
                // store falls back to reading it there rather than starting
                // the user with an empty library.
                continue
            }
        }
        // Clips, so the folder the user can see holds everything.
        let oldRuns = legacyRoot.appendingPathComponent("Runs", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldRuns.path),
           !FileManager.default.fileExists(atPath: runs.path) {
            try? FileManager.default.moveItem(at: oldRuns, to: runs)
            movedAnything = true
        }
        return movedAnything
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Can we actually write here? Creating a directory proves nothing: a
    /// protected folder accepts `createDirectory` and refuses the first file.
    static func isWritable(_ url: URL) -> Bool {
        guard ensureDirectory(url) else { return false }
        let probe = url.appendingPathComponent(".cuebar-write-probe")
        do {
            try Data("probe".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}
