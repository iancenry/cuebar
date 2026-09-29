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

    @Test func legacyDocsDecodeWithDefaultCategory() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","body":"hi there","updatedAt":0}
        """.data(using: .utf8)!
        let doc = try JSONDecoder().decode(ScriptDocument.self, from: json)
        #expect(doc.category == "Scripts")
        #expect(doc.wordCount == 2)
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
