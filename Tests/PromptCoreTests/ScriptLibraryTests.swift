import Foundation
import Testing
import PromptCore

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

    @Test @MainActor func categoriesRegisterAndDerive() {
        let store = ScriptStore(inMemory: [])
        #expect(store.knownCategories.isEmpty)
        let doc = store.add(title: "Talk")
        store.setCategory("Interviews", for: doc.id)
        #expect(store.knownCategories == ["Interviews"])
        let seeded = ScriptStore(inMemory: [
            ScriptDocument(title: "A", body: "hi", category: "Presentations"),
            ScriptDocument(title: "B", body: "yo", category: "Presentations"),
        ])
        #expect(seeded.knownCategories == ["Presentations"])
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
        #expect(s.readingWidth == nil)
        #expect(s.naturalPacing == true)
        #expect(s.catchUpBoost == 1.6)
        #expect(s.pauseOnPauseCues == false)
        #expect(s.releaseFollowOnScroll == true)
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

    @Test func legacyDocsDecodeWithDefaultCategory() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","body":"hi there","updatedAt":0}
        """.data(using: .utf8)!
        let doc = try JSONDecoder().decode(ScriptDocument.self, from: json)
        #expect(doc.category == "Scripts")
        #expect(doc.wordCount == 2)
    }
}
