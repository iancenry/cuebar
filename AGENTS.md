# AGENTS.md — context for agents working on Cuebar

macOS teleprompter (SwiftPM, Swift 6, SwiftUI). Two targets:

- **PromptCore** (`Sources/PromptCore/`) — pure, unit-tested engine code. No SwiftUI, no AppKit. If logic can live here, it must (layout math, parsing, matching, engine).
- **Cuebar** — the app. Views, drivers, overlay, settings UI.

## Commands

```bash
swift build
swift test                     # 618 tests, PromptCore only — view logic is untested by design
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
- `PaceTarget` (PromptCore) — fit-to-time arithmetic: drift against
  `targetMinutes` (CueSettings), position-based not wall-clock, so thinking
  time is never counted against the presenter. A readout only — nothing
  changes the reading speed to hit the target. Shown in `StatusPill` (once a
  run exists) and on the phone (`driftSeconds` in `RemoteSnapshot`).
- `SleepGuard` — one `ProcessInfo.beginActivity` power assertion held while
  the engine is playing **or** the overlay is up, released when both are
  false. Owned by `PlaybackDriver` (the only view that already observes both
  inputs); idempotent so double-fires can't stack assertions. The token type
  is `any NSObjectProtocol` — the SDK deleted the typed activity class.
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
- Rehearsal — `Practice.swift` (the plan) and `RunReport.swift` (the
  arithmetic) are PromptCore and tested; `PracticeController`, `RunRecorder`,
  `RunCapture` (AVFoundation) and the two sheets are the app layer. ⌥P/⌥⇧P
  practice, ⌘⇧R record.
- Script tools — `TeleprompterFriendly` (offline tidying), `AIScript` (the
  request/response contract), `AISettings` (the non-secret half), `ScriptDiff`
  (line diffs) are PromptCore and tested; `AIClient`, `Keychain`,
  `ScriptToolsView`, `ScriptToolsTab` are the app layer. ⌥A pacing notes,
  ⌥⇧A tools.

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
- **One writer per script rewrite.** Cuebar has three things that change a
  script's text — ⌘K (the caret), pacing notes, Script Tools — and they all
  go through `CuebarApp.applyRewrite(body:to:)`: store, `draftBody`, re-parse,
  `ScriptIndex`, and an `engine.loadScript` *only when the words changed*, so
  staging a cue does not cancel a timed hold that is running.
- **The recorder is fed by the tick loop, never by its own timer.** Two loops
  reading the same engine a few milliseconds apart can invent a pause that
  never happened. `RunReport` samples at 4 Hz off `PlaybackDriver.tick`, and
  `stopIfRecording()` on `onDisappear` because a run must not keep the camera
  recording after the window that started it has gone. The tick loop stops
  when nothing is moving, so the HUD *also* calls `RunRecorder.heartbeat()`
  from a `TimelineView`: it repeats the last position and reads nothing, and
  without it a rehearsed pause reports no time at all.
- **Silence starts where the words stopped, not where the gap was noticed.**
  `RunReport`'s first version opened a pause when two samples were more than
  `pauseThreshold` apart — which only fires when the *sampler* goes quiet, and
  the recorder samples four times a second. Every real run reported "0 pauses"
  and a longest gap of zero. `RunReportDenseSamplingTests` pins the dense
  regime separately from the sparse one, because that is how it slipped
  through: the original test sampled at 1 Hz, which the app never does.
- **`startRecording` needs a path that does not exist, and enforces it with an
  Objective-C exception.** `RunCapture` created a zero-byte file first — its
  own comment said AVFoundation wanted a path that did not exist, and then it
  created one — so every recording attempt threw, and an exception on any
  thread is an unconditional `abort()`. Every clip in `Runs/` was 0 bytes,
  which is the proof visible in the filesystem. `RunCaptureFolder
  .freshDestination` creates only the *folder*; the movie file is AVFoundation's
  to make. Start the session *before* starting the recording, as Apple's sample
  does, and do both off the main actor: `requestAccess` can put a dialog on
  screen, and `startRunning` blocks for as long as the sensor takes.
- **This machine writes no crash reports for a SwiftPM-built binary**, but a
  bundled, launched app's report *is* written to
  `~/Library/Logs/DiagnosticReports/`. Read it before guessing:
  `json.loads(open(ips).read().split('\n', 1)[1])`, then the `triggered`
  thread's frames. A practice-mode crash that four hours of reasoning had not
  explained was two lines away in
  `-[AVCaptureMovieFileOutput_Tundra startRecordingToOutputFileURL:...]`.
- **A run's clip is optional; the report is not.** Every failure path in
  `RunCapture` — camera denied, no device, a delegate that never calls back —
  ends with the telemetry intact. The timeout latches are a single
  continuation resumed exactly once: resuming a `CheckedContinuation` twice
  traps, so `settle(_:_:)` is the only thing that touches them.
- **`AVPlayerViewController` is iOS.** On macOS the player is `AVPlayerView`
  in its own `NSWindow` — a sheet with a video in it swallows the report,
  which is what the presenter came for.
- **A rewrite is a diff before it is an edit.** Both the offline tidy and the
  model answer land as a preview; nothing reaches the script until Apply. And
  `TeleprompterFriendly`'s rules must be *minimal* ranges (the spaces, not the
  line): a whole-line replacement is computed from the original text and
  restores the markup a sibling rule just removed.
- **No two edits may touch the same character**, in any edit list,
  everywhere. `apply` runs right to left, so an overlapping pair means the
  second offset was computed against text the first had already changed — and
  the symptom is a *missing letter* ("text" → "ext"), not a loud failure.
  Markup rules, whitespace rules and the carriage-return pass are filtered
  through one `overlaps` check, and the invariant is a test.
- **`String.contains("\r")` is false for a string that contains one.**
  `String.contains` goes through Foundation's canonical comparison, which
  treats a carriage return as interchangeable with nothing at all; use
  `unicodeScalars.contains`. `
