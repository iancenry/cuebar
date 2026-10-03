import Foundation
import PromptCore

/// Fetching a page and turning it into a script body.
///
/// The one place Cuebar talks to the internet on its own initiative, so it
/// is small and boring on purpose: http(s) only, a size ceiling, a
/// content-type check, and no cookies, no credentials and no redirect to a
/// private address.
enum ScriptWeb: Sendable {
    /// The ceiling on a fetched page. A talk is not 8 MB of HTML; a
    /// download link is not a web page.
    static let maxBytes = 8 * 1024 * 1024

    enum Failure: LocalizedError {
        case notAURL(String)
        case badStatus(Int)
        case tooLarge
        case wrongContentType(String)
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .notAURL(let text):
                return "“\(text)” isn't a web address."
            case .badStatus(let code):
                return "The page answered with status \(code)."
            case .tooLarge:
                return "That page is too large to be a script."
            case .wrongContentType(let type):
                return "That address serves \(type), not a web page."
            case .unreadable:
                return "That page couldn't be read."
            case .empty:
                return "That page has no text in it — it may need JavaScript, or be a scan."
            }
        }
    }

    /// Fetch and convert. Returns the script, ready for the store.
    ///
    /// Deliberately not `@MainActor`: the request has no reason to occupy
    /// the run loop, and the caller hops back when it has something to show.
    static func script(for url: URL, existingTitles: [String] = []) async throws -> ImportedScript {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            throw Failure.notAURL(url.absoluteString)
        }
        let target = WebPage.sanitized(url)
        var request = URLRequest(url: target)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
                         forHTTPHeaderField: "Accept")
        request.setValue("Cuebar (macOS teleprompter)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        // 200–299, and nothing else: a 3xx that we followed to a login page
        // produces a script made of a password field.
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.badStatus(http.statusCode)
        }
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        if let type = http.value(forHTTPHeaderField: "Content-Type"),
           !type.lowercased().contains("html") && !type.lowercased().contains("text/") {
            throw Failure.wrongContentType(type)
        }
        guard let html = ScriptText.decode(data) ?? String(data: data, encoding: .utf8) else {
            throw Failure.unreadable
        }
        let body = HTMLText.plainBody(html)
        let title = ScriptText.title(fromHTML: html, url: target)
        guard let script = ScriptImport.fromBody(body, title: title,
                                                existingTitles: existingTitles) else {
            throw Failure.empty
        }
        return script
    }

    /// The clipboard's text, if it is a page and nothing else.
    static func url(fromClipboardText text: String?) -> URL? {
        guard let text else { return nil }
        return WebPage.url(in: text)
    }
}