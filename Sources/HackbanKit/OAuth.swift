import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tokens for one account. The refresh token rotates on every refresh, so persist after each one.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

/// Everything needed to keep an account signed in. Lives in the Keychain.
public struct AccountCredentials: Codable, Sendable, Equatable {
    public var clientId: String
    public var tokenEndpoint: URL
    public var tokens: OAuthTokens

    public init(clientId: String, tokenEndpoint: URL, tokens: OAuthTokens) {
        self.clientId = clientId
        self.tokenEndpoint = tokenEndpoint
        self.tokens = tokens
    }
}

/// RFC 8414 authorization server metadata (served at /.well-known/oauth-authorization-server).
public struct ServerMetadata: Decodable, Sendable {
    public let issuer: String?
    public let authorization_endpoint: URL
    public let token_endpoint: URL
    public let registration_endpoint: URL?
    public let scopes_supported: [String]?
}

public enum OAuth {
    public static let callbackScheme = "hackban-desktop"
    public static let redirectURI = "hackban-desktop://oauth/callback"

    /// "hackban.example.com" or "https://hackban.example.com/b/123" → "https://hackban.example.com".
    /// http is kept only when typed explicitly (local development servers).
    public static func normalizeServer(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw HackbanError.badURL(raw) }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty,
              c.scheme == "https" || c.scheme == "http"
        else { throw HackbanError.badURL(raw) }
        c.path = ""
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        guard let url = c.url else { throw HackbanError.badURL(raw) }
        return url
    }

    public static func discover(server: URL, http: HTTP) async throws -> ServerMetadata {
        let url = server.appendingPathComponent(".well-known/oauth-authorization-server")
        let (data, res) = try await http.send(URLRequest(url: url))
        guard res.statusCode == 200 else {
            if res.statusCode == 404 { throw HackbanError.serverTooOld }
            throw HackbanError.http(status: res.statusCode, message: "Couldn't reach Hackban at \(server.host ?? server.absoluteString).")
        }
        let meta: ServerMetadata
        do { meta = try JSONDecoder().decode(ServerMetadata.self, from: data) }
        catch { throw HackbanError.oauth("\(server.absoluteString) doesn't look like a Hackban server.") }
        guard meta.scopes_supported?.contains("app") == true, meta.registration_endpoint != nil else {
            throw HackbanError.serverTooOld
        }
        return meta
    }

    /// RFC 7591 dynamic registration as a public client (PKCE, no secret).
    public static func register(_ meta: ServerMetadata, clientName: String, http: HTTP) async throws -> String {
        guard let endpoint = meta.registration_endpoint else { throw HackbanError.serverTooOld }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "client_name": .string(clientName),
            "redirect_uris": [.string(redirectURI)],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ]
        req.httpBody = try JSONEncoder().encode(body)
        let (data, res) = try await http.send(req)
        struct Reg: Decodable { let client_id: String }
        guard (200..<300).contains(res.statusCode), let reg = try? JSONDecoder().decode(Reg.self, from: data) else {
            throw HackbanError.oauth("the server refused to register this app (\(res.statusCode)).")
        }
        return reg.client_id
    }

    public static func authorizeURL(_ meta: ServerMetadata, clientId: String, pkce: PKCE, state: String) -> URL {
        var c = URLComponents(url: meta.authorization_endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "scope", value: "app"),
        ]
        return c.url!
    }

    /// The code from `hackban-desktop://oauth/callback?code=…&state=…`.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let get = { (n: String) in items.first { $0.name == n }?.value }
        if let err = get("error") {
            throw err == "access_denied" ? HackbanError.cancelled : HackbanError.oauth(get("error_description") ?? err)
        }
        guard get("state") == expectedState else { throw HackbanError.oauth("the sign-in response didn't match this request.") }
        guard let code = get("code") else { throw HackbanError.oauth("no authorization code came back.") }
        return code
    }

    public static func exchange(code: String, verifier: String, clientId: String, tokenEndpoint: URL, http: HTTP) async throws -> OAuthTokens {
        try await tokenRequest(tokenEndpoint, http: http, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
    }

    public static func refresh(_ creds: AccountCredentials, http: HTTP) async throws -> OAuthTokens {
        try await tokenRequest(creds.tokenEndpoint, http: http, [
            "grant_type": "refresh_token",
            "refresh_token": creds.tokens.refreshToken,
            "client_id": creds.clientId,
        ])
    }

    private static func tokenRequest(_ endpoint: URL, http: HTTP, _ form: [String: String]) async throws -> OAuthTokens {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(formEncode(form).utf8)
        let (data, res) = try await http.send(req)
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let scope: String?
        }
        struct ErrorResponse: Decodable { let error: String }
        guard res.statusCode == 200 else {
            let err = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ?? "HTTP \(res.statusCode)"
            if err == "invalid_grant" || err == "invalid_client" { throw HackbanError.signedOut }
            throw HackbanError.oauth(err)
        }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: t.access_token,
            refreshToken: t.refresh_token,
            expiresAt: Date().addingTimeInterval(t.expires_in ?? 3600),
            scope: t.scope
        )
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { k in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(form[k]!.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }
}

/// Hands out a fresh access token, refreshing (once, even under concurrent callers) when it's about to
/// expire. Refresh tokens are single-use and a replay revokes the whole grant on the server, so two
/// refreshes must never race.
public actor TokenManager {
    private var creds: AccountCredentials?
    private let http: HTTP
    private let persist: @Sendable (AccountCredentials?) -> Void
    private var inFlight: Task<OAuthTokens, Error>?

    public init(credentials: AccountCredentials?, http: HTTP, persist: @escaping @Sendable (AccountCredentials?) -> Void) {
        self.creds = credentials
        self.http = http
        self.persist = persist
    }

    public var isSignedIn: Bool { creds != nil }

    public func set(_ c: AccountCredentials?) {
        creds = c
        persist(c)
    }

    /// A valid access token. `forceRefresh` after a 401 on a token we thought was valid.
    public func accessToken(forceRefresh: Bool = false, rejected: String? = nil) async throws -> String {
        guard let c = creds else { throw HackbanError.signedOut }
        // Someone else already refreshed since the rejected token was handed out.
        if let rejected, rejected != c.tokens.accessToken { return c.tokens.accessToken }
        if !forceRefresh, c.tokens.expiresAt.timeIntervalSinceNow > 60 { return c.tokens.accessToken }
        if let t = inFlight { return try await t.value.accessToken }
        let http = self.http
        let task = Task { try await OAuth.refresh(c, http: http) }
        inFlight = task
        defer { inFlight = nil }
        do {
            let tokens = try await task.value
            var next = c
            next.tokens = tokens
            set(next)
            return tokens.accessToken
        } catch HackbanError.signedOut {
            set(nil)
            throw HackbanError.signedOut
        }
    }
}
