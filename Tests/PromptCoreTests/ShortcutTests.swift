import Testing
import Foundation
@testable import PromptCore

@Suite struct ShortcutTests {
    // MARK: - Chords

    @Test func chordDescriptionsUseSystemGlyphs() {
        #expect(KeyChord(keyCode: KeyCode.space, modifiers: .option).description == "⌥Space")
        #expect(KeyChord(keyCode: KeyCode.k, modifiers: .command).description == "⌘K")
        #expect(KeyChord(keyCode: KeyCode.upArrow, modifiers: [.command, .shift]).description == "⇧⌘↑")
        #expect(KeyChord(keyCode: KeyCode.m, modifiers: [.control, .option, .shift, .command]).description == "⌃⌥⇧⌘M")
        #expect(KeyChord(keyCode: KeyCode.rightBracket, modifiers: .option).description == "⌥]")
        #expect(KeyChord(keyCode: KeyCode.enter, modifiers: []).description == "↩")
    }

    @Test func chordsNeedAModifier() {
        #expect(!KeyChord(keyCode: KeyCode.space, modifiers: []).isValid)
        #expect(!KeyChord(keyCode: KeyCode.a, modifiers: []).isValid)
        #expect(KeyChord(keyCode: KeyCode.space, modifiers: .option).isValid)
    }

    /// ⌘Q is the only way out of the app — binding it would trap the user.
    @Test func systemShortcutsAreReserved() {
        for code in [KeyCode.q, KeyCode.w, KeyCode.m, KeyCode.h, KeyCode.tab] {
            #expect(KeyChord(keyCode: code, modifiers: .command).isReserved)
            #expect(!KeyChord(keyCode: code, modifiers: .command).isValid)
        }
        // Same key without ⌘ is fine.
        #expect(KeyChord(keyCode: KeyCode.m, modifiers: .option).isValid)
    }

    // MARK: - Defaults

    @Test func defaultChordsAreUnique() {
        let chords = ShortcutAction.allCases.map(\.defaultChord)
        #expect(Set(chords).count == chords.count)
        #expect(ShortcutMap.default.hasUniqueChords)
    }

    @Test func everyDefaultIsValid() {
        for action in ShortcutAction.allCases {
            #expect(action.defaultChord.isValid)
        }
    }

    @Test func emptyMapServesDefaults() {
        let map = ShortcutMap()
        for action in ShortcutAction.allCases {
            #expect(map.chord(for: action) == action.defaultChord)
            #expect(!map.isCustomized(action))
        }
    }

    // MARK: - Binding

    @Test func bindingStoresOnlyOverrides() {
        var map = ShortcutMap()
        let free = KeyChord(keyCode: KeyCode.j, modifiers: [.control, .option])
        map.bind(free, to: .playPause)
        #expect(map.chord(for: .playPause) == free)
        #expect(map.isCustomized(.playPause))
        #expect(map.customized == [.playPause])
        map.reset(.playPause)
        #expect(map.chord(for: .playPause) == ShortcutAction.playPause.defaultChord)
        #expect(map.customized.isEmpty)
    }

    @Test func bindingTheShippedChordStoresNothing() {
        var map = ShortcutMap()
        map.bind(KeyChord(keyCode: KeyCode.space, modifiers: .option), to: .playPause)
        #expect(!map.isCustomized(.playPause))
        #expect(map.customized.isEmpty)
    }

    /// Taking another command's key swaps them instead of leaving two
    /// commands on one key (or silently disarming one).
    @Test func bindingOverAnotherCommandSwapsThem() {
        var map = ShortcutMap()
        let stolen = ShortcutAction.insertCue.defaultChord
        map.bind(stolen, to: .playPause)
        #expect(map.chord(for: .playPause) == stolen)
        #expect(map.chord(for: .insertCue) == ShortcutAction.playPause.defaultChord)
        #expect(map.hasUniqueChords)
    }

    @Test func swappingBackRestoresTheDefaults() {
        var map = ShortcutMap()
        let stolen = ShortcutAction.insertCue.defaultChord
        map.bind(stolen, to: .playPause)
        map.bind(ShortcutAction.playPause.defaultChord, to: .insertCue)
        #expect(map.chord(for: .playPause) == stolen)
        #expect(map.chord(for: .insertCue) == ShortcutAction.playPause.defaultChord)
    }

