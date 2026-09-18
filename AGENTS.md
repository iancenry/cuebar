# AGENTS.md — context for agents working on Cuebar

macOS teleprompter (SwiftPM, Swift 6, SwiftUI). Two targets:

- **PromptCore** (`Sources/PromptCore/`) — pure, unit-tested engine code. No SwiftUI, no AppKit. If logic can live here, it must (layout math, parsing, matching, engine).
- **Cuebar** — the app. Views, drivers, overlay, settings UI.

## Commands

```bash
swift build
swift test                     # 84 tests, PromptCore only — view logic is untested by design
./Scripts/make-app.sh          # build dist/Cuebar.app (debug); pass "release" for release
open dist/Cuebar.app
```

**Always run the packaged app, not `swift run`.** A bare binary never owns the
menu bar (⌘K/⌘S/⌘O/⌘N don't fire) and TCC prompts (mic/speech) get attributed
to the parent terminal instead of Cuebar. The bundle script handles Info.plist
+ resource bundle (`.build/$CONFIG` is a symlink — globs need a trailing slash)
and ad-hoc signs it.

## Architecture map

- `CuebarApp` — scenes, menu commands (⌘N/⌘O/⌘S/⌘K), cue palette, import/export.
- `PlaybackDriver` (view in ContentView background) — the 60 Hz MainActor Task
  loop that ticks the engine; owns guidance gating, smart pause, timed-cue
  holds, voice lifecycle, ticker lifecycle.
- `VoiceTracker` + `LegacyDriver` (SFSpeechRecognizer) / `AnalyzerDriver`
  (SpeechAnalyzer, macOS 26+) — mic + transcription. Drivers are thin; the
  tracker owns state/matching.
- `PromptEngine` — tick-driven word-position engine; velocity ramps; timed
  holds (`[pause 2s]`).
- `ReadingWindow` — pure layout/geometry (pages, notch placement, cue maps).
- `OverlayController` — NSPanel (notch/floating/fullscreen), chrome-only refresh.
- `ScriptStore` / `SettingsStore` — @Observable stores, debounced persistence.

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
- **Voice-gated ticking**: voiceActivated/wordTracking tick only while speaking,
  but must keep ticking while `engine.isStopping || engine.isHolding` or pause()
  never settles and timed cues never expire.
- **Smart mode must not move in silence**: WPM fallback = 3 s grace after Play
  with a live mic only; transcript matching only fires while speech is recent
  (<1.5 s since last VAD hit — recognizers drain buffered audio after you stop).
- **Manual always wins**: play/pause/jump cancel holds; matching never moves the
  highlight backwards (monotonic confirm).
- **Settings/scripts saves are debounced** (300 ms) — sliders write at drag rate.
- **Force dark appearance** (`preferredColorScheme(.dark)`) — CuePalette is a
  dark-only design; Light Mode washes everything out.
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
