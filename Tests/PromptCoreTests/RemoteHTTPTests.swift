import Testing
import Foundation
@testable import PromptCore

/// The remote's parser is the gate between the local network and a live
/// talk, so these lean on the *refusals* as much as the successes.
@Suite struct RemoteHTTPTests {
    private func request(_ raw: String) -> RemoteHTTP.Request? {
        RemoteHTTP.parse(Data(raw.utf8))
    }

    private func command(_ json: String) -> RemoteCommand? {
        RemoteHTTP.command(from: Data(json.utf8))
    }

    // MARK: - Request line

    @Test func parsesPathAndQuery() {
        let parsed = request("GET /?t=AB12CD HTTP/1.1\r\nHost: mac.local:5000\r\n\r\n")
        #expect(parsed?.method == "GET")
        #expect(parsed?.path == "/")
        #expect(parsed?.query["t"] == "AB12CD")
        #expect(parsed?.needsMoreBody == false)
    }

    @Test func parsesPathWithoutQuery() {
        let parsed = request("GET /api/state HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(parsed?.path == "/api/state")
        #expect(parsed?.query["t"] == nil)
    }

    @Test func percentDecodesTheToken() {
        // A token typed by hand off a screen can arrive encoded, and a
        // token that doesn't compare equal to the real one is a locked door.
        #expect(request("GET /?t=A%2BB HTTP/1.1\r\nHost: x\r\n\r\n")?.query["t"] == "A+B")
    }

    @Test func refusesGarbage() {
        #expect(request("not http at all") == nil)
        #expect(request("") == nil)
        #expect(request("GET\r\n\r\n") == nil)
        // No blank line: the head never arrived, so there is nothing to act on.
        #expect(request("GET /?t=AB HTTP/1.1\r\nHost: x") == nil)
    }

    // MARK: - Body

    @Test func readsTheDeclaredBodyAndStopsThere() {
        let parsed = request("POST /api/action?t=T HTTP/1.1\r\n"
            + "Content-Type: text/plain\r\nContent-Length: 22\r\n\r\n"
            + #"{"action":"playPause"}xx"#)
        #expect(parsed?.body == Data(#"{"action":"playPause"}"#.utf8))
        #expect(parsed?.needsMoreBody == false)
    }

    @Test func waitsForAnIncompleteBody() {
        let parsed = request("POST /api/action?t=T HTTP/1.1\r\nContent-Length: 40\r\n\r\n{\"a\":1}")
        #expect(parsed?.needsMoreBody == true)
        #expect(parsed?.body == Data(), "a half body is never acted on")
    }

    @Test func bodyMayContainBlankLines() {
        // The split is on the *first* blank line only; a body carrying its
        // own blank lines is not truncated at the second one.
        let body = "{\"section\":1}\n\n{\"action\":\"restart\"}"
        let parsed = request("POST /api/action?t=T HTTP/1.1\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(parsed?.body == Data(body.utf8))
    }

    @Test func headerValueWithAColonDoesNotConfuseLength() {
        let parsed = request("POST /api/action?t=T HTTP/1.1\r\n"
            + "Referer: http://192.168.1.4:5000/\r\nContent-Length: 2\r\n\r\n{}")
        #expect(parsed?.needsMoreBody == false)
        #expect(parsed?.body == Data("{}".utf8))
    }

    // MARK: - Commands

    @Test func actionByName() {
        #expect(command(#"{"action":"nextCue"}"#) == .action(.nextCue))
    }

    @Test func progressBecomesAScrub() {
        // Both spellings: a bare fraction, and one sent alongside an action
        // by a page that has not been updated. The fraction wins, so a stale
        // name can't swallow a thumb drag.
        #expect(command(#"{"progress":0.5}"#) == .scrub(0.5))
        #expect(command(#"{"action":"restart","progress":0.5}"#) == .scrub(0.5))
        #expect(command(#"{"action":"noSuchCommand","progress":0.25}"#) == .scrub(0.25))
    }

    @Test func sectionStep() {
        #expect(command(#"{"section":1}"#) == .sectionOffset(1))
        #expect(command(#"{"section":-1}"#) == .sectionOffset(-1))
    }

    @Test func refusesUnknownOrNonsenseCommands() {
        // A name the app has no such command for, a step that is not a
        // step, and a body that is not JSON. All refusals: a typo in a
        // button must not move a live script.
        #expect(command(#"{"action":"selfDestruct"}"#) == nil)
        #expect(command(#"{"section":0}"#) == nil)
        #expect(command(#"{"section":7}"#) == nil)
        #expect(command("not json") == nil)
        #expect(command("[]") == nil)
        #expect(command("{}") == nil)
    }

    @Test func ignoresUnknownKeys() {
        #expect(command(#"{"action":"playPause","extra":[1,2,3]}"#) == .action(.playPause))
    }

    // MARK: - Responses

    @Test func htmlResponseCountsRealBytes() {
        let body = "let x = \"héllo\""
        let text = String(data: RemoteHTTP.html(body), encoding: .utf8) ?? ""
        let after = text.range(of: "Content-Length: ")?.upperBound
        let declared = after.flatMap { Int(text[$0...].prefix { $0.isNumber }) }
        // Characters, not bytes, would be short by one here — a page Safari
        // hangs on.
        #expect(declared == body.utf8.count)
        #expect(text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(text.contains("Cache-Control: no-store"))
    }

    @Test func forbiddenRevealsNothing() {
        let text = String(data: RemoteHTTP.forbidden(), encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 403"))
        #expect(text.contains("Content-Length: 0"))
        #expect(!text.contains("Cuebar"), "a refusal must not name what is listening")
    }

    @Test func jsonRoundTrips() {
        let snapshot = RemoteSnapshot(title: "Demo", isPlaying: true, currentWord: 3,
                                      totalWords: 10, wordsPerMinute: 140,
                                      sections: ["A"], elapsed: 1, remaining: 2)
        let data = RemoteHTTP.json(snapshot)
        let decoded = data.flatMap { try? JSONDecoder().decode(RemoteSnapshot.self, from: $0) }
        #expect(decoded == snapshot)
    }

}

/// A remote is an unauthenticated door into the process, so a malformed
/// header must be a refusal and never a crash. `Data.prefix(_:)` traps on a
/// negative count, and the parse runs before the token is checked: one
/// hand-typed `Content-Length` from anything on the venue wifi was enough to
/// kill the prompter mid-talk.
@Suite struct RemoteHTTPMalformedLengthTests {
    private func request(_ head: String, body: String = "") -> Data {
        Data((head + "\r\n\r\n" + body).utf8)
    }

    @Test func aNegativeContentLengthIsRefusedRatherThanParsed() {
        #expect(RemoteHTTP.parse(request("POST /c HTTP/1.1\r\nContent-Length: -5")) == nil)
    }

    /// A length that is not a number is read as "no body". That is the
    /// forgiving reading, and it is safe precisely because nothing ever waits
    /// for bytes it was not told about: the request is answered from the head
    /// and the connection closes.
    @Test func aNonsenseContentLengthMeansNoBody() {
        let parsed = RemoteHTTP.parse(request("POST /c HTTP/1.1\r\nContent-Length: banana"))
        #expect(parsed?.needsMoreBody == false)
        #expect(parsed?.body.isEmpty == true)
    }

    /// `receive` re-arms until the declared length arrives, so an unbounded
    /// `Content-Length` is a promise to keep buffering.
    @Test func anOversizedBodyIsRefused() {
        let head = "POST /c HTTP/1.1\r\nContent-Length: "
            + String(9_000_000_000)
        #expect(RemoteHTTP.parse(request(head)) == nil)
    }

    @Test func aBodyAtTheLimitIsStillAccepted() {
        let head = "POST /c HTTP/1.1\r\nContent-Length: "
            + String(RemoteHTTP.Request.maximumBodyBytes)
        // Headers only: not a refusal, just a body still arriving.
        #expect(RemoteHTTP.parse(request(head))?.needsMoreBody == true)
        #expect(RemoteHTTP.parse(request(head, body: String(repeating: "x", count: 200)))
            .map { $0.needsMoreBody } == true)
        // …and the full body is accepted.
        let full = String(repeating: "x", count: RemoteHTTP.Request.maximumBodyBytes)
        #expect(RemoteHTTP.parse(request(head, body: full))?.needsMoreBody == false)
    }

    @Test func aRequestWithNoBodyStillParses() {
        let parsed = RemoteHTTP.parse(request("GET /state HTTP/1.1"))
        #expect(parsed?.path == "/state")
        #expect(parsed?.needsMoreBody == false)
    }
}
