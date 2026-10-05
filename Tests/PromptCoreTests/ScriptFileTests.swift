import Testing
import Foundation
@testable import PromptCore

/// The file format, on its own: what a script looks like on disk, and what
/// happens to text that merely looks like metadata.
@Suite struct ScriptFileTests {
    @Test func aScriptWithNothingToRememberIsJustTheScript() {
        #expect(ScriptFile.render("Good evening.", metadata: nil) == "Good evening.")
        let plain = ScriptFile.Metadata()
        #expect(plain.isEmptyForAFile)
    }

    /// Somebody's own front matter — a Jekyll `layout:`, a note to self — is
    /// left alone. Cuebar does not get to be the only thing that can read
    /// these files.
    @Test func unknownFieldsAreIgnoredRatherThanDropped() {
        let text = """
        ---
        layout: talk
        id: 11111111-2222-3333-4444-555555555555
        note: rewrite the opening
        ---

        Good evening.
        """
        let parsed = ScriptFile.parse(text)
        #expect(parsed.metadata?.id.uuidString == "11111111-2222-3333-4444-555555555555")
        #expect(parsed.body == "Good evening.")
        #expect(ScriptFile.render("Good evening.", metadata: parsed.metadata)
            .contains("id: 11111111-2222-3333-4444-555555555555"))
    }

    @Test func tagsSurviveTheRoundTrip() {
        let meta = ScriptFile.Metadata(tags: ["keynote", "billing"])
        let parsed = ScriptFile.parse(ScriptFile.render("Body.", metadata: meta))
        #expect(parsed.metadata?.tags == ["keynote", "billing"])
        #expect(parsed.body == "Body.")
    }

    /// An id read off a disk has to be written back, or the script silently
    /// becomes a different script the next time it is saved.
    @Test func anIdFromDiskIsWrittenBack() {
        let parsed = ScriptFile.parse("""
        ---
        id: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
        ---

        Body.
        """)
        let meta = try! #require(parsed.metadata)
        #expect(ScriptFile.render("Body.", metadata: meta)
            .contains("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    }

    /// ...but a brand-new script with nothing to remember stays plain text,
    /// id and all.
    @Test func aNewScriptWithNothingToRememberHasNoBlock() {
        let meta = ScriptFile.Metadata(id: UUID())
        #expect(ScriptFile.render("Body.", metadata: meta) == "Body.")
    }

    @Test func anEmptyBodyStillRoundTrips() {
        let meta = ScriptFile.Metadata(tags: ["x"])
        let parsed = ScriptFile.parse(ScriptFile.render("", metadata: meta))
        #expect(parsed.body == "")
        #expect(parsed.metadata?.tags == ["x"])
    }

    /// A blank line the author wrote must not be mistaken for the separator
    /// between the block and the talk: exactly one is removed, not all of them.
    @Test func exactlyOneBlankLineIsSeparation() {
        let body = "\n\nAct one.\n"
        let parsed = ScriptFile.parse(ScriptFile.render(body, metadata: ScriptFile.Metadata()))
        #expect(parsed.body == body, Comment(rawValue: parsed.body.debugDescription))
    }

    @Test func carriageReturnsAreNormalisedOnTheWayIn() {
        let library = ScriptLibrary(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(library.normalised("a\r\nb\rc") == "a\nb\nc")
    }

    // MARK: - Filenames

    @Test func illegalCharactersBecomeDashes() {
        #expect(ScriptFile.filename(for: "Q&A: the /what\\ now") == "Q&A- the -what- now")
        #expect(ScriptFile.filename(for: "  ") == "Untitled")
        #expect(ScriptFile.filename(for: "Talk.") == "Talk")
        #expect(ScriptFile.filename(for: ".hidden") == "-hidden")
    }

    /// A 300-character title must still produce a file the filesystem will
    /// accept, or the script cannot be saved at all.
    @Test func aVeryLongTitleStillMakesAFile() {
        let name = ScriptFile.filename(for: String(repeating: "long ", count: 120))
        #expect((name + ".md").utf8.count <= 255)
    }

    /// APFS compares case-insensitively, so "Talk" and "talk" are one name.
    /// Cuebar has to agree with the filesystem or a rename will destroy a
    /// script.
    @Test func collisionsAreFoundTheWayTheFilesystemWouldFindThem() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "one".write(to: directory.appendingPathComponent("Talk.md"), atomically: true, encoding: .utf8)

        #expect(ScriptFile.uniqueFilename("Keynote", in: directory) == "Keynote")
        #expect(ScriptFile.uniqueFilename("talk", in: directory) == "talk 2")
        #expect(ScriptFile.uniqueFilename("TALK", in: directory) == "TALK 2")
        // Renaming a script to the name it already has is not a collision.
        #expect(ScriptFile.uniqueFilename("Talk", in: directory, ignoring: ["Talk.md"]) == "Talk")
    }
}

/// Moving the library off one JSON file is the one piece of this that has to
/// be right for people who already have scripts, so it is tested against a
/// real directory rather than trusted.
@MainActor
@Suite struct ScriptLibraryMigrationTests {
    private func temporaryRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct LegacyEnvelope: Encodable {
        var selectedID: UUID?
        var scripts: [LegacyDoc]
    }
    private struct LegacyDoc: Encodable {
        var id: UUID
        var title: String
        var body: String
        var updatedAt: Date
        var lastOpenedAt: Date?
        var folderID: UUID?
        var tags: [String]
        var isFavorite: Bool
        var isArchived: Bool
    }

    @Test func aSingleFileLibraryBecomesOneFilePerScript() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let talks = ScriptFolder(name: "Talks")
        let selected = UUID()
        let legacy = LegacyEnvelope(selectedID: selected, scripts: [
            LegacyDoc(id: UUID(), title: "Keynote", body: "Good evening.",
                      updatedAt: Date(), lastOpenedAt: Date(), folderID: talks.id,
                      tags: ["q3"], isFavorite: true, isArchived: false),
            LegacyDoc(id: selected, title: "Interview/Ana: on cue", body: "Thanks for having me.",
                      updatedAt: Date(), lastOpenedAt: nil, folderID: nil,
                      tags: [], isFavorite: false, isArchived: false),
        ])
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("scripts.json"))
        try JSONEncoder().encode([talks]).write(to: root.appendingPathComponent("folders.json"))

        // The migration entry point the app uses.
        let store = ScriptStore(libraryRoot: root, legacyLibrary: root.appendingPathComponent("scripts.json"),
                                legacyFolders: root.appendingPathComponent("folders.json"))
        let keynote = try #require(store.scripts.first { $0.title == "Keynote" })
        #expect(keynote.body == "Good evening.")
        #expect(keynote.tags == ["q3"])
        #expect(keynote.isFavorite)
        #expect(store.folderPath(keynote.folderID) == "Talks")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Talks/Keynote.md").path))
        // A title with a slash and a colon still has to arrive: it becomes a
        // legal filename rather than a script that cannot be saved.
        #expect(store.scripts.contains { $0.title == "Interview-Ana- on cue" },
                Comment(rawValue: store.scripts.map(\.title).description))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Interview-Ana- on cue.md").path))

        // The old file is kept, renamed — never deleted. If the conversion is
        // wrong, the original is still there to convert again from.
        let parked = try FileManager.default
            .contentsOfDirectory(atPath: root.path).first { $0.hasPrefix("scripts.json.migrated") }
        #expect(parked != nil)

        // And the files are the library now, not the JSON.
        let reopened = ScriptStore(libraryRoot: root)
        #expect(reopened.scripts.count == 2)
        #expect(reopened.scripts.contains { $0.body == "Thanks for having me." })
    }

    /// Migrating twice must not double the library — the kind of bug that
    /// shows up as "my scripts are all still here" the first launch and
    /// "why are there two of everything" the second.
    @Test func migratingTwiceDoesNotDuplicateAnything() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LegacyEnvelope(selectedID: nil, scripts: [
            LegacyDoc(id: UUID(), title: "Only", body: "Once.", updatedAt: Date(),
                      lastOpenedAt: nil, folderID: nil, tags: [], isFavorite: false,
                      isArchived: false),
        ])
        let encoder = JSONEncoder()
        try encoder.encode(legacy).write(to: root.appendingPathComponent("scripts.json"))
        for _ in 0..<2 {
            _ = ScriptStore(libraryRoot: root,
                            legacyLibrary: root.appendingPathComponent("scripts.json"))
        }
        #expect(ScriptStore(libraryRoot: root).scripts.count == 1)
    }

    /// A script whose title is not a legal filename still has to arrive.
    @Test func illegalTitlesBecomeLegalFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = LegacyEnvelope(selectedID: nil, scripts: [
            LegacyDoc(id: UUID(), title: "Ana: \"the /end\"", body: "Body.",
                      updatedAt: Date(), lastOpenedAt: nil, folderID: nil, tags: [],
                      isFavorite: false, isArchived: false),
        ])
        try JSONEncoder().encode(legacy)
            .write(to: root.appendingPathComponent("scripts.json"))
        let store = ScriptStore(libraryRoot: root,
                                legacyLibrary: root.appendingPathComponent("scripts.json"))
        #expect(store.scripts.count == 1)
        #expect(!store.scripts[0].title.contains("/"))
        #expect(store.scripts[0].body == "Body.")
    }
}

