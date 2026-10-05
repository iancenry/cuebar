import Testing
import Foundation
@testable import PromptCore

/// Every setting has to come back.
///
/// This is the third time a property has been added to `CueSettings` with a
/// default and then left out of `init(from:)` — `ai`, then
/// `advertiseRemote`/`deckApp`. The symptom is the same every time: written on
/// quit, ignored on launch, so the setting only exists until the app restarts,
/// and a round-trip test that only ever set two fields reported all green.
///
/// So the sweep does not enumerate fields by hand. It encodes the defaults,
/// replaces every leaf it can with a value of that leaf's own JSON type, and
/// requires that decoding and re-encoding gives the same document back. A key
/// the decoder drops falls back to its default and the documents differ.
///
/// What it cannot cover, stated plainly rather than left to look thorough:
/// a leaf whose default is `null` (an optional left nil), and a *string* leaf
/// whose type is an enum — there is no way to invent a raw value the enum will
/// accept. String settings a user picks in the UI are covered by name in
/// `stringSettingsSurviveTheRoundTrip` instead, and
/// `everyStringLeafIsNamedInATest` fails when a new one appears that nobody has.
@Suite struct SettingsRoundTripTests {
    @Test func everyBooleanAndNumberSurvivesTheRoundTrip() throws {
        let lost = try lostLeaves()
        #expect(lost.isEmpty,
                "settings written but not read back: \(lost.joined(separator: ", "))")
    }

    /// The guard on the guard: if the model gains a field this sweep cannot
    /// reach, the coverage stops being an accident.
    @Test func theSweepStillReachesTheBulkOfTheModel() throws {
        let reached = try sweepableLeafCount()
        #expect(reached > 30,
                "the sweep only reaches \(reached) leaves — if the model grew nothing, this test has quietly stopped testing anything")
    }

    @Test func stringSettingsSurviveTheRoundTrip() throws {
        var settings = CueSettings()
        settings.theme = ThemeCatalog.oled
        settings.surfaceTheme = ThemeCatalog.warm
        settings.highContrast = true
        settings.guidance = .voiceActivated
        settings.fontFamily = .mono
        settings.textSize = .xl
        settings.cueColor = .green
        settings.overlayMode = .fullscreen
        settings.deckApp = .keynote
        settings.ai.provider = .openAI
        settings.ai.model = "gpt-4o-mini"
        settings.smartPause = .aggressive
        settings.speechLanguage = "en-GB"
        settings.ai.baseURL = "https://example.invalid/v1"

        let decoded = try JSONDecoder().decode(
            CueSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.theme == ThemeCatalog.oled)
        #expect(decoded.surfaceTheme == ThemeCatalog.warm)
        #expect(decoded.highContrast)
        #expect(decoded.guidance == .voiceActivated)
        #expect(decoded.fontFamily == .mono)
        #expect(decoded.textSize == .xl)
        #expect(decoded.cueColor == .green)
        #expect(decoded.overlayMode == .fullscreen)
        #expect(decoded.deckApp == .keynote)
        #expect(decoded.ai.provider == .openAI)
        #expect(decoded.ai.model == "gpt-4o-mini")
        #expect(decoded.smartPause == .aggressive)
        #expect(decoded.speechLanguage == "en-GB")
        #expect(decoded.ai.baseURL == "https://example.invalid/v1")
    }

    /// A new enum-shaped setting arrives in a pull request, nobody adds it to
    /// `stringSettingsSurviveTheRoundTrip`, and the sweep skips it silently.
    /// This names it instead.
    @Test func everyStringLeafIsNamedInATest() throws {
        let leaves = try stringLeafKeys()
        let unnamed = leaves.subtracting(Self.namedStringSettings)
        #expect(unnamed.isEmpty,
                "string settings with no round-trip test: \(unnamed.sorted().joined(separator: ", "))")
    }

    /// A settings file written by an older build must not lose the fields it
    /// does have — which is the whole job of the tolerant decoder.
    @Test func anOldFileDecodesWithTheNewFieldsAtTheirDefaults() throws {
        let json = #"{"wordsPerMinute":140,"guidance":"auto"}"#
        let decoded = try JSONDecoder().decode(CueSettings.self, from: Data(json.utf8))
        #expect(decoded.wordsPerMinute == 140)
        #expect(decoded.theme.isEmpty, "follow the system unless the user said otherwise")
        #expect(decoded.surfaceTheme.isEmpty)
        #expect(!decoded.highContrast)
    }

    /// Every string-valued key the model writes, by dotted path.
    private static let namedStringSettings: Set<String> = [
        "theme", "surfaceTheme", "guidance", "fontFamily", "textSize", "cueColor",
        "cueBrightness", "overlayMode", "displayTarget", "transcriptionEngine",
        "fontWeight", "textColor", "surfaceStyle", "textAlignment", "highlight",
        "highlightStyle", "deckApp", "smartPause", "speechLanguage",
        "ai.provider", "ai.model", "ai.baseURL",
        "shortcuts.playPause", "shortcuts.restart", "shortcuts.nextCue",
        "shortcuts.previousCue", "shortcuts.jumpBack", "shortcuts.jumpForward",
        "shortcuts.speedUp", "shortcuts.speedDown", "shortcuts.togglePractice",
        "shortcuts.newScriptFromClipboard", "shortcuts.importFromWeb",
        "shortcuts.analyseScript", "shortcuts.scriptTools", "shortcuts.toggleOverlay",
        "shortcuts.settings", "shortcuts.reset",
    ]

    // MARK: - The sweep

    /// Mutate every boolean and number leaf, decode, re-encode, and report the
    /// keys that came back at their default.
    private func lostLeaves() throws -> [String] {
        var mutated = try defaultsJSON()
        for leaf in try sweepableLeaves() {
            apply(leaf.value, at: leaf.path, in: &mutated)
        }
        let decoded = try JSONDecoder().decode(
            CueSettings.self, from: try JSONSerialization.data(withJSONObject: mutated))
        let reencoded = try asObject(try JSONEncoder().encode(decoded))
        // Read the mutated document back through JSON before comparing: it is
        // holding Swift literals, and a Swift `Bool` prints "false" where the
        // `__NSCFBoolean` it becomes prints "0" — a difference in the harness
        // that looks exactly like a forgotten field.
        let normalized = try asObject(try JSONSerialization.data(withJSONObject: mutated))
        return differences(between: normalized, and: reencoded, path: [])
    }

    private func defaultsJSON() throws -> [String: Any] {
        try asObject(try JSONEncoder().encode(CueSettings()))
    }

    private func asObject(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func sweepableLeafCount() throws -> Int {
        try sweepableLeaves().count
    }

    private func stringLeafKeys() throws -> Set<String> {
        var keys: Set<String> = []
        var found: [String] = []
        collectLeafPaths(try defaultsJSON(), path: []) { node, path in
            if node is String { found.append(path.joined(separator: ".")) }
        }
        keys.formUnion(found)
        return keys
    }

    /// Leaves a sentinel can be built for: booleans and numbers, at any depth.
    private func sweepableLeaves() throws -> [(path: [String], value: Any)] {
        var out: [(path: [String], value: Any)] = []
        collectLeafPaths(try defaultsJSON(), path: []) { node, path in
            if let sentinel = Self.sentinel(for: node) { out.append((path, sentinel)) }
        }
        return out
    }

    private func collectLeafPaths(_ node: Any, path: [String],
                                  _ visit: (Any, [String]) -> Void) {
        if let dict = node as? [String: Any] {
            for key in dict.keys.sorted() {
                collectLeafPaths(dict[key]!, path: path + [key], visit)
            }
        } else if let array = node as? [Any] {
            for (index, element) in array.enumerated() {
                collectLeafPaths(element, path: path + ["\(index)"], visit)
            }
        } else {
            visit(node, path)
        }
    }

    /// A *different* value of the same JSON type.
    ///
    /// The boolean case is an identity test against the `CFBoolean` singletons
    /// on purpose: `NSNumber(0)` bridges to `Bool`, so `node is Bool` matches an
    /// integer setting too — and mutating an `Int` into `true` makes the
    /// decoder fall back to its default, which looks exactly like a forgotten
    /// field.
    private static func sentinel(for node: Any) -> Any? {
        let object = node as AnyObject
        if object === kCFBooleanTrue { return false }
        if object === kCFBooleanFalse { return true }
        guard let number = node as? NSNumber else { return nil }
        // Keep the fractional shape: a `Double` field cannot decode `7`.
        if String(cString: number.objCType) == "d" { return number.doubleValue + 0.5 }
        return number.intValue + 7
    }

    private func apply(_ value: Any, at path: [String], in node: inout [String: Any]) {
        let key = path[0]
        if path.count == 1 {
            node[key] = value
            return
        }
        var child = node[key] as? [String: Any] ?? [:]
        apply(value, at: Array(path.dropFirst()), in: &child)
        node[key] = child
    }

    private func differences(between a: [String: Any], and b: [String: Any],
                             path: [String]) -> [String] {
        var out: [String] = []
        for (key, value) in a {
            let here = (path + [key]).joined(separator: ".")
            guard let other = b[key] else {
                out.append(here)
                continue
            }
            if let left = value as? [String: Any], let right = other as? [String: Any] {
                out += differences(between: left, and: right, path: path + [key])
            } else if "\(value)" != "\(other)" {
                out.append(here)
            }
        }
        return out.sorted()
    }
}