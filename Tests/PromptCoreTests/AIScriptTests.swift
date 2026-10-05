import Foundation
import Testing
@testable import PromptCore

@Suite struct AIScriptTests {
    private func request(_ provider: AIRequest.Provider = .anthropic,
                         task: AIScriptTask = .conversational,
                         script: String = "One two three.") -> AIRequest {
        AIRequest(provider: provider, baseURL: provider.defaultBaseURL,
                  model: provider.defaultModel, key: "sk-test", task: task,
                  script: script)
    }

    @Test func anthropicPostsToMessagesWithItsOwnHeaders() throws {
        let body = try request(.anthropic).jsonBody()
        #expect(request(.anthropic).endpoint?.absoluteString
                == "https://api.anthropic.com/v1/messages")
        let headers = request(.anthropic).headers
        #expect(headers["x-api-key"] == "sk-test")
        #expect(headers["anthropic-version"] == "2023-06-01")
        #expect(headers["authorization"] == nil)
        #expect(body.contains("\"system\":"))
        #expect(body.contains("\"messages\":[{\"role\":\"user\""))
    }

    @Test func openAIPutsTheSystemPromptInTheMessages() throws {
        let body = try request(.openAI).jsonBody()
        #expect(request(.openAI).endpoint?.absoluteString
                == "https://api.openai.com/v1/chat/completions")
        #expect(request(.openAI).headers["authorization"] == "Bearer sk-test")
        #expect(body.contains("\"role\":\"system\""))
        #expect(!body.contains("\"system\":"))
        #expect(body.contains("\"stream\":false"))
    }

    @Test func ollamaNeedsNoKey() throws {
        let plain = AIRequest(provider: .openAICompatible, baseURL: "http://localhost:11434/v1",
                              model: "llama3.1", key: "", task: .trim,
                              script: "x", minutes: 3)
        #expect(plain.headers["authorization"] == nil)
        #expect(plain.endpoint?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(!AIRequest.Provider.openAICompatible.needsKey)
    }

    @Test func aBaseURLIsNormalised() {
        func endpoint(_ base: String, _ provider: AIRequest.Provider) -> String? {
            AIRequest(provider: provider, baseURL: base, model: "m", key: "k",
                      task: .plain, script: "x").endpoint?.absoluteString
        }
        #expect(endpoint("https://api.anthropic.com/", .anthropic)
                == "https://api.anthropic.com/v1/messages")
        #expect(endpoint("https://api.anthropic.com", .anthropic)
                == "https://api.anthropic.com/v1/messages")
        #expect(endpoint("https://api.openai.com/v1/", .openAI)
                == "https://api.openai.com/v1/chat/completions")
        #expect(endpoint("https://api.openai.com/v1", .openAI)
                == "https://api.openai.com/v1/chat/completions")
        #expect(endpoint("http://localhost:11434", .openAICompatible)
                == "http://localhost:11434/v1/chat/completions")
        #expect(endpoint("", .anthropic) == nil)
        #expect(endpoint("   ", .anthropic) == nil)
        // Refused, not repaired: a scheme-less paste is the commonest
        // mistake, and guessing "https" for it hides the mistake until the
        // request fails somewhere less obvious.
        #expect(endpoint("api.anthropic.com", .anthropic) == nil)
        #expect(endpoint("https://", .anthropic) == nil)
        #expect(endpoint("ftp://example.com", .openAI) == nil)
    }

    @Test func theScriptIsEscapedNotDropped() throws {
        let nasty = "He said \"ship it\"\\ then\nleft\ttab"
        let body = try request(.anthropic, script: nasty).jsonBody()
        #expect(body.contains("He said \\\"ship it\\\"\\\\ then\\nleft\\ttab"))
        // And it is still valid JSON with the script intact.
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == nasty)
    }

    @Test func controlCharactersAreEscaped() {
        #expect(AIRequest.escape("a\u{1}b") == "a\\u0001b")
    }

    @Test func theTrimTaskCarriesAWordBudget() {
        let five = AIScriptTask.trim.instructions(minutes: 5, wordsPerMinute: 140)
        #expect(five.contains("700 words"))
        #expect(five.contains("140 words per minute"))
        // A nonsense duration still produces something sendable.
        #expect(AIScriptTask.trim.instructions(minutes: 0).contains("50 words"))
    }

    @Test func everyTaskProtectsCuesAndHeadings() {
        for task in AIScriptTask.allCases {
            let instructions = task.instructions()
            #expect(instructions.contains("[cue]"), "\(task) may lose a cue")
            #expect(instructions.contains("#"), "\(task) may lose a heading")
            #expect(instructions.contains("nothing else"))
            #expect(!instructions.contains("sk-"), "no key-shaped text in a prompt")
        }
    }

    @Test func maxTokensScalesWithTheScript() {
        let small = request(.anthropic, script: "one two three").maxTokens
        let large = request(.anthropic, script: String(repeating: "word ", count: 6000)).maxTokens
        #expect(small == 1024)
        #expect(large == 8192)
        #expect(request(.anthropic, script: String(repeating: "word ", count: 500)).maxTokens == 1500)
    }

    @Test func anAnthropicReplyIsRead() {
        let data = Data("""
        {"id":"msg_1","stop_reason":"end_turn","content":[
          {"type":"text","text":"We shipped it."}
        ]}
        """.utf8)
        guard case .success(let text) = AIResponse.parse(provider: .anthropic, data: data) else {
            Issue.record("an ordinary reply should parse")
            return
        }
        #expect(text == "We shipped it.")
    }

    @Test func anOpenAIReplyIsRead() {
        let data = Data("""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"We shipped it."},
        "finish_reason":"stop"}]}
        """.utf8)
        guard case .success(let text) = AIResponse.parse(provider: .openAI, data: data) else {
            Issue.record("an ordinary reply should parse")
            return
        }
        #expect(text == "We shipped it.")
    }

    @Test func aLocalCompletionStyleReplyIsRead() {
        let data = Data("{\"choices\":[{\"text\":\"We shipped it.\"}]}".utf8)
        guard case .success(let text) = AIResponse.parse(provider: .openAICompatible, data: data) else {
            Issue.record("a completion-style reply should parse")
            return
        }
        #expect(text == "We shipped it.")
    }

    @Test func fencesComeOffAndNothingElseIsGuessed() {
        #expect(AIResponse.stripFences("```\nOne.\nTwo.\n```") == "One.\nTwo.")
        #expect(AIResponse.stripFences("```markdown\nOne.\nTwo.\n```") == "One.\nTwo.")
        #expect(AIResponse.stripFences("One.\nTwo.") == "One.\nTwo.")
        // An unterminated fence still yields the text.
        #expect(AIResponse.stripFences("```\nOne.\nTwo.") == "One.\nTwo.")
    }

    @Test func anErrorBodyIsAnError() {
        let data = Data("""
        {"type":"error","error":{"type":"authentication_error",
        "message":"invalid x-api-key"}}
        """.utf8)
        guard case .failure(let error) = AIResponse.parse(provider: .anthropic, data: data) else {
            Issue.record("an error body is not a rewrite")
            return
        }
        #expect(error == .provider("invalid x-api-key"))
        #expect(!error.errorDescription!.isEmpty)
        #expect(!error.recovery.isEmpty)
    }

    @Test func aProxyErrorPageIsNotMistakenForAReply() {
        let data = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        guard case .failure(let error) = AIResponse.parse(provider: .openAI, data: data) else {
            Issue.record("HTML is not JSON")
            return
        }
        #expect(error.errorDescription!.contains("JSON"))
    }

    @Test func aTruncatedReplySaysWhy() {
        let data = Data("{\"stop_reason\":\"max_tokens\",\"content\":[]}".utf8)
        guard case .failure(let error) = AIResponse.parse(provider: .anthropic, data: data) else {
            Issue.record("no text is a failure")
            return
        }
        #expect(error == .empty("stopped: max_tokens"))
    }

    @Test func noKeyMeansNotConfigured() {
        #expect(AIResponse.AIError.notConfigured.errorDescription!.contains("Settings"))
    }

    @Test func thePromptNeverCarriesTheKey() throws {
        let body = try AIRequest(provider: .anthropic, baseURL: "https://api.anthropic.com",
                                  model: "claude-sonnet-4-5", key: "sk-do-not-leak",
                                  task: .stageDirections,
                                  script: "[smile] One two.").jsonBody()
        #expect(!body.contains("sk-do-not-leak"))
    }
}