/// What happens when the library changes *underneath* Cuebar. Both of these
/// were silent: one lost a user's edit from another app, the other turned a
/// folder-filtered sidebar into an empty "Unfiled" after a single keystroke.
@MainActor
@Suite struct ScriptStoreOutsideEditTests {
    private func temporaryRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func folderIdentitiesSurviveAReload() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let before = store.folders.map(\.id)
        #expect(before.count == 3)

        store.reloadFromDisk()
        // Compared as a set: the enumerator's order is not guaranteed, and
        // what has to hold is that no folder changed *identity*.
        #expect(Set(store.folders.map(\.id)) == Set(before),
                Comment(rawValue: "\(store.folders.map(\.id)) vs \(before)"))

        let presentations = try #require(store.folders.first { $0.name == "Presentations" })
        let doc = store.add(title: "Keynote", body: "Filed.", folder: presentations.id)
        store.reloadFromDisk()
        // The sidebar's collapsed set and folder selection key on these ids, so
        // a script must still be findable in the folder it was filed in.
        #expect(store.folderName(doc.folderID) == "Presentations")
        #expect(store.scripts(inFolder: presentations.id).map(\.id) == [doc.id])
    }

    /// The failure this pins: the open script's file was rewritten by another
    /// app, Cuebar's store adopted it, and nothing in the view tree heard
    /// about it — so the editor's debounced commit wrote the *old* text over
    /// the user's edit and the edit was gone.
    @Test func anOutsideEditToTheOpenScriptIsHeldAndReported() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let doc = store.add(title: "Talk", body: "mine")
        try await settle()

        // Somebody else rewrites the file, keeping the front matter so it is
        // still the same script.
        let url = root.appendingPathComponent("Personal/Talk.md")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "mine", with: "theirs")
        try text.write(to: url, atomically: true, encoding: .utf8)

        store.reloadFromDisk()
        #expect(store.externalChanges == [doc.id],
                Comment(rawValue: "\(store.externalChanges)"))
        #expect(store.localBody(doc.id) == "mine",
                "the editor's text must not be replaced under the caret")

        store.acceptExternalChange(doc.id)
        #expect(store.localBody(doc.id) == "theirs")
        #expect(store.externalChanges.isEmpty)
    }

    /// The other half of the offer: the presenter keeps what they typed, and
    /// that is what lands in the file.
    @Test func keepingTheEditorsVersionWritesItBack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let doc = store.add(title: "Talk", body: "mine")
        try await settle()
        let url = root.appendingPathComponent("Personal/Talk.md")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "mine", with: "theirs")
        try text.write(to: url, atomically: true, encoding: .utf8)
        store.reloadFromDisk()

        store.keepLocalVersion(doc.id)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains("mine"))
        #expect(!after.contains("theirs"))
        #expect(store.externalChanges.isEmpty)
    }

    /// A script that is *not* open is adopted without asking, which is the
    /// whole point of using files: a talk dropped in from Finder just appears.
    @Test func anOutsideEditToAnotherScriptIsAdoptedQuietly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let open = store.add(title: "Open", body: "reading this")
        let other = store.add(title: "Other", body: "first draft")
        store.select(open.id)
        try await settle()

        let url = root.appendingPathComponent("Personal/Other.md")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "first draft", with: "second draft")
        try text.write(to: url, atomically: true, encoding: .utf8)

        store.reloadFromDisk()
        #expect(store.localBody(other.id) == "second draft")
        #expect(store.externalChanges.isEmpty)
    }

    /// Cuebar's own save comes back through the watcher; it must not be read
    /// as somebody else editing the file.
    @Test func ourOwnSaveIsNotReportedAsAnOutsideEdit() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScriptStore(libraryRoot: root)
        let doc = store.add(title: "Talk", body: "mine")
        store.updateBody(doc.id, body: "mine, edited")
        try await Task.sleep(for: .milliseconds(500))
        store.reloadFromDisk()
        #expect(store.externalChanges.isEmpty,
                "the app's own write was reported as somebody else's edit")
        #expect(store.localBody(doc.id) == "mine, edited")
    }

    /// Let the debounced save land, so the file on disk is the store's.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }
}