` is also *not* in `CharacterSet.whitespaces`,
  so "blank line" checks that trim whitespace do not see a CRLF blank line.
- **A continuation per wait, never one slot with a phase tag.** `RunCapture`
  keeps `starting` and `stopping` latches separately because both can be open
  at once: Stop pressed during Start. With a single `pending` slot, `stop()`
  overwrote the starting continuation, `start()` suspended forever, and the
  runtime said so — `SWIFT TASK CONTINUATION MISUSE: leaked its continuation
  without resuming it`. Two slots, each nil'd as it resumes: a finish answers
  both, and a late reply after a timeout finds its slot empty instead of
  trapping. Verified against a harness of the old and new shapes.
- **Do not claim a race you have not demonstrated.** The same pass asserted
  that a delegate reply could land between two synchronous lines of a
  `@MainActor` function. It cannot: the hop needs the main actor, which is
  busy executing that stretch. Measured, not assumed — a harness is cheap and
  a wrong "hard-won constraint" in this file is worse than none, because the
  next agent trusts it.
- **Guard conditions get tested, because they invert silently.** `RunCapture`
  once read `guard session.inputs.isEmpty else { throw }`, which throws on the
  *success* case: a run recorded, reported correctly, and never wrote a clip.
  The verdict lives in `CapturePlan` (PromptCore) so `CapturePlanTests` can
  pin it. The same class of bug hides in any one-line `if` a test cannot reach.
- **The key is in the keychain, the endpoint is not.** `AISettings` (provider,
  base URL, model, budget) lives in the preferences JSON; the secret lives in
  a `kSecAttrAccessibleWhenUnlocked` generic-password item, is read per
  request, and is never held in a view property. PromptCore cannot leak it,
  and two tests say so: the request body must not contain the key, and every
  task's instructions must protect `[cue]` spans and `#` headings.
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
- **The library is one Markdown file per script, in real folders**
  (`~/Documents/Cuebar/Scripts/<Folder>/<Title>.md`). One JSON envelope was
  a development shortcut that shipped into a product decision: a talk a
  presenter wrote is not the app's private database, and a single file means
  no Finder visibility, no per-script backup, no other editor, no iCloud, and
  one corrupt write to lose the lot. `ScriptFile` owns the format:
  the title *is* the filename (one name, so a rename anywhere retitles the
  script), folders are directories, and front matter is written only when
  there is metadata to keep (`id`, `created`, `opened`, `tags`, `favorite`,
  `archived`) — a script nobody has touched is plain text. Unknown
  front-matter keys are somebody else's and are left alone.
  `ScriptLibrary` is the filesystem edge (atomic write to a dot-prefixed
  sibling then rename, per-file) and `ScriptWatcher` reports outside edits;
  the store keeps the public API it always had, so views did not change.
  Consequences that are easy to undo by accident:
  - A `---`-opening script is **not** front matter — the block is only front
    matter when it carries a key Cuebar knows. Otherwise a talk that opens
    with a rule reads back as its last section, silently.
  - Filenames need sanitising (`: / ` and `\\` are illegal, a leading dot hides the
    file from Finder *and* from the scanner) and collisions are resolved
    case-insensitively, because APFS is. The title follows the numbered file.
  - Dates are written with fractional seconds. Whole seconds tie, and "the
    talk I was reading" must not depend on sort order.
  - `save()` takes the script's id. It used to default to nil and silently
    save *nothing*, which is why every call site now names its script.
  - Nothing unreadable is ever deleted or rewritten: `unreadableFiles` is
    reported, a failed write lands in `unsavedScripts` and the editor says
    "Not saved". The watcher holds in-memory text that is not yet on disk, so
    a save in flight cannot be read back over.
  - The old `scripts.json` is migrated once and **renamed**
    (`scripts.json.migrated-<stamp>`), never deleted, and never written
    again — a conversion bug must not be able to destroy the original.
