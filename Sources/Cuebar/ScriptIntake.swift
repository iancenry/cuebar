import AppKit
import PromptCore

/// One place that answers "a script just arrived — what now?".
///
/// The panel, the pasteboard, the web sheet, a drag out of Finder and
/// double-clicking a file in Finder all end up here. Five entry points and
/// five copies of "insert, select, tell them what was skipped" is five
/// chances to make one of them forget the last step, which is the step the
/// user notices: they dropped a file and nothing is open on the prompter.
@MainActor
enum ScriptIntake {
    /// Handle a drop. `folder` is the drop target's folder, or nil for the
    /// window itself.
    static func handle(_ drop: ScriptDrop, scripts: ScriptStore) {
        switch drop {
        case .files(let urls):
            let outcome = ScriptIO.importFiles(urls, existingTitles: scripts.titles)
            land(outcome, in: scripts)
            ScriptIO.reportRejected(outcome)
        case .scripts(let ids):
            for id in ids { scripts.select(id) }
        case .text(let text):
            guard let script = ScriptImport.fromBody(text, title: ScriptIO.pastedTitle(for: text),
                                                      existingTitles: scripts.titles) else { return }
            land(ScriptImport.Outcome(scripts: [script], rejected: []), in: scripts)
        }
    }

    /// Insert the imported scripts and open the last one.
    ///
    /// The *last* one, because that is the one the list ends on and the one
    /// a person dropping five files at once wants to look at. The store
    /// bumps `lastImportedID` on the way in, which is how the view tree
    /// knows to switch to the prompter — the import command runs at app
    /// level, where the perform/edit switch can't be reached.
    @discardableResult
    static func land(_ outcome: ScriptImport.Outcome, in scripts: ScriptStore,
                     folder: UUID? = nil, open: Bool = true) -> UUID? {
        guard !outcome.scripts.isEmpty else { return nil }
        var lastID: UUID?
        for script in outcome.scripts {
            lastID = scripts.importScript(script, folder: folder).id
        }
        if open, let lastID { scripts.select(lastID) }
        return lastID
    }
}