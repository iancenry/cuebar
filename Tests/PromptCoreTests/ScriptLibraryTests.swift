import Foundation
import Testing
@testable import PromptCore

@Suite struct ScriptTokenTests {
    @Test func singleWordCue() {
        #expect(ScriptParser.parse("Hello [smile] world") == [.word("Hello"), .cue("[smile]"), .word("world")])
    }

    @Test func multiwordCueStaysOneToken() {
        #expect(ScriptParser.parse("[pause for effect] go") == [.cue("[pause for effect]"), .word("go")])
    }

    @Test func unclosedBracketIsPlainWords() {
        #expect(ScriptParser.parse("Hello [oops") == [.word("Hello"), .word("[oops")])
    }

    @Test func wordsHelperStripsCues() {
        #expect(ScriptParser.words("Good morning [smile] all") == ["Good", "morning", "all"])
    }
}

@Suite struct ScriptStoreTests {
    @Test @MainActor func addSelectDelete() {
        let store = ScriptStore(inMemory: [])
        #expect(store.scripts.isEmpty)
        let doc = store.add(title: "Talk")
        #expect(store.selectedID == doc.id)
        store.updateBody(doc.id, body: "Hello [pause] world")
        #expect(store.selected?.wordCount == 2)
        store.delete(doc.id)
        #expect(store.scripts.isEmpty)
    }

    @Test @MainActor func foldersNestAndFileScripts() {
        let store = ScriptStore(inMemory: [], folders: [
            ScriptFolder(name: "Presentations"),
        ])
        let top = store.folders[0]
        #expect(store.childFolders(of: nil).map(\.name) == ["Presentations"])

        let sub = store.createFolder(name: "Product Demo", parent: top.id)
        let deeper = store.createFolder(name: "Slides", parent: sub.id)
        #expect(store.folderPath(sub.id) == "Presentations / Product Demo")
        #expect(store.folderPath(deeper.id) == "Presentations / Product Demo / Slides")
        // Depth-first draw order, parents before children.
        #expect(store.folderRows().map(\.folder.name) == ["Presentations", "Product Demo", "Slides"])

        let doc = store.add(title: "Talk")
        store.moveScript(doc.id, to: sub.id)
        #expect(store.scripts(inFolder: top.id, includeNested: true).map(\.id) == [doc.id])
        #expect(store.scripts(inFolder: sub.id, includeNested: false).map(\.id) == [doc.id])
        #expect(store.scriptCount(in: top.id) == 1)
    }

    @Test @MainActor func deletingAFolderRefilesItsContentsToTheParent() {
        let store = ScriptStore(inMemory: [], folders: [ScriptFolder(name: "Top")])
        let top = store.folders[0]
        let sub = store.createFolder(name: "Sub", parent: top.id)
        let doc = store.add(title: "Talk")
        store.moveScript(doc.id, to: sub.id)

        store.deleteFolder(sub.id)
        #expect(store.folders.contains { $0.name == "Sub" } == false)
        // Deleted, not lost: the script lands in the parent, never Unfiled.
        #expect(store.scripts.first?.folderID == top.id)
    }

    @Test @MainActor func tagsAreFreeTextAndDeduplicated() {
        let store = ScriptStore(inMemory: [])
        let doc = store.add(title: "Talk")
        store.addTag("#Keynote", to: doc.id)
        store.addTag("keynote", to: doc.id)          // same tag, different case
        store.addTag("  ", to: doc.id)               // nothing to add
        #expect(store.scripts.first?.tags == ["Keynote"])
        #expect(store.allTags == ["Keynote"])
        #expect(store.scripts(tagged: "KEYNOTE").count == 1)
        store.removeTag("keynote", from: doc.id)
        #expect(store.allTags.isEmpty)
    }

    @Test @MainActor func favoritesRecentAndArchive() {
        let store = ScriptStore(inMemory: [])
        let a = store.add(title: "A")
        let b = store.add(title: "B")
        store.toggleFavorite(a.id)
        #expect(store.favorites.map(\.id) == [a.id])
        // Both were just created, so both are recent, and `b` was created
        // second, so it leads.
        #expect(store.recentScripts.first?.id == b.id)
        // Editing an old script must not promote it: recency is about being
        // opened, not about being written.
        store.updateBody(a.id, body: "x")
        #expect(store.recentScripts.first?.id == b.id)
        store.markOpened(a.id)
        #expect(store.recentScripts.first?.id == a.id)
        store.setArchived(true, for: a.id)
        #expect(store.favorites.isEmpty)             // archived leaves the library
        #expect(store.archivedScripts.map(\.id) == [a.id])
    }