- **A directory watcher does not report a file's contents.** `ScriptWatcher`
  keeps one `DispatchSource` per *directory* (entry changes: create, rename,
  delete, replace) **and** one per *script file* (content writes). The
  directory half alone looked complete and reported nothing: an in-place save
  (`> file`, `tee`, a `FileHandle`) is invisible at every directory level, so
  a talk edited in the user's own editor was never noticed and the next Cuebar
  save overwrote it. Two more things it had to get right: `rescan()` runs in
  `init`, not only from the event handler (a folder that already existed at
  launch was unwatched until something *else* reported in), and a deleted
  script's source is released (a source on a removed inode never fires again).
- **"Somebody edited this file" is a content comparison, not a clock.**
  `ScriptStore.lastWritten` holds the exact text of the last successful write,
  so `reloadFromDisk` can tell an outside edit from our own save with no echo
  window and no blind spot.
- **An outside edit to the *open* script is held and offered, never adopted.**
  Its text belongs to the caret and to the editor's pending 400 ms commit;
  reading the file back over it either loses keystrokes or silently discards
  an edit made elsewhere. So the store records `externalChanges` and the
  editor offers **Use the File** / **Keep Mine**. Any *other* script is adopted
  silently, which is the whole reason for using files.
- **A folder's id is looked up, never minted.** Folder ids are derived from a
  directory's relative path and must survive a reload: `SidebarView` keys its
  collapsed set and its folder selection on them, and re-minting on every
  `load()` popped every folder open and turned a filtered sidebar into an
  empty "Unfiled". **`relativeKey` resolves symlinks on both sides** — on
  macOS `/var` is a symlink to `/private/var` and the enumerator resolves it,
  so an unresolved comparison made every folder look new on every read.
- **A tolerant decoder forgets silently.** `CueSettings.init(from:)` once
  omitted `ai`, `advertiseRemote` and `deckApp`: written on quit, ignored on
  launch, so the phone remote stopped advertising and the AI provider/endpoint/
  model/budget reset while the keychain kept their key. A property with a
  default that the decoder forgets is a setting that only exists until the app
  quits — and the round-trip test masked it by only ever setting two fields.
- **`#` at the start of a line is only a heading if the line is one.**
  `#tag is how we filed it [smile]` used to buffer the line and re-split it
  with a plain whitespace split, which has no cue logic: `[smile]` came back
  as a *spoken* word. Both scanners now look ahead and, when the line is not a
  heading, carry on through the ordinary path — there is no second word
  scanner to forget about cues.