@Suite struct ScriptDiffTests {
    @Test func identicalTextHasNoChanges() {
        #expect(!ScriptDiff.hasChanges(from: "One\nTwo", to: "One\nTwo"))
        // Nothing changed, so there is nothing to preview: an unchanged
        // script must not produce a page of "same" the presenter reads past.
        #expect(ScriptDiff.chunks(from: "One", to: "One").isEmpty)
    }

    @Test func oneChangedLineIsOneChunk() {
        let chunks = ScriptDiff.chunks(from: "One\nTwo\nThree", to: "One\nTwo point\nThree")
        #expect(chunks.count == 3)
        guard case .changed(let old, let new) = chunks[1] else {
            Issue.record("the middle line changed")
            return
        }
        #expect(old == "Two")
        #expect(new == "Two point")
        #expect(ScriptDiff.changeCount(from: "One\nTwo\nThree", to: "One\nTwo point\nThree") == 1)
    }

    @Test func aRemovedLineShowsAsRemoved() {
        let chunks = ScriptDiff.chunks(from: "One\nTwo\nThree", to: "One\nThree")
        #expect(chunks.contains { if case .removed = $0 { true } else { false } })
    }

    @Test func anAddedLineShowsAsAdded() {
        let chunks = ScriptDiff.chunks(from: "One\nThree", to: "One\nTwo\nThree")
        #expect(chunks.contains { if case .added = $0 { true } else { false } })
    }