    @Test @MainActor func duplicateKeepsFilingAndTagsButNotFavoritism() throws {
        let store = ScriptStore(inMemory: [], folders: [ScriptFolder(name: "F")])
        let folder = store.folders[0]
        let source = store.add(title: "Talk")
        store.moveScript(source.id, to: folder.id)
        store.addTag("draft", to: source.id)
        store.toggleFavorite(source.id)

        let copy = try #require(store.duplicate(source.id))
        #expect(copy.title == "Talk copy")
        #expect(copy.folderID == folder.id)
        #expect(copy.tags == ["draft"])
        #expect(copy.isFavorite == false)
        // A second duplicate must not collide with the first copy's title.
        let again = try #require(store.duplicate(source.id))
        #expect(again.title == "Talk copy 2")
    }
}

@Suite struct CueSettingsTests {
    @Test func defaultsAreSane() {
        let s = CueSettings()
        #expect(s.guidance == .classic)
        #expect(s.textSize.points == 16)
        #expect(s.cueBrightness.badgeOpacity < 0.5)
        #expect(s.hideFromShare == true)
        #expect(s.transcriptionEngine == .automatic)
        #expect(s.hideMainWhilePresenting == true)
        #expect(s.alwaysOnTop == true)
        #expect(s.showCues == true)
        #expect(s.smoothScroll == true)
        #expect(s.highlightStyle == .pill)
        #expect(s.floatingOriginX == nil)
        #expect(s.readingWidth == 650)
        #expect(s.naturalPacing == true)
        #expect(s.catchUpBoost == 1.6)
        #expect(s.pauseOnPauseCues == true)
        #expect(s.smartPause == .off)
        #expect(s.autoNextScript == false)
        #expect(s.releaseFollowOnScroll == true)
    }

    // MARK: - Smart Pause thresholds

    @Test func smartPauseOffNeverFires() {
        let mode = CueSettings.SmartPauseMode.off
        #expect(mode.silenceThreshold == .infinity)
        #expect(mode.resumeThreshold == 0)
    }

    @Test func smartPauseConservativeThresholds() {
        let mode = CueSettings.SmartPauseMode.conservative
        #expect(mode.silenceThreshold == 4.0)
        #expect(mode.resumeThreshold == 1.0)
    }

    @Test func smartPauseNormalThresholds() {
        let mode = CueSettings.SmartPauseMode.normal
        #expect(mode.silenceThreshold == 3.0)   // the spec's three seconds
        #expect(mode.resumeThreshold == 1.5)
    }

    @Test func smartPauseAggressiveThresholds() {
        let mode = CueSettings.SmartPauseMode.aggressive
        #expect(mode.silenceThreshold == 1.5)
        #expect(mode.resumeThreshold == 2.5)
    }

    @Test func smartPauseThresholdsMonotonic() {
        // Conservative is slowest to pause, aggressive is fastest.
        let off = CueSettings.SmartPauseMode.off
        let cons = CueSettings.SmartPauseMode.conservative
        let norm = CueSettings.SmartPauseMode.normal
        let aggr = CueSettings.SmartPauseMode.aggressive
        #expect(off.silenceThreshold > cons.silenceThreshold)
        #expect(cons.silenceThreshold > norm.silenceThreshold)
        #expect(norm.silenceThreshold > aggr.silenceThreshold)
        // Resume: conservative resumes fastest, aggressive waits longest.
        #expect(cons.resumeThreshold < norm.resumeThreshold)
        #expect(norm.resumeThreshold < aggr.resumeThreshold)
    }

    @Test func smartPauseCorruptFallback() throws {
        let json = """
        {"smartPause":"invalid_mode"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(CueSettings.self, from: json)
        #expect(s.smartPause == .off)
    }

    @Test func corruptFieldFallsBackToDefault() throws {
        let json = """
        {"guidance":"nope","overlayWidth":"wide","hideFromShare":true}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(CueSettings.self, from: json)
        #expect(s.guidance == .classic)
        #expect(s.overlayWidth == 460)
        #expect(s.hideFromShare == true)
    }