/// A `#` at the start of a line is only a heading if the line really is one.
/// Both scanners used to buffer the line and then re-split it with a plain
/// whitespace split, which had no cue logic in it at all — so `[smile]` on a
/// `#tag` line came back as a spoken word: highlighted on stage, counted in
/// the reading-time estimate, and offered to the recogniser as a target.
@Suite struct HashTagLineTests {
    private let body = """
    #tag is how we filed it [smile] and it worked.
    A plain line for contrast.
    """

    @Test func aCueOnAHashtagLineStaysACue() {
        let cues = ScriptParser.parse(body).compactMap { token -> String? in
            if case .cue(let text) = token { return text }
            return nil
        }
        #expect(cues == ["[smile]"], Comment(rawValue: "\(cues)"))
    }

    @Test func aHashtagLineSpeaksItsWords() {
        let words = ScriptParser.words(body)
        #expect(!words.contains("[smile]"))
        #expect(words.contains("#tag"))
        #expect(words.last == "contrast.")
    }

    /// The invariant that matters: one definition of "a word". The tokeniser
    /// and the range scanner must agree, or the prompter renders a different
    /// script from the one the driver cues.
    @Test func bothScannersAgree() {
        let tokenisedWords = ScriptParser.parse(body).compactMap { token -> String? in
            if case .word(let text, _) = token { return text }
            return nil
        }
        #expect(tokenisedWords == ScriptParser.words(body),
                Comment(rawValue: "\(tokenisedWords) vs \(ScriptParser.words(body))"))
        #expect(ScriptParser.wordCount(body) == ScriptParser.words(body).count)
    }

    @Test func realHeadingsAreStillHeadings() {
        let text = "## Section one\n# Section two\n#### Too deep\n#\n#tag not a heading"
        let sections = ScriptParser.parse(text).compactMap { token -> String? in
            if case .section(let name, _) = token { return name }
            return nil
        }
        #expect(sections == ["Section one", "Section two"],
                Comment(rawValue: "\(sections)"))
        #expect(ScriptParser.words(text).contains("#tag"))
    }

    @Test func aRunOfHeadingsIsStillRecognised() {
        // Two headings in a row used to parse as one section plus stray words,
        // because the second line's `#` was no longer at a line start.
        let text = "## test\n## hello"
        #expect(ScriptParser.parse(text).compactMap { token -> String? in
            if case .section(let name, _) = token { return name }
            return nil
        } == ["test", "hello"])
        #expect(ScriptParser.words(text).isEmpty)
    }
}

