import Foundation
import PromptCore

/// Sends one script to a model and reads the answer back.
///
/// The thin half. Everything that could be wrong about a request — where the
/// key goes, which endpoint a base URL means, how a reply is shaped, what an
/// error says — is `AIRequest` and `AIResponse` in PromptCore, with tests.
/// This class does the one thing only the app layer can: hand bytes to
/// `URLSession` and hand the answer back on the main actor.
@MainActor
@Observable
final class AIClient {
    enum State: Equatable {
        case idle
        case sending
        case done
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The last rewrite, ready to preview.
    private(set) var result: String?
    /// The error, and what to do about it.
    private(set) var issue: AIResponse.AIError?

    /// Seconds before giving up. A local model on a laptop can take a while
    /// to load; a hosted one that takes two minutes is not going to answer.
    private let timeout: TimeInterval = 120

    /// Discard whatever is on screen and stop waiting for it.
    ///
    /// Cancelling the request too: without a handle, "Discard" left the
    /// in-flight answer alive, and it arrived afterwards and put the rewrite
    /// the user had just thrown away back into the preview.
    func reset() {
        inFlight?.cancel()
        inFlight = nil
        state = .idle
        result = nil
        issue = nil
    }

    /// The current request, so `reset()` can cancel it.
    private var inFlight: Task<Void, Never>?

    /// Run the task. The key is read from the keychain here rather than held
    /// anywhere, so a failed request has nothing to leak and the view never
    /// has the secret in a property.
    func run(_ task: AIScriptTask, script: String, settings: AISettings,
             wordsPerMinute: Int = 140) {
        guard state != .sending else { return }
        // Clear first, not later. The old rewrite used to survive a failure:
        // these early returns happened *before* `result = nil`, so a run that
        // could not start left the previous answer on screen with Apply still
        // live — and the header naming the task that had just been switched.
        result = nil
        issue = nil
        let key = Keychain.read("scripttools") ?? ""
        if settings.provider.needsKey, key.isEmpty {
            state = .failed(AIResponse.AIError.notConfigured.localizedDescription)
            issue = .notConfigured
            return
        }
        guard let endpoint = settings.request(task: task, script: script).endpoint else {
            // Not `.notConfigured`: that reads "no key yet" and sends the user
            // to a field that is already filled in. Say which field is wrong.
            issue = .transport("No endpoint — check the base URL in Settings.")
            state = .failed(issue?.localizedDescription ?? "No endpoint.")
            return
        }
        var request = settings.request(task: task, script: script)
        request = AIRequest(provider: request.provider, baseURL: request.baseURL,
                            model: request.model, key: key, task: task, script: script,
                            minutes: settings.minutes, wordsPerMinute: wordsPerMinute)
        let body: Data
        do {
            body = Data(try request.jsonBody().utf8)
        } catch {
            issue = .provider(error.localizedDescription)
            state = .failed(issue!.localizedDescription)
            return
        }

        state = .sending
        result = nil
        issue = nil
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        inFlight = Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                // URLSession's completion is not a main-actor context, and
                // nothing here is safe to touch off it: hop explicitly rather
                // than trusting the compiler's inference (see AGENTS.md).
                let outcome = Self.outcome(provider: request.provider, data: data,
                                           response: response)
                finish(outcome)
            } catch {
                finish(.failure(.transport(error.localizedDescription)))
            }
        }
    }

    /// Status first, then the body: a 401 with a useful message should say the
    /// message, and a 429 with none should say 429.
    static func outcome(provider: AIRequest.Provider, data: Data,
                        response: URLResponse) -> Result<String, AIResponse.AIError> {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let message = AIResponse.parse(provider: provider, data: data)
                .failureMessage ?? ""
            return .failure(.status(status, message))
        }
        return AIResponse.parse(provider: provider, data: data)
    }

    private func finish(_ outcome: Result<String, AIResponse.AIError>) {
        switch outcome {
        case .success(let text):
            result = text
            state = .done
        case .failure(let error):
            // A failure must not leave an answer on screen: the preview reads
            // `result` before it looks at the state, so a stale rewrite would
            // be shown — and applied — under an error message.
            result = nil
            issue = error
            state = .failed(error.localizedDescription)
        }
        inFlight = nil
    }
}

extension Result where Failure == AIResponse.AIError {
    /// The provider's own message, when there is one.
    var failureMessage: String? {
        guard case .failure(let error) = self else { return nil }
        switch error {
        case .provider(let message), .status(_, let message): return message
        case .refused(let message): return message
        case .notJSON(let text): return String(text.prefix(120))
        case .empty(let reason): return reason
        case .notConfigured: return nil
        case .transport(let message): return message
        }
    }
}