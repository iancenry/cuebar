import Foundation

/// What Cuebar asks a model to do to a script.
///
/// Three actions, because three are enough and each one is a thing
/// presenters actually ask for. "Make it better" is not on the list: it is
/// the request that produces a rewrite nobody recognises as their talk.
public enum AIScriptTask: String, CaseIterable, Sendable {
    /// Sound like a person talking: shorter sentences, contractions, no
    /// written-talk connectors.
    case conversational
    /// Cut to a length. The word budget travels with the request because
    /// "shorter" without a number is not an instruction a model can follow
    /// and a presenter cannot check.
    case trim
    /// Plain language: the same argument with the jargon gone.
    case plain
    /// Add the pauses a presenter has to remember: breaths between long
    /// thoughts, a beat before the point.
    case stageDirections

    public var title: String {
        switch self {
        case .conversational: return "Sound conversational"
        case .trim: return "Trim to a length"
        case .plain: return "Plain language"
        case .stageDirections: return "Add stage directions"
        }
    }

    public var help: String {
        switch self {
        case .conversational:
            return "Shorter sentences and spoken phrasing, same argument."
        case .trim:
            return "Cut to a word budget without losing the spine of the talk."
        case .plain:
            return "Replace jargon and abstraction with concrete words."
        case .stageDirections:
            return "Insert [pause 1s] and [breath 1.5s] cues where the talk needs air."
        }
    }

    /// The instructions, in the imperative. Kept out of the view so the sheet
    /// shows the same words the model was given.
    public func instructions(minutes: Int? = nil, wordsPerMinute: Int = 140) -> String {
        let shared = """
        You are editing a talk that will be read aloud from a teleprompter, by \
        a person, to a room. Return the whole script as plain text with the \
        same line breaks, and nothing else: no preamble, no commentary, no \
        markdown fences, no explanation of what you changed.

        Hard rules:
        - Keep every [cue] exactly as it is, including the text inside the \
        brackets. Bracketed spans are stage directions, not prose.
        - Keep lines starting with # as section headings.
        - Do not invent facts, numbers, names or examples.
        - Do not add a greeting, an apology, a summary or a thank-you.
        - Keep the presenter's own voice: their words, not a press release.
        """
        switch self {
        case .conversational:
            return shared + """

            Rewrite for the ear:
            - One idea per sentence. Split anything over about 20 words.
            - Prefer the short word to the precise one where both work aloud.
            - Contractions are fine and usually better.
            - Cut connectors that only make sense on paper: however, \
            moreover, additionally, therefore, in order to.
            - Say numbers and dates the way they are said.
            """
        case .trim:
            let budget = max(50, (minutes ?? 5) * wordsPerMinute)
            return shared + """

            Cut the script to about \(budget) words (\(minutes ?? 5) minutes at \
            \(wordsPerMinute) words per minute).
            - Cut whole examples and whole digressions, not half a clause.
            - Never cut the opening line or the closing line.
            - Keep the argument's spine: the same claims in the same order.
            """
        case .plain:
            return shared + """

            Rewrite in plain language:
            - Replace jargon, acronyms and internal names with what they mean.
            - Prefer concrete nouns and short verbs.
            - Keep every claim, but state it so a listener would follow it.
            """
        case .stageDirections:
            return shared + """

            Keep the words exactly as written. Only add cues:
            - [breath 1.5s] between long thoughts, where the speaker needs air.
            - [pause 1s] before a line that lands, and after a claim that needs
              a moment to settle.
            - Never add more than one cue per paragraph, and never add a cue to
              a paragraph that already has one.
            """
        }
    }
}

/// One request, as bytes.
///
/// Built here and sent by the app layer, because the *shape* of a request is
/// where a key leaks: an `Authorization` header in the wrong place, a body
/// that echoes the key, an error message that quotes the URL with a token in
/// it. All of that is decided by pure code and pinned by tests; the app layer
/// only has to hand the bytes to `URLSession`.
public struct AIRequest: Equatable, Sendable {
    public enum Provider: String, CaseIterable, Codable, Sendable {
        case anthropic
        case openAI
        /// Any OpenAI-compatible endpoint — Ollama, LM Studio, a gateway.
        case openAICompatible

