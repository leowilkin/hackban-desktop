import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What `board.onEvent` yields: something on the board (or one card on it) changed.
public struct BoardEvent: Decodable, Sendable, Equatable {
    public let boardId: String
    public let cardId: String?
    /// `x-client-id` of whoever caused it, so a client can skip its own echoes.
    public let origin: String?
    /// "board" | "card" | "deleted"
    public let kind: String
}

/// Incremental parser for text/event-stream. Feed it lines; it returns complete events.
public struct SSEParser: Sendable {
    public struct Event: Equatable, Sendable {
        public var event: String?
        public var data: String
        public var id: String?
    }

    private var event: String?
    private var data: [String] = []
    private var id: String?

    public init() {}

    /// Feed one line (without its terminator). A blank line dispatches the pending event.
    public mutating func feed(line: String) -> Event? {
        if line.isEmpty {
            defer { event = nil; data = []; id = nil }
            guard !data.isEmpty || event != nil else { return nil }
            return Event(event: event, data: data.joined(separator: "\n"), id: id)
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let i = line.firstIndex(of: ":") {
            field = line[..<i]
            value = line[line.index(after: i)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    /// The board event inside a tRPC SSE message, or nil for control events
    /// (`connected`, `ping`, `return`) and anything unparseable.
    public static func boardEvent(_ e: Event) -> BoardEvent? {
        guard e.event == nil || e.event == "message" else { return nil }
        let env = try? JSONDecoder().decode(SuperJSONEnvelope<BoardEvent>.self, from: Data(e.data.utf8))
        return env?.json
    }
}

#if canImport(Darwin)
public extension TRPCClient {
    /// Live updates for a board until the task is cancelled. Reconnects with backoff on errors and idle
    /// timeouts (the server sends no keep-alive pings). Yields `nil` after each (re)connect so callers
    /// can refetch whatever they missed while disconnected.
    func boardEvents(boardId: String) -> AsyncStream<BoardEvent?> {
        AsyncStream { continuation in
            let task = Task {
                var delay: UInt64 = 1
                while !Task.isCancelled {
                    do {
                        let input = try SuperJSON.encode(["id": .string(boardId)])
                        var c = URLComponents(url: endpoint("board.onEvent"), resolvingAgainstBaseURL: false)!
                        c.queryItems = [URLQueryItem(name: "input", value: String(decoding: input, as: UTF8.self))]
                        var req = URLRequest(url: c.url!)
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        // No pings from the server: allow long silences, reconnect if it's really dead.
                        req.timeoutInterval = 300
                        let token = try await tokens.accessToken()
                        decorate(&req, token: token)
                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 {
                            _ = try await tokens.accessToken(forceRefresh: true, rejected: token)
                            continue
                        }
                        guard status == 200 else { throw HackbanError.http(status: status, message: "Live updates unavailable") }
                        delay = 1
                        continuation.yield(nil)
                        var parser = SSEParser()
                        for try await line in bytes.lines {
                            // `lines` skips blank lines, so dispatch on every data line instead.
                            _ = parser.feed(line: line)
                            if line.hasPrefix("data:"), let e = parser.feed(line: ""), let ev = SSEParser.boardEvent(e) {
                                continuation.yield(ev)
                            }
                        }
                    } catch HackbanError.signedOut {
                        break
                    } catch {
                        if Task.isCancelled { break }
                    }
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