- **The tidy never edits a `[cue]`.** Cue text is a note to the app;
  `[smile (big)]` became `[smile [big]]`, and since the parser reads a cue as
  everything up to the first `]`, the script gained a literal `]` word that the
  presenter then said aloud. `ScriptFile.cueRanges` is the shared authority —
  a bracket span at the start of a token, *not* a Markdown link label.
- **A diagnosis has to point at a word, not at a length.** The breathless
  note used `start + run.length` as an index, so a comma-free sentence that
  was its own run pointed one past the end: the staged `[breath]` had no
  offset and vanished silently.
- **`alreadyCued` means an actual cue.** "Is there a `[`…`]` before this word"
  matched `array[0]`, and `## Notes [draft]` ate the cue staged for the first
  word under the heading — one click did nothing and said nothing.
- **A remote is an unauthenticated door.** `RemoteHTTP` refuses a negative or
  oversized `Content-Length`: the first reached `Data.prefix(_:)` and *trapped*
  before the token was even checked, so one malformed request from anything on
  the venue wifi killed the prompter mid-talk.
- **Staging a cue must not cancel the pause it wrote.** `ContentView.commit`
  skips the engine reload when the parsed tokens are unchanged; a reload calls
  `cancelHold()`, and ⌘K writes `draftBody`, which arms that debounce — so
  staging a `[pause 2s]` cancelled it 400 ms later.
- **A blank line is content.** `ScriptDiff` trims trailing blank lines from
  each *body*, once. Filtering them inside each changed chunk deleted interior
  ones too, which made a respacing-only rewrite diff as "Identical" with Apply
  disabled — so the tidy's own blank-line rules could never be applied.
- **The archive is not a queue.** Auto-next walks `liveScripts`; it used the
  full list, so it could select and play a talk the presenter had archived.
- **Reloading the deck is not free.** `SlideSync.load` starts at slide 1 and
  clears the crossed history, so it runs only when the cue *triggers* or the
  selected script change — otherwise staging a cue with ⌘K rewound the
  presenter's deck mid-talk.
- **`AXObserver` has no usable initialiser in Swift**, so a grant of
  Accessibility cannot be observed. `GlobalHotkeys` polls while it is waiting
  (a `Task`, never a `Timer`) so the tap arrives without toggling the prompter.
- **A masked word's slot is measured, not guessed.** `MaskedWordWidth` uses
  CoreText, memoised on (text, face, size, weight, tracking). Half an em per
  character was ~21% wide on prose and ~40% narrow on capitals and CJK, so the
  page re-wrapped whenever a word was unmasked. It must stay off the
  SwiftUI→AppKit bridge: `Font.custom(...)` has no `NSFont` to convert, and the
  throw happens inside the layout pass (an unconditional `abort`).
- **Watch the tree with FSEvents, not with a descriptor per file.** The
  library is one `FSEventStream` with `FileEvents` + `MustScanSubDirs`. The
  previous design opened a `DispatchSource` per directory *and* per script,
  and was wrong twice: a directory's descriptor reports entry changes and
  never content, so an in-place save (`> file`, `tee`, a `FileHandle`) was
  invisible; and adding a descriptor per file fixed that at the cost of the
  whole process's descriptor budget — a Finder-launched app inherits
  `launchctl limit maxfiles` = 256, so a few hundred talks exhausted it and
  **the app could no longer save anything at all** (measured: 20/20 writes
  failing with the watcher on, 0/20 with it off). An atomic save also
  *replaces* the file, leaving a descriptor on a dead inode — so the script
  stopped being watched after its first save, which is the exact case the
  rewrite existed for. The debounce also needs a ceiling: with only a trailing
  edge, a steady stream of writes (a backup agent, a `git checkout`) starved
  the reload for as long as it lasted.
- **A file copied in Finder is a second script.** Two files carrying the same
  id used to collapse into one identity — last-writer-wins on the path map —
  so every later edit landed in whichever file the enumerator happened to
  visit last while the sidebar showed the other one. A duplicate id on a
  different path now mints a new id.
- **A failed write is the only copy of that text.** `reloadFromDisk` must
  re-add such a document from memory. The "hold this while reloading" list
  excluded exactly those, so the next unrelated library event deleted the
  script and every later keystroke was swallowed by a `firstIndex` guard on
  something that no longer existed.