    @Test func invalidChordsAreRefused() {
        var map = ShortcutMap()
        let before = map.chord(for: .playPause)
        map.bind(KeyChord(keyCode: KeyCode.space, modifiers: []), to: .playPause)
        map.bind(KeyChord(keyCode: KeyCode.q, modifiers: .command), to: .playPause)
        #expect(map.chord(for: .playPause) == before)
        #expect(map.customized.isEmpty)
    }

    /// The key monitor acts only on a chord with exactly one claim, so a
    /// command that can be reached by no key at all is worse than a bad
    /// default: it is silent. Every action must be dispatchable as shipped.
    @Test func everyCommandIsReachableInTheDefaultMap() {
        let map = ShortcutMap.default
        for action in ShortcutAction.allCases {
            #expect(map.claims(of: map.chord(for: action)) == [action])
        }
    }

    @Test func lookupFindsTheOwner() {
        var map = ShortcutMap()
        #expect(map.holder(of: ShortcutAction.toggleFollow.defaultChord) == .toggleFollow)
        map.bind(KeyChord(keyCode: KeyCode.j, modifiers: .command), to: .restart)
        #expect(map.holder(of: KeyChord(keyCode: KeyCode.j, modifiers: .command)) == .restart)
        // ⌘J belonged to nobody, so Restart kept its ⌘R… unless asked otherwise.
        #expect(map.chord(for: .restart) == KeyChord(keyCode: KeyCode.j, modifiers: .command))
        #expect(map.holder(of: ShortcutAction.restart.defaultChord) == nil)
    }

    /// Swapping on reset: the command that was squatting on the freed default
    /// chord takes over the chord being given up, so no key is ever orphaned.
    @Test func resetHandsTheFreedChordToWhoeverWasUsingIt() {
        var map = ShortcutMap()
        map.bind(ShortcutAction.insertCue.defaultChord, to: .playPause)
        #expect(map.chord(for: .playPause) == ShortcutAction.insertCue.defaultChord)
        #expect(map.chord(for: .insertCue) == ShortcutAction.playPause.defaultChord)
        map.reset(.playPause)
        #expect(map.chord(for: .playPause) == ShortcutAction.playPause.defaultChord)
        #expect(map.chord(for: .insertCue) == ShortcutAction.insertCue.defaultChord)
        #expect(map.hasUniqueChords)
        #expect(!map.isCustomized(.insertCue))
    }

    /// Even a map that somehow starts out colliding must repair fully.
    @Test func bindingRepairsEveryClaimant() {
        var map = ShortcutMap(bindings: [
            .restart: KeyChord(keyCode: KeyCode.j, modifiers: .command),
            .nextCue: KeyChord(keyCode: KeyCode.j, modifiers: .command),
        ])
        let collided = map.chord(for: .restart)
        #expect(map.claims(of: collided).count == 2)
        map.bind(collided, to: .previousCue)
        // Both squatters move to the chord being given up — repairing only the
        // first would leave a collision the monitor silently ignores.
        #expect(map.chord(for: .restart) == ShortcutAction.previousCue.defaultChord)
        #expect(map.chord(for: .nextCue) == ShortcutAction.previousCue.defaultChord)
        #expect(map.claims(of: ShortcutAction.previousCue.defaultChord).count == 2)
        #expect(map.claims(of: collided) == [.previousCue])
    }

    @Test func everyCommandIsDescribedAndGrouped() {
        for action in ShortcutAction.allCases {
            #expect(!action.title.isEmpty)
            #expect(!action.help.isEmpty)
            #expect(ShortcutAction.allCases.filter { $0.group == action.group }.count >= 4)
        }
        #expect(Set(ShortcutAction.allCases.map(\.group)).count == 3)
    }

    /// Every recorded chord must be displayable, or the Keyboard tab and the
    /// menu would print "Key 96".
    @Test func chordNamesExistForEveryBoundKey() {
        for action in ShortcutAction.allCases {
            #expect(!KeyChord.name(for: action.defaultChord.keyCode).hasPrefix("Key "))
        }
        #expect(KeyChord.name(for: 200) == "Key 200")   // unbound keys still read
    }

    @Test func resetAllClearsOverrides() {
        var map = ShortcutMap()
        map.bind(KeyChord(keyCode: KeyCode.j, modifiers: .command), to: .restart)
        map.bind(KeyChord(keyCode: KeyCode.k, modifiers: .control), to: .nextCue)
        map.resetAll()
        #expect(map.customized.isEmpty)
        #expect(map.hasUniqueChords)
    }

    // MARK: - Persistence

