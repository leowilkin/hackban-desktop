import AppKit
import AuthenticationServices
import Foundation
import HackbanKit

/// Browser sign-in: discover the server, register this app, then authorize with PKCE in an
/// ASWebAuthenticationSession (shares cookies with Safari, so an existing Hackban login is reused).
@MainActor
final class SignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(server: URL, http: HTTP) async throws -> AccountCredentials {
        let meta = try await OAuth.discover(server: server, http: http)
        let host = Host.current().localizedName ?? "Mac"
        let clientId = try await OAuth.register(meta, clientName: "Hackban for Mac (\(host))", http: http)
        let pkce = PKCE()
        let state = Data.random(count: 16).base64URL
        let url = OAuth.authorizeURL(meta, clientId: clientId, pkce: pkce, state: state)
        let callback = try await present(url)
        let code = try OAuth.code(fromCallback: callback, expectedState: state)
        let tokens = try await OAuth.exchange(code: code, verifier: pkce.verifier, clientId: clientId, tokenEndpoint: meta.token_endpoint, http: http)
        guard tokens.scope == "app" else { throw HackbanError.serverTooOld }
        return AccountCredentials(clientId: clientId, tokenEndpoint: meta.token_endpoint, tokens: tokens)
    }

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: OAuth.callbackScheme) { callback, error in
                if let callback { cont.resume(returning: callback) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: HackbanError.cancelled) }
                else { cont.resume(throwing: error ?? HackbanError.oauth("no response")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(throwing: HackbanError.oauth("couldn't open the sign-in window.")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}
