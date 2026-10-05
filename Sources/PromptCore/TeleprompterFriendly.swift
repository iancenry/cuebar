import Foundation

/// The changes that make a written script sayable, applied without a model.
///
/// A talk is written with the eye and read with the mouth, and the two
/// disagree in ways that are mechanical to fix and embarrassing to leave:
/// `**bold**` renders as literal asterisks on stage, `—` is a symbol nobody
/// says, `[text](url)` is an address nobody can pronounce, and a parenthetical
/// aside is read *aloud* even though it was written to be thought.
///
/// Every edit here is safe, local and reversible, which is why it can run
/// without a key, without a network, and without asking: the diff is the
/// permission. What it deliberately does *not* do is change a sentence —
/// splitting a 30-word sentence is a judgement about meaning, and that one
/// belongs to the presenter or to a model they asked, never to a rule.
public enum TeleprompterFriendly {
    /// The tidy-ups, as edits against the original body.
    ///
    /// Rules are applied in order and an edit that overlaps one already kept
    /// is dropped. Two rules can see the same characters — a parenthetical
    /// beside a dash — and applying both produced `(aside),, bold`: the dash
    /// replaced by a comma and the aside turned into a cue *around* the
    /// comma the other rule had just inserted. One place in the text, one
    /// change.
    public static func edits(for body: String) -> [ScriptEdit] {
        var candidates: [ScriptEdit] = []
        for rule in rules {
            candidates.append(contentsOf: edits(in: body, for: rule))
        }
        // Whitespace candidates are filtered against the markup ones too, not
        // merely among themselves — and that was the bug behind "text"
        // arriving as "ext". The dash rule's range covers the spaces on both
        // sides of the dash (" —    " is six characters); the trailing-space
        // rule covered the same four. Both were kept, `apply` ran them right to
        // left, and the second one's offset had been computed against text the
        // first had already shortened.
        candidates.append(contentsOf: whitespaceEdits(in: body))
        return withoutOverlaps(candidates)
    }

    /// One change per character, in position order.
    ///
    /// A sweep over sorted candidates, not a scan of everything kept so far:
    /// that scan was quadratic, and a 127 000-character script with 16 000
    /// edits took 47 seconds — in a debug build, on the main actor, from
    /// inside a `Button` label. Sorted, one pass with a cursor settles it.
    static func withoutOverlaps(_ candidates: [ScriptEdit]) -> [ScriptEdit] {
        let sorted = candidates.sorted { $0.range.location < $1.range.location }
        var kept: [ScriptEdit] = []
        var cursor = 0
        var spans: [NSRange] = []
        for edit in sorted {
            let lower = edit.range.location
            let upper = lower + edit.range.length
            while cursor < spans.count, spans[cursor].location + spans[cursor].length <= lower {
                cursor += 1
            }
            if cursor < spans.count, spans[cursor].location < upper { continue }
            kept.append(edit)
            spans.append(edit.range)
        }
        return kept
    }

