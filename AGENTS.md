# AGENTS.md — context for agents working on Cuebar

macOS teleprompter (SwiftPM, Swift 6, SwiftUI). Two targets:

- **PromptCore** (`Sources/PromptCore/`) — pure, unit-tested engine code. No SwiftUI, no AppKit. If logic can live here, it must (layout math, parsing, matching, engine).
- **Cuebar** — the app. Views, drivers, overlay, settings UI.

## Commands

```bash
swift build
swift test                     # 290 tests, PromptCore only — view logic is untested by design
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
  can't drift. `add(body:)` and `importScript(_:)` both file beside the
  current script rather than always landing in Unfiled.
- Import/export — `ScriptFormat`, `ScriptText`, `MarkdownText`, `HTMLText`,
  `WebPage`, `ScriptImport`, `ZipWriter`, `DocxWriter`, `PdfLayout` are all
  PromptCore and all tested; `ScriptIO` (panels), `SystemText`
  (`NSAttributedString`/`PDFKit`), `PdfExport` (CoreGraphics), `ScriptWeb`
  (`URLSession`), `ScriptDragDrop` and `ScriptIntake` are the app layer.

## Hard-won constraints (do not regress)

- **Audio taps**: the tap closure runs on Apple's realtime thread — never touch
  actor state there (`nonisolated`, locals only). `AVAudioConverter.convert(to:from:)`
  (push style) **cannot do sample-rate conversion** and throws an uncatchable
  ObjC exception (`_AVAE_Check` → SIGABRT); mic is 48 kHz, analyzer wants 16 kHz —
  always use the block-based pull converter. Taps are installed once per session
  (Legacy recycles swap only the request via a lock-guarded box); converter input
  format must equal the pinned tap format.
- **A `@Sendable` closure is not an isolation guarantee**: Swift 6 lets a
  callback written inside a `@MainActor` method *type-check* as if it ran
  on the main actor, but a framework that owns the callback (Network,
  AppKit, an ObjC completion) runs it on its own queue. Calling into
  `@MainActor` state from the body is a runtime trap, not a compile error:
  the phone remote's `NWConnection.receive` handler built
  `state()` → `ScriptStore.selected` off-actor and died with
  `EXC_BREAKPOINT` (SIGTRAP), taking the prompter down mid-talk. Every
  framework callback that reaches app state must hop explicitly —
  `Task { @MainActor in … }` — even where the compiler says it is already
  isolated. Same family as the ticker bug below.
- **Swift 6.2 runtime bug**: `MainActor.assumeIsolated` crashes (SIGBUS) when
  called from a run-loop context with no task. The ticker is a MainActor
  `Task` loop — do not reintroduce `Timer` + `assumeIsolated`.
- **Voice-gated ticking**: voiceActivated ticks only while the *recognizer is
  producing words* (`VoiceTracker.lastWordDate`), not while the level meter says
  speech — a bang on the desk trips any VAD, and the adaptive noise floor only
  learns to ignore a *sustained* noise, so level-gated ticking let a bumped desk
  scroll the script. The sole exception is a recognizer that has never delivered
  a single transcript, where the level meter is the only evidence available and a
  frozen prompter is the worse failure. Both voice modes must also keep ticking
  while `engine.isStopping || engine.isHolding` or pause() never settles and
  timed cues never expire.
- **Smart mode is match-driven**: confirmed transcript matches move the highlight;
  the WPM timer only takes over after a ~2.5 s match stall (`lastMatchDate`) *and*
  recent recognized words, or during the 3 s post-Play grace — ticking it during
  all detected sound cruised ahead of the reader's words and turned room noise
  into scrolling. `SpeechMatcher` confirms a *chain* (consecutive script
  positions, ≤`maxChainGap` apart, ≥`minChainDensity` of its span, grown back from
  the newest match): a plain subsequence scan confirmed everything between any two
  heard words, and a transcript word that missed used to consume the whole script
  window — which killed matching entirely once the 20-word tail sat behind the
  reading position. Every transcript word is tried as the anchor of the
  alignment and the best chain wins, because a single greedy pass cannot
  recover from a duplicate word — the on-device recognizer garbles enough
  of a live read ("Cuebar" → "Cuba", "Press Option-Space to" → "It's best
  to") that a two-word gap cap never completed a chain and the highlight
  froze at the first misheard word. Transcript matching only fires while speech is recent
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
- **The phone remote is a server, so it is armed only while the prompter is
  up** (`ContentView.armRemote` on the overlay edge, `disarm` on the way
  down), and its authority is a six-hex token that is *not* put in the
  Bonjour TXT record — advertising it would hand the remote to every
  device on the venue wifi. `NSLocalNetworkUsageDescription` +
  `NSBonjourServices` are in the packaging script: without them the
  listener never becomes ready on macOS 15+, so the address in Settings
  would simply never appear. The request parser and the page's whole
  command vocabulary live in `PromptCore` (`RemoteHTTP`, `RemoteSnapshot`)
  and are tested, because an unparsed request must be *refused*, never
  guessed at.
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
  Accessibility permission *and* an unsandboxed build, so the setting reports
  `.unavailable` rather than pretending. The *local* monitor needs neither,
  which is why it is the primary path and the tap is opt-in. Note what
  `make-app.sh` actually does: it ad-hoc signs **without**
  `--entitlements`, so the packaged app is *not* sandboxed today and
  `Cuebar.entitlements` documents intent rather than reality. Turning the
  sandbox on is a one-line change to that script and a project-wide change
  to what works — don't do it as a side effect of something else.
- **Cue-only scripts**: `ScriptIndex.pageTokenRange` has no word range to
  slice by, so it falls back to the whole token array — otherwise a script
  that is nothing but cues renders a blank page.
- **Import is one pipeline, entered from five places.** `ScriptImport.plan`
  (PromptCore, tested) decides everything: decode, normalise, reject what is
  empty or oversized, de-duplicate titles against the library. `SystemText`
  and `PdfExport` (app layer) are the only parts that need a framework, and
  `ScriptIntake.land` is the only thing that inserts *and* selects. The
  panel, the pasteboard, the web sheet, a Finder drop and a drag all end up
  there — five copies of "insert, select, report what was skipped" is five
  chances to forget the last step, which is the one the user notices.
- **The reader is chosen by extension, not by format.** `.rtf` and `.html`
  are both `ScriptFormat.richText` and want opposite readers, so
  `ScriptFormat.reader(forFilename:)` exists and is tested; insisting RTF on
  an HTML file imported nothing, and a file that imports as nothing looks
  exactly like a file that was never imported.
- **Two different hygiene rules, on purpose.** A *file* keeps its layout
  (leading indentation included) so an exported script round-trips byte for
  byte; *pasted* text is de-indented, because the indentation on a paste
  came from a mail client or a code block and means nothing aloud. Text
  formats are decoded by `ScriptText`, which strips zero-width characters,
  soft hyphens and exotic spaces — Word and PDF put them inside ordinary
  words, and the tokenizer split on them. U+200D/U+200C are deliberately
  *not* stripped: they hold an emoji sequence together.
- **Paste is verbatim, `.md` is not.** The pasteboard's plain-text flavour is
  already the readable version of what was copied, so it is taken as-is;
  a `.md` file goes through `MarkdownText`, which keeps headings (they
  become sections) and drops inline markup so nothing says "star star" from
  the stage.
- **An import lands *on stage*, not in the editor.** The import commands run
  at app level (`CuebarApp`), where `mode` — the perform/edit switch —
  cannot be reached, so `ScriptStore.lastImportedID` is the relay:
  `ContentLifecycle` watches it, switches to Perform, and clears it. Watch
  the id rather than the selection, or a script the user goes back to later
  drags them out of the editor at the wrong moment.
- **No `CFBundleDocumentTypes`, deliberately.** With a `WindowGroup`,
  declaring them makes macOS open a *window per file* — Cuebar is
  single-window by design (one editor, one overlay, one key monitor). Files
  arrive through ⌘O, a drag or the pasteboard; a `cuebar://` link is an
  event rather than a document, so it never makes a window.
