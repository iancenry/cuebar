import Foundation
import PromptCore

/// Practice mode: which words are hidden, and how much.
///
/// Owned by the app rather than a view, because the prompter and the
/// transport both read it, and because a rehearsal outlives the window it
/// started in (the window closes, the overlay keeps going, and the plan is
/// still there when the window comes back).
@MainActor
@Observable
final class PracticeController {
    /// Off by default: rehearsal is a mode you choose, not one Cuebar
    /// decides for you.
    var isOn = false { didSet { if !isOn { revealing = false } } }

    /// Which pass of the ladder. `0` shows the whole script — reading
    /// practice, where the only thing being tested is delivery.
    private(set) var pass = 0

    /// Peek: one keypress shows the blanks, and they stay shown until the
    /// key is pressed again. A presenter who has lost the thread needs an
    /// escape hatch that is faster than restarting the run.
    var revealing = false

    /// The script the plan was made for. A different script gets a fresh
    /// plan rather than somebody else's gaps.
    private var planScriptID: UUID?
    private var words: [String] = []
    private var seed: UInt64 = 0

    private(set) var plan: PracticePlan = .none()

    /// Gaps as the prompter needs them: word indices, minus the word being
    /// read right now.
    var hiddenWords: Set<Int> { plan.hiddenWords(excluding: currentWord) }

    /// Set by whoever renders the prompter, each frame. Main-actor like the
    /// rest of the controller: the *current word is never a gap*, and the
    /// only thing that knows which word that is, is the engine.
    private(set) var currentWord: Int?

    func noteCurrentWord(_ index: Int?) {
        currentWord = index
    }

    var passCount: Int { PracticePlan.passCount }

    var level: Double { plan.hiddenFraction }
    var levelDescription: String {
        isOn ? "\(pass + 1) of \(passCount) · \(Int((level * 100).rounded()))% hidden" : ""
    }


    func prepare(scriptID: UUID?, words: [String]) {
        // Compare the *words*, not their count. A same-count edit — a
        // reword, a cue staged — used to leave the plan describing the text
        // as it was when the script was selected, so every gap pointed at
        // words the presenter had never read.
        guard planScriptID != scriptID || words != self.words else { return }
        planScriptID = scriptID
        self.words = words
        // Seeded from the script, not the clock: the same script rehearses the
        // same way twice, which is the point of a rehearsal.
        seed = UInt64(bitPattern: Int64(scriptID?.hashValue ?? 0))
        rebuild()
    }

    func start() {
        isOn = true
        pass = max(pass, 1)
        rebuild()
    }

    func stop() {
        isOn = false
        revealing = false
    }

    func toggle() {
        isOn ? stop() : start()
    }

    /// More hidden. Stops at the last rung rather than wrapping: wrapping
    /// would make the button feel broken at the top of the ladder.
    func harder() {
        guard pass + 1 < passCount else { return }
        pass += 1
        rebuild()
    }

    func easier() {
        guard pass > 0 else { return }
        pass -= 1
        rebuild()
    }

    func toggleReveal() {
        revealing.toggle()
    }

    /// A run is over: the next pass hides more, so "gradually increase the
    /// amount hidden" happens without the presenter thinking about it.
    ///
    /// Called from the driver's end-of-script branch. It was dead code for a
    /// while — defined, documented as automatic, and never called from
    /// anywhere, so the pass only moved when somebody clicked the chevron.
    func advanceAfterRun() {
        guard isOn else { return }
        harder()
    }

    private func rebuild() {
        plan = isOn ? PracticePlan.planForPass(words: words, pass: pass, seed: seed)
                    : .none(totalWords: words.count)
    }
}