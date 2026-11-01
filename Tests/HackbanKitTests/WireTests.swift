import Foundation
import XCTest
@testable import HackbanKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WireTests: XCTestCase {
    func testSHA256() {
        func hex(_ s: String) -> String { SHA256.hash(Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(String(repeating: "a", count: 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPKCEMatchesRFC7636() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertGreaterThanOrEqual(PKCE().verifier.count, 43)
    }

    func testSuperJSONMarksDates() throws {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        let v = SuperJSON.serialize(["id": "c1", "due": .date(d), "start": .null, "keep": ["at": .date(d)], "list": [.date(d)]])
        XCTAssertEqual(v["json"]?["due"], .date(d))
        XCTAssertEqual(v["meta"]?["values"]?["due"], ["Date"])
        XCTAssertEqual(v["meta"]?["values"]?["keep.at"], ["Date"])
        XCTAssertEqual(v["meta"]?["values"]?["list.0"], ["Date"])
        XCTAssertNil(v["meta"]?["values"]?["start"])
        let text = String(decoding: try SuperJSON.encode(["due": .date(d)]), as: UTF8.self)
        XCTAssertEqual(text, #"{"json":{"due":"2027-01-15T08:00:00.000Z"},"meta":{"values":{"due":["Date"]}}}"#)
        XCTAssertEqual(String(decoding: try SuperJSON.encode(["id": "x"]), as: UTF8.self), #"{"json":{"id":"x"}}"#)
    }

    func testDecodeResultVoidAndErrors() throws {
        struct R: Decodable { let id: String; let at: Date }
        let ok = Data(#"{"result":{"data":{"json":{"id":"a","at":"2026-10-28T12:00:00.000Z"},"meta":{"values":{"at":["Date"]}}}}}"#.utf8)
        let r: R = try TRPCClient.decode(ok, status: 200)
        XCTAssertEqual(r.id, "a")
        XCTAssertEqual(r.at, ISODate.parse("2026-10-28T12:00:00Z"))

        let void = Data(#"{"result":{"data":{"meta":{"values":["undefined"]}}}}"#.utf8)
        let _: Nothing = try TRPCClient.decode(void, status: 200)

        let err = Data(#"{"error":{"json":{"message":"Only board admins can move a board.","code":-32003,"data":{"code":"FORBIDDEN","httpStatus":403,"path":"board.move","zodError":null}}}}"#.utf8)
        XCTAssertThrowsError(try TRPCClient.decode(err, status: 403) as Nothing) { e in
            XCTAssertEqual(e as? HackbanError, .server(code: "FORBIDDEN", status: 403, message: "Only board admins can move a board."))
        }

        let zod = Data(#"{"error":{"json":{"message":"[{\"code\":\"too_small\"}]","code":-32600,"data":{"code":"BAD_REQUEST","httpStatus":400,"zodError":{"formErrors":[],"fieldErrors":{"title":["String must contain at least 1 character(s)"]}}}}}}"#.utf8)
        XCTAssertThrowsError(try TRPCClient.decode(zod, status: 400) as Nothing) { e in
            XCTAssertEqual((e as? HackbanError)?.errorDescription, "title: String must contain at least 1 character(s)")
        }
    }

    func testSSEParser() {
        var p = SSEParser()
        let stream = """
        event: connected
        data: {}

        data: {"json":{"boardId":"b1","cardId":"c1","origin":"x","kind":"card"}}

        event: ping
        data:

        : comment
        data: {"json":{"boardId":"b1","kind":"board"}}
        id: 7

        """
        var events: [SSEParser.Event] = []
        for line in stream.components(separatedBy: "\n") { if let e = p.feed(line: line) { events.append(e) } }
        XCTAssertEqual(events.count, 4)
        XCTAssertNil(SSEParser.boardEvent(events[0]))
        XCTAssertEqual(SSEParser.boardEvent(events[1]), BoardEvent(boardId: "b1", cardId: "c1", origin: "x", kind: "card"))
        XCTAssertNil(SSEParser.boardEvent(events[2]))
        XCTAssertEqual(SSEParser.boardEvent(events[3])?.kind, "board")
        XCTAssertEqual(events[3].id, "7")
    }

    func testNormalizeServer() throws {
        XCTAssertEqual(try OAuth.normalizeServer("hackban.hackclub.com").absoluteString, "https://hackban.hackclub.com")
        XCTAssertEqual(try OAuth.normalizeServer(" https://hackban.hackclub.com/b/abc?x=1 ").absoluteString, "https://hackban.hackclub.com")
        XCTAssertEqual(try OAuth.normalizeServer("http://localhost:3000/").absoluteString, "http://localhost:3000")
        XCTAssertThrowsError(try OAuth.normalizeServer(""))
        XCTAssertThrowsError(try OAuth.normalizeServer("ftp://x.com"))
    }

    func testCallbackParsing() throws {
        XCTAssertEqual(try OAuth.code(fromCallback: URL(string: "hackban-desktop://oauth/callback?code=abc&state=s1")!, expectedState: "s1"), "abc")
        XCTAssertThrowsError(try OAuth.code(fromCallback: URL(string: "hackban-desktop://oauth/callback?code=abc&state=other")!, expectedState: "s1"))
        XCTAssertThrowsError(try OAuth.code(fromCallback: URL(string: "hackban-desktop://oauth/callback?error=access_denied&state=s1")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? HackbanError, .cancelled)
        }
        XCTAssertEqual(OAuth.formEncode(["b": "x y+z", "a": "1"]), "a=1&b=x%20y%2Bz")
    }

    func testAuthorizeURLAsksForAppScope() throws {
        let meta = try JSONDecoder().decode(ServerMetadata.self, from: Data(#"{"authorization_endpoint":"https://h.com/oauth/authorize","token_endpoint":"https://h.com/api/oauth/token","registration_endpoint":"https://h.com/api/oauth/register","scopes_supported":["mcp","app"]}"#.utf8))
        let url = OAuth.authorizeURL(meta, clientId: "c1", pkce: PKCE(verifier: "v".padding(toLength: 43, withPad: "v", startingAt: 0)), state: "st")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "app")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "hackban-desktop://oauth/callback")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
    }
}

/// Canned HTTP for token and tRPC tests.
final class MockHTTP: HTTP, @unchecked Sendable {
    var handler: (URLRequest) -> (Int, String)
    var requests: [URLRequest] = []
    let lock = NSLock()

    init(_ handler: @escaping (URLRequest) -> (Int, String)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        let (status, body) = handler(request)
        lock.unlock()
        try await Task.sleep(nanoseconds: 10_000_000)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class TokenTests: XCTestCase {
    func creds(expiresIn: TimeInterval) -> AccountCredentials {
        AccountCredentials(clientId: "c", tokenEndpoint: URL(string: "https://h.com/api/oauth/token")!,
                           tokens: OAuthTokens(accessToken: "old", refreshToken: "r1", expiresAt: Date().addingTimeInterval(expiresIn), scope: "app"))
    }

    func testConcurrentCallersRefreshOnce() async throws {
        var n = 0
        let http = MockHTTP { _ in
            n += 1
            return (200, #"{"access_token":"new\#(n)","refresh_token":"r\#(n + 1)","expires_in":3600,"scope":"app"}"#)
        }
        let saved = Box<AccountCredentials?>(nil)
        let tm = TokenManager(credentials: creds(expiresIn: 10), http: http) { saved.value = $0 }
        async let a = tm.accessToken()
        async let b = tm.accessToken()
        async let c = tm.accessToken()
        let tokens = try await [a, b, c]
        XCTAssertEqual(Set(tokens), ["new1"])
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(saved.value?.tokens.refreshToken, "r2")
        // Fresh token: no more refreshes.
        _ = try await tm.accessToken()
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRevokedGrantSignsOut() async {
        let http = MockHTTP { _ in (400, #"{"error":"invalid_grant"}"#) }
        let saved = Box<AccountCredentials?>(nil)
        saved.value = creds(expiresIn: 0)
        let tm = TokenManager(credentials: creds(expiresIn: 0), http: http) { saved.value = $0 }
        do {
            _ = try await tm.accessToken()
            XCTFail("expected sign-out")
        } catch {
            XCTAssertEqual(error as? HackbanError, .signedOut)
        }
        XCTAssertNil(saved.value)
        let signedIn = await tm.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testClientRetriesOnceAfter401() async throws {
        var refreshed = false
        let http = MockHTTP { req in
            if req.url!.path.hasSuffix("/api/oauth/token") {
                refreshed = true
                return (200, #"{"access_token":"fresh","refresh_token":"r2","expires_in":3600}"#)
            }
            let auth = req.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer old" { return (401, #"{"error":{"json":{"message":"UNAUTHORIZED","data":{"code":"UNAUTHORIZED","httpStatus":401}}}}"#) }
            return (200, #"{"result":{"data":{"json":[]}}}"#)
        }
        let tm = TokenManager(credentials: creds(expiresIn: 3000), http: http) { _ in }
        let client = TRPCClient(server: URL(string: "https://h.com")!, tokens: tm, http: http)
        let n: [HackbanNotification] = try await HackbanAPI(client: client).notifications()
        XCTAssertEqual(n.count, 0)
        XCTAssertTrue(refreshed)
        let last = http.requests.last!
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        XCTAssertEqual(last.value(forHTTPHeaderField: "x-client-id"), client.clientId)
        XCTAssertEqual(last.url?.path, "/api/trpc/notification.list")
    }

    func testQueryAndMutationWireFormat() async throws {
        let http = MockHTTP { _ in (200, #"{"result":{"data":{"json":null,"meta":{"values":["undefined"]}}}}"#) }
        let tm = TokenManager(credentials: creds(expiresIn: 3000), http: http) { _ in }
        let api = HackbanAPI(client: TRPCClient(server: URL(string: "https://h.com")!, tokens: tm, http: http))
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        try await api.updateCard("c1", .init(due: .some(due), coverColor: .some(nil)))
        let req = http.requests.last!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/trpc/card.update")
        let body = try JSONDecoder().decode(JSONValue.self, from: req.httpBody!)
        XCTAssertEqual(body["json"]?["id"], "c1")
        XCTAssertEqual(body["json"]?["due"], "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(body["json"]?["coverColor"], .null)
        XCTAssertNil(body["json"]?["title"])
        XCTAssertEqual(body["meta"]?["values"]?["due"], ["Date"])

        _ = try? await api.search("a+b c")
        let q = http.requests.last!
        XCTAssertEqual(q.httpMethod ?? "GET", "GET")
        let input = URLComponents(url: q.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "input" }!.value!
        XCTAssertEqual(input, #"{"json":{"q":"a+b c"}}"#)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