/// The tidy's own promise is that it only changes how a script *reads*. Text
/// inside a `[cue]` is a note to the app, not to the presenter, and rewriting
/// it changed what the prompter showed and said.
@Suite struct TeleprompterFriendlyCueTests {
    @Test func aCueIsNotRewritten() {
        let body = "One [smile (big)] two."
        #expect(TeleprompterFriendly.rewritten(body) == body,
                Comment(rawValue: TeleprompterFriendly.rewritten(body)))
    }

    /// The failure this pins: the parser reads a cue as everything up to the
    /// first `]`, so `[smile [big]]` leaves a literal `]` word on stage.
    @Test func aRewrittenCueWouldAddASpokenBracket() {
        let body = "One [smile (big)] two."
        let before = ScriptParser.words(body)
        #expect(TeleprompterFriendly.rewritten(body) == body)
        #expect(ScriptParser.words(body) == before)
        #expect(!ScriptParser.words(body).contains("]"))
    }

    @Test func aDashInsideACueIsLeftAlone() {
        // The deck driver reads a slide cue's label, so a dash rewritten to a
        // comma inside the brackets changes a slide instruction.
        let body = "One [slide 3 — the chart] two."
        #expect(TeleprompterFriendly.rewritten(body) == body)
    }

    /// A heading's `(one)` is not a cue, and headings are text, so cleaning it
    /// is the tidy doing its job.
    @Test func markdownLinksAreStillCleaned() {
        let body = "The docs are at the [engine page](https://example.com/engine)."
        #expect(TeleprompterFriendly.rewritten(body) == "The docs are at the engine page.")
    }

    /// `array[0]` is an index; treating it as a cue would exempt the whole
    /// sentence from every rule.
    @Test func bracketedCodeIsNotMistakenForACue() {
        let ranges = ScriptFile.cueRanges(of: "The array[0] value settles here.")
        #expect(ranges.isEmpty)
        #expect(ScriptFile.cueRanges(of: "Wait [pause 2s] now.").count == 1)
        #expect(ScriptFile.cueRanges(of: "Unclosed [oops here").isEmpty)
    }
}

