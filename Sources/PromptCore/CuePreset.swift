import Foundation

/// A named bundle of reading settings.
///
/// A preset is a **patch, not a copy**. It carries only the settings it
/// actually changes, so a preset written today keeps meaning something after
/// the app grows a new setting tomorrow — a full snapshot would silently
/// reset whatever the user changed afterwards, every time they applied it
/// again.
///
/// Four ship with the app because they describe four genuinely different
/// presentations, and a presenter should not have to assemble "large text,
/// slow, strong highlight, no clock" from four separate controls before their
/// first run.
public struct CuePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    /// Built-ins cannot be deleted or renamed. A user preset can.
    public var isBuiltIn: Bool

    // Every field is optional and means "leave this alone".
    public var textSize: CueSettings.TextSize?
    public var prompterScale: Double?
    public var wordsPerMinute: Double?
    public var naturalPacing: Bool?
    public var smartPause: CueSettings.SmartPauseMode?
    public var pauseOnPauseCues: Bool?
    public var showElapsed: Bool?
    public var highlightStyle: CueSettings.HighlightStyle?
    public var highlightCurrent: Bool?
    public var lineSpacing: Double?
    public var letterSpacing: Double?
    public var readingWidth: Double?
    public var showCues: Bool?
    public var alwaysOnTop: Bool?
    public var overlayMode: CueSettings.OverlayMode?
    public var guidance: CueSettings.GuidanceMode?
    public var fontFamily: CueSettings.FontFamily?
    public var fontWeight: CueSettings.FontWeight?
    public var highlight: CueSettings.Accent?
    public var cueColor: CueSettings.Accent?
    public var textColor: CueSettings.TextColor?
    public var surfaceStyle: CueSettings.SurfaceStyle?
    public var paragraphSpacing: Double?
    public var catchUpBoost: Double?
    public var pageSize: Int?

    public init(id: UUID = UUID(), name: String, symbolName: String,
                isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isBuiltIn = isBuiltIn
    }

    /// The settings this preset actually changes, for the summary line under
    /// its name. Order is fixed so the line does not reshuffle between launches.
    public var summary: [String] {
        var out: [String] = []
        if let prompterScale, prompterScale != CueSettings().prompterScale {
            out.append("text \(Int((prompterScale * 100).rounded()))%")
        }
        if let wordsPerMinute, wordsPerMinute != CueSettings().wordsPerMinute {
            out.append("\(Int(wordsPerMinute)) wpm")
        }
        if let smartPause, smartPause != .off { out.append("auto pause") }
        if showElapsed == false { out.append("minimal UI") }
        if highlightStyle != nil { out.append("\(highlightStyle!.shortName) highlight") }
        if showCues == true { out.append("cues visible") }
        if let guidance, guidance != CueSettings().guidance {
            out.append(guidance == .wordTracking ? "voice follow" : guidance.rawValue)
        }
        if let fontFamily, fontFamily != CueSettings().fontFamily {
            out.append(fontFamily == .dyslexia ? "dyslexia font" : fontFamily.rawValue)
        }
        if alwaysOnTop == true { out.append("always on top") }
        if let overlayMode { out.append(overlayMode.shortName) }
        if let readingWidth, readingWidth != CueSettings().readingWidth {
            out.append("width \(Int(readingWidth))")
        }
        return out
    }

    /// Apply the patch. Only the fields this preset carries.
    public func apply(to settings: inout CueSettings) {
        if let textSize { settings.textSize = textSize }
        // Clamped, because a preset can come from a hand-edited preferences
        // file and this is the one writer that bypassed `setWordsPerMinute`.
        // A 5000 wpm preset disagreed with its own slider; a negative scale
        // became a negative font size on stage.
        if let prompterScale { settings.prompterScale = min(3, max(0.5, prompterScale)) }
        if let wordsPerMinute { settings.setWordsPerMinute(wordsPerMinute) }
        if let naturalPacing { settings.naturalPacing = naturalPacing }
        if let smartPause { settings.smartPause = smartPause }
        if let pauseOnPauseCues { settings.pauseOnPauseCues = pauseOnPauseCues }
        if let showElapsed { settings.showElapsed = showElapsed }
        if let highlightStyle { settings.highlightStyle = highlightStyle }
        if let highlightCurrent { settings.highlightCurrent = highlightCurrent }
        if let lineSpacing { settings.lineSpacing = min(4, max(0.8, lineSpacing)) }
        if let letterSpacing { settings.letterSpacing = min(4, max(-2, letterSpacing)) }
        if let readingWidth { settings.readingWidth = min(2000, max(200, readingWidth)) }
        if let showCues { settings.showCues = showCues }
        if let alwaysOnTop { settings.alwaysOnTop = alwaysOnTop }
        if let overlayMode { settings.overlayMode = overlayMode }
        if let guidance { settings.guidance = guidance }
        if let fontFamily { settings.fontFamily = fontFamily }
        if let fontWeight { settings.fontWeight = fontWeight }
        if let highlight { settings.highlight = highlight }
        if let cueColor { settings.cueColor = cueColor }
        if let textColor { settings.textColor = textColor }
        if let surfaceStyle { settings.surfaceStyle = surfaceStyle }
        if let paragraphSpacing {
            settings.paragraphSpacing = min(3, max(0.5, paragraphSpacing))
        }
        if let catchUpBoost { settings.catchUpBoost = min(4, max(0, catchUpBoost)) }
        if let pageSize { settings.pageSize = max(20, pageSize) }
    }

    /// Capture the current settings as a preset, recording only what differs
    /// from the defaults. This is what "save my own" does, and it is why
    /// applying it again later does not silently revert a setting the user
    /// changed in between.
    public static func capturing(_ settings: CueSettings, name: String,
                                 symbolName: String = "star.fill") -> CuePreset {
        let defaults = CueSettings()
        var preset = CuePreset(name: name, symbolName: symbolName)
        if settings.prompterScale != defaults.prompterScale {
            preset.prompterScale = settings.prompterScale
        }
        if settings.wordsPerMinute != defaults.wordsPerMinute {
            preset.wordsPerMinute = settings.wordsPerMinute
        }
        if settings.naturalPacing != defaults.naturalPacing {
            preset.naturalPacing = settings.naturalPacing
        }
        if settings.smartPause != defaults.smartPause {
            preset.smartPause = settings.smartPause
        }
        if settings.pauseOnPauseCues != defaults.pauseOnPauseCues {
            preset.pauseOnPauseCues = settings.pauseOnPauseCues
        }
        if settings.showElapsed != defaults.showElapsed {
            preset.showElapsed = settings.showElapsed
        }
        if settings.highlightStyle != defaults.highlightStyle {
            preset.highlightStyle = settings.highlightStyle
        }
        if settings.highlightCurrent != defaults.highlightCurrent {
            preset.highlightCurrent = settings.highlightCurrent
        }
        if settings.lineSpacing != defaults.lineSpacing {
            preset.lineSpacing = settings.lineSpacing
        }
        if settings.letterSpacing != defaults.letterSpacing {
            preset.letterSpacing = settings.letterSpacing
        }
        if settings.readingWidth != defaults.readingWidth {
            preset.readingWidth = settings.readingWidth
        }
        if settings.showCues != defaults.showCues {
            preset.showCues = settings.showCues
        }
        if settings.alwaysOnTop != defaults.alwaysOnTop {
            preset.alwaysOnTop = settings.alwaysOnTop
        }
        if settings.overlayMode != defaults.overlayMode {
            preset.overlayMode = settings.overlayMode
        }
        if settings.textSize != defaults.textSize { preset.textSize = settings.textSize }
        // Without these, "save my own" captured a tenth of what the presenter
        // had set: the card's summary came out empty (so applying it looked like
        // nothing happened) and re-applying it restored none of it.
        if settings.guidance != defaults.guidance { preset.guidance = settings.guidance }
        if settings.fontFamily != defaults.fontFamily { preset.fontFamily = settings.fontFamily }
        if settings.fontWeight != defaults.fontWeight { preset.fontWeight = settings.fontWeight }
        if settings.highlight != defaults.highlight { preset.highlight = settings.highlight }
        if settings.cueColor != defaults.cueColor { preset.cueColor = settings.cueColor }
        if settings.textColor != defaults.textColor { preset.textColor = settings.textColor }
        if settings.surfaceStyle != defaults.surfaceStyle {
            preset.surfaceStyle = settings.surfaceStyle
        }
        if settings.paragraphSpacing != defaults.paragraphSpacing {
            preset.paragraphSpacing = settings.paragraphSpacing
        }
        if settings.catchUpBoost != defaults.catchUpBoost {
            preset.catchUpBoost = settings.catchUpBoost
        }
        if settings.pageSize != defaults.pageSize { preset.pageSize = settings.pageSize }
        return preset
    }

    // MARK: - The four that ship

    /// A talk on a stage: big, slow, unmistakable, and nothing on screen that
    /// is not the script.
    public static let presentation = CuePreset(
        id: "00000000-0000-4000-8000-000000000001",
        name: "Presentation", symbolName: "person.wave.2.fill"
    ) { preset in
        preset.prompterScale = 1.35
        preset.wordsPerMinute = 110
        preset.naturalPacing = false
        preset.highlightStyle = .bold
        preset.highlightCurrent = true
        preset.showElapsed = false
        preset.lineSpacing = 1.5
    }

    /// Reading into a microphone at a natural pace, on a second display or a
    /// floating window, with the clock out of the way.
    public static let podcast = CuePreset(
        id: "00000000-0000-4000-8000-000000000002",
        name: "Podcast", symbolName: "mic.fill"
    ) { preset in
        preset.prompterScale = 1.15
        preset.naturalPacing = true
        preset.overlayMode = .floating
        preset.showElapsed = false
        preset.readingWidth = 640
    }

    /// A conversation: big enough to glance at, driven by the presenter, with
    /// sections and cues legible because the next question is somewhere in them.
    public static let interview = CuePreset(
        id: "00000000-0000-4000-8000-000000000003",
        name: "Interview", symbolName: "bubble.left.and.bubble.right.fill"
    ) { preset in
        preset.prompterScale = 1.3
        preset.naturalPacing = false
        preset.showCues = true
        preset.showElapsed = true
        preset.lineSpacing = 1.55
    }

    /// A rehearsal take: follows the voice, pauses on the cue, and keeps the
    /// chrome out of the way so the recording is the talking.
    public static let recording = CuePreset(
        id: "00000000-0000-4000-8000-000000000004",
        name: "Recording", symbolName: "video.fill"
    ) { preset in
        preset.naturalPacing = true
        preset.smartPause = .normal
        preset.pauseOnPauseCues = true
        preset.showElapsed = false
        preset.prompterScale = 1.2
    }

    public static let builtIns: [CuePreset] = [presentation, podcast, interview, recording]
}

extension CuePreset {
    /// Build with a closure, so the built-ins read as the list of differences
    /// they are rather than as a wall of `nil`s.
    fileprivate init(id: String, name: String, symbolName: String,
                     _ fill: (inout CuePreset) -> Void) {
        // Literal ids, not derived ones. The first attempt derived them from
        // `name.hashValue`, which is per-process seeded — and the literal was not
        // even a UUID, so `UUID(uuidString:)` returned nil and the fallback
        // minted a fresh random id on every launch. A built-in that cannot be
        // addressed by id cannot be selected, updated or de-duplicated.
        self.init(id: UUID(uuidString: id) ?? UUID(), name: name,
                  symbolName: symbolName, isBuiltIn: true)
        fill(&self)
    }
}

extension CueSettings.HighlightStyle {
    var shortName: String {
        switch self {
        case .pill: return "Pill"
        case .underline: return "Underline"
        case .bold: return "Bold"
        }
    }
}

extension CueSettings.OverlayMode {
    var shortName: String {
        switch self {
        case .notch: return "Notch"
        case .floating: return "Floating"
        case .fullscreen: return "Fullscreen"
        }
    }
}