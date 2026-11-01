import Foundation

public enum HackbanError: LocalizedError, Equatable {
    /// The server answered with a tRPC error (`code` is e.g. "FORBIDDEN", "NOT_FOUND", "BAD_REQUEST").
    case server(code: String, status: Int, message: String)
    /// Plain HTTP failure outside tRPC (file routes).
    case http(status: Int, message: String)
    /// The account's tokens are gone or were revoked; the user has to sign in again.
    case signedOut
    /// The server is reachable but doesn't support native-app sign-in yet.
    case serverTooOld
    case badURL(String)
    case oauth(String)
    case decoding(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message): return message
        case .http(let status, let message): return message.isEmpty ? "Request failed (\(status))." : message
        case .signedOut: return "You've been signed out. Sign in again from Settings → Accounts."
        case .serverTooOld:
            return "This Hackban server doesn't support the Mac app yet. It needs a version with native app sign-in (scope \"app\")."
        case .badURL(let s): return "\(s) isn't a valid server address."
        case .oauth(let s): return "Sign-in failed: \(s)"
        case .decoding(let s): return "Unexpected response from the server: \(s)"
        case .cancelled: return "Cancelled."
        }
    }

    public var isAuthFailure: Bool {
        switch self {
        case .signedOut: return true
        case .server(let code, let status, _): return code == "UNAUTHORIZED" || status == 401
        case .http(let status, _): return status == 401
        default: return false
        }
    }
}

/// tRPC error body: `{"error": {"json": {"message", "code", "data": {"code", "httpStatus", "zodError"}}}}`.
struct TRPCErrorBody: Decodable {
    struct Shape: Decodable {
        struct Data: Decodable {
            let code: String?
            let httpStatus: Int?
            let zodError: ZodError?
        }
        let message: String?
        let data: Data?
    }
    struct ZodError: Decodable {
        let formErrors: [String]?
        let fieldErrors: [String: [String]]?
    }
    let error: SuperJSONEnvelope<Shape>

    func toError(status: Int) -> HackbanError {
        let shape = error.json
        let code = shape?.data?.code ?? "INTERNAL_SERVER_ERROR"
        var message = shape?.message ?? "Something went wrong."
        // Zod validation errors put a JSON dump in `message`; prefer the readable field errors.
        if let z = shape?.data?.zodError {
            let parts = (z.formErrors ?? []) + (z.fieldErrors ?? [:]).sorted { $0.key < $1.key }.flatMap { k, v in v.map { "\(k): \($0)" } }
            if !parts.isEmpty { message = parts.joined(separator: "\n") }
        }
        return .server(code: code, status: shape?.data?.httpStatus ?? status, message: message)
    }
}
