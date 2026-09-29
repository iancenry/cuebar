# AGENTS.md — context for agents working on Cuebar

macOS teleprompter (SwiftPM, Swift 6, SwiftUI). Two targets:

- **PromptCore** (`Sources/PromptCore/`) — pure, unit-tested engine code. No SwiftUI, no AppKit. If logic can live here, it must (layout math, parsing, matching, engine).
- **Cuebar** — the app. Views, drivers, overlay, settings UI.

## Commands

```bash
swift build
swift test                     # 168 tests, PromptCore only — view logic is untested by design
./Scripts/make-app.sh          # build dist/Cuebar.app (debug); pass "release" for release
open dist/Cuebar.app
```

**Always run the packaged app, not `swift run`.** A bare binary never owns the
menu bar (⌘K/⌘S/⌘O/⌘N don't fire) and TCC prompts (mic/speech) get attributed
to the parent terminal instead of Cuebar. The bundle script handles Info.plist
+ resource bundle (`.build/$CONFIG` is a symlink — globs need a trailing slash)
and ad-hoc signs it.

## Architecture map

- `CuebarApp` — scenes, the Playback menu (every command, chord spelled out),
  cue palette, import/export.
- `PlaybackDriver` (view in ContentView background) — the 60 Hz MainActor Task
  loop that ticks the engine; owns guidance gating, smart pause, timed-cue
  holds, voice lifecycle, ticker lifecycle.
- `VoiceTracker` + `LegacyDriver` (SFSpeechRecognizer) / `AnalyzerDriver`
  (SpeechAnalyzer, macOS 26+) — mic + transcription. Drivers are thin; the
  tracker owns state/matching.
- `PromptEngine` — tick-driven word-position engine; velocity ramps; timed
  holds (`[pause 2s]`).
- `ReadingWindow` — pure layout/geometry (pages, notch placement, word
  ranges, jump words). Cue behaviour lives in `ScriptIndex`.
- `HotkeyPolicy.swift` + `TextFlow.swift` (PromptCore) — the one key-decision
  function both key hooks call, and the pure wrapping-layout arithmetic
  `FlowLayout` renders with. Both are fuzzed in tests because their bugs
  (a swallowed keystroke, a collapsed line height) were both invisible.
- `ScriptIndex.swift` (PromptCore) — one parse per edit: word indices, page
  slicing (O(page) not O(script)), pre-interpreted cues and the cue plan. The
  *only* implementation of the cue rules; `ReadingWindow`'s three readers
  delegate to it. `tokens` and `index` are built together, in one place
  (`ContentView.adopt`) — a path that wrote one without the other would leave
  the prompter rendering a different script from the one the driver cues.
- `Shortcuts.swift` (PromptCore) — `KeyChord` / `ShortcutAction` / `ShortcutMap`:
  the whole remapping model, AppKit-free and unit-tested.
- `OverlayController` — NSPanel (notch/floating/fullscreen), chrome-only refresh.
- `HotkeyCenter` — one dispatcher for every command: menu items and keys both
  go through `perform(_:)`, so a rebind moves the command and its menu row.
  Owns the app-wide `keyDown` local monitor.
- `GlobalHotkeys` — optional session-level key tap for presenting over
  another app; off by default, and only armed while the overlay is showing
  (`OverlayController.onPresentingChanged`, which fires even with the main
  window closed). Both hooks call `HotkeyPolicy.decide`.
- `ScriptStore` / `SettingsStore` — @Observable stores, debounced persistence.
  `ScriptDocument.wordCount` is cached and `body` is read-only, so the two
  can't drift.

## Hard-won constraints (do not regress)

- **Audio taps**: the tap closure runs on Apple's realtime thread — never touch
  actor state there (`nonisolated`, locals only). `AVAudioConverter.convert(to:from:)`
  (push style) **cannot do sample-rate conversion** and throws an uncatchable
  ObjC exception (`_AVAE_Check` → SIGABRT); mic is 48 kHz, analyzer wants 16 kHz —
  always use the block-based pull converter. Taps are installed once per session
  (Legacy recycles swap only the request via a lock-guarded box); converter input
  format must equal the pinned tap format.
- **Swift 6.2 runtime bug**: `MainActor.assumeIsolated` crashes (SIGBUS) when
  called from a run-loop context with no task. The ticker is a MainActor
  `Task` loop — do not reintroduce `Timer` + `assumeIsolated`.
- **Voice-gated ticking**: voiceActivated ticks only while speaking, but both
  voice modes must keep ticking while `engine.isStopping || engine.isHolding` or
  pause() never settles and timed cues never expire.
- **Smart mode is match-driven**: confirmed transcript matches move the highlight;
  the WPM timer only takes over after a ~2.5 s match stall (`lastMatchDate`) or
  the 3 s post-Play grace — ticking it during all speech cruised ahead of the
  reader's words. Transcript matching only fires while speech is recent
  (<1.5 s since last VAD hit — recognizers drain buffered audio after you stop).
- **Manual always wins**: play/pause/jump cancel holds; matching never moves the
  highlight backwards (monotonic confirm).
- **One key policy, two hooks**: `HotkeyPolicy.decide` (PromptCore, tested)
  is the only place that answers "what happens to this key press". The
  `NSEvent` local monitor uses it for the app; the optional `CGEvent` tap
  (`GlobalHotkeys`) uses it for the presenting-over-another-app case. The tap
  stands down when Cuebar is frontmost, so the two can never both fire.
  A session-level tap needs the Accessibility permission **and an
  unsandboxed build** — `Cuebar.entitlements` sets app-sandbox, so the
  setting reports `.unavailable` rather than pretending. Opt-in only, and
  only while the overlay is up.
- **One owner per chord**: the key monitor in `HotkeyCenter` is the
  *only* thing that dispatches keys, and menu rows carry **no**
  `.keyboardShortcut` (they spell the live chord out in the title). An earlier
  split — native shortcut for shipped chords, monitor for rebound ones —
  silently stranded five commands: their default chord was neither, so
  ⌥F/⌥M/⌥O/⌥[/⌥] did nothing while the menu advertised them. A second owner
  also risks one press driving two commands. The monitor fires only when a
  chord has **exactly one** claim; ambiguity (a hand-edited prefs file) means
  nobody fires, which is the safe way to be wrong. `ShortcutMap.bind` swaps
  with the current holder and `reset` hands the freed chord to whoever was
  using it, so no command can be left without a key.
- **Key monitor**: `HotkeyCenter.refresh()` reinstalls the monitor so the
  closure captures the shortcut map, capture mode and the Edit-mode binding as
  plain *values* — the handler must not read MainActor state off-task, and
  `MainActor.assumeIsolated` from a monitor is the SIGBUS trap above. Bindings
  need a modifier (a bare key would type), ⌘Q/⌘W/⌘M/⌘H/⌘Tab/⌘,/⌘/ stay with
  macOS, and in Edit mode only *stage* commands (the ones that drive the
  display) fire — so ⌘K/⌘F/⌘R keep their macOS meaning in the editor.
  `HotkeyWiring` reinstalls on a mode change, because the decision context
  snapshots whether the editor is up and a stale value would eat the editor's
  own keys,
  and `event.isARepeat` is dropped (native shortcuts never repeat). The
  recorder reuses the same monitor, which is why it checks capture mode first,
  and it *swallows* a reserved chord rather than forwarding ⌘Q.
- **Cue arrival is forward-only**: `handleCueArrival` remembers the last index
  and writes it *unconditionally*, so a backwards jump (Previous Cue, restart,
  tapping an earlier word) never re-fires the `[pause 2s]` it lands on — and
  still re-arms every cue after it. Resetting the mark to `nil` instead looked
  equivalent and wasn't: `arriving` became unconditionally true. Starting playback on a cue *does* execute it, which is
  how a leading `[pause 2s]` works — hence the `force` flag on the play
  transition. The cue map is built once per script (`ReadingWindow.cuePlan`),
  not per word change.
- **Mic mute is intent, not state**: `VoiceTracker.isMutedByUser` survives
  `syncVoice`, which re-opens the mic on every Play in voice modes — a mute
  living only in `voice.state` was undone the moment Play was pressed. A mute
  also (a) abandons a smart auto-pause, since auto-resume needs a mic to hear
  you, and (b) puts both voice modes back on the reading clock, because the
  presenter asked to stop *listening*, not to stop reading. `VoiceTracker.start`
  is async: it re-checks the mute (and `Task.isCancelled`) after every await,
  or a mute during an on-device model download leaves a live capture behind.
- **Parse once, index once**: `ScriptIndex` is built next to `tokens` in one
  place (`ContentView.adopt`) and read by the prompter, the driver, the
  overlay and the dispatcher. It is the only implementation of the cue
  rules and the only source of cue strings for rendering — a second
  implementation is how `[pause 2s][smile]` came to cancel its own hold.
- **Don't put hot-loop bookkeeping in `@State`**: `@State` lives on the view,
  so writing one twice a tick invalidated `PlaybackDriver.body` (nine
  modifiers) to redraw a zero-size view. The tick and smart-pause accumulators
  live in reference-typed boxes instead.
- **Settings/scripts saves are debounced** (300 ms) — sliders write at drag rate.
- **Force dark appearance** (`preferredColorScheme(.dark)`) — CuePalette is a
  dark-only design; Light Mode washes everything out.
- **Sandbox vs the key tap**: a session-level `CGEvent` tap needs the
  Accessibility permission *and* an unsandboxed build; `Cuebar.entitlements`
  sets app-sandbox, so the setting reports `.unavailable` rather than
  pretending. The *local* monitor needs neither, which is why it is the
  primary path and the tap is opt-in.
- **Cue-only scripts**: `ScriptIndex.pageTokenRange` has no word range to
  slice by, so it falls back to the whole token array — otherwise a script
  that is nothing but cues renders a blank page.
- `glassSurface(in:)` wraps Liquid Glass (macOS 26+) with a card fallback —
  glass goes on floating chrome only, never on the reading surface.
- `.build/debug` is a **symlink** — `find`/globs need a trailing slash.

## Conventions

- Comments explain *why*, not what. They often encode a past crash — read them
  before refactoring the surrounding code.
- Everything is `@MainActor` + `@Observable`; audio-tap closures are
  `nonisolated` on purpose (a MainActor touch there is a runtime trap — the
  build is arranged to fail compilation if you regress it).
- Pure logic goes in PromptCore with tests; keep Cuebar views thin.
- Crash logs from real runs land in `~/Library/Logs/DiagnosticReports/Cuebar-*.ips`
  — check the newest one before guessing at crash causes.
