import Foundation
import Network
import PromptCore

#if os(macOS)
import AppKit
#endif

/// A phone-sized control for the prompter, served over the local network.
///
/// **Armed only while the prompter is up.** This is a server on whatever
/// wifi the venue has, and it can move the highlight of a live talk, so it
/// does not run as a background service waiting to be found — it exists
/// for the length of a presentation and stops after. That is the same
/// discipline as the global key tap, and it is the reason a presenter
/// never has to remember to switch something off.
///
/// **A page, not an app.** A phone opens it in Safari; there is no second
/// Xcode target, no signing and no review. The protocol is the whole
/// interface, so a native shell later is a nicer window onto the same
/// thing rather than a rewrite.
///
/// **The token is the security, so it is not advertised.** Bonjour carries
/// the service name only. A device on the network can see that a Cuebar
/// exists; it cannot drive it without the token in the URL, which only
/// ever appears on the Mac's screen. A hostile *web page* on the same
/// network can't read the URL either — which is the case that would
/// otherwise get through, since a `text/plain` POST is a simple request
/// and needs no preflight.
@MainActor
@Observable
final class RemoteController {
    private(set) var isArmed = false
    /// Shown on the Mac so the presenter can type it once. Nil while
    /// disarmed — there is no URL for a server that isn't listening.
    private(set) var url: String?

    private var listener: NWListener?
    private let token = RemoteController.makeToken()
    private var state: () -> RemoteSnapshot = {
        RemoteSnapshot(title: "", isPlaying: false, currentWord: 0, totalWords: 0,
                       wordsPerMinute: 0, sections: [], elapsed: 0, remaining: 0)
    }
    private var perform: (RemoteCommand) -> Void = { _ in }

    /// Six hex characters is 16 million possibilities against a listener
    /// that only exists for a few minutes. It has to be short enough to
    /// type on a phone, and it is per-process, so a stale URL from a
    /// previous talk is simply wrong rather than still open.
    private static func makeToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(6)).uppercased()
    }

    /// The local IPv4 address, for the URL the presenter reads off screen.
    /// `en0` first because that is the wifi on every Mac; a phone on the
    /// same network needs an address it can actually reach, and
    /// `127.0.0.1` is not it.
    private static func localAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard pointer.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(pointer.pointee.ifa_addr.pointee.sa_len)
            guard getnameinfo(pointer.pointee.ifa_addr, length, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            address = String(cString: host)
            if name == "en0" { break }
        }
        return address
    }

    // MARK: - Arming

    func arm(state: @escaping () -> RemoteSnapshot,
             perform: @escaping (RemoteCommand) -> Void) {
        self.state = state
        self.perform = perform
        guard listener == nil else { return }

        let listener = try? NWListener(using: .tcp, on: .any)
        guard let listener else { return }
        // Bonjour, name only. Advertising the token would hand the remote
        // to every device on the network.
        listener.service = NWListener.Service(name: "Cuebar", type: "_cuebar._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.serve(connection) }
        }
        listener.stateUpdateHandler = { [weak self] ready in
            guard case .ready = ready, let self, let port = listener.port else { return }
            // `Task { @MainActor [self] in … }` rather than the bare form:
            // without a capture list the closure is ambiguous with
            // `Task.init(value:operation:)` and fails to compile.
            Task { @MainActor [self] in
                isArmed = true
                url = Self.localAddress().map {
                    "http://\($0):\(port.rawValue)/?t=\(token)"
                }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func disarm() {
        listener?.cancel()
        listener = nil
        isArmed = false
        url = nil
    }

    // MARK: - Requests

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, into: Data())
    }

    /// Read one request, answer it, close. No keep-alive: a phone polling
    /// every half second gains nothing from a held connection, and a
    /// per-request socket has no state to leak between callers.
    private func receive(on connection: NWConnection, into buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            // **Hop to the main actor explicitly.** This closure is written
            // inside a @MainActor method, so Swift 6 lets it type-check as
            // if it were already isolated — but Network calls it on its own
            // dispatch queue, and nothing enforces the compiler's
            // assumption at runtime. Calling `respond` from here directly
            // built the whole chain (`state()` → `ScriptStore.selected`)
            // off-actor and trapped: EXC_BREAKPOINT, and the prompter died
            // mid-presentation. The same reason `assumeIsolated` is banned
            // for the ticker.
            Task { @MainActor [weak self] in
                guard let self else { return }
                var accumulated = buffer
                if let data { accumulated.append(data) }
                guard error == nil else { connection.cancel(); return }
                guard let request = RemoteHTTP.parse(accumulated) else {
                    // Not a request we can read. Closing rather than waiting
                    // for more is the point: the first version treated an
                    // unreadable head as a request still arriving, so a
                    // stray connection to the port was held open until it
                    // timed out.
                    if !isComplete {
                        connection.send(content: RemoteHTTP.forbidden(),
                                        completion: .contentProcessed { _ in connection.cancel() })
                    } else {
                        connection.cancel()
                    }
                    return
                }
                if request.needsMoreBody {
                    if isComplete { connection.cancel() } else {
                        self.receive(on: connection, into: accumulated)
                    }
                    return
                }
                let response = self.respond(to: request)
                connection.send(content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func respond(to request: RemoteHTTP.Request) -> Data {
        // The token is checked before the path, so a wrong token cannot
        // even tell you which endpoints exist.
        guard request.query["t"] == token else { return RemoteHTTP.forbidden() }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return Self.htmlResponse()
        case ("GET", "/api/state"):
            return Self.jsonResponse(state())
        case ("POST", "/api/action"):
            guard let command = RemoteHTTP.command(from: request.body) else {
                return RemoteHTTP.jsonError("unknown command")
            }
            perform(command)
            // Answer with the state that results, so the phone's next paint
            // is the truth rather than a guess made before the main actor
            // had applied anything.
            return Self.jsonResponse(state())
        default:
            return RemoteHTTP.notFound()
        }
    }

    // MARK: - Responses

    private static func htmlResponse() -> Data {
        guard let url = Bundle.module.url(forResource: "Remote", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            // The page missing is a packaging fault, not a caller error, so
            // it is a 500 rather than a refusal.
            return RemoteHTTP.serverError()
        }
        return RemoteHTTP.html(html)
    }

    private static func jsonResponse(_ snapshot: RemoteSnapshot) -> Data {
        guard let json = RemoteHTTP.json(snapshot) else { return RemoteHTTP.serverError() }
        return RemoteHTTP.jsonOK(json)
    }
}