    @Test func contextIsCollapsed() {
        let before = (1...40).map { "Line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "Line 20", with: "Line twenty")
        let chunks = ScriptDiff.chunks(from: before, to: after)
        // One change plus a little context, not forty lines of script.
        #expect(chunks.count <= 5, "\\(chunks.count) chunks for a one-line change")
        // One line changed, whatever context surrounds it.
        #expect(ScriptDiff.changeCount(from: before, to: after) == 1)
    }

    @Test func aRewriteThatChangesEverythingIsHonestAboutIt() {
        let before = ScriptAnalysisTestsSample.before
        let after = ScriptAnalysisTestsSample.after
        // Two of the three paragraphs were rewritten.
        #expect(ScriptDiff.changeCount(from: before, to: after) == 2)
        #expect(ScriptDiff.hasChanges(from: before, to: after))
    }

    @Test func aRewriteThatKeepsACueIsShownKeepingIt() {
        // Not a property of the diff but of the contract it exists for: the
        // presenter must be able to see that the cues survived the rewrite.
        let before = "[smile] One two. Three four."
        let after = "[smile] One two — clearly. Three four."
        let chunks = ScriptDiff.chunks(from: before, to: after)
        let same = chunks.contains { chunk in
            if case .same(let line) = chunk { return line.contains("[smile]") }
            return false
        }
        #expect(same || ScriptDiff.chunks(from: before, to: after)
            .contains { chunk in
                if case .changed(_, let new) = chunk { return new.contains("[smile]") }
                return false
            })
        #expect(after.contains("[smile]"))
    }

    @Test func diffOfNothingIsAChange() {
        #expect(ScriptDiff.hasChanges(from: "", to: "One"))
        #expect(ScriptDiff.hasChanges(from: "One", to: ""))
    }

    @Test func anEmptyScriptIsHandled() {
        #expect(ScriptDiff.changeCount(from: "", to: "") == 0)
        #expect(ScriptDiff.changeCount(from: "One", to: "One\nTwo") == 1)
    }

