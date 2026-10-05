import Foundation
import Testing
@testable import PromptCore

/// Everything here runs against input no provider would send: a truncated
/// body, an HTML error page, a `choices` array of the wrong shape. The point
/// is not that the answer is right — it is that `parse` *returns* instead of
/// trapping, because this runs on whatever the network handed back and a trap
/// in a prompter is a dead talk.
@Suite struct AIResponseFuzzTests {
    private func parse(_ json: String, _ provider: AIRequest.Provider = .anthropic)
    -> Result<String, AIResponse.AIError> {
        AIResponse.parse(provider: provider, data: Data(json.utf8))
    }

    @Test func truncatedAndEmptyBodiesFailCleanly() {
        for body in ["", "{", "{}", "[]", "null", "not json at all", "\u{0}\u{1}",
                     "{\"content\":", "{\"choices\":[{}]}", "{\"content\":[]}",
                     "{\"content\":[{}]}", "{\"error\":{}}", "{\"error\":\"plain\"}",
                     "{\"choices\":\"nope\"}", "{\"stop_reason\":null,\"content\":null}"] {
            let result = parse(body)
            if case .success(let text) = result {
                #expect(!text.isEmpty, "an empty rewrite for \\(body.debugDescription)")
            }
            #expect(result.failureDescription != nil,
                    "a failure with nothing to show the user: \\(body.debugDescription)")
        }
    }

    /// Every body against every provider: whatever comes back, a failure
    /// always has something to say. Providers disagree about shapes, and a
    /// user who points Cuebar at a local server should not get a blank sheet
    /// because that server answers like the other one.
    @Test func bothProvidersSurviveTheSameGarbage() {
        let bodies = ["", "{", "{}", "{\"content\":[{\"text\":\"hi\"}]}",
                      "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}",
                      "{\"choices\":[{\"text\":\"hi\"}]}"]
        for provider in AIRequest.Provider.allCases {
            for body in bodies {
                let result = parse(body, provider)
                switch result {
                case .success(let text):
                    #expect(!text.isEmpty, "\(provider.label) succeeded with nothing")
                case .failure(let error):
                    #expect(!(error.errorDescription ?? "").isEmpty,
                            "\(provider.label) failed silently on \(body.debugDescription)")
                }
            }
        }
    }

    @Test func everyFailureHasSomethingToShowAndSomethingToDo() {
        let errors: [AIResponse.AIError] = [
            .notJSON("<html>"), .provider("nope"), .empty(nil), .empty("stopped"),
            .notConfigured, .transport("offline"), .status(429, ""), .status(500, "boom"),
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty,
                    "\\(error) says nothing")
            #expect(!error.recovery.isEmpty, "\\(error) says nothing about what to do")
        }
    }

    @Test func aFuzzedJSONBodyNeverTraps() {
        var random = SplitMix64(seed: 7)
        let fragments = ["{", "}", "[", "]", "\"", ":", ",", "content", "choices",
                         "message", "text", "error", "1", "null", "true", "\\", "stop_reason"]
        for _ in 0..<500 {
            let length = Int(random.next() % 40) + 1
            let json = (0..<length).map { _ in fragments[Int(random.next() % UInt64(fragments.count))] }
                .joined()
            let result = parse(json, random.next() % 2 == 0 ? .anthropic : .openAI)
            if case .success(let text) = result {
                #expect(!text.isEmpty, "an empty success for \\(json.debugDescription)")
            }
        }
    }

    @Test func aValidReplySurvivesSurroundingNoise() {
        // Real providers wrap the answer in a little more than the minimum,
        // and the prompter does not care about the rest.
        let chatty = """
        {"id":"chatcmpl-1","object":"chat.completion","created":1,"model":"gpt-4o-mini",
         "choices":[{"index":0,"logprobs":null,"finish_reason":"stop",
         "message":{"role":"assistant","content":"One two three.","refusal":null}}],
         "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
        """
        guard case .success(let text) = parse(chatty, .openAI) else {
            Issue.record("a real reply should parse")
            return
        }
        #expect(text == "One two three.")
    }

    @Test func aRefusalIsNotAnEmptyRewrite() {
        let refused = """
        {"choices":[{"message":{"role":"assistant","content":null,"refusal":
        "I can't help with that."}}]}
        """
        let result = parse(refused, .openAI)
        #expect(result.failureDescription != nil)
    }
}

/// What the sheet shows in the failure case.
extension Result where Failure == AIResponse.AIError {
    var failureDescription: String? {
        switch self {
        case .success: return nil
        case .failure(let error): return error.errorDescription ?? error.recovery
        }
    }
}

@Suite struct AIRequestFuzzTests {
    @Test func anyScriptSurvivesTheBody() throws {
        var random = SplitMix64(seed: 13)
        let pieces = ["quote \"", "backslash \\", "newline\n", "tab\t", "emoji 🎉",
                      "[smile]", "# Heading", "</script>", "\\u0041", "control \u{1}",
                      " line separator", " nbsp"]
        for _ in 0..<200 {
            let count = Int(random.next() % 12) + 1
            let script = (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }
                .joined(separator: " ")
            for provider in AIRequest.Provider.allCases {
                let request = AIRequest(provider: provider, baseURL: provider.defaultBaseURL,
                                        model: "model \"quoted\"", key: "k",
                                        task: .trim, script: script, minutes: 3)
                let body = try request.jsonBody()
                // The body must parse, and the script must come back out
                // byte-identical: a prompt that mangles the presenter's words
                // produces a rewrite of the wrong talk.
                let object = try #require(
                    try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                let content: String
                switch provider {
                case .anthropic:
                    content = try #require((object["messages"] as? [[String: Any]])?
                        .first?["content"] as? String)
                case .openAI, .openAICompatible:
                    let messages = try #require(object["messages"] as? [[String: Any]])
                    content = try #require(messages.last?["content"] as? String)
                }
                #expect(content == script, "script mangled for \\(provider.label)")
                #expect(!body.contains("sk-"), "a key-shaped string in the body")
            }
        }
    }

    @Test func anyBaseURLEitherResolvesOrReturnsNil() {
        let bases = ["", " ", "not a url", "http://", "https://a.b/c", "https://a.b/v1/",
                     "ftp://x", "https://api.anthropic.com/v1", "http://[::1]:11434"]
        for base in bases {
            for provider in AIRequest.Provider.allCases {
                let request = AIRequest(provider: provider, baseURL: base, model: "m",
                                        key: "k", task: .plain, script: "x")
                if let endpoint = request.endpoint {
                    #expect(endpoint.scheme?.hasPrefix("http") == true,
                            "\\(base) -> \\(endpoint.absoluteString)")
                }
            }
        }
    }
}
