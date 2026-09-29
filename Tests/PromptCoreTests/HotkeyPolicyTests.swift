import Testing
import Foundation
@testable import PromptCore

/// The key policy used to live inline in the event monitor — untestable, and
/// twice implemented once a global tap existed. It is pure now, and this is
/// the contract.
@Suite struct HotkeyPolicyTests {
    private func chord(_ action: ShortcutAction) -> KeyChord {
        ShortcutMap.default.chord(for: action)
    }

    private var performContext: HotkeyPolicy.Context {
        var c = HotkeyPolicy.Context()
        c.map = .default
        return c
    }

    @Test func everyDefaultChordIsConsumedInPerformMode() {
        for action in ShortcutAction.allCases {
            let decision = HotkeyPolicy.decide(chord(action), isRepeat: false,
                                               context: performContext)
            #expect(decision == .consume(action), "unreachable command: \(action.rawValue)")
        }
    }

    @Test func unboundChordsPassThrough() {
        let free = KeyChord(keyCode: KeyCode.a, modifiers: [.control, .option, .command])
        #expect(HotkeyPolicy.decide(free, isRepeat: false, context: performContext) == .forward)
        // A bare key is never ours — it has to keep typing.
        let bare = KeyChord(keyCode: KeyCode.space, modifiers: [])
        #expect(HotkeyPolicy.decide(bare, isRepeat: false, context: performContext) == .forward)
    }

    @Test func repeatsAreSwallowedForOursAndForwardedOtherwise() {
        let mine = chord(.playPause)
        #expect(HotkeyPolicy.decide(mine, isRepeat: true, context: performContext) == .ignore)
        let theirs = KeyChord(keyCode: KeyCode.a, modifiers: [.control, .option, .command])
        #expect(HotkeyPolicy.decide(theirs, isRepeat: true, context: performContext) == .forward)
    }

    @Test func ambiguousChordFiresNobody() {
        // A hand-built map with two commands on one chord: the safe answer.
        var map = ShortcutMap(bindings: [
            .restart: KeyChord(keyCode: KeyCode.j, modifiers: .command),
            .nextCue: KeyChord(keyCode: KeyCode.j, modifiers: .command),
        ])
        map.resetAll()   // keep the binding; `resetAll` is the escape hatch
        map = ShortcutMap(bindings: [
            .restart: KeyChord(keyCode: KeyCode.j, modifiers: .command),
            .nextCue: KeyChord(keyCode: KeyCode.j, modifiers: .command),
        ])
        var context = performContext
        context.map = map
        #expect(HotkeyPolicy.decide(KeyChord(keyCode: KeyCode.j, modifiers: .command),
                                    isRepeat: false, context: context) == .forward)
    }

    @Test func editorKeepsItsOwnEditingChords() {
        var context = performContext
        context.isEditing = true
        // Stage commands still work, so the mic and the overlay can be
        // toggled while editing.
        #expect(HotkeyPolicy.decide(chord(.toggleMicrophone), isRepeat: false,
                                    context: context) == .consume(.toggleMicrophone))
        #expect(HotkeyPolicy.decide(chord(.toggleFullscreen), isRepeat: false,
                                    context: context) == .forward)   // ⌘F is Find
        // ⌘K has no macOS meaning and a cue is text, so the palette
        // answers here — the editor's own footer advertises it.
        #expect(HotkeyPolicy.decide(chord(.insertCue), isRepeat: false,
                                    context: context) == .consume(.insertCue))
        // So does play/pause, for the same reason: the footer advertises
        // Option-Space, and the handler promotes to Perform.
        #expect(HotkeyPolicy.decide(chord(.playPause), isRepeat: false,
                                    context: context) == .consume(.playPause))
        // The rest are released: text-navigation chords and the document
        // commands that would swap the file out from under the caret.
        for action in [ShortcutAction.restart, .nextCue, .speedUp, .jumpForward, .newScript] {
            #expect(HotkeyPolicy.decide(chord(action), isRepeat: false,
                                        context: context) == .forward,
                    "editor should keep \(action.rawValue)")
        }
    }

    @Test func noWindowKeepsOnlyTheScriptCommands() {
        var context = performContext
        context.hasWindow = false
        for action in [ShortcutAction.insertCue, .newScript, .importScripts, .exportScript] {
            #expect(HotkeyPolicy.decide(chord(action), isRepeat: false,
                                        context: context) == .consume(action))
        }
        for action in [ShortcutAction.playPause, .restart, .toggleOverlay, .toggleFollow] {
            #expect(HotkeyPolicy.decide(chord(action), isRepeat: false,
                                        context: context) == .forward)
        }
    }

    @Test func theGlobalTapStandsDownWhenCuebarIsInFront() {
        var context = performContext
        context.source = .global
        context.isFrontmost = true
        #expect(HotkeyPolicy.decide(chord(.playPause), isRepeat: false,
                                    context: context) == .forward)
        context.isFrontmost = false
        #expect(HotkeyPolicy.decide(chord(.playPause), isRepeat: false,
                                    context: context) == .consume(.playPause))
    }

    // MARK: - Recording

    @Test func recordingCapturesTheChord() {
        var context = performContext
        context.recording = .restart
        let pressed = KeyChord(keyCode: KeyCode.j, modifiers: [.control, .option])
        #expect(HotkeyPolicy.decide(pressed, isRepeat: false, context: context)
                == .record(.restart, pressed))
    }

    @Test func escCancelsAndReservedChordsAreRefused() {
        var context = performContext
        context.recording = .restart
        let escape = KeyChord(keyCode: KeyCode.escape, modifiers: [])
        #expect(HotkeyPolicy.decide(escape, isRepeat: false, context: context) == .cancelRecording)
        // ⌘Q must be swallowed (it would quit the app) and explained.
        let quit = KeyChord(keyCode: KeyCode.q, modifiers: .command)
        guard case .refuse(let reason) = HotkeyPolicy.decide(quit, isRepeat: false, context: context)
        else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("macOS"))
        // A modifier-less press is refused too, not silently eaten.
        guard case .refuse = HotkeyPolicy.decide(KeyChord(keyCode: KeyCode.a, modifiers: []),
                                                 isRepeat: false, context: context) else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test func recordingBeatsTheCommandPath() {
        // Even the action's own current chord is recorded, not executed.
        var context = performContext
        context.recording = .playPause
        #expect(HotkeyPolicy.decide(chord(.playPause), isRepeat: false, context: context)
                == .record(.playPause, chord(.playPause)))
    }

    @Test func repeatIsIgnoredWhileRecording() {
        var context = performContext
        context.recording = .restart
        #expect(HotkeyPolicy.decide(KeyChord(keyCode: KeyCode.j, modifiers: .command),
                                    isRepeat: true, context: context) == .ignore)
    }
}

