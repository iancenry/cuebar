import Foundation

/// Just enough HTTP for a control page and two endpoints.
///
/// Strict on purpose. This parser decides whether a request from the local
/// network may move a live presentation, so a request it does not fully
/// understand is **refused**, not guessed at. Everything here is pure
/// bytes-to-meaning, which is why it lives in PromptCore and is tested
/// rather than sitting in a view where a half-read request would look the
/// same as a good one.
public enum RemoteHTTP {
    /// A parsed request, or nil when it isn't one we can act on.
    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var query: [String: String]
        public var body: Data
        /// Headers have arrived but the declared body has not. The caller
        /// must read more before deciding anything.
        public var needsMoreBody: Bool
    }

    public static func parse(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // A split on the first blank line: everything after it is body,
        // even if the body happens to contain blank lines of its own.
        guard let headEnd = text.range(of: "\r\n\r\n") else { return nil }
        let head = String(text[text.startIndex..<headEnd.lowerBound])
        let rawBody = Data(text[headEnd.upperBound...].utf8)

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.components(separatedBy: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let target = requestLine[1]
        guard !method.isEmpty, !target.isEmpty else { return nil }

        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<mark])
            for pair in target[target.index(after: mark)...].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                guard let key = kv.first, !key.isEmpty else { continue }
                query[key] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? "") : ""
            }
        }

        var length = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0].lowercased() == "content-length",
               let value = Int(kv[1].trimmingCharacters(in: .whitespaces)) {
                length = value
            }
        }
        if rawBody.count < length {
            return Request(method: method, path: path, query: query,
                           body: Data(), needsMoreBody: true)
        }
        return Request(method: method, path: path, query: query,
                       body: Data(rawBody.prefix(length)), needsMoreBody: false)
    }

    /// Read a JSON command body: either a `ShortcutAction` by name, a
    /// scrub fraction, or a section step.
    ///
    /// The names are the app's own — a remote button is a command the
    /// dispatcher already has, so a rebind in Settings changes the phone
    /// too, and there is no second vocabulary to fall out of step.
    public static func command(from body: Data) -> RemoteCommand? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        // A scrub is a scrub: it carries its own fraction, so it needs no
        // action name, and a page that sent both must not have its fraction
        // ignored because the name was stale.
        if let fraction = object["progress"] as? Double { return .scrub(fraction) }
        if let step = object["section"] as? Int, step == 1 || step == -1 {
            return .sectionOffset(step)
        }
        guard let name = object["action"] as? String,
              let action = ShortcutAction(rawValue: name) else { return nil }
        return .action(action)
    }

    // MARK: - Responses

    public static func html(_ body: String) -> Data {
        response(status: "200 OK", type: "text/html; charset=utf-8", body: Data(body.utf8),
                 extra: "Cache-Control: no-store")
    }

    public static func json(_ object: some Encodable) -> Data? {
        try? JSONEncoder().encode(object)
    }

    public static func jsonOK(_ body: Data) -> Data {
        response(status: "200 OK", type: "application/json", body: body,
                 extra: "Cache-Control: no-store")
    }

    public static func jsonError(_ message: String) -> Data {
        let body = Data("{\"error\":\"\(message)\"}".utf8)
        return response(status: "400 Bad Request", type: "application/json", body: body)
    }

    /// A bare refusal, no body: a device that guessed the address learns
    /// nothing about what is listening.
    public static func forbidden() -> Data {
        Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    public static func notFound() -> Data {
        Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    public static func serverError() -> Data {
        Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private static func response(status: String, type: String, body: Data,
                                 extra: String = "") -> Data {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        if !extra.isEmpty { head += extra + "\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
