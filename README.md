# Cuebar

A teleprompter for the Mac, built for people who speak from a script —
keynotes, lectures, streams, and the camera. It scrolls what you wrote,
follows your voice while you read it, and gets out of the way.

Cuebar is a native macOS app: SwiftUI, Swift 6, no Electron, no subscription,
no cloud between you and your own words. Your scripts are plain Markdown
files in real folders that Finder, iCloud, and any other editor can open.

## Features

**Four ways to move**

- **Traditional** — a steady clock at your chosen words-per-minute.
- **Smart** — the highlight follows your voice word for word. On-device
  speech recognition matches the transcript against the script; when
  tracking loses you, Cuebar stops and says so instead of guessing and
  jumping paragraphs. Uncertainty resolves to waiting, never to scrolling.
- **Voice** — scroll only while you are actually speaking.
- **Auto** — picks the mode for you.

**A prompter that lives where your eyes are**

- Notch island that grows out of the camera housing, a draggable floating
  panel, or fullscreen on any display.
- Mirror mode (horizontal / vertical / both) for beam-splitter glass and
  periscope rigs — the script flips, the controls don't.
- Hidden from screen sharing and recordings, so a captured stream never
  shows the prompter.
- Adjustable typography: four families (including OpenDyslexic), size,
  weight, tracking, line and paragraph spacing, alignment, themes, and a
  high-contrast mode.

**Cues in the text**

Write directions into the script and Cuebar acts on them:

```
Welcome, everyone. [smile]

## The demo

Here is the slide deck. [slide 3]

Let this land. [pause 2s]

Take a breath. [breath 1.5]
```

Timed cues (`[pause 2s]`, `[hold 500ms]`, `[breath 1.5]`) hold the prompter
for their duration; a bare `[pause]` eases to a stop until you say go on.
`[slide 4]` steps Keynote or PowerPoint. Cues render as badges and never
count as words. **Bold** and *italic* mark emphasis on stage and come off
before anything is read or matched.

**A phone as your remote**

Any phone's browser on the same network can drive the prompter: play/pause,
scrub, sections, slides, speed, follow and mic. The server only listens
while the prompter is up, and the six-hex token in the address is the whole
of its authority — it is never advertised over Bonjour.

**Rehearsal, with evidence**

- Practice mode hides words you should know and reveals them on demand.
- Record a rehearsal run (with camera) and get a report: pauses, pace
  over time, where the run ended.
- Pacing notes diagnose breathless sentences offline, before you're at
  the lectern.

**A script library, not a database**

One Markdown file per script, in real folders under
`~/Documents/Cuebar/Scripts`. Titles are filenames, front matter is only
what Cuebar needs, and edits you make in another app are detected and
offered rather than overwritten. Import `.txt`, `.md`, `.rtf`, `.docx`,
`.pdf`, `.html`, a web page, or the clipboard; export to PDF, DOCX, HTML,
or a web page. Drop a file anywhere on the window.

**And the rest**

- Fit-to-time: set a target length and the status pill shows how far
  ahead or behind your pace is — a readout, never an automatic speed
  change.
- Script Tools: an offline tidy that fixes teleprompter-hostile text, and
  optional AI-assisted rewrites (your key, your provider, diffed and
  applied only when you say so).
- Presets, remappable shortcuts, opt-in global hotkeys, launch at login,
  auto-next script, resume-where-you-were, and a display that stays awake
  while you're presenting.

## Requirements

- macOS 15 (Sequoia) or newer
- A Mac that can run Swift 6 to build it (see below)
- On macOS 26 and newer, transcription uses Apple's SpeechAnalyzer;
  earlier systems use `SFSpeechRecognizer`. Both run on-device. Voice
  modes ask for microphone and speech-recognition permission the first
  time.

## Building

```bash
swift build          # debug build
swift test           # engine test suite (PromptCore)
./Scripts/make-app.sh        # dist/Cuebar.app, debug
./Scripts/make-app.sh release
open dist/Cuebar.app
```

**Always run the packaged app, not `swift run`.** A bare binary doesn't own
the menu bar, so its keyboard shortcuts don't fire, and macOS attributes
the microphone permission prompt to whatever terminal launched it instead
of Cuebar. The bundle script handles the `Info.plist`, the resource bundle,
and ad-hoc signing.

## Using it

1. Drop a script on the window, or import one with ⌘O.
2. Press **⌥Space** to read. The prompter pops out; everything is
   drivable from the keyboard.
3. Open the phone remote from Settings → Display while the prompter is up.

### The keys that matter

All of these are remappable in Settings → Keyboard.

| Key | Does |
| --- | --- |
| `⌥Space` | Play / pause |
| `⌘↑` / `⌘↓` | Speed ±10 wpm (`⇧` for ±1) |
| `⌥←` / `⌥→` | Jump 10 s back / forward |
| `⌥[` / `⌥]` | Previous / next cue |
| `⌥⇧←` / `⌥⇧→` | Previous / next slide |
| `⌥O` | Show / hide the prompter overlay |
| `⌘F` | Fullscreen prompter |
| `⌥F` / `⌥M` | Follow / microphone |
| `⌘K` | Cue palette (drop a `[cue]` at the caret) |
| `⌘B` / `⌘I` | Bold / italic |
| `⌘O` / `⌘S` | Import / export |
| `⇧⌘V` / `⇧⌘U` | New script from clipboard / from a web page |
| `⌥P` / `⌥⇧P` | Practice on / off / reveal |
| `⌘⇧R` | Record a rehearsal run |
| `⌘R` | Restart |
| `⌥A` / `⌥⇧A` | Pacing notes / Script Tools |
| `⌥⇧I` | Resume reading where you left off |

Every command is also in the **Playback** menu with its live chord spelled
out, and the phone remote always follows the bindings Settings shows.

## The script format

A script is a Markdown file. The title is the filename. `#` headings become
sections (what the pager and the phone navigate), `**bold**` and `*italic*`
mark emphasis, and `[square brackets]` are cues. Front matter is optional
and only written when there is metadata worth keeping:

```markdown
---
id: 9E4B96BE-581A-4D48-B53C-63FBB4434F6F
created: 2026-10-05T09:30:00.000Z
tags: keynote, v2
favorite: true
---

# Opening

Good morning. [smile]
```

A `---` opening line is only front matter when it carries a key Cuebar
knows — a talk that just opens with a horizontal rule stays a talk.

## Development

The package has two targets:

- **PromptCore** — the pure engine: parsing, layout math, the prompter's
  motion, cue behaviour, speech matching, the shortcut model, the script
  library's file format, and the run-report arithmetic. No SwiftUI, no
  AppKit. If logic can live here, it must — it is where the 618 tests are.
- **Cuebar** — the app: views, audio drivers, the overlay, the phone
  remote's transport, and the panels. Thin on purpose; view logic is
  untested by design.

```bash
swift test         # PromptCore suite
swift build        # everything
```

Two conventions worth knowing before you touch anything: comments in this
codebase explain *why*, not what, and they often encode a past crash — read
them before refactoring. And every new setting needs an entry in
`CueSettings.init(from:)`'s tolerant decoder; a property the decoder forgets
is a setting that exists only until the app quits, and the round-trip sweep
in `SettingsRoundTripTests` is what catches it.

## Acknowledgements

- [OpenDyslexic](https://opendyslexic.org/) is bundled under the SIL Open
  Font License (see `Sources/Cuebar/Resources/OFL.txt`).