    @Test func fuzzedDiffsAlwaysReconstruct() {
        var random = SplitMix64(seed: 41)
        let lines = ["One", "Two", "Three", "", "Four", "# Heading", "[smile] five"]
        for _ in 0..<200 {
            let count = Int(random.next() % 20) + 1
            let before = (0..<count).map { _ in lines[Int(random.next() % UInt64(lines.count))] }
                .joined(separator: "\n")
            let after = Bool(random.next() % 2 == 0)
                ? before.replacingOccurrences(of: "Two", with: "Two words")
                : before + "\nadded \(Int(random.next() % 100))"
            // Context is collapsed on purpose, so only a line that is *new*
            // has to appear in the diff: one that silently dropped would make
            // Apply delete a paragraph nobody was shown.
            let chunks = ScriptDiff.chunks(from: before, to: after)
            // A chunk carries *lines*, joined: `.added("a\nb")` is two lines.
            // Treating it as one hid a new line from the check below whenever a
            // chunk happened to hold more than one.
            let rendered = chunks.flatMap { chunk -> [String] in
                switch chunk {
                case .same(let line): return [line]
                case .changed(_, let new): return new.components(separatedBy: "\n")
                case .removed: return []
                case .added(let lines): return lines.components(separatedBy: "\n")
                }
            }
            let existing = before.components(separatedBy: "\n")
            for line in after.components(separatedBy: "\n")
            where !line.isEmpty && !existing.contains(line) {
                #expect(rendered.contains(line),
                        "a new line vanished: \(line.debugDescription)")
            }
        }
    }
}

/// Two bodies used by the diff tests. Named so the expectation reads as
/// "a rewrite happened" rather than as two blobs of text.
enum ScriptAnalysisTestsSample {
    static let before = """
    However, the engine we inherited in 2019 could not settle an invoice in \
    under two seconds.

    Moreover, the reconciliation job ran nightly.

    We rebuilt it.
    """
    static let after = """
    The engine we inherited in 2019 could not settle an invoice in two seconds.

    Reconciliation ran nightly.

    We rebuilt it.
    """
}
/// The diff's own numbers, which the Script Tools footer reads.
@Suite struct ScriptDiffCountingTests {
    @Test func consecutiveRewritesCountAsLinesNotChunks() {
        let before = (1...10).map { "line \($0) old" }.joined(separator: "\n")
        let after = (1...10).map { "line \($0) new" }.joined(separator: "\n")
        // One chunk, ten changed lines.
        #expect(ScriptDiff.chunks(from: before, to: after).filter { chunk in
            if case .same = chunk { return false }
            return true
        }.count == 1)
        #expect(ScriptDiff.changeCount(from: before, to: after) == 10,
                Comment(rawValue: "reported \(ScriptDiff.changeCount(from: before, to: after))"))
    }

    @Test func aWholeDocumentRewriteIsNotOneChange() {
        let before = (1...1_400).map { "Line \($0)" }.joined(separator: "\n")
        let after = (1...1_400).map { "Line \($0) revised" }.joined(separator: "\n")
        // Past `lineLimit` the diff is coarse by design; the count must not be.
        #expect(ScriptDiff.changeCount(from: before, to: after) > 1_000,
                Comment(rawValue: "reported \(ScriptDiff.changeCount(from: before, to: after))"))
    }

    @Test func aTrailingNewlineAloneIsNotAChange() {
        #expect(!ScriptDiff.hasChanges(from: "One two", to: "One two\n"))
        // "One\n" → "\n" really does drop a line, so it *is* a change.
        #expect(ScriptDiff.hasChanges(from: "One\n", to: "\n"))
        // Deleting the text is a change, though: one line gone.
        #expect(ScriptDiff.changeCount(from: "One\n", to: "") == 1)
    }

    @Test func aRemovedParagraphCountsItsLines() {
        let before = "One\n\nTwo three\n\nFour"
        let after = "One\n\nFour"
        // Two lines went: the paragraph, and the blank line that followed it.
        // It used to count as one, because empty lines were filtered out of
        // both sides of every changed chunk — which also made a rewrite that
        // only respaces look identical with Apply disabled, so the blank-line
        // rules could never be applied. Apply writes blank lines, so the
        // preview counts them.
        #expect(ScriptDiff.changeCount(from: before, to: after) == 2)
        #expect(ScriptDiff.changeCount(from: "One\n\nTwo three\n\nFour",
                                       to: "One\n\nFour") == 2)
    }
}