- **`ScriptFile.uuid(from:)` accepts braced and unhyphenated UUIDs**, and
  `UUID(uuidString:)` alone refuses both — silently minting a new id and
  writing it into the file on the next save, which loses the identity every
  other tool that knew the file still uses.
- **Front matter needs an `id` or a `created` line to count.** A block of any
  other recognised key is a *talk about Cuebar* that opens with a horizontal
  rule: `---\narchived: true\n---` used to archive the script that contained
  it.
- **Three places a presenter can be, and the one that is restored.**
  `ReadingPosition` keeps the prompter's position, the last word voice
  *confirmed*, and the last word they deliberately *jumped to* — they are
  different questions, and only the first is where you resume. It is a single
  `positions.json` beside the scripts and deliberately **not** in the script's
  front matter: a position changes several times a minute, and rewriting a
  talk's file that often would mean an atomic save and a watcher event per
  tick. `resumeIndex(into:)` refuses a position from a much longer script,
  because restoring word 700 into a 120-word talk is a blank prompter.
- **Voice tracking uncertainty resolves to *stopping*, never to scrolling
  away.** The most-reported failure in this product class is the prompter
  jumping paragraphs; the fix that works is to hold position and say so. No
  percentage: Apple's per-segment confidence is unverified on device (reported
  absent by the tools that read it, never calibrated anywhere we found), and a
  presenter cannot act on a figure mid-sentence. A breath between sentences is
  *not* a loss — 1.6s, then two confirmations to re-arm — because treating every
  pause as a failure produces the other common complaint: it stops and you have
  to restart. `TrackingUncertaintyTests` pins the rule as pure arithmetic.
- **A preset is a patch, not a copy.** `CuePreset` carries only the settings it
  changes, so applying one never resets the dozen it leaves out, and a preset
  written today still means something after the app grows a setting. The four
  that ship describe four genuinely different presentations.
- **Emphasis is file syntax, not speech.** `**bold**` stays in the Markdown and
  comes off *before* anything is said, read, counted, matched **or exported** —
  which is what makes an editor Bold button safe in a teleprompter. Five rules,
  each of which broke something the first time it was written:
  the strip needs a *balanced run of equal length* at both ends of one word, or
  `2*3*4` is spoken as `234`; the closing run may be followed by punctuation
  (`*quiet*.` — requiring the marker last left asterisks on stage all sentence);
  `****` is a pair around nothing and must be left alone, or an empty word is
  counted in the duration and offered to the matcher; the **unclosed-bracket**
  word branch strips too, or `parse` and `words` disagree permanently and every
  ⌘K reloads the engine and cancels the hold it just wrote; and `wordRanges`
  keeps the **outer** range including the markers, because a staged cue's
  character offset is measured from there and inserting at the trimmed start
  split the word in two.
- **Settings is a sidebar, not a tab strip.** Nine pages in four groups
  (Essentials, Appearance, Library, System) with a search field, each page a
  titled pane of cards. It replaced a six-tab `TabView`: a strip has to be
  *remembered*, and the pause behaviour living in "Voice" is exactly the sort of
  thing nobody finds. Nothing was dropped in the move — every section of every
  old tab is still here — and `Scripts`, `Presets` and `General` are new pages
  for settings that had nowhere sensible to live. Search matches *keywords*, not
  just titles, so "wpm" finds the page that says "Words per minute".
- **Deleting asks, and the question can be turned off.** `confirmBeforeDeleting`
  is read by the sidebar's own delete action, not merely displayed — a switch
  that says it confirms and is then ignored is worse than no switch.
- **A delete confirmation names the file.** "This deletes the file in
  `~/Documents/Cuebar/Scripts`", because that is what it now does.
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
- **Mirror flips the reading surface only.** The `scaleEffect` sits on the
  scroll ZStack in `PrompterBody` (and `ReadingPreview`), never on the
  header/footer/page controls: the glass un-flips the script for the
  presenter, while whoever drives the controls still faces readable chrome.
  `scaleEffect` is a transform, not a re-layout — anchoring, fades and
  tap-to-jump all work in the flipped space.
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
