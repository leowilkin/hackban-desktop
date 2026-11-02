import Foundation

/// One account's offline data on disk: what the server last said, and the changes waiting to sync.
///
///     <root>/account.json      profile, workspaces, boards in the sidebar, notifications, my cards
///     <root>/boards/<id>.json  the last board.get of each board you've opened
///     <root>/cards/<id>.json   the last card.get of each card you've opened
///     <root>/queue.json        the OfflineQueue
///
/// Every file is `{"version": 1, "savedAt": "…", "data": …}`, written atomically. A file with another
/// version reads as missing; `setAside` moves one out of the way without losing it.
public final class OfflineStore: @unchecked Sendable {
    public static let formatVersion = 1

    public let root: URL
    private let io = DispatchQueue(label: "hackban.offline-store")
    /// Background saves not written yet, by path. Only touched on `io`.
    private var waiting: [String: @Sendable () throws -> Data] = [:]

    public init(root: URL) { self.root = root }

    private struct Header: Decodable {
        let version: Int
        let savedAt: Date
    }

    private struct Envelope<T: Encodable>: Encodable {
        let version: Int
        let savedAt: Date
        let data: T
    }

    private struct Contents<T: Decodable>: Decodable {
        let data: T
    }

    /// ISO 8601 dates with milliseconds, which `JSONDecoder.hackban` reads back exactly.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.string(date))
        }
        return e
    }

    public func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    /// A file name for an id (ids are cuids, but never trust them with a path).
    public static func file(_ folder: String, _ id: String) -> String {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return "\(folder)/\(String(safe)).json"
    }

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    public func load<T: Decodable>(_ type: T.Type, _ path: String) -> (value: T, savedAt: Date)? {
        guard let data = try? Data(contentsOf: url(path)) else { return nil }
        let d = JSONDecoder.hackban
        guard let h = try? d.decode(Header.self, from: data), h.version == Self.formatVersion,
              let c = try? d.decode(Contents<T>.self, from: data) else { return nil }
        return (c.data, h.savedAt)
    }

    static func encode<T: Encodable>(_ value: T, savedAt: Date) throws -> Data {
        try encoder().encode(Envelope(version: formatVersion, savedAt: savedAt, data: value))
    }

    private func writeData(_ data: Data, _ path: String) throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
    }

    /// Writes now, on this thread. For the queue, which must be on disk before the next request goes out.
    public func write<T: Encodable>(_ value: T, _ path: String, savedAt: Date = Date()) throws {
        let data = try Self.encode(value, savedAt: savedAt)
        try io.sync {
            waiting[path] = nil
            try writeData(data, path)
        }
    }

    /// Writes in the background after `delay`, keeping only the newest value if it's saved again meanwhile
    /// (a board refetched on every live update is written once).
    public func save<T: Encodable & Sendable>(_ value: T, _ path: String, savedAt: Date = Date(), delay: TimeInterval = 1) {
        io.async {
            let scheduled = self.waiting[path] != nil
            self.waiting[path] = { try Self.encode(value, savedAt: savedAt) }
            if !scheduled {
                self.io.asyncAfter(deadline: .now() + delay) { self.writeWaiting(path) }
            }
        }
    }

    private func writeWaiting(_ path: String) {
        guard let make = waiting.removeValue(forKey: path) else { return }
        try? writeData(make(), path)
    }

    /// Writes every background save now.
    public func flush() {
        io.sync { for path in Array(waiting.keys) { writeWaiting(path) } }
    }

    public func remove(_ path: String) {
        io.sync {
            waiting[path] = nil
            try? FileManager.default.removeItem(at: url(path))
        }
    }

    public func removeAll() {
        io.sync {
            waiting = [:]
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Moves a file it can't read out of the way, so it's never overwritten, and returns where it went.
    @discardableResult
    public func setAside(_ path: String, now: Date = Date()) -> URL? {
        let from = url(path)
        guard FileManager.default.fileExists(atPath: from.path) else { return nil }
        let stamp = Int(now.timeIntervalSince1970)
        let to = from.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        return io.sync { (try? FileManager.default.moveItem(at: from, to: to)) != nil ? to : nil }
    }

    /// Deletes all but the `keep` most recently written files in `folder`, never touching `except`.
    public func prune(_ folder: String, keep: Int, except: Set<String> = []) {
        io.sync {
            let fm = FileManager.default
            let dir = url(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            let files: [(name: String, date: Date)] = names.filter { $0.hasSuffix(".json") }.map { name in
                let date = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
                return (name, date ?? .distantPast)
            }
            let protected = Set(except.map { (Self.file(folder, $0) as NSString).lastPathComponent })
            for f in files.sorted(by: { $0.date > $1.date }).dropFirst(keep) where !protected.contains(f.name) {
                try? fm.removeItem(at: dir.appendingPathComponent(f.name))
            }
        }
    }
}