        public var label: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openAI: return "OpenAI"
            case .openAICompatible: return "OpenAI-compatible"
            }
        }

        /// Does this provider need an API key? Ollama does not, and asking
        /// for one it will never use is how a setting stops being believed.
        public var needsKey: Bool { self != .openAICompatible }

        public var defaultModel: String {
            switch self {
            case .anthropic: return "claude-sonnet-4-5"
            case .openAI: return "gpt-4o-mini"
            case .openAICompatible: return "llama3.1"
            }
        }

        public var defaultBaseURL: String {
            switch self {
            case .anthropic: return "https://api.anthropic.com"
            case .openAI: return "https://api.openai.com/v1"
            case .openAICompatible: return "http://localhost:11434/v1"
            }
        }

        /// Anthropic's version header is not optional and not a constant of
        /// the API — get it wrong and every request 400s with a message that
        /// does not mention it.
        public var anthropicVersion: String { "2023-06-01" }
    }

    public let provider: Provider
    public let baseURL: String
    public let model: String
    public let key: String
    public let task: AIScriptTask
    public let script: String
    public let minutes: Int?
    public let wordsPerMinute: Int

    public init(provider: Provider, baseURL: String, model: String, key: String,
                task: AIScriptTask, script: String, minutes: Int? = nil,
                wordsPerMinute: Int = 140) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.key = key
        self.task = task
        self.script = script
        self.minutes = minutes
        self.wordsPerMinute = wordsPerMinute
    }

    /// The full endpoint for this provider and base URL. A base URL with a
    /// trailing slash, a `/v1` already on it, or a path pasted from a docs
    /// page all have to end up in the same place.
    public var endpoint: URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        // Refused rather than repaired. "api.anthropic.com" pasted without a
        // scheme is the common mistake, and `URL(string:)` accepts it as a
        // scheme-less relative URL — which `URLSession` then refuses with a
        // transport error about a host that does not exist. Same principle as
        // the remote's request parser: an address we cannot read is one we
        // do not guess at.
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              parsed.host?.isEmpty == false else { return nil }
        // A base carrying a query, a fragment or credentials is refused
        // rather than appended to. The appended path landed *inside* the query
        // value — so `?api-key=SECRET` put the secret in the request line,
        // where every proxy on the way logs it — and a `#fragment` silently
        // swallowed `/v1/messages` altogether, sending the request to the bare
        // base path. An address we cannot read is one we do not guess at.
        guard parsed.query == nil, parsed.fragment == nil,
              parsed.user == nil, parsed.password == nil else { return nil }
        let suffix = provider == .anthropic ? "/v1/messages" : "/chat/completions"
        // An OpenAI base already ending in /v1 (or deeper) does not get a
        // second one; an Anthropic base never carries it.
        if provider == .openAI, trimmed.hasSuffix("/v1") { return URL(string: trimmed + "/chat/completions") }
        if provider == .openAICompatible {
            // Ollama and the other local servers put their API under /v1, and
            // a base pasted out of a docs page usually does not say so. A base
            // that already ends in /v1 is left alone.
            let last = trimmed.split(separator: "/").last.map(String.init) ?? ""
            if last == "v1" { return URL(string: trimmed + "/chat/completions") }
            return URL(string: trimmed + "/v1/chat/completions")
        }
        return URL(string: trimmed + suffix)
    }

    /// Headers. The key goes in one place per provider and nowhere else.
    public var headers: [String: String] {
        switch provider {
        case .anthropic:
            var out = ["content-type": "application/json",
                       "x-api-key": key,
                       "anthropic-version": provider.anthropicVersion]
            // Ollama and friends speak the OpenAI dialect; Anthropic needs no
            // CORS dance because this is not a browser.
            return out
        case .openAI, .openAICompatible:
            var out = ["content-type": "application/json"]
            if !key.isEmpty { out["authorization"] = "Bearer \(key)" }
            return out
        }
    }

    /// The body, as JSON text.
    ///
    /// Built by hand rather than with `Encodable`/`JSONEncoder` for one
    /// reason: the order of the keys is then pinned by a test, and a
    /// hand-edited settings file cannot produce a body that a model silently
    /// misreads. `system` is separate from `messages` on Anthropic and inside
    /// the first message everywhere else, which is the other thing that is
    /// easy to get wrong and hard to read in an error.
    public func jsonBody() throws -> String {
        let instructions = task.instructions(minutes: minutes, wordsPerMinute: wordsPerMinute)
        let escapedScript = Self.escape(script)
        let escapedSystem = Self.escape(instructions)
        let escapedModel = Self.escape(model)
        switch provider {
        case .anthropic:
            return """
            {"model":"\(escapedModel)","max_tokens":\(maxTokens),"system":"\(escapedSystem)",\
            "messages":[{"role":"user","content":"\(escapedScript)"}]}
            """
        case .openAI, .openAICompatible:
            return """
            {"model":"\(escapedModel)","stream":false,\
            "messages":[{"role":"system","content":"\(escapedSystem)"},\
            {"role":"user","content":"\(escapedScript)"}]}
            """
        }
    }

    /// Enough room for a rewrite of a long talk. Anthropic requires the
    /// field; the others ignore it.
    public var maxTokens: Int {
        // Roughly three tokens per script word, floor 1024, ceiling 8192 —
        // the model's own limit is the app's problem, not the user's.
        let words = max(1, script.split(whereSeparator: { $0.isWhitespace }).count)
        return min(8192, max(1024, words * 3))
    }

    /// JSON string escaping, done by hand so the escaping is testable and
    /// cannot depend on a Foundation version's idea of what JSON is.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 16)
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out
    }
}

