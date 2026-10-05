import Foundation

/// One unified settings model — Textream spreads this across 7 tabs.
/// Cuebar keeps a single source of truth, persisted as JSON.
public struct CueSettings: Codable, Equatable, Sendable {
    public enum GuidanceMode: String, Codable, Sendable, CaseIterable {
        case classic, wordTracking, voiceActivated
        case auto

        /// User-facing label for the settings picker.
        public var label: String {
            switch self {
            case .classic: return "Traditional"
            case .auto: return "Auto"
            case .voiceActivated: return "Voice"
            case .wordTracking: return "Smart"
            }
        }

        /// Whether this mode needs an active microphone.
        public var usesVoice: Bool {
            switch self {
            case .wordTracking, .voiceActivated: return true
            case .classic, .auto: return false
            }
        }

        /// Whether this mode uses voice matching (SpeechMatcher) rather
        /// than just voice-activated scrolling.
        public var usesSpeechMatching: Bool {
            self == .wordTracking
        }
    }
    public enum FontFamily: String, Codable, Sendable, CaseIterable {
        case sans, serif, mono, dyslexia
    }
    public enum TextSize: String, Codable, Sendable, CaseIterable {
        case xs, sm, lg, xl
        public var points: Double {
            switch self { case .xs: return 14; case .sm: return 16; case .lg: return 20; case .xl: return 24 }
        }
    }
    public enum Accent: String, Codable, Sendable, CaseIterable {
        case white, yellow, green, blue, pink, orange
    }
    public enum CueBrightness: String, Codable, Sendable, CaseIterable {
        case dim, low, medium, bright
        /// Badge wash behind cue pills; the cue text itself stays vivid.
        public var badgeOpacity: Double {
            switch self { case .dim: return 0.14; case .low: return 0.2; case .medium: return 0.28; case .bright: return 0.38 }
        }
    }
    public enum OverlayMode: String, Codable, Sendable, CaseIterable {
        case notch, floating, fullscreen
    }
    public enum DisplayTarget: String, Codable, Sendable, CaseIterable {
        case followMouse, fixed
    }
    public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
        case automatic, onDevice, legacy
    }
    public enum FontWeight: String, Codable, Sendable, CaseIterable {
        case regular, medium, semibold, bold
    }
    public enum TextColor: String, Codable, Sendable, CaseIterable {
        case paper, white, stone
    }
    /// Which deck app `[slide]` cues drive. Plain data, so it can live here
    /// and be persisted; the code that actually talks to Keynote lives in the
    /// app, because it is the part that needs AppKit.
    public enum DeckApp: String, Codable, Sendable, CaseIterable, Identifiable, Equatable {
        case none, keynote, powerPoint
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .none: return "None"
            case .keynote: return "Keynote"
            case .powerPoint: return "PowerPoint"
            }
        }
    }

    public enum SurfaceStyle: String, Codable, Sendable, CaseIterable {
        case espresso, black, slate
    }
    public enum TextAlignment: String, Codable, Sendable, CaseIterable {
        case leading, center
    }
    public enum HighlightStyle: String, Codable, Sendable, CaseIterable {
        case pill, underline, bold
    }
    public enum SmartPauseMode: String, Codable, Sendable, CaseIterable {
        case off, conservative, normal, aggressive

        /// Seconds of sustained silence before the prompter auto-pauses.
        /// At ~8 Hz polling, each tick is 125 ms.
        public var silenceThreshold: Double {
            switch self {
            case .off: return .infinity
            case .conservative: return 4.0
            case .normal: return 3.0
            case .aggressive: return 1.5
            }
        }

        /// Seconds of sustained speech before the prompter auto-resumes.
        public var resumeThreshold: Double {
            switch self {
            case .off: return 0
            case .conservative: return 1.0
            case .normal: return 1.5
            case .aggressive: return 2.5
            }
        }
    }

    public var guidance: GuidanceMode = .classic
    public var speechLanguage: String = "en-US"
    public var transcriptionEngine: TranscriptionEngine = .automatic

    public var fontFamily: FontFamily = .sans
    public var textSize: TextSize = .sm
    public var prompterScale: Double = 1.6 // multiplier over base size for reading view
    public var highlight: Accent = .orange
    public var cueColor: Accent = .pink
    public var cueBrightness: CueBrightness = .dim

    public var overlayWidth: Double = 460
    public var overlayHeight: Double = 260
    public var overlayMode: OverlayMode = .floating
    public var displayTarget: DisplayTarget = .followMouse
    public var transparencyEnabled: Bool = true
    public var transparencyAmount: Double = 0.95 // 0 transparent … 1 opaque
    public var showElapsed: Bool = true
    public var hideFromShare: Bool = true
    /// Whether the phone remote announces itself over Bonjour.
    ///
    /// **Off by default.** Advertising is the one part of the remote that
    /// reaches out onto the network uninvited, and on macOS 15+ it is what
    /// makes the system ask for local-network permission — a dialog that
    /// arrives at full *alert* volume, so it can be startling on
    /// headphones, at exactly the moment someone is about to present. The
    /// remote works perfectly well without it: the address is in
    /// Settings → Display → Phone Remote, typed once into Safari.
    /// Turning this on buys "a phone can find Cuebar by name" and costs the
    /// prompt, which is the user's call to make rather than ours.
    public var advertiseRemote: Bool = false
    /// Which deck app `[slide]` cues drive, if any.
    ///
    /// **Off by default**, and not out of caution about Keynote: because
    /// Cuebar would be *controlling another application*, macOS treats it
    /// as Automation and raises a consent dialog the first time. A consent
    /// prompt is a poor surprise for a teleprompter, and a presenter should
    /// be the one who asks for it. The slide position, the badges and the
    /// phone's stepper all work with this off.
    public var deckApp: DeckApp = .none
    /// The chrome theme's id, or `""` to follow the system appearance.
    ///
    /// Two separate fields because chrome and the reading surface have
    /// different requirements — see `ThemeChoice`. Both are ids rather than
    /// colours, so a theme that ships later is a new value rather than a
    /// migration.
    public var theme: String = ThemeChoice.followSystem
    /// The reading surface's theme id, or `""` to follow the chrome theme
    /// (falling back to dark when the chrome theme is light).
    public var surfaceTheme: String = ""
    /// High Contrast is a mode, not a preference: it overrides the reading
    /// surface whatever the two themes above say.
    public var highContrast: Bool = false
    public var autoNextScript: Bool = false
    public var pageSize: Int = 300
    public var fixedDisplayIndex: Int = 0
    public var hideMainWhilePresenting: Bool = true
    public var alwaysOnTop: Bool = true
    public var floatingOriginX: Double? = nil
    public var floatingOriginY: Double? = nil
    public var fontWeight: FontWeight = .regular
    public var textColor: TextColor = .paper
    public var surfaceStyle: SurfaceStyle = .espresso
    public var lineSpacing: Double = 0.5
    public var paragraphSpacing: Double = 0.5
    public var letterSpacing: Double = 0
    public var readingWidth: Double? = 650
    public var textAlignment: TextAlignment = .leading
    public var smoothScroll: Bool = true
    public var scrollSpeed: Double = 1.0 // multiplier on smooth-scroll animation
    public var wordsPerMinute: Double = 150 // persisted reading speed (30…480)
    public var popOutOnPlay: Bool = true
    /// Human pacing: long words linger, clause ends breathe. Off = steady robot rate.
    public var naturalPacing: Bool = true
    /// Hold-to-catch-up multiplier (1.2…2.5×) while the boost key/button is held.
    public var catchUpBoost: Double = 1.6
    /// Auto-pause when the highlight reaches a bare [pause]/[wait]/[hold]
    /// cue. On by default: a bare [pause] in a script is a request to stop,
    /// and the ⌘K palette says so. Timed cues ([pause 2s]) always execute,
    /// regardless of this.
    public var pauseOnPauseCues: Bool = true
    /// Detect sustained speech silence and auto-pause; resume when speech returns.
    public var smartPause: SmartPauseMode = .off
    /// Scroll wheel releases Follow instead of fighting auto-scroll.
    public var releaseFollowOnScroll: Bool = true
    public var highlightCurrent: Bool = true
    public var highlightStyle: HighlightStyle = .pill
    /// Script Tools: provider, endpoint, model. The *key* is not here — it
    /// lives in the login keychain, because this file is a plain JSON blob in
    /// Application Support and a key in it is a key that has to be rotated
    /// every time the user copies their preferences to another Mac.
    public var ai: AISettings = .default
    /// The presenter's own presets, after the four that ship. Stored with the
    /// settings rather than in a separate file so one save covers them.
    public var presets: [CuePreset] = []

    // MARK: - General
    /// Open Cuebar when you log in. Registered with `SMAppService`, which is
    /// why it lives in the app's preferences rather than the app bundle.
    public var launchAtLogin: Bool = false
    /// Ask before a script is deleted. Deleting is now a file deletion, and a
    /// file can go to the Trash — but a talk lost without a word is still a talk
    /// lost.
    public var confirmBeforeDeleting: Bool = true
    /// Reopen a script where it was being read. Off means it always opens at
    /// the top, which is what somebody rehearsing something else wants.
    public var restoreLastPosition: Bool = true
    /// Where a new script lands. Empty means "beside whatever is open", which
    /// is the old behaviour and still the default.
    public var defaultFolderID: UUID?
    /// User-remappable command keys. Sparse: absent actions ride their default.
    public var shortcuts: ShortcutMap = .default
    /// Let Cuebar's shortcuts work while another app is in front, but only
    /// while the prompter overlay is up. Needs the macOS Accessibility
    /// permission, so it is opt-in.
    public var globalHotkeys: Bool = false
    public var showCues: Bool = true
    public var hidePunctuation: Bool = false
    public var showProgress: Bool = true
    public var showCenterLine: Bool = true

    /// Rendering window, clamped so a corrupt pref can't explode the view tree.
    public var clampedPageSize: Int { min(600, max(50, pageSize)) }

    /// Engine speed in words/sec derived from the persisted WPM.
    public var wordsPerSecond: Double { max(0.5, min(8.0, wordsPerMinute / 60.0)) }

    /// Presenter-speed bounds in one place: every writer (keys, transport
    /// stepper, speed sliders) goes through this so the range can't drift.
    /// A function on purpose — reading it off a `Double` is what a stale copy
    /// of the range always looks like.
    public static func clampedWPM(_ value: Double) -> Double {
        min(480, max(30, value.rounded()))
    }

    public var clampedWordsPerMinute: Double { Self.clampedWPM(wordsPerMinute) }

    /// The only supported ways to change reading speed. Rounding first keeps
    /// a ±5 stepper from persisting 152.5 and drifting the slider; the clamp
    /// is the single copy of the 30…480 range.
    public mutating func adjustWordsPerMinute(by delta: Double) {
        setWordsPerMinute(wordsPerMinute + delta)
    }

    public mutating func setWordsPerMinute(_ value: Double) {
        wordsPerMinute = Self.clampedWPM(value)
    }

    /// Smooth-scroll animation duration: faster scrollSpeed snaps quicker.
    public var scrollAnimationDuration: Double {
        let speed = max(0.25, min(2.0, scrollSpeed))
        return 0.3 / speed
    }

    public var clampedParagraphSpacing: Double { min(1.5, max(0, paragraphSpacing)) }

    /// Hold-to-boost multiplier, clamped so a corrupt pref can't 10× the reader.
    public var clampedCatchUpBoost: Double { min(2.5, max(1.2, catchUpBoost)) }

    public init() {}

    /// Only key that isn't a property name. Read once, on decode: the old
    /// `autoNextPage` spelling of `autoNextScript`.
    private enum LegacyKeys: String, CodingKey {
        case autoNextPage
    }

    /// Tolerant decode: every field falls back to its default, so one
    /// corrupt or renamed key can never wipe the whole prefs file again.
    /// (The old `autoNextPage` key migrates into `autoNextScript`.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, default value: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? value
        }
        let defaults = CueSettings()
        guidance = decode(.guidance, default: defaults.guidance)
        speechLanguage = decode(.speechLanguage, default: defaults.speechLanguage)
        transcriptionEngine = decode(.transcriptionEngine, default: defaults.transcriptionEngine)
        fontFamily = decode(.fontFamily, default: defaults.fontFamily)
        textSize = decode(.textSize, default: defaults.textSize)
        prompterScale = decode(.prompterScale, default: defaults.prompterScale)
        highlight = decode(.highlight, default: defaults.highlight)
        cueColor = decode(.cueColor, default: defaults.cueColor)
        cueBrightness = decode(.cueBrightness, default: defaults.cueBrightness)
        overlayWidth = decode(.overlayWidth, default: defaults.overlayWidth)
        overlayHeight = decode(.overlayHeight, default: defaults.overlayHeight)
        overlayMode = decode(.overlayMode, default: defaults.overlayMode)
        displayTarget = decode(.displayTarget, default: defaults.displayTarget)
        transparencyEnabled = decode(.transparencyEnabled, default: defaults.transparencyEnabled)
        transparencyAmount = decode(.transparencyAmount, default: defaults.transparencyAmount)
        showElapsed = decode(.showElapsed, default: defaults.showElapsed)
        hideFromShare = decode(.hideFromShare, default: defaults.hideFromShare)
        autoNextScript = decode(.autoNextScript, default: defaults.autoNextScript)
            || ((try? legacy.decodeIfPresent(Bool.self, forKey: .autoNextPage)) ?? nil) == true
        pageSize = decode(.pageSize, default: defaults.pageSize)
        fixedDisplayIndex = decode(.fixedDisplayIndex, default: defaults.fixedDisplayIndex)
        hideMainWhilePresenting = decode(.hideMainWhilePresenting, default: defaults.hideMainWhilePresenting)
        alwaysOnTop = decode(.alwaysOnTop, default: defaults.alwaysOnTop)
        floatingOriginX = decode(.floatingOriginX, default: defaults.floatingOriginX)
        floatingOriginY = decode(.floatingOriginY, default: defaults.floatingOriginY)
        fontWeight = decode(.fontWeight, default: defaults.fontWeight)
        textColor = decode(.textColor, default: defaults.textColor)
        surfaceStyle = decode(.surfaceStyle, default: defaults.surfaceStyle)
        lineSpacing = decode(.lineSpacing, default: defaults.lineSpacing)
        letterSpacing = decode(.letterSpacing, default: defaults.letterSpacing)
        paragraphSpacing = decode(.paragraphSpacing, default: defaults.paragraphSpacing)
        scrollSpeed = decode(.scrollSpeed, default: defaults.scrollSpeed)
        wordsPerMinute = decode(.wordsPerMinute, default: defaults.wordsPerMinute)
        popOutOnPlay = decode(.popOutOnPlay, default: defaults.popOutOnPlay)
        naturalPacing = decode(.naturalPacing, default: defaults.naturalPacing)
        catchUpBoost = decode(.catchUpBoost, default: defaults.catchUpBoost)
        pauseOnPauseCues = decode(.pauseOnPauseCues, default: defaults.pauseOnPauseCues)
        smartPause = decode(.smartPause, default: defaults.smartPause)
        releaseFollowOnScroll = decode(.releaseFollowOnScroll, default: defaults.releaseFollowOnScroll)
        shortcuts = decode(.shortcuts, default: defaults.shortcuts)
        globalHotkeys = decode(.globalHotkeys, default: defaults.globalHotkeys)
        readingWidth = decode(.readingWidth, default: defaults.readingWidth)
        textAlignment = decode(.textAlignment, default: defaults.textAlignment)
        smoothScroll = decode(.smoothScroll, default: defaults.smoothScroll)
        highlightCurrent = decode(.highlightCurrent, default: defaults.highlightCurrent)
        highlightStyle = decode(.highlightStyle, default: defaults.highlightStyle)
        showCues = decode(.showCues, default: defaults.showCues)
        hidePunctuation = decode(.hidePunctuation, default: defaults.hidePunctuation)
        showProgress = decode(.showProgress, default: defaults.showProgress)
        showCenterLine = decode(.showCenterLine, default: defaults.showCenterLine)
        // These three were declared, encoded and then never read, so every
        // launch quietly reset them: the phone remote stopped advertising, the
        // deck app went back to "none", and the AI provider, endpoint, model
        // and budget the user had typed were replaced by the defaults — while
        // the keychain kept their key, so every request then failed with a
        // provider error naming the wrong service. A property with a default
        // that this function forgets is a setting that only exists until the
        // app quits.
        advertiseRemote = decode(.advertiseRemote, default: defaults.advertiseRemote)
        deckApp = decode(.deckApp, default: defaults.deckApp)
        theme = decode(.theme, default: defaults.theme)
        surfaceTheme = decode(.surfaceTheme, default: defaults.surfaceTheme)
        highContrast = decode(.highContrast, default: defaults.highContrast)
        ai = decode(.ai, default: defaults.ai)
        // Added to the tolerant decode list the day it was written, because a
        // stored property this function forgets is a setting that exists only
        // until the app quits — which is exactly what happened to `ai`.
        presets = decode(.presets, default: defaults.presets)
        launchAtLogin = decode(.launchAtLogin, default: defaults.launchAtLogin)
        confirmBeforeDeleting = decode(.confirmBeforeDeleting,
                                       default: defaults.confirmBeforeDeleting)
        restoreLastPosition = decode(.restoreLastPosition,
                                    default: defaults.restoreLastPosition)
        defaultFolderID = decode(.defaultFolderID, default: defaults.defaultFolderID)
        // Clamped on the way in as well as on the way through the Stepper: the
        // number goes straight into the words of a prompt, so a hand-edited
        // preferences file could ask a model to "cut the script to about 50
        // words (-5 minutes at 140 words per minute)".
        ai.minutes = min(240, max(1, ai.minutes))
    }
}

// Encoding is synthesised. The hand-written `encode(to:)` that used to mirror
// the property list was 50 lines that could silently drift from the struct;
// the one non-obvious key (`autoNextPage`) is decode-only, which a synthesised
// encoder skips for free.
