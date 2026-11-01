import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Decodes from any JSON (for procedures that return nothing useful).
public struct Nothing: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}

/// `{"result": {"data": {"json": T}}}`
struct TRPCResult<T: Decodable>: Decodable {
    struct Inner: Decodable { let data: SuperJSONEnvelope<T>? }
    let result: Inner
}

/// Speaks Hackban's tRPC 11 HTTP protocol (non-batched, superjson):
/// - query:    `GET  /api/trpc/<path>?input=<superjson>`
/// - mutation: `POST /api/trpc/<path>` with a superjson body
/// - response: `{"result": {"data": {"json": …}}}` or `{"error": {"json": {…}}}`
public final class TRPCClient: @unchecked Sendable {
    public let server: URL
    public let tokens: TokenManager
    public let http: HTTP
    /// Sent as `x-client-id` so the live-update stream can skip this client's own changes.
    public let clientId = Data.random(count: 9).base64URL

    public init(server: URL, tokens: TokenManager, http: HTTP) {
        self.server = server
        self.tokens = tokens
        self.http = http
    }

    public func query<T: Decodable>(_ path: String, _ input: JSONValue? = nil, as: T.Type = T.self) async throws -> T {
        var c = URLComponents(url: endpoint(path), resolvingAgainstBaseURL: false)!
        if let input {
            let data = try SuperJSON.encode(input)
            c.queryItems = [URLQueryItem(name: "input", value: String(decoding: data, as: UTF8.self))]
            // URLComponents leaves "+" alone, which servers read as a space.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return try await send(URLRequest(url: c.url!))
    }

    @discardableResult
    public func mutate<T: Decodable>(_ path: String, _ input: JSONValue? = nil, as: T.Type = T.self) async throws -> T {
        var req = URLRequest(url: endpoint(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try SuperJSON.encode(input ?? .object([:]))
        return try await send(req)
    }

    public func mutate(_ path: String, _ input: JSONValue? = nil) async throws {
        let _: Nothing = try await mutate(path, input, as: Nothing.self)
    }

    func endpoint(_ path: String) -> URL { server.appendingPathComponent("api/trpc/\(path)") }

    /// Adds auth and the headers the server reads, retrying once with a refreshed token on 401.
    public func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        let token = try await tokens.accessToken()
        decorate(&req, token: token)
        var (data, res) = try await http.send(req)
        if res.statusCode == 401 {
            let fresh = try await tokens.accessToken(forceRefresh: true, rejected: token)
            decorate(&req, token: fresh)
            (data, res) = try await http.send(req)
            if res.statusCode == 401 { throw HackbanError.signedOut }
        }
        return (data, res)
    }

    func decorate(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientId, forHTTPHeaderField: "x-client-id")
        req.setValue(String(-TimeZone.current.secondsFromGMT() / 60), forHTTPHeaderField: "x-tz-offset")
        req.setValue("hackban-desktop", forHTTPHeaderField: "x-trpc-source")
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, res) = try await authorized(request)
        return try Self.decode(data, status: res.statusCode)
    }

    static func decode<T: Decodable>(_ data: Data, status: Int) throws -> T {
        let decoder = JSONDecoder.hackban
        if !(200..<300).contains(status) {
            if let err = try? decoder.decode(TRPCErrorBody.self, from: data) { throw err.toError(status: status) }
            throw HackbanError.http(status: status, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        do {
            let r = try decoder.decode(TRPCResult<T>.self, from: data)
            if let v = r.result.data?.json { return v }
            if let n = Nothing() as? T { return n }
            throw HackbanError.decoding("empty result")
        } catch let e as HackbanError {
            throw e
        } catch {
            throw HackbanError.decoding(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return String(describing: error) }
        func path(_ ctx: DecodingError.Context) -> String { ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let ctx): return "missing \(k.stringValue) at \(path(ctx))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx): return "\(ctx.debugDescription) at \(path(ctx))"
        @unknown default: return String(describing: e)
        }
    }

    // MARK: - Plain routes (files, avatars, logos, export)

    /// GET a server-relative path (e.g. `/api/files/abc`) with auth. Absolute URLs on other hosts are
    /// fetched without credentials so a token never leaks to a third party.
    public func download(_ urlOrPath: String) async throws -> Data {
        guard let url = resolve(urlOrPath) else { throw HackbanError.badURL(urlOrPath) }
        let (data, res): (Data, HTTPURLResponse)
        if isSameOrigin(url) { (data, res) = try await authorized(URLRequest(url: url)) }
        else { (data, res) = try await http.send(URLRequest(url: url)) }
        guard (200..<300).contains(res.statusCode) else {
            throw HackbanError.http(status: res.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    public func upload(_ path: String, files: [(name: String, mimeType: String, data: Data)], method: String = "POST") async throws -> Data {
        var mp = Multipart()
        for f in files { mp.addFile(name: f.name, mimeType: f.mimeType, data: f.data) }
        var req = URLRequest(url: server.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(mp.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = mp.finished()
        let (data, res) = try await authorized(req)
        guard (200..<300).contains(res.statusCode) else {
            throw HackbanError.http(status: res.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    public func delete(_ path: String) async throws {
        var req = URLRequest(url: server.appendingPathComponent(path))
        req.httpMethod = "DELETE"
        let (data, res) = try await authorized(req)
        guard (200..<300).contains(res.statusCode) else {
            throw HackbanError.http(status: res.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    public func resolve(_ urlOrPath: String) -> URL? {
        if urlOrPath.hasPrefix("/") { return URL(string: urlOrPath, relativeTo: server)?.absoluteURL }
        return URL(string: urlOrPath)
    }

    public func isSameOrigin(_ url: URL) -> Bool {
        url.scheme == server.scheme && url.host == server.host && url.port == server.port
    }

    /// Link to a page on the web app (for things that stay in the browser).
    public func webURL(_ path: String) -> URL { URL(string: path, relativeTo: server)!.absoluteURL }
}