/// A diagnosis that points at the wrong word is worse than no diagnosis, and
/// one that points past the end of the script stages nothing at all while the
/// sheet reports success.
@Suite struct ScriptAnalysisBreathlessTests {
    private let fifteen = ["one", "two", "three", "four", "five", "six", "seven",
                           "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                           "fourteen", "fifteen."]

    @Test func aRunThatIsTheWholeSentenceStillHasAWayToLand() {
        let notes = ScriptAnalysis.analyse(words: fifteen)
        let breathless = try! #require(notes.first { $0.kind == .breathless })
        #expect(breathless.wordIndex < fifteen.count,
                Comment(rawValue: "index \\(breathless.wordIndex) is past the end"))
        // And it must actually stage, rather than quietly doing nothing.
        let body = fifteen.joined(separator: " ")
        #expect(CueInsertion.inserting(cues: CueInsertion.stagingPoints(for: notes), in: body) != body,
                "the cue vanished: \\(notes)")
    }

    @Test func aRunInsideALongerSentenceBreathesAtItsEnd() {
        // A leading 17-word run after "so", then the plain sentence. The breath
        // must land on the last word of that run — not on the first word of
        // the sentence after it, which is where "start + length" put it.
        let words = ["Okay", "so", "oooo", "pppp", "qqqq", "rrrr", "ssss", "tttt",
                     "uuuu", "vvvv", "wwww", "xxxx", "yyyy", "zzzz", "aaaa",
                     "bbbb", "cccc."] + fifteen
        let notes = ScriptAnalysis.analyse(words: words)
        let breathless = try! #require(notes.first { $0.kind == .breathless })
        #expect(breathless.wordIndex <= 17,
                Comment(rawValue: "the breath landed on \\(breathless.wordIndex), "
                    + "inside the next sentence"))
    }

    @Test func theReasonStillCountsTheWords() {
        let notes = ScriptAnalysis.analyse(words: fifteen)
        let breathless = try! #require(notes.first { $0.kind == .breathless })
        #expect(breathless.reason.contains("15 words"))
    }
}

/// Staging a cue has to visibly do something. The dedupe check used to be
/// "is there a `[`…`]` before this word", which matched ordinary text — and
/// `## Notes [draft]`, which is how half the world writes a heading, ate the
/// cue staged for the first word under it. The sheet reported success.
@Suite struct CueInsertionDedupeTests {
    @Test func aCueUnderAHeadingThatEndsInBracketsStillLands() {
        let body = "## Notes [draft]\nThis is the talk."
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 1, in: body)
        #expect(out.contains("[pause 1s]"), Comment(rawValue: out))
        #expect(out.hasPrefix("## Notes [draft]"), Comment(rawValue: out))
    }

    @Test func bracketedCodeIsNotTreatedAsAnExistingCue() {
        let body = "The array[0] value settles here."
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 2, in: body)
        #expect(out.contains("[pause 1s]"), Comment(rawValue: out))
    }

    @Test func aRealCueStillBlocksADuplicate() {
        // Words: One(0) two(1) three(2). "two" is the one already cued.
        let body = "One [smile] two three."
        #expect(CueInsertion.inserting(cue: "pause 1s", beforeWord: 1, in: body) == body,
                "a cue was staged on top of an existing one")
    }

    @Test func aCueInAnEarlierParagraphDoesNotBlock() {
        // Words: One(0) two(1) Three(2) four(3).
        let body = "[smile] One two.\n\nThree four."
        let out = CueInsertion.inserting(cue: "pause 1s", beforeWord: 2, in: body)
        #expect(out.contains("[pause 1s]"), Comment(rawValue: out))
    }
}