    @Test func bindingsSurviveSettingsRoundTrip() throws {
        var settings = CueSettings()
        settings.shortcuts.bind(KeyChord(keyCode: KeyCode.j, modifiers: .command), to: .restart)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CueSettings.self, from: data)
        #expect(decoded.shortcuts.chord(for: .restart) == KeyChord(keyCode: KeyCode.j, modifiers: .command))
        #expect(decoded.shortcuts.isCustomized(.restart))
        #expect(!decoded.shortcuts.isCustomized(.playPause))
    }

    @Test func freshSettingsCarryTheDefaults() throws {
        let decoded = try JSONDecoder().decode(CueSettings.self, from: Data("{}".utf8))
        #expect(decoded.shortcuts.chord(for: .playPause) == ShortcutAction.playPause.defaultChord)
    }

    @Test func unusableBindingsFallBackToTheDefault() throws {
        // Hand-written prefs: a chord with no modifier would type into the
        // script, and ⌘Q would trap the user in the app. Neither is honoured.
        let json = """
        {"shortcuts":{"restart":{"keyCode":40,"modifiers":0},
                      "nextCue":{"keyCode":53,"modifiers":0},
                      "playPause":{"keyCode":12,"modifiers":8}}}
        """
        let decoded = try JSONDecoder().decode(CueSettings.self, from: Data(json.utf8))
        #expect(decoded.shortcuts.chord(for: .restart) == ShortcutAction.restart.defaultChord)
        #expect(decoded.shortcuts.chord(for: .nextCue) == ShortcutAction.nextCue.defaultChord)
        #expect(decoded.shortcuts.chord(for: .playPause) == ShortcutAction.playPause.defaultChord)
        #expect(decoded.shortcuts.customized.isEmpty)
        #expect(decoded.shortcuts.hasUniqueChords)
    }
}

@Suite struct ShortcutResilienceTests {
    /// A hand-edited prefs file must not be able to orphan a command: an
    /// override that lands on another command's *shipped* chord is rejected
    /// rather than accepted, because the dispatcher (rightly) refuses a
    /// chord with two claims and both commands would go silent.
    @Test func anOverrideCannotStealAnotherCommandsDefault() throws {
        let json = #"{"shortcuts":{"playPause":{"keyCode":40,"modifiers":8}}}"#  // ⌘K
        let decoded = try JSONDecoder().decode(CueSettings.self, from: Data(json.utf8))
        #expect(decoded.shortcuts.customized.isEmpty)
        #expect(decoded.shortcuts.chord(for: .playPause) == ShortcutAction.playPause.defaultChord)
        #expect(decoded.shortcuts.chord(for: .insertCue) == ShortcutAction.insertCue.defaultChord)
        #expect(decoded.shortcuts.hasUniqueChords)
    }

    /// Unknown modifier bits (a corrupt or hand-edited payload) must not
    /// produce a chord that claims a modifier nothing renders — it would
    /// read as bare and swallow plain typing.
    @Test func unknownModifierBitsAreMasked() throws {
        #expect(KeyChord.Modifiers(rawValue: 16).isEmpty)   // a bit we never render
        #expect(KeyChord.Modifiers(rawValue: 16).rawValue == 0)
        let json = #"{"shortcuts":{"restart":{"keyCode":49,"modifiers":16}}}"#  // ⌥Space + 16
        let decoded = try JSONDecoder().decode(CueSettings.self, from: Data(json.utf8))
        // Masked to "no modifier" → unusable → dropped, so Restart keeps ⌘R
        // instead of parking on a chord that would swallow plain typing.
        #expect(decoded.shortcuts.customized.isEmpty)
        #expect(decoded.shortcuts.chord(for: .restart) == ShortcutAction.restart.defaultChord)
    }

    @Test func settingsAndHelpChordsStayWithMacOS() {
        // ⌘, opens Settings and ⌘/ opens Help; Cuebar's own menus claim both.
        for code: UInt16 in [43, 44, 50, 27] {
            #expect(KeyChord(keyCode: code, modifiers: .command).isReserved)
        }
        #expect(KeyChord(keyCode: 43, modifiers: .option).isValid)
    }

    /// ⌘N must stay with macOS: Cuebar is single-window, and it is the way
    /// back once the window is closed.
    @Test func newScriptDoesNotClaimCommandN() {
        #expect(ShortcutAction.newScript.defaultChord
            == KeyChord(keyCode: KeyCode.n, modifiers: [.command, .shift]))
        #expect(ShortcutAction.newScript.defaultChord != KeyChord(keyCode: KeyCode.n,
                                                                 modifiers: .command))
    }
}