/// What came back.
///
/// Two response shapes and a pile of error shapes, all parsed here so the UI
/// can say what went wrong without a regex in a view.
public enum AIResponse {
    public static func parse(provider: AIRequest.Provider, data: Data) -> Result<String, AIError> {
        let text = String(decoding: data, as: UTF8.self)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.notJSON(text))
        }
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? text
            return .failure(.provider(message))
        }
        switch provider {
        case .anthropic:
            if let content = object["content"] as? [[String: Any]] {
                // Joined with a newline, not with nothing: a multi-part reply
                // is two pieces of text, and `joined()` fused the last word of
                // one to the first word of the next.
                let text = content.compactMap { $0["text"] as? String }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !text.isEmpty { return .success(stripFences(text)) }
            }
            // A refusal or a max-tokens stop arrives with a stop reason and
            // no text; saying "the model returned nothing" is more useful than
            // "unexpected shape".
            let reason = object["stop_reason"] as? String
            return .failure(.empty(reason.map { "stopped: \($0)" } ?? nil))
        case .openAI, .openAICompatible:
            if let choices = object["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                return .success(stripFences(content))
            }
            if let choices = object["choices"] as? [[String: Any]],
               let text = choices.first?["text"] as? String, !text.isEmpty {
                // Completion-style, for a local server configured without chat.
                return .success(stripFences(text))
            }
            // A refusal is an answer, and it is the one the user most needs to
            // see. Reporting "the model returned no text" and suggesting a
            // shorter script sends them after the wrong problem.
            if let choices = object["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["refusal"] as? String, !text.isEmpty {
                return .failure(.refused(text))
            }
            return .failure(.empty(nil))
        }
    }

    /// A model that ignored the "no markdown fences" instruction still
    /// produces a usable script once the fences come off — but nothing else
    /// is guessed at. Guessing is how a rewrite silently loses its first
    /// line.
    /// Strip a fenced code block out of a reply, wherever it appears.
    ///
    /// The whole reply does not have to *start* with the fence. Models add a
    /// line of preamble even when told not to ("Here is the rewrite:"), and a
    /// fence after it was left in — so the preamble became the prompter's first
    /// line and the closing fence its last.
    static func stripFences(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = out.range(of: "```") else { return out }
        // Anything before the fence is the model's chatter, not the script.
        out = String(out[opening.upperBound...])
        // Drop the language tag on the opening fence.
        if let firstNewline = out.firstIndex(of: "\n") {
            out = String(out[out.index(after: firstNewline)...])
        }
        if let closing = out.range(of: "```", options: .backwards) {
            out = String(out[out.startIndex..<closing.lowerBound])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum AIError: LocalizedError, Equatable {
        /// The endpoint answered with something that was not JSON — a proxy
        /// error page, a captive portal, a typo in the base URL.
        case notJSON(String)
        /// The provider said no.
        case provider(String)
        /// The model declined to answer this one. Distinct from `empty`,
        /// because the recovery is completely different: there is no text to
        /// retry for, and the fix is a different prompt or a different model,
        /// not a shorter script.
        case refused(String)
        /// No text came back.
        case empty(String?)
        /// No key, or no base URL.
        case notConfigured
        /// The transport failed.
        case transport(String)
        /// HTTP status with the provider's message.
        case status(Int, String)

        public var errorDescription: String? {
            switch self {
            case .notJSON(let text):
                let head = text.prefix(120)
                return "The server did not answer with JSON: \(head)"
            case .provider(let message): return message
            case .empty(let reason): return reason ?? "The model returned no text."
            case .refused(let message): return "The model declined: \(message)"
            case .notConfigured:
                return "No key yet — add one in Settings → Script Tools."
            case .transport(let message): return message
            case .status(let code, let message):
                return message.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(message)"
            }
        }

        /// What to do about it, which is not the same as what went wrong.
        public var recovery: String {
            switch self {
            case .notConfigured: return "Open Settings → Script Tools and paste your key."
            case .notJSON: return "Check the base URL — it should end at /v1."
            case .provider, .status: return "The key or the model name may be wrong."
            case .empty: return "Try a shorter script, or a different model."
            case .refused:
                return "The model would not rewrite this one — try a different "
                    + "model, or make the request in smaller pieces."
            case .transport: return "Check the network and try again."
            }
        }
    }
}