@Suite struct HotkeyContextTests {
    /// The context factory is the seam the app's monitor and tap both build
    /// from, so its fields are the whole decision — nothing else is read at
    /// dispatch time.
    @Test func theFactoryFillsEveryField() {
        var map = ShortcutMap()
        map.bind(KeyChord(keyCode: KeyCode.j, modifiers: [.control, .option]), to: .restart)
        let context = HotkeyPolicy.context(source: .global, map: map, recording: .playPause,
                                           hasWindow: false, isEditing: true)
        #expect(context.source == .global)
        #expect(context.map.chord(for: .restart) == KeyChord(keyCode: KeyCode.j,
                                                             modifiers: [.control, .option]))
        #expect(context.recording == .playPause)
        #expect(context.hasWindow == false)
        #expect(context.isEditing)
    }

    /// A context built with a stale `isEditing` was the defect that ate the
    /// editor's own keys: transport chords were swallowed and then dropped.
    @Test func aStaleEditFlagIsVisibleAsWrongBehaviour() {
        let stale = HotkeyPolicy.context(source: .local, map: .default, recording: nil,
                                         hasWindow: true, isEditing: false)
        let fresh = HotkeyPolicy.context(source: .local, map: .default, recording: nil,
                                         hasWindow: true, isEditing: true)
        // ⌘↑ is a real text-navigation binding, so it is the chord that
        // shows the difference: the flag is what decides whether we eat it.
        let speedUp = ShortcutMap.default.chord(for: .speedUp)
        // Stale: the key is ours and gets eaten, but `perform` is inert in the
        // editor — a swallowed keystroke that does nothing.
        #expect(HotkeyPolicy.decide(speedUp, isRepeat: false, context: stale) == .consume(.speedUp))
        // Fresh: the editor keeps the key and moves the caret with it.
        #expect(HotkeyPolicy.decide(speedUp, isRepeat: false, context: fresh) == .forward)
        // Play/pause is editor-safe now, so both flags consume it — the
        // guard against this class of bug is `HotkeyWiring` reinstalling
        // the monitor on a mode change, not the policy.
        let playPause = ShortcutMap.default.chord(for: .playPause)
        #expect(HotkeyPolicy.decide(playPause, isRepeat: false, context: stale) == .consume(.playPause))
        #expect(HotkeyPolicy.decide(playPause, isRepeat: false, context: fresh) == .consume(.playPause))
        // The stage commands answer in both.
        let mic = ShortcutMap.default.chord(for: .toggleMicrophone)
        #expect(HotkeyPolicy.decide(mic, isRepeat: false, context: stale) == .consume(.toggleMicrophone))
        #expect(HotkeyPolicy.decide(mic, isRepeat: false, context: fresh) == .consume(.toggleMicrophone))
    }
}
