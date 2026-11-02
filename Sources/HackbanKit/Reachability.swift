import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a failed request means for the change that made it.
public enum FailureKind: Equatable, Sendable {
    /// The server couldn't be reached: go offline and keep the change.
    case offline
    /// The server had a problem: try again a little later, then give up on the change.
    case retryLater
    case signedOut
    /// The server said no: the change fails.
    case rejected
    case cancelled
}

public enum Reachability {
    /// URL errors that mean the server (or the network) isn't there.
    static let unreachable: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
        .timedOut, .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]

    /// URL errors raised before anything was sent.
    static let neverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive, .badURL, .unsupportedURL,
    ]

    static func urlErrorCode(_ error: Error) -> URLError.Code? {
        if let e = error as? URLError { return e.code }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain ? URLError.Code(rawValue: ns.code) : nil
    }

    public static func classify(_ error: Error) -> FailureKind {
        if let e = error as? AfterChangeError { return classify(e.underlying) }
        if let code = urlErrorCode(error) {
            if code == .cancelled { return .cancelled }
            return unreachable.contains(code) ? .offline : .retryLater
        }
        guard let e = error as? HackbanError else { return .rejected }
        if e.isAuthFailure { return .signedOut }
        switch e {
        case .cancelled: return .cancelled
        // Refreshing the token failed for some reason other than a revoked grant: the server's in trouble.
        case .oauth: return .offline
        case .http(let status, _), .server(_, let status, _):
            switch status {
            // 0 = no response; 502–504 = a proxy in front of a server that's down.
            case 0, 502, 503, 504: return .offline
            case 408, 425, 429, 500...599: return .retryLater
            default: return .rejected
            }
        default: return .rejected
        }
    }

    /// Whether the server may have carried out a request that failed. A create that may have happened is
    /// looked for before it's sent again.
    public static func mayHaveReachedServer(_ error: Error) -> Bool {
        if error is AfterChangeError { return true }
        if let code = urlErrorCode(error) { return !neverSent.contains(code) }
        guard let e = error as? HackbanError else { return true }
        switch e {
        // Stopped at the token, or turned away before anything ran.
        case .signedOut, .oauth, .badURL, .serverTooOld: return false
        case .http(let status, _), .server(_, let status, _):
            if e.isAuthFailure { return false }
            return status == 0 || (status >= 500 && status != 503)
        default: return true
        }
    }
}