/// The diff is the app's promise about what Apply will do. Two of its promises
/// were wrong in a way that made a *working* feature unreachable: a
/// respacing-only rewrite reported "Identical" with Apply disabled, so the
/// tidy's own "three blank lines is a layout accident" rule could never be
/// applied at all.
@Suite struct ScriptDiffBlankLineTests {
    @Test func aRespacingOnlyRewriteIsAChange() {
        let old = "One two.\nThree four.\nFive six."
        let new = "One two.\n\nThree four.\n\nFive six."
        #expect(ScriptDiff.hasChanges(from: old, to: new),
                "Apply would have been disabled on a real change")
        #expect(ScriptDiff.changeCount(from: old, to: new) > 0)
    }

    @Test func aTrailingNewlineIsStillNotAChange() {
        #expect(ScriptDiff.changeCount(from: "One two.", to: "One two.\n") == 0)
        #expect(ScriptDiff.changeCount(from: "One two.\n\n\n", to: "One two.") == 0)
    }

    /// The strongest honest statement: whatever the chunks are, reading them
    /// left to right has to *be* the rewritten script. A preview that quietly
    /// drops a blank line is a preview that lies about what Apply writes.
    @Test func aBlankLineInAMixedEditIsVisible() {
        let before = "**One** two.\n\n\nThree *four*."
        let after = "One two.\n\nThree four."
        let chunks = ScriptDiff.chunks(from: before, to: after)
        let rendered = chunks.flatMap { chunk -> [String] in
            switch chunk {
            case .same(let line): return [line]
            case .changed(_, let new): return new.components(separatedBy: "\n")
            case .removed: return []
            case .added(let lines): return lines.components(separatedBy: "\n")
            }
        }
        #expect(ScriptDiff.changeCount(from: before, to: after) > 0)
        #expect(rendered == after.components(separatedBy: "\n"),
                Comment(rawValue: "\(chunks.map(String.init(describing:)))"))
    }
}

/// The fix round: a bracket span is protected from rules that are not about
/// brackets, and the re-audit found three ways the first attempt at that was
/// wrong in both directions.
@Suite struct CueProtectionTests {
    /// `array [0] items` — the tokenizer says a cue starts at a token start,
    /// after *any* whitespace, including the non-breaking space a Word
    /// document or a web page puts in front of a bracket.
    @Test func aNonBreakingSpaceStillStartsACue() {
        let body = "nbsp\u{00A0}[smile] after"
        #expect(ScriptFile.cueRanges(of: body).count == 1,
                Comment(rawValue: "\(ScriptFile.cueRanges(of: body))"))
        #expect(TeleprompterFriendly.rewritten(body) == body)
    }

    /// On stage `[label](url)` *is* a cue followed by words, so the label is
    /// protected too — and the link rule still cleans the link, because its
    /// match is about brackets and removes them.
    @Test func aLinkLabelIsACueAndTheLinkIsStillCleaned() {
        let body = "see [label](https://example.com) here"
        #expect(ScriptFile.cueRanges(of: body).count == 1)
        #expect(TeleprompterFriendly.rewritten(body) == "see label here",
                Comment(rawValue: TeleprompterFriendly.rewritten(body)))
    }

    @Test func bracketsAreSafeOnlyForRulesThatRemoveThem() {
        // The dash rule's replacement is a comma — no brackets in it — and it
        /// still must not reach into a cue.
        let body = "One [slide 3 — the chart] two."
        #expect(TeleprompterFriendly.rewritten(body) == body)
    }
}

/// A copied talk is two talks. Two files carrying the same id used to collapse
/// into one identity, and every later edit landed in whichever file the
/// enumerator happened to visit last.
@MainActor
@Suite struct ScriptStoreCopiedFileTests {
    @Test func aFileCopiedInFinderBecomesItsOwnScript() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ScriptStore(libraryRoot: root)
        let original = store.add(title: "Keynote", body: "The talk.")
        try await Task.sleep(for: .milliseconds(400))