/// The AI layer's edge cases, all of which were found by audit rather than by
/// a model being polite. A model that disobeys its instructions is normal, so
/// the parser has to be the thing that is reliable.
@Suite struct AIResponseDefianceTests {
    /// A preamble plus a fence used to come back whole: the preamble became the
    /// prompter's first line and the closing fence its last.
    @Test func aFenceAfterAPreambleIsStillStripped() {
        let reply = "Here is the rewritten script:\n```\n[smile] One two.\n```"
        #expect(AIResponse.stripFences(reply) == "[smile] One two.")
    }

    @Test func aPlainReplyIsLeftExactlyAsItIs() {
        #expect(AIResponse.stripFences("One two three.") == "One two three.")
        #expect(AIResponse.stripFences("") == "")
    }

    /// Multi-part content joined with nothing fused the last word of one part
    /// to the first word of the next.
    @Test func aMultiPartReplyIsJoinedWithANewline() {
        let json = """
        {"content": [{"type": "text", "text": "One two."},
                     {"type": "text", "text": "Three four."}]}
        """
        let parsed = AIResponse.parse(provider: .anthropic,
                                      data: Data(json.utf8))
        #expect((try? parsed.get()) == "One two.\nThree four.",
                Comment(rawValue: "\(parsed)"))
    }

    /// A refusal reported as "no text" told the user to shorten the script,
    /// which is not the problem at all.
    @Test func aRefusalIsReportedAsARefusal() {
        let json = """
        {"choices": [{"message": {"content": null,
                                  "refusal": "I can't rewrite that."}}]}
        """
        let parsed = AIResponse.parse(provider: .openAI, data: Data(json.utf8))
        guard case .failure(.refused(let message)) = parsed else {
            Issue.record("expected .refused, got \(parsed)")
            return
        }
        #expect(message == "I can't rewrite that.")
    }

    /// A base URL carrying a query put the secret in the request line, where
    /// every proxy between here and the provider logs it — and a fragment
    /// swallowed the endpoint path entirely, so the request went to the bare
    /// base and 404'd with nothing to suggest why.
    @Test func anEndpointWithAQueryOrFragmentIsRefused() {
        let leaky = AIRequest(provider: .anthropic,
                              baseURL: "https://gw.example.com/v1?api-key=SECRET123",
                              model: "m", key: "", task: .conversational,
                              script: "x", minutes: 5, wordsPerMinute: 140)
        #expect(leaky.endpoint == nil)
        #expect(leaky.endpoint?.absoluteString.contains("SECRET") != true)

        let fragment = AIRequest(provider: .anthropic,
                                 baseURL: "https://gw.example.com/v1#frag",
                                 model: "m", key: "", task: .conversational,
                                 script: "x", minutes: 5, wordsPerMinute: 140)
        #expect(fragment.endpoint == nil)

        let credentials = AIRequest(provider: .anthropic,
                                    baseURL: "https://user:pass@gw.example.com/v1",
                                    model: "m", key: "", task: .conversational,
                                    script: "x", minutes: 5, wordsPerMinute: 140)
        #expect(credentials.endpoint == nil)

        // The ordinary cases still work.
        let plain = AIRequest(provider: .anthropic,
                              baseURL: "https://api.anthropic.com",
                              model: "m", key: "", task: .conversational,
                              script: "x", minutes: 5, wordsPerMinute: 140)
        #expect(plain.endpoint?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    /// One trailing slash made a stock Anthropic URL look custom, so choosing
    /// OpenAI kept sending the OpenAI body to Anthropic's host.
    @Test func aTrailingSlashIsStillTheStockURL() {
        var settings = AISettings(provider: .anthropic)
        settings.baseURL = "https://api.anthropic.com/"
        settings.setProvider(.openAI)
        #expect(settings.baseURL == AIRequest.Provider.openAI.defaultBaseURL,
                Comment(rawValue: settings.baseURL))
    }

    /// `minutes` is clamped where it is typed, but not on the way in from a
    /// hand-edited preferences file — and the number goes straight into the
    /// prompt text.
    @Test func minutesFromDiskAreClamped() {
        var settings = AISettings()
        settings.minutes = -5
        settings = AISettings(provider: settings.provider, baseURL: settings.baseURL,
                              model: settings.model, minutes: settings.minutes)
        #expect(settings.minutes >= 0,
                "a negative duration would be read out in the prompt")
    }
}
