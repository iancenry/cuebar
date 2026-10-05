import SwiftUI
import PromptCore
import AppKit
import AVKit

/// The recording indicator. It lives in the transport rather than floating
/// over the prompter because a presenter glances *down* for it: the dot, the
/// clock, and whether the clip is actually being written. The last of those
/// is the reason this is not just a red dot — a rehearsal where the camera
/// silently produced nothing is worse than one that never asked.
struct RunHUD: View {
    @Bindable var recorder: RunRecorder

    /// The tick loop feeds the recorder while something is moving; this feeds
    /// it while the presenter has stopped to think. Without it a paused
    /// rehearsal reported no time at all — see `RunRecorder.heartbeat`.
    ///
    /// Twice the report's sampling rate, so a run that is only ever fed from
    /// here still gets a sample every quarter second rather than every half.
    private static let cadence: Double = RunRecorder.sampleInterval / 2

    /// The clock is derived from the timeline's date rather than kept as
    /// `@State`: one fewer thing to synchronise, and no 8 Hz write to
    /// app-lifetime state repainting every observer of the recorder.
    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.cadence)) { context in
            row(at: context.date)
                .onChange(of: context.date) { _, _ in recorder.heartbeat() }
        }
    }

    private func row(at now: Date) -> some View {
        HStack(spacing: 8) {
            Button {
                recorder.toggle()
            } label: {
                Label(recorder.isRecording ? "Stop" : "Record",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(recorder.isRecording ? Color.red : CuePalette.ink.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(recorder.isRecording
                  ? "Stop the run and show the report"
                  : "Time this run: pace, pauses and how far you got")

            if recorder.isRecording {
                Divider().frame(height: 14)
                dot
                Text(Self.clock(recorder.startedAt.map { now.timeIntervalSince($0) } ?? 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CuePalette.ink)
                if recorder.isCapturingVideo {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.red)
                        .help("Recording video and audio")
                } else if let issue = recorder.captureIssue {
                    Image(systemName: "video.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(CuePalette.muted)
                        .help(issue)
                }
            }
        }
        .fixedSize()
    }

    private var dot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Recording")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rest = total % 60
        return String(format: "%d:%02d", minutes, rest)
    }
}

/// The report. Numbers first, then the shape of the run underneath them —
/// a presenter wants to know *where* they rushed, not that they did.
struct RunResultsView: View {
    let result: RunReport.Result
    var clip: URL?
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(CuePalette.ink)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 10) {
                stat("Ran", RunHUD.clock(result.duration))
                stat("Pace", "\(Int(result.averagePace.rounded())) wpm")
                stat("Speaking", "\(Int(result.speakingPace.rounded())) wpm")
                stat("Reached", "\(result.wordsReached)/\(result.totalWords)")
                if result.sectionTotal > 0 {
                    stat("Sections", "\(result.sectionsCompleted)/\(result.sectionTotal)")
                }
            }

            PaceChart(pace: result.pace, pauses: result.pauses)

            if !result.pauses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pauses")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CuePalette.muted)
                        .textCase(.uppercase)
                    ForEach(Array(result.pauses.prefix(5).enumerated()), id: \.offset) { index, pause in
                        HStack(spacing: 8) {
                            Text(RunHUD.clock(pause.start))
                                .monospacedDigit()
                                .foregroundStyle(CuePalette.ink.opacity(0.7))
                            Capsule()
                                .fill(CuePalette.peach.opacity(0.7))
                                .frame(width: min(160, pause.length * 22), height: 4)
                            Text(String(format: "%.1fs", pause.length))
                                .monospacedDigit()
                                .foregroundStyle(CuePalette.inkMuted)
                            if index == 0 {
                                Text("longest")
                                    .font(.caption2)
                                    .foregroundStyle(CuePalette.peach)
                            }
                        }
                        .font(.caption)
                    }
                }
            }

            Spacer(minLength: 0)

            if let clip {
                HStack {
                    Label("Clip saved", systemImage: "video.fill")
                        .font(.caption)
                        .foregroundStyle(CuePalette.inkMuted)
                    Text(clip.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(CuePalette.ink.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Play") {
                        RunCapturePlayerWindow.present(clip)
                    }
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([clip])
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(22)
        .frame(width: 560, height: 460, alignment: .topLeading)
        .background(CuePalette.surface)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(CuePalette.muted)
                .textCase(.uppercase)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(CuePalette.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CuePalette.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Words per minute per window, with the gaps drawn where they happened:
/// a bar is pace, a notch is a pause, and the two together are the shape of
/// the talk.
struct PaceChart: View {
    let pace: [RunReport.Pace]
    let pauses: [RunReport.Pause]

    private var peak: Double { max(60, pace.map(\.wordsPerMinute).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pace over the run")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CuePalette.muted)
                .textCase(.uppercase)
            GeometryReader { geometry in
                let barWidth = max(4, geometry.size.width / CGFloat(max(pace.count, 1)) - 3)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(pace.enumerated()), id: \.offset) { _, window in
                        let height = geometry.size.height
                            * CGFloat(min(1, window.wordsPerMinute / peak))
                        Capsule()
                            .fill(CuePalette.peach.opacity(0.75))
                            .frame(width: barWidth, height: max(2, height))
                            .help("\(RunHUD.clock(window.start)) · \(Int(window.wordsPerMinute.rounded())) wpm")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 96)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(CuePalette.card, in: RoundedRectangle(cornerRadius: 10))
            if !pauses.isEmpty {
                Text("Longest pause \(String(format: "%.1f", pauses[0].length))s · "
                     + "\(RunHUD.clock(pauses.reduce(0) { $0 + $1.length })) of silence in total")
                    .font(.caption)
                    .foregroundStyle(CuePalette.inkMuted)
            }
        }
    }
}

/// The clip, in its own small window.
///
/// `AVPlayerView` (not `AVPlayerViewController` — that one is iOS) in a
/// window rather than in a sheet: a rehearsal video is the thing you watch
/// *after* reading the report, and a sheet that swallows the report with a
/// video in it is the wrong order.
enum RunCapturePlayerWindow {
    @MainActor
    static func present(_ url: URL) {
        let player = AVPlayer(url: url)
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.title = url.lastPathComponent
        window.center()
        window.isReleasedWhenClosed = false
        // Keep it alive: nothing else holds a reference once this returns,
        // and a released player window plays nothing. The list is a cache, not
        // a log — a presenter who plays the same rehearsal six times should
        // not leave six windows behind.
        players.append(NSWindowController(window: window))
        if players.count > 3 {
            let stale = players.removeFirst()
            stale.close()
        }
        window.makeKeyAndOrderFront(nil)
        player.play()
    }

    @MainActor private static var players: [NSWindowController] = []
}