    static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0
    }

    /// Apply edits right to left, so every range is still valid when the next
    /// one lands. A range that no longer fits the text is skipped rather than
    /// trapping: an edit list can outlive the text it was computed from (an
    /// edit, then a keystroke).
    public static func apply(_ edits: [ScriptEdit], to body: String) -> String {
        let out: NSMutableString = body.mutableCopy() as! NSMutableString
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.location >= 0,
                  edit.range.location + edit.range.length <= out.length else { continue }
            out.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return out as String
    }

    /// The tidied body.
    ///
    /// Applied to a fixed point rather than in one pass. When two rules want
    /// the same characters the second one is *dropped* — no overlap, no lost
    /// letter — and the dropped one has to be reconsidered against the text
    /// the first one produced. That is not a bug to design around; it is what
    /// "one change per character" means when the rules are independent. Four
    /// passes is far more than any real script needs, and the loop stops as
    /// soon as nothing changes, so a clean script costs one.
    public static func rewritten(_ body: String) -> String {
        var current = body
        for _ in 0..<4 {
            let next = apply(edits(for: current), to: current)
            if next == current { break }
            current = next
        }
        return current
    }

    /// Whitespace, in one character pass: trailing spaces gone, runs of blank
    /// lines collapsed to one, and the typewriter's two spaces after a full
    /// stop.
    ///
    /// The ranges are *minimal* — the spaces themselves, not the whole line —
    /// because a whole-line replacement is computed from the original text
    /// and would restore every `**bold**` another rule had just removed. One
    /// place in the text, one change, whichever rule got there first.
    public static func whitespaceEdits(in body: String) -> [ScriptEdit] {
        var out: [ScriptEdit] = []
        let ns = body as NSString

        var offset = 0
        var previousBlank = false
        let lines = body.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            // Lengths come from the *raw* line: the ranges below are offsets
            // into the body as it stands, and measuring a carriage-return-free
            // line shifted every range after the first "\r" by one character
            // — which is how "Three four" lost its "our".
            let length = (raw as NSString).length
            // Inspection sees the line as it will be once the CRs are gone,
            // otherwise "\r\n\r\n\r\n" is three lines of "\r" — not
            // blank — and the blank-line rule never fires on a Windows script.
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, previousBlank {
                // The line *and* the newline that separated it: dropping only
                // the text would leave the blank behind. The last line has no
                // newline to take, and a range reaching past the end of the
                // body is one `apply` refuses — which silently kept the
                // trailing space this branch was supposed to clear.
                let withNewline = index < lines.count - 1 ? length + 1 : length
                // A blank last line has no newline of its own, so the range
                // would be empty — an edit that describes nothing, in a list
                // whose whole contract is "one change per character".
                guard withNewline > 0 else { previousBlank = blank; offset += length + 1; continue }
                out.append(ScriptEdit(
                    kind: .tidy,
                    range: NSRange(location: offset, length: withNewline),
                    original: ns.substring(with: NSRange(location: offset, length: withNewline)),
                    replacement: "",
                    reason: "More than one blank line is a layout accident."))
            } else {
                // Every run on the line, not just the first: "One.  Two.  Three"
                // needed two passes before both were fixed, and the second
                // pass's answer differed from the first's.
                for double in doubleSpaceRuns(in: line) {
                    out.append(ScriptEdit(
                        kind: .tidy,
                        range: NSRange(location: offset + double.location, length: double.length),
                        original: ns.substring(with: NSRange(location: offset + double.location,
                                                             length: double.length)),
                        replacement: " ",
                        reason: "Two spaces after a full stop is a typewriter habit."))
                }
                if let trailing = trailingSpaceRun(in: line), trailing.length > 0 {
                    out.append(ScriptEdit(
                        kind: .tidy,
                        range: NSRange(location: offset + trailing.location, length: trailing.length),
                        original: ns.substring(with: NSRange(location: offset + trailing.location,
                                                             length: trailing.length)),
                        replacement: "",
                        reason: "Trailing spaces shift the measured line length."))
                }
            }
            previousBlank = blank
            offset += length + 1
        }

        // Carriage returns, one minimal edit each.
        //
        // Minimal rather than one whole-body edit: a whole-body replacement
        // covers every other edit's range, and `apply` runs right to left, so
        // a CR strip made that way lands last and undoes every fix applied to
        // the text it had just rewritten.
        //
        // `body.contains("\r")` is *false* for a string that has one:
        // String.contains goes through Foundation's canonical comparison,
        // which treats a carriage return as interchangeable with nothing at
        // all. The first version of this rule used it, so it never fired and
        // the tidy claimed to handle Windows line endings while leaving every
        // one of them in. `unicodeScalars` is the honest question.
        if body.unicodeScalars.contains("\r") {
            for at in 0..<ns.length where ns.substring(with: NSRange(location: at, length: 1)) == "\r" {
                out.append(ScriptEdit(kind: .tidy,
                                      range: NSRange(location: at, length: 1),
                                      original: "\r",
                                      replacement: "",
                                      reason: "Windows line endings."))
            }
        }

        // Filtered against the line walk's own edits, not merely appended: the
        // blank-line rule's range already *includes* the carriage return of
        // the line it removes, so an unfiltered CR edit landed on the same
        // character. Applied right to left, whichever ran last won — and a
        // one-character deletion landing on a shifted index is how
        // "Three four" lost its "T".
        var kept: [ScriptEdit] = []
        for edit in out.sorted(by: { $0.range.location < $1.range.location }) {
            guard !kept.contains(where: { overlaps($0.range, edit.range) }) else { continue }
            kept.append(edit)
        }
        return kept
    }

    /// Every run of two or more spaces after a full stop.
    static func doubleSpaceRuns(in line: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: "\\.( {2,})(?=[A-Z])") else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                let group = match.range(at: 1)
                guard group.location != NSNotFound, group.length > 1 else { return nil }
                return group
            }
    }

    /// The run of spaces and tabs at the end of a line.
    static func trailingSpaceRun(in line: String) -> NSRange? {
        let ns = line as NSString
        let length = ns.length
        guard length > 0 else { return nil }
        var at = length
        while at > 0 {
            let character = ns.substring(with: NSRange(location: at - 1, length: 1))
            if character != " " && character != "\t" { break }
            at -= 1
        }
        guard at < length else { return nil }
        return NSRange(location: at, length: length - at)
    }

    // MARK: - The rules

    struct Rule: Sendable {
        let pattern: String
        /// `NSRegularExpression` template: `$1` for the first capture group.
        var template: String = ""
        var reason: String = ""
        var kind: ScriptEdit.Kind = .tidy
        /// Decides the replacement for a single match, given the body, the
        /// match's UTF-16 location and the matched text. `nil` drops it.
        /// Used where the right answer depends on what is *beside* the match:
        /// a dash after a comma needs no comma.
        var resolve: (@Sendable (String, Int, String) -> String?)?

        static let link = Rule(pattern: "\\[([^\\]\n]+)\\]\\(([^)]+)\\)", template: "$1",
                               reason: "A link would be read out as its URL.", kind: .tidy)
        /// `***both***`. Its own rule, ahead of `bold`, because bold matches the
        /// inner `**x**` and leaves `*x*` for a second pass — and the tidy runs
        /// once, from a button.
        static let boldItalic = Rule(pattern: "\\*\\*\\*([^*\n]+)\\*\\*\\*", template: "$1",
                                     reason: "Emphasis markers are read out loud.", kind: .tidy)
        static let bold = Rule(pattern: "\\*\\*([^*\n]+)\\*\\*", template: "$1",
                               reason: "Bold markers are read out loud.", kind: .tidy)
        static let underscoreBold = Rule(pattern: "__([^_\n]+)__", template: "$1",
                                         reason: "Bold markers are read out loud.", kind: .tidy)
        /// A `*` with a letter or a digit on the far side is *not* markup:
        /// it is arithmetic ("2*3*4"), a glob, a footnote. Stripping it
        /// turned "two pi pi r" into "two pir" — the tidy changing what
        /// is said, which is the one thing it must never do. The guard now
        /// mirrors the underscore rule's `(?<![\w_])`.
        static let italic = Rule(pattern: "(?<![\\w*])\\*([^*\n]+)\\*(?![\\w*])",
                                 template: "$1",
                                 reason: "Emphasis markers are read out loud.", kind: .tidy)
        /// `___both___`, for the same reason as `***both***`.
        static let underscoreBoldItalic = Rule(pattern: "___([^_\\n]+)___", template: "$1",
                                               reason: "Emphasis markers are read out loud.")
        static let underscoreItalic = Rule(pattern: "(?<![\\w_])_([^_\\n]+)_(?![\\w_])",
                                           template: "$1",
                                           reason: "Emphasis markers are read out loud.", kind: .tidy)
        static let code = Rule(pattern: "`([^`\\n]+)`", template: "$1",
                               reason: "Code markers are read out loud.", kind: .tidy)
        static let strike = Rule(pattern: "~~([^~\\n]+)~~", template: "$1",
                                 reason: "Strikethrough markers are read out loud.", kind: .tidy)
        /// One rule for both dashes, and the whole *run* in one match: "x — – y"
        /// produced ", " twice, and the two commas then tidied differently on
        /// the next pass.
        ///
        /// Leading whitespace is required, which is what keeps "1990–1995" a
        /// range rather than turning it into "1990, 1995".
        static let dash = Rule(
            pattern: "(?:[ \\t]+[—–]+)+[ \\t]+",
            reason: "A dash is a symbol nobody says.",
            resolve: { body, location, original in
                let ns = body as NSString
                let before = location > 0
                    ? ns.substring(with: NSRange(location: location - 1, length: 1))
                    : " "
                let after = location + (original as NSString).length
                let next = after < ns.length
                    ? ns.substring(with: NSRange(location: after, length: 1))
                    : ""
                // Already punctuated, or ending the line: the dash is doing
                // nothing, so drop it rather than adding a second comma to the
                // sentence — a comma *and* the space the match consumed left a
                // dangling ", " that the next pass then tidied, so the same
                // script kept changing under the presenter's feet.
                if ",.;:!?—–".contains(before) { return " " }
                if next.isEmpty || next == "\n" { return "" }
                return ", "
            })
        static let aside = Rule(pattern: "\\(([^()\\n]{1,80})\\)", template: "[$1]",
                                reason: "A parenthetical reads as prose unless it is a cue.",
                                kind: .tidy)
    }

    /// Markup rules only. Whitespace is normalised by `whitespaceEdits`, a
    /// plain character pass: as five separate regexes the rules fought each
    /// other — one collapsing a blank-line run while another claimed the
    /// newline inside it — and the same script needed three passes to settle,
    /// with two runs of the same text settling differently. A pass that walks
    /// lines once cannot disagree with itself.
    ///
    /// A marker pair may not span a line.
    ///
    /// It used to be allowed to, and `[^*]+` matches newlines, so a span could
    /// enclose the blank lines and trailing spaces inside it. The overlap
    /// filter then dropped the whitespace edits it covered, and the tidy
    /// needed a second pass to settle — a promise the button does not keep.
    static let rules: [Rule] = [
        .link, .boldItalic, .underscoreBoldItalic,
        .bold, .underscoreBold, .italic, .underscoreItalic, .code, .strike,
        .dash, .aside,
    ]

    static func edits(in body: String, for rule: Rule) -> [ScriptEdit] {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return [] }
        let ns = body as NSString
        // Parenthesis depth, advanced only as far as each match needs. It used
        // to be `ns.substring(to: match.location)` per match — re-slicing the
        // whole prefix every time, which is O(characters × parentheses) and was
        // 84% of this function's runtime on a large script. Matches arrive in
        // ascending order, so one cursor over the body serves all of them.
        var scanned = 0
        var depth = 0
        // Where the cues are. A rule may rewrite anything — including text
        // *inside* a `[cue]`, which is not a reading instruction at all but a
        // note to the app: `[smile (big)]` became `[smile [big]]`, and since
        // the parser reads a cue as everything up to the first `]`, the script
        // gained a literal `]` word that the presenter then said aloud. So a
        // match that touches a cue span is not this rule's business.
        let cues = ScriptFile.cueRanges(of: body)
        func insideACue(_ range: NSRange) -> Bool {
            cues.contains { NSIntersectionRange($0, range).length > 0 }
        }
        return regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                let original = ns.substring(with: match.range)
                // The template is applied to the *match*, so `$1` cannot pick
                // up a group from somewhere else in the line.
                let replacement: String
                if let resolve = rule.resolve {
                    guard let decided = resolve(body, match.range.location, original) else {
                        return nil
                    }
                    replacement = decided
                } else {
                    replacement = regex.stringByReplacingMatches(
                        in: original,
                        range: NSRange(location: 0, length: (original as NSString).length),
                        withTemplate: rule.template)
                }
                // An edit that changes nothing is noise: it makes a clean
                // script look like it has findings, and it is what turned
                // "seconds. Nobody" into a "two spaces after a full stop".
                guard replacement != original else { return nil }
                // A rule that reaches into a bracketed span is editing a cue —
                // text that is a note to the app, not to the presenter.
                // `[smile (big)]` became `[smile [big]]`, and since the parser
                // reads a cue as everything up to the first `]`, the script
                // gained a literal `]` word that was then said aloud.
                //
                // The exception is a rule that is *about* the brackets and
                // removes them: a Markdown link `[the docs](https://…)` really
                // is a cue as far as the stage is concerned, and flattening it
                // to `the docs` leaves no bracket behind to misread. Refusing
                // that would make the tidy's most-used rule do nothing. The test
                // is on the *match*, not the replacement — the dash rule's
                // replacement is a comma, and it would otherwise slip through.
                if insideACue(match.range),
                   !original.contains("["), !original.contains("]") {
                    return nil
                }
                // A parenthetical *inside* another parenthetical is left to
                // the outer one: rewriting the inner would leave the outer
                // unbalanced, and "Hello (well (sort of))" has no honest
                // single answer.
                if rule.pattern.hasPrefix("\\(") {
                    while scanned < match.range.location {
                        let character = ns.substring(with: NSRange(location: scanned, length: 1))
                        if character == "(" { depth += 1 }
                        if character == ")" { depth -= 1 }
                        scanned += 1
                    }
                    guard depth <= 0 else { return nil }
                    // Brackets inside the aside: "(see [slide 1])" became
                    // "[see [slide 1]]", and the parser reads a cue as
                    // everything up to the *first* "]" — so the script gained
                    // a literal "]" word and the cue lost its tail. Cue text
                    // cannot nest, so leave an ambiguous aside alone.
                    guard !original.contains("["), !original.contains("]") else { return nil }
                }
                return ScriptEdit(kind: rule.kind, range: match.range,
                                  original: original, replacement: replacement,
                                  reason: rule.reason)
            }
    }
}