        let source = root.appendingPathComponent("Personal/Keynote.md")
        try FileManager.default.copyItem(at: source,
                                         to: root.appendingPathComponent("Personal/Keynote copy.md"))
        store.reloadFromDisk()
        let copy = try #require(store.scripts.first { $0.title == "Keynote copy" })
        #expect(copy.id != original.id)

        store.updateBody(copy.id, body: "The talk, edited once.")
        try await Task.sleep(for: .milliseconds(400))   // the store debounces
        let copiedFile = try String(contentsOf:
            root.appendingPathComponent("Personal/Keynote copy.md"), encoding: .utf8)
        let originalFile = try String(contentsOf: source, encoding: .utf8)
        #expect(copiedFile.contains("edited once"))
        #expect(!originalFile.contains("edited once"),
                "the edit landed in the wrong file")
    }

    /// A file whose last write failed is the only copy of that text. A reload
    /// must not delete it — which it did, because the "hold this" list
    /// explicitly excluded the unsaved documents, and every later keystroke was
    /// then swallowed by a `firstIndex` guard on a document that was gone.
    @Test func aFailedWriteSurvivesAReload() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-unsaved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ScriptStore(libraryRoot: root)
        let keep = store.add(title: "Saved", body: "On disk.")
        let lost = store.add(title: "Blocked", body: "Only in memory")
        try await Task.sleep(for: .milliseconds(400))

        // A directory where the file should be: the write fails for a reason
        // no permission flag can undo. Placed *after* the file exists, or the
        // store would simply have named the new script "Blocked 2".
        let blocked = root.appendingPathComponent("Personal/Blocked.md")
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let unsaved = store
        unsaved.updateBody(lost.id, body: "Typed into me, never written.")
        try await Task.sleep(for: .milliseconds(400))
        #expect(unsaved.unsavedScripts.contains(lost.id))

        // An unrelated library event.
        var text = try String(contentsOf: root.appendingPathComponent("Personal/Saved.md"),
                              encoding: .utf8)
        text = text.replacingOccurrences(of: "On disk.", with: "On disk, edited.")
        try text.write(to: root.appendingPathComponent("Personal/Saved.md"),
                       atomically: false, encoding: .utf8)
        unsaved.reloadFromDisk()

        #expect(unsaved.localBody(lost.id) == "Typed into me, never written.",
                "a document that exists nowhere else was dropped by a reload")
        #expect(unsaved.scripts.contains { $0.id == keep.id })
    }

    /// "Use the File" has to stick: if the accepted text is not remembered as
    /// ours, the next reload puts the banner straight back — a button that
    /// clears a warning which returns on the next event.
    @Test func acceptingTheFileVersionSticks() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cuebar-accept-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ScriptStore(libraryRoot: root)
        let doc = store.add(title: "Talk", body: "mine")
        try await Task.sleep(for: .milliseconds(400))
        let url = root.appendingPathComponent("Personal/Talk.md")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "mine", with: "theirs")
        try text.write(to: url, atomically: true, encoding: .utf8)

        store.reloadFromDisk()
        #expect(store.externalChanges == [doc.id])
        store.acceptExternalChange(doc.id)
        store.reloadFromDisk()
        store.reloadFromDisk()
        #expect(store.externalChanges.isEmpty,
                Comment(rawValue: "the banner came back: \(store.externalChanges)"))
    }
}

/// Emphasis is file syntax, not speech — and a printed or exported script is
/// speech too. Without this the Bold button put literal asterisks into every
/// PDF and `.docx` the app produced.
@Suite struct ExportDropsEmphasisTests {
    @Test func aPDFDoesNotPrintAsterisks() {
        let blocks = PdfLayout.blocks(from: "This is **important** and *quiet*.",
                                      title: "Talk")
        #expect(blocks.contains { block in
            if case .paragraph(let text) = block {
                // The trailing period goes with the markers it followed; the
                // prompter has a setting for punctuation, and the exporter does
                // not need it here.
                return text == "This is important and quiet"
            }
            return false
        }, Comment(rawValue: "\(blocks)"))
    }

    @Test func aDocxDoesNotPrintAsterisks() throws {
        // The archive's own bytes: `document.xml` is where the text lives.
        let data = DocxWriter.document(body: "**Bold** and *soft*.", title: "Talk")
        let xml = String(decoding: data, as: UTF8.self)
        #expect(!xml.contains("**"), "literal asterisks reached the .docx")
        #expect(xml.contains("Bold"))
    }
}