    @Test func legacyAutoNextKeyMigrates() throws {
        let json = """
        {"autoNextPage":true}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(CueSettings.self, from: json)
        #expect(s.autoNextScript == true)
    }

    @Test func legacyDocsDecodeWithTheirCategoryHeldForMigration() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","body":"hi there","updatedAt":0}
        """.data(using: .utf8)!
        let doc = try JSONDecoder().decode(ScriptDocument.self, from: json)
        #expect(doc.wordCount == 2)
        #expect(doc.folderID == nil)
        #expect(doc.legacyCategory == nil)
    }

    @Test func anOldFileWithCategoriesSurvivesTheRoundTrip() throws {
        // What a pre-folder scripts.json actually contained.
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","body":"hi there","updatedAt":0,"category":"Interviews"}
        """.data(using: .utf8)!
        let doc = try JSONDecoder().decode(ScriptDocument.self, from: json)
        #expect(doc.legacyCategory == "Interviews")
        // And the category is never written back, so a re-encode cannot
        // resurrect a second answer to where the script lives.
        let out = try JSONEncoder().encode(doc)
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("\"category\"") == false)
    }
}

@Suite struct LegacySettingsKeyTests {
    /// The old `autoNextPage` spelling still migrates — and a fresh file
    /// must not gain a phantom `autoNextScript` (decoding must not invent
    /// values the user never set).
    @Test func autoNextPageMigrates() throws {
        let json = #"{"autoNextPage": true}"#
        let decoded = try JSONDecoder().decode(CueSettings.self, from: Data(json.utf8))
        #expect(decoded.autoNextScript)
    }

    /// A tolerant decoder forgets a field silently, because the property has a
    /// default and nothing complains. `ai`, `advertiseRemote` and `deckApp`
    /// were all in that state: written on quit, ignored on launch.
    @Test func theFieldsThatWereOnceForgottenNowSurvive() throws {
        var settings = CueSettings()
        settings.ai = AISettings(provider: .openAI, baseURL: "http://localhost:8080/v1",
                                model: "qwen2.5", minutes: 17)
        settings.advertiseRemote = true
        settings.deckApp = .keynote
        settings.presets = [CuePreset.capturing(CueSettings(), name: "Mine")]

        let decoded = try JSONDecoder().decode(
            CueSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.ai == settings.ai)
        #expect(decoded.ai.provider == .openAI)
        #expect(decoded.ai.baseURL == "http://localhost:8080/v1")
        #expect(decoded.ai.minutes == 17)
        #expect(decoded.advertiseRemote)
        #expect(decoded.deckApp == .keynote)
        #expect(decoded.presets.map(\.name) == ["Mine"],
                "a user's own presets were dropped on the next launch")
    }

    @Test func encodingRoundTripsEveryField() throws {
        var settings = CueSettings()
        settings.autoNextScript = true
        settings.shortcuts.bind(KeyChord(keyCode: KeyCode.j, modifiers: [.command, .option]), to: .restart)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CueSettings.self, from: data)
        #expect(decoded == settings)
        // The legacy key is decode-only: it must not appear in output.
        #expect(!String(decoding: data, as: UTF8.self).contains("autoNextPage"))
    }

    @Test func wordsPerMinuteIsClampedToPresenterSpeeds() {
        var settings = CueSettings()
        settings.adjustWordsPerMinute(by: 10_000)
        #expect(settings.wordsPerMinute == 480)
        settings.adjustWordsPerMinute(by: -10_000)
        #expect(settings.wordsPerMinute == 30)
        // Stepping never leaves a fractional value behind for the slider.
        settings.wordsPerMinute = 152
        settings.adjustWordsPerMinute(by: 1)
        #expect(settings.wordsPerMinute == 153)
    }
}

/// One file per script means the open script is still open after a relaunch:
/// `lastOpenedAt` lives in that script's own file, so there is no index to
/// fall out of step with the folder.
@MainActor
@Suite struct ScriptStoreSelectionPersistenceTests {
    /// A store pointed at a folder this test owns — never the user's library.
    private func temporaryRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theOpenScriptIsStillOpenAfterARelaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let first = store.add(title: "First", body: "One two three.")
        store.add(title: "Second", body: "Four five six.")
        store.select(first.id)
        // Let the debounced save land.
        try await Task.sleep(for: .milliseconds(500))

        let reopened = ScriptStore(libraryRoot: root)
        let reopenedTitle = reopened.selected?.title ?? "nothing"
        #expect(reopened.selectedID == first.id,
                Comment(rawValue: "reopened on \(reopenedTitle)"))
    }

    @Test func everyScriptIsAFileAndTheBodyIsInIt() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        // New scripts land beside the open one, which is in Personal on a
        // fresh library — so the file is Personal/Keynote.md, and Finder shows
        // exactly the filing the sidebar shows.
        store.add(title: "Keynote", body: "Good evening. [smile]")

        let files = try FileManager.default
            .contentsOfDirectory(atPath: root.path).sorted()
        #expect(files == ["Presentations", "Interviews", "Personal"].sorted(),
                Comment(rawValue: "\(files)"))
        let text = try String(contentsOf:
            root.appendingPathComponent("Personal/Keynote.md"), encoding: .utf8)
        #expect(text.contains("Good evening."))
        #expect(store.scripts.count == 2)
    }

    /// The metadata block is bookkeeping on top of the talk, never a
    /// rewrite of it: everything after the block must be the script, byte for
    /// byte, because that text is the thing being performed.
    @Test func theMetadataBlockNeverTouchesTheScriptText() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let body = "One two three.\n\n[smile]\nFour five."
        store.add(title: "Plain", body: body)
        let text = try String(contentsOf:
            root.appendingPathComponent("Personal/Plain.md"), encoding: .utf8)
        #expect(text.hasPrefix("---\n"))
        #expect(text.hasSuffix(body), Comment(rawValue: repr(text)))
        #expect(ScriptFile.parse(text).body == body)
    }

    /// A script that opens with a horizontal rule must not be mistaken for
    /// front matter — on write or on read, or it grows a stray line every
    /// time it is saved.
    @Test func aScriptThatStartsWithARuleSurvivesARoundTrip() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let body = "---\n\nAct one.\n---\nThe end."
        let doc = store.add(title: "Dashes", body: body)
        store.addTag("act", to: doc.id)      // rewrites the file with a header
        try await Task.sleep(for: .milliseconds(500))
        let reopened = ScriptStore(libraryRoot: root)
        #expect(reopened.scripts.first { $0.id == doc.id }?.body == body,
                Comment(rawValue: repr(reopened.scripts.first { $0.id == doc.id }?.body)))
    }

    /// The failure this guards is silent and total: a talk that opens with a
    /// horizontal rule was read as its own front matter, so everything up to
    /// the next rule was thrown away and the script performed as its last
    /// section.
    @Test func aScriptOfNothingButRulesIsNotReadAsMetadata() {
        let body = "---\n\nAct one.\n---\n\nAct two.\n---\nThe end."
        let parsed = ScriptFile.parse(body)
        #expect(parsed.body == body, Comment(rawValue: repr(parsed.body)))
        #expect(parsed.metadata == nil)
    }

    /// Folders are directories, so a talk dropped into one from Finder is in
    /// the library on the next launch — the whole reason for using files.
    @Test func aScriptDroppedInByHandAppearsInTheRightFolder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let presentations = try #require(store.folders.first { $0.name == "Presentations" })
        let directory = root.appendingPathComponent("Presentations", isDirectory: true)
        try "Dropped in from Finder.".write(
            to: directory.appendingPathComponent("Airport.md"), atomically: true, encoding: .utf8)

        let reopened = ScriptStore(libraryRoot: root)
        let dropped = try #require(reopened.scripts.first { $0.title == "Airport" })
        #expect(dropped.body == "Dropped in from Finder.")
        #expect(reopened.folderName(dropped.folderID) == "Presentations")
    }

    /// The title *is* the filename. Two scripts with one name means one file
    /// would be silently overwritten, so the newcomer is numbered instead.
    @Test func twoScriptsWithOneNameDoNotOverwriteEachOther() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        store.add(title: "Talk", body: "First one.")
        let second = store.add(title: "Talk", body: "Second one.")
        #expect(second.title == "Talk 2")
        let reopened = ScriptStore(libraryRoot: root)
        #expect(reopened.scripts.count == 3)     // Welcome, Talk, Talk 2
        #expect(reopened.scripts.first { $0.title == "Talk 2" }?.body == "Second one.")
    }

    @Test func renamingAScriptRenamesItsFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let doc = store.add(title: "Draft", body: "Rehearse this.")
        store.rename(doc.id, title: "Rehearsal")
        let names = try FileManager.default
            .contentsOfDirectory(atPath: root.appendingPathComponent("Personal").path)
        #expect(names.contains("Rehearsal.md"))
        #expect(!names.contains("Draft.md"))
        #expect(ScriptStore(libraryRoot: root).scripts.first { $0.id == doc.id }?
            .title == "Rehearsal")
    }

    /// Deleting in Finder is a real deletion, not a resurrection: the store
    /// forgets the script when its file is gone.
    @Test func aFileDeletedOutsideTheAppLeavesTheLibrary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let doc = store.add(title: "Temporary", body: "Gone soon.")
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Personal/Temporary.md"))
        let reopened = ScriptStore(libraryRoot: root)
        #expect(!reopened.scripts.contains { $0.id == doc.id })
    }

    /// A folder rename is a directory rename, and the scripts inside it must
    /// still be filed correctly afterwards — folder ids come from paths, so
    /// this is the case that would silently unfile a whole talk.
    @Test func renamingAFolderKeepsItsScriptsFiled() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let presentations = try #require(store.folders.first { $0.name == "Presentations" })
        let doc = store.add(title: "Keynote", body: "In a folder.", folder: presentations.id)
        let child = store.createFolder(name: "2026", parent: presentations.id)
        store.moveScript(doc.id, to: child.id)
        store.renameFolder(presentations.id, to: "Talks")

        let reopened = ScriptStore(libraryRoot: root)
        let filed = try #require(reopened.scripts.first { $0.id == doc.id })
        #expect(reopened.folderPath(filed.folderID) == "Talks / 2026",
                Comment(rawValue: reopened.folderPath(filed.folderID)))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Talks/2026/Keynote.md").path))
    }

    /// Deleting a folder reorganises: its scripts move up to the parent on
    /// disk, and nothing is lost.
    @Test func deletingAFolderPullsItsScriptsUp() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let presentations = try #require(store.folders.first { $0.name == "Presentations" })
        let doc = store.add(title: "Keynote", body: "Stays put.", folder: presentations.id)
        store.deleteFolder(presentations.id)
        let reopened = ScriptStore(libraryRoot: root)
        let filed = try #require(reopened.scripts.first { $0.id == doc.id })
        #expect(filed.folderID == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Keynote.md").path))
    }

    /// A library Cuebar cannot read is a fact to report, not a reason to
    /// overwrite: the unparseable file stays exactly where it was, and the
    /// readable ones still open.
    @Test func anUnreadableFileIsReportedAndKept() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        store.add(title: "Readable", body: "Fine.")
        // Invalid UTF-8 is the realistic version of this: a file saved by
        // something that is not a text editor.
        let bad = root.appendingPathComponent("Broken.md")
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: bad)

        let reopened = ScriptStore(libraryRoot: root)
        #expect(reopened.unreadableFiles == ["Broken.md"],
                Comment(rawValue: "\(reopened.unreadableFiles)"))
        #expect(reopened.scripts.contains { $0.title == "Readable" })
        #expect(FileManager.default.fileExists(atPath: bad.path),
                "an unreadable file was deleted")
    }

    /// A script the app cannot write — a folder someone made read-only, a
    /// volume that went away — must not lose the edit in silence.
    @Test func aFailedWriteIsReported() async throws {
        let root = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = ScriptStore(libraryRoot: root)
        let doc = store.add(title: "Locked", body: "Before.")
        let url = root.appendingPathComponent("Personal/Locked.md")
        #expect(store.unsavedScripts.isEmpty)
        // A directory where the file should be makes the write fail in a way
        // no permission bit can undo.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.updateBody(doc.id, body: "After.")
        #expect(store.selected?.body == "After.",
                "the edit should still be on screen even when it cannot be saved")
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.hasUnsavedScripts)
        #expect(store.unsavedScripts.contains(doc.id))
    }
}

private func repr(_ text: String?) -> String {
    text.map { $0.debugDescription } ?? "nil"
}