- **Drops are told apart, not guessed.** `ScriptDropReader` reads the
  drag's *pasteboard* directly, in a fixed order — a script (our private
  `com.cuebar.script` type), then files, then text — and it refuses text
  that is a path, because AppKit hands a file drop back as a path string
  too. The receiving view is an AppKit `NSView` in a **background layer**
  (`ScriptDropArea`), not SwiftUI's `onDrop`: `onDrop` takes part in hit
  testing, so covering the window with drop targets cost it its buttons,
  and `NSItemProvider` loads are async, which puts a drag that has already
  finished into a `Task`. `NSTextView` answers a file drop by inserting the
  path as text *before* any target is consulted, and its
  `readablePasteboardTypes` has no setter — so `ScriptText.droppedFile`
  (pure, tested) finds the insertion afterwards and the editor imports the
  document instead. A drop target nobody can see reads as broken, so every
  one has an accent border while targeted.
- **There is no Import button in the sidebar, and that is load-bearing.**
  A SwiftUI `Button` in the rail's top row never ran its action: the events
  reached the window, `hitTest` named the hosting view, a synthetic click on
  an identical control works in a plain window, and a tap gesture in the same
  place fired 20/20 while an identical `Button` in the editor works every
  time. Scripts come in by **dropping them on the window** instead — the
  better gesture for a teleprompter anyway — with ⌘O as the keyboard path.
  Do not add a button back there to "fix" discoverability without measuring
  that it fires first.
- **A PDF is drawn with CoreText, not `NSAttributedString.draw(at:)` in a
  "flipped" `NSGraphicsContext`.** That trick is for bitmap contexts; on a
  PDF consumer it rendered the page upside-down *and* mirrored — a file that
  opens, looks like a document, and is unreadable. `PdfLayout` owns the
  arithmetic (pure, tested); `PdfExport` only measures and draws.
- **`.docx` is written, not read, by Cuebar.** A minimal stored-entry ZIP of
  five XML parts; `ZipWriter` stores uncompressed because Apple's
  libcompression only offers a zlib-wrapped deflate and the container wants
  raw. Two of its bugs are invisible in the file and fatal in Word: XML
  attributes must be separated by a space (a `\` continuation eats the next
  line's indentation) and every part needs a correct CRC-32. Verify a change
  with `unzip -l` + `xmllint` + `textutil -convert txt`.
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
