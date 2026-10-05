import Foundation

/// The parts of an AI setup that are not secret, persisted with the rest of
/// the preferences. The key itself is deliberately *not* here: a JSON file in
/// `~/Library/Application Support` is world-readable to anything with a home
/// directory, and a key in there is a key that has to be rotated after the
/// user copies their settings to a new Mac.
public struct AISettings: Codable, Equatable, Sendable {
    public var provider: AIRequest.Provider = .anthropic
    /// The endpoint root. Editable because the whole point of "bring your own
    /// key" is that it is not always the vendor.
    public var baseURL: String = AIRequest.Provider.anthropic.defaultBaseURL
    public var model: String = AIRequest.Provider.anthropic.defaultModel
    /// The budget for the trim task.
    public var minutes: Int = 5

    public static let `default` = AISettings()

    public init(provider: AIRequest.Provider = .anthropic,
                baseURL: String? = nil, model: String? = nil, minutes: Int = 5) {
        self.provider = provider
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.model = model ?? provider.defaultModel
        self.minutes = max(1, minutes)
    }

    /// Move to a provider and take its defaults with it, unless the user has
    /// clearly pointed the base URL somewhere on purpose (a local server, or a
    /// gateway host) — in which case their URL survives and only the model
    /// name follows the provider.
    public mutating func setProvider(_ provider: AIRequest.Provider) {
        // Compared with the trailing slash and surrounding space normalised
        // away: "https://api.anthropic.com/" is the same address, and treating
        // it as custom left the OpenAI request aimed at Anthropic's host.
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalised = trimmed
        while normalised.hasSuffix("/") { normalised.removeLast() }
        let stock = [AIRequest.Provider.anthropic, .openAI, .openAICompatible]
            .map { $0.defaultBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        let custom = !normalised.isEmpty && !stock.contains(normalised)
        self.provider = provider
        self.baseURL = custom ? baseURL : provider.defaultBaseURL
        self.model = provider.defaultModel
    }

    /// Everything the client needs but not the key.
    public func request(task: AIScriptTask, script: String) -> AIRequest {
        AIRequest(provider: provider, baseURL: baseURL, model: model,
                  key: "", task: task, script: script, minutes: minutes)
    }
}
