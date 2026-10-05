import Foundation

/// One change to the script text, with a reason.
///
/// Every rewrite Cuebar performs — the deterministic tidying, and the one a
/// model proposes — arrives as a list of these, because the only honest way
/// to change somebody's talk is to show them what changed first. A button
/// labelled "Apply" with no preview is how you lose a paragraph of somebody's
/// work, and the presenter is the only person who can tell whether the
/// rewrite improved the sentence.
public struct ScriptEdit: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// Mechanical: markup, dashes, doubled spaces.
        case tidy
        /// Structural: a sentence split, a clause moved. Proposes, never applies.
        case pacing
        /// Written by a model at the user's request.
        case rewrite
        /// A stage direction staged from a diagnosis.
        case cue
    }

    public let kind: Kind
    /// Replaced range in the original body, as UTF-16 offsets — NSRange, so
    /// the AppKit-side editor can splice without re-deriving indices.
    public let range: NSRange
    public let original: String
    public let replacement: String
    public let reason: String

    public var id: String { "\(range.location)-\(range.length)-\(replacement)" }

    public init(kind: Kind, range: NSRange, original: String, replacement: String,
                reason: String) {
        self.kind = kind
        self.range = range
        self.original = original
        self.replacement = replacement
        self.reason = reason
    }
}

/// Line-level differences between two bodies of the same script.
///
/// Line-granular because that is how a presenter reads a diff: whole changed
/// lines, in order, with the old and new side by side. A character-level diff
/// of a 4000-word talk is a wall; a line-level diff is a page, and it is the
/// page where the model usually rewrote a clause that mattered.
public enum ScriptDiff {
    public enum Chunk: Equatable, Sendable {
        case same(String)
        case changed(old: String, new: String)
        case removed(String)
        case added(String)
    }

    /// Diff two bodies, coalescing neighbouring changed lines into one chunk.
    /// Above this many lines the LCS table is not worth building: 4000 lines
    /// is 16 million Ints — 128 MB on the main actor, for a preview. Past
    /// the limit the diff is honest about being coarse: one changed chunk
    /// rather than a hung window.
    public static let lineLimit = 1200

    public static func chunks(from old: String, to new: String) -> [Chunk] {
        // Trailing blank lines are dropped from each *body*, once, before the
        // comparison: a body that differs from another only by a newline at
        // the end must not report a change and offer an Apply button that
        // alters nothing.
        //
        // Trimming inside each changed chunk instead — which is what this used
        // to do — deleted interior blank lines too, because a blank line is
        // trailing on the side it was added to. A respacing-only rewrite then
        // diffed as "Identical" with Apply disabled, so the tidy's own rule for
        // collapsing a run of blank lines could never be applied at all.
        let before = lines(of: old).droppingTrailingBlankLines
        let after = lines(of: new).droppingTrailingBlankLines
        guard max(before.count, after.count) <= lineLimit else {
            return before == after ? []
                : [.changed(old: old, new: new)]
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: after.count + 1),
                           count: before.count + 1)
        // Longest common subsequence: 4000 words of talk is a few hundred
        // lines, so the table is small and the walk is obvious.
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                table[i][j] = before[i] == after[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var raw: [Chunk] = []
        var i = 0
        var j = 0
        while i < before.count || j < after.count {
            if i < before.count, j < after.count, before[i] == after[j] {
                raw.append(.same(before[i]))
                i += 1
                j += 1
                continue
            }
            // A free substitution does not exist in an LCS: consuming both
            // lines always costs a point, so the walk follows whichever skip
            // keeps more of the script. Substitutions are recovered below, by
            // pairing an adjacent removal with an addition — which is also
            // what keeps the diff readable.
            let down = i < before.count ? table[i + 1][j] : -1
            let right = j < after.count ? table[i][j + 1] : -1
            if i < before.count, down >= right {
                raw.append(.removed(before[i]))
                i += 1
            } else {
                raw.append(.added(after[j]))
                j += 1
            }
        }
        return coalesce(raw)
    }

    /// Did the rewrite change anything at all? The Apply button's worthiness.
    public static func hasChanges(from old: String, to new: String) -> Bool {
        chunks(from: old, to: new).contains {
            if case .same = $0 { return false }
            return true
        }
    }

    /// One line of context either side of a change, collapsed into runs.
    static func coalesce(_ chunks: [Chunk]) -> [Chunk] {
        var out: [Chunk] = []
        var index = 0
        while index < chunks.count {
            if case .same = chunks[index] {
                // Keep one context line before and after a change, drop the
                // rest: a diff of a whole talk should read as the whole talk's
                // changes, not as the whole talk.
                let nextIsChange = index + 1 < chunks.count && !isSame(chunks[index + 1])
                let previousWasChange = index > 0 && !isSame(chunks[index - 1])
                if nextIsChange || previousWasChange {
                    out.append(chunks[index])
                }
                index += 1
                continue
            }
            var old: [String] = []
            var new: [String] = []
            while index < chunks.count, !isSame(chunks[index]) {
                switch chunks[index] {
                case .changed(let o, let n):
                    if old.isEmpty && !o.isEmpty { old.append(o) }
                    if !n.isEmpty { new.append(n) }
                case .removed(let line):
                    old.append(line)
                case .added(let line):
                    new.append(line)
                case .same:
                    break
                }
                index += 1
            }
            // Nothing is filtered here: a chunk made only of blank lines is
            // still a change, and it has to survive to be previewed — Apply
            // writes blank lines, so a preview without them is a lie.
            if !old.isEmpty, !new.isEmpty {
                out.append(.changed(old: old.joined(separator: "\n"),
                                    new: new.joined(separator: "\n")))
            } else if !old.isEmpty {
                out.append(.removed(old.joined(separator: "\n")))
            } else if !new.isEmpty {
                out.append(.added(new.joined(separator: "\n")))
            }
        }
        return out
    }

    static func isSame(_ chunk: Chunk) -> Bool {
        if case .same = chunk { return true }
        return false
    }

    /// Lines for comparison, with line endings *out* of the picture.
    ///
    /// `components(separatedBy: .newlines)` splits a CRLF body at both the
    /// carriage return and the newline, so a Windows-imported script and an
    /// LF answer from a model had different shapes and every line showed as
    /// changed — a diff that says "everything" tells the presenter nothing,
    /// which is the one thing a diff must not do.
    static func lines(of body: String) -> [String] {
        body.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    /// How many *lines* changed — the number in the header above the diff.
    ///
    /// It counted chunks, and `coalesce` merges every run of changed lines
    /// into one chunk, so ten consecutive rewritten lines reported "1 change".
    /// Past `lineLimit` the whole document is one chunk, so the count there is
    /// the line count of both bodies: a 200-page script must not say "1".
    public static func changeCount(from old: String, to new: String) -> Int {
        var total = 0
        for chunk in chunks(from: old, to: new) {
            switch chunk {
            case .same: continue
            case .changed(let before, let after):
                total += max(lines(of: before).count, lines(of: after).count)
            case .removed(let text):
                total += lines(of: text).count
            case .added(let text):
                total += lines(of: text).count
            }
        }
        return total
    }

}

extension Array where Element == String {
    /// With trailing blank lines removed. Interior blank lines are the
    /// author's spacing and stay.
    var droppingTrailingBlankLines: [String] {
        var copy = self
        while let last = copy.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.removeLast()
        }
        return copy
    }
}
