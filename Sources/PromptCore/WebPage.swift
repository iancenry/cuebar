import Foundation

/// Recognising a web page someone pasted.
///
/// Pure, because "is this one line a link or is it the first line of a
/// script?" is a decision, and getting it wrong is either a script that
/// silently became an HTTP fetch or a link that was read aloud character by
/// character.
public enum WebPage {
    /// The URL in `text`, when the text is *only* a URL. A sentence with a
    /// link in it is a sentence, not a link.
    ///
    /// Only http(s): a `file:` or `javascript:` URL here would mean Cuebar
    /// fetching something the user did not mean to send anywhere, and
    /// nothing else is a web page.
    public static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// A URL with any credentials stripped, and any tracking query removed,
    /// before it is sent. A pasted link is not consent to send somebody
    /// else's session token to a server as a request parameter.
    public static func sanitized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.user = nil
        components.password = nil
        if let items = components.queryItems {
            let noise: Set<String> = ["utm_source", "utm_medium", "utm_campaign",
                                      "utm_term", "utm_content", "gclid", "fbclid",
                                      "mc_cid", "mc_eid", "ref", "ref_src"]
            let kept = items.filter { !noise.contains($0.name.lowercased()) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url ?? url
    }

    /// Filename for the fetched page, so an import of a link has the same
    /// title rules as an import of a file.
    public static func itemName(for url: URL, html: String?) -> String {
        let title = html.map { ScriptText.title(fromHTML: $0, url: url) }
        return "\(title ?? url.host ?? url.absoluteString).html"
    }
}