import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The transport, so tests can swap in canned responses.
public protocol HTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTP: HTTP, @unchecked Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    let ns = error as NSError
                    cont.resume(throwing: ns.code == NSURLErrorCancelled ? HackbanError.cancelled : error)
                } else if let http = response as? HTTPURLResponse {
                    cont.resume(returning: (data ?? Data(), http))
                } else {
                    cont.resume(throwing: HackbanError.http(status: 0, message: "No response."))
                }
            }
            task.resume()
        }
    }
}

/// multipart/form-data body for the file routes (field name "file").
public struct Multipart {
    public let boundary = "hackban-\(UUID().uuidString)"
    public private(set) var body = Data()

    public init() {}

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addFile(field: String = "file", name: String, mimeType: String, data: Data) {
        let safe = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(safe)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public func finished() -> Data {
        var b = body
        b.append(Data("--\(boundary)--\r\n".utf8))
        return b
    }
}

public enum MimeType {
    public static func guess(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }
}
