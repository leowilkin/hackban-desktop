import Foundation

/// Any JSON value. Used for free-form payloads (activity and notification data) and for tRPC inputs.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    /// A date. Encoded as an ISO 8601 string; superjson needs it listed in `meta` (see `SuperJSON`).
    case date(Date)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .date(let d): try c.encode(ISODate.string(d))
        }
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return ISODate.string(d)
        default: return nil
        }
    }

    public var dateValue: Date? {
        switch self {
        case .date(let d): return d
        case .string(let s): return ISODate.parse(s)
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral v: String) { self = .string(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSONValue {
    /// `.string`, or `.null` for nil (a nullable field being cleared).
    static func optional(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    static func optional(_ d: Date?) -> JSONValue { d.map { .date($0) } ?? .null }
    static func strings(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }
}

/// ISO 8601 with milliseconds, as JavaScript's `Date#toJSON` writes it.
public enum ISODate {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }
    // ISO8601DateFormatter is thread-safe for formatting and parsing once configured.
    nonisolated(unsafe) private static let withMs = formatter(fractional: true)
    nonisolated(unsafe) private static let withoutMs = formatter(fractional: false)

    public static func string(_ d: Date) -> String { withMs.string(from: d) }
    public static func parse(_ s: String) -> Date? { withMs.date(from: s) ?? withoutMs.date(from: s) }
}

extension JSONDecoder {
    /// Decoder for Hackban responses: ISO dates with or without milliseconds.
    public static var hackban: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISODate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }
}
