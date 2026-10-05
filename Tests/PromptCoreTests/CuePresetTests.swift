import Testing
import Foundation
@testable import PromptCore

/// A preset is a patch, not a copy. That is the whole design: it means
/// applying a preset does not silently reset the dozen settings it does not
/// mention, and it means a preset written today still means something after
/// the app grows a new setting.
@Suite struct CuePresetTests {
    @Test func theFourShipAndAllDifferFromTheDefaults() {
        #expect(CuePreset.builtIns.count == 4)
        for preset in CuePreset.builtIns {
            #expect(preset.isBuiltIn)
            #expect(!preset.summary.isEmpty,
                    "\(preset.name) would show an empty description")
            var settings = CueSettings()
            preset.apply(to: &settings)
            var changed = false
            for preset in CuePreset.builtIns {
                var probe = CueSettings()
                preset.apply(to: &probe)
                if probe != settings { changed = true }
            }
            #expect(changed)
        }
    }

    /// The failure a snapshot design produces: applying a preset wipes a
    /// setting the user changed afterwards.
    @Test func applyingAPresetLeavesEverythingElseAlone() {
        var settings = CueSettings()
        settings.showCues = true
        settings.fontFamily = .dyslexia
        CuePreset.presentation.apply(to: &settings)
        #expect(settings.showCues)
        #expect(settings.fontFamily == .dyslexia)
    }

    @Test func presentationIsBigSlowAndUnmistakable() {
        var settings = CueSettings()
        CuePreset.presentation.apply(to: &settings)
        #expect(settings.prompterScale > 1.2)
        #expect(settings.wordsPerMinute < 130)
        #expect(settings.naturalPacing == false)
        #expect(settings.showElapsed == false)
        #expect(settings.highlightCurrent)
    }

    @Test func podcastFollowsTheVoiceInAFloatingWindow() {
        var settings = CueSettings()
        CuePreset.podcast.apply(to: &settings)
        #expect(settings.naturalPacing)
        #expect(settings.overlayMode == .floating)
    }

    @Test func interviewIsManualWithCuesVisible() {
        var settings = CueSettings()
        CuePreset.interview.apply(to: &settings)
        #expect(settings.naturalPacing == false)
        #expect(settings.showCues)
        #expect(settings.prompterScale > 1.2)
    }

    @Test func recordingFollowsTheVoiceAndPausesOnCue() {
        var settings = CueSettings()
        CuePreset.recording.apply(to: &settings)
        #expect(settings.naturalPacing)
        #expect(settings.smartPause != .off)
        #expect(settings.pauseOnPauseCues)
    }

    /// "Save my own" captures only the differences, so re-applying it later
    /// does not revert settings the user changed in between.
    @Test func aSavedPresetRecordsOnlyTheDifferences() {
        var settings = CueSettings()
        settings.prompterScale = 1.4
        settings.showCues = false        // the default is true
        let preset = CuePreset.capturing(settings, name: "Mine")
        #expect(preset.prompterScale == 1.4)
        #expect(preset.showCues == false)
        #expect(preset.highlightStyle == nil, "an unchanged setting was captured")

        // …and the captured patch still leaves later changes alone.
        var later = CueSettings()
        later.highlightStyle = .underline
        preset.apply(to: &later)
        #expect(later.highlightStyle == .underline)
    }

    @Test func presetsSurviveARoundTrip() throws {
        let data = try JSONEncoder().encode(CuePreset.builtIns)
        let decoded = try JSONDecoder().decode([CuePreset].self, from: data)
        #expect(decoded == CuePreset.builtIns)
    }
}

/// The re-audit's findings on presets, all of which were real: a built-in whose
/// id could not be parsed (so it was re-minted every launch), an `apply` that
/// bypassed the clamped accessors, and a "save my own" that captured a tenth of
/// what the presenter had set — while reporting an empty summary.
@Suite struct CuePresetHardeningTests {
    @Test func builtInIdsAreStableAcrossLaunches() {
        // A derived id from `hashValue` is per-process seeded, so this was a
        // different value on every launch and no built-in could be addressed.
        let again = CuePreset.builtIns
        #expect(again.map(\.id) == CuePreset.builtIns.map(\.id))
        #expect(Set(again.map(\.id)).count == 4)
        #expect(CuePreset.presentation.id.uuidString
                == "00000000-0000-4000-8000-000000000001")
    }

    /// A preset from a hand-edited preferences file must not be able to write a
    /// value the rest of the app assumes is in range.
    @Test func applyingAHandEditedPresetClamps() {
        var preset = CuePreset(name: "Broken", symbolName: "star")
        preset.wordsPerMinute = 5000
        preset.prompterScale = -4
        preset.readingWidth = -1
        preset.lineSpacing = 900
        var settings = CueSettings()
        preset.apply(to: &settings)
        #expect(settings.clampedWordsPerMinute <= 480)
        #expect((settings.prompterScale ?? 0) >= 0.5)
        #expect((settings.readingWidth ?? 0) > 0)
        #expect((settings.lineSpacing ?? 99) <= 4)
        #expect(settings.textSize.points * (settings.prompterScale ?? 1) > 0,
                "a negative font size on stage")
    }

    /// The settings a presenter is most likely to have changed, and the ones
    /// the first version silently dropped.
    @Test func saveCurrentCapturesWhatAPresenterActuallyChanges() {
        var settings = CueSettings()
        settings.guidance = .wordTracking
        settings.fontFamily = .dyslexia
        settings.highlight = .blue
        settings.paragraphSpacing = 1.4
        settings.pageSize = 120
        let preset = CuePreset.capturing(settings, name: "Mine")
        #expect(preset.guidance == .wordTracking)
        #expect(preset.fontFamily == .dyslexia)
        #expect(preset.highlight == .blue)
        #expect(preset.paragraphSpacing == 1.4)
        #expect(preset.pageSize == 120)
        #expect(!preset.summary.isEmpty, "the card would show an empty description")

        var later = CueSettings()
        preset.apply(to: &later)
        #expect(later.guidance == .wordTracking)
        #expect(later.fontFamily == .dyslexia)
        #expect(later.pageSize == 120)
    }

    @Test func aPercentageIsNotTruncated() {
        var preset = CuePreset(name: "P", symbolName: "star")
        preset.prompterScale = 1.15
        #expect(preset.summary.contains { $0.contains("115%") },
                Comment(rawValue: "\(preset.summary)"))
    }
